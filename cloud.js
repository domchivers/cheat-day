/* Accounts and sync through Supabase, the same project the Chinese app uses, so one
 * email + password works in both. Plain fetch() against the REST API, no SDK.
 *
 * LOCAL-FIRST: localStorage stays the source of truth and everything works offline.
 * Signing in adds a cloud copy in the `cheatday` table (one row per user, JSON in `data`).
 *
 * The project URL and public anon key live in supabase-config.js. The anon key is PUBLIC
 * by design; row-level security in Postgres is what protects the data. The service_role
 * key must never appear anywhere in this app. */
"use strict";

(function () {
  const cfg = window.SUPABASE_CONFIG;
  if (!cfg || !cfg.url || !cfg.anonKey) { window.cloud = null; return; }
  const SUPABASE_URL = cfg.url, SUPABASE_ANON_KEY = cfg.anonKey;
  const TABLE = "cheatday";
  const LS_SESSION = "cheatday.session.v1";

  let session = (() => { try { return JSON.parse(localStorage.getItem(LS_SESSION)) || null; } catch (e) { return null; } })();
  const authListeners = [];
  const signedIn = () => !!(session && session.access_token);
  const userOf = () => signedIn() ? { id: session.user.id, email: session.user.email } : null;
  function setSession(s) {
    session = s;
    try { if (s) localStorage.setItem(LS_SESSION, JSON.stringify(s)); else localStorage.removeItem(LS_SESSION); } catch (e) {}
    authListeners.forEach((cb) => cb(userOf()));
  }

  function sb(path, opts = {}, useAuth = true) {
    const headers = Object.assign({ apikey: SUPABASE_ANON_KEY, "Content-Type": "application/json" }, opts.headers || {});
    if (useAuth && signedIn()) headers.Authorization = `Bearer ${session.access_token}`;
    return fetch(SUPABASE_URL + path, Object.assign({}, opts, { headers }));
  }
  // Access tokens expire after about an hour: refresh once and replay. Only a definite
  // rejection of the refresh token ends the session, never a network blip.
  async function sbAuthed(path, opts = {}) {
    const r = await sb(path, opts);
    if (r.status !== 401 || !session || !session.refresh_token) return r;
    let rr;
    try {
      rr = await sb("/auth/v1/token?grant_type=refresh_token", { method: "POST", body: JSON.stringify({ refresh_token: session.refresh_token }) }, false);
    } catch (e) { return r; }
    if (!rr.ok) { if (rr.status === 400 || rr.status === 401) setSession(null); return r; }
    setSession(await rr.json());
    return sb(path, opts);
  }
  async function authError(r, fallback) {
    const j = await r.json().catch(() => ({}));
    return new Error(j.error_description || j.msg || j.message || j.error || fallback);
  }

  window.cloud = {
    get user() { return userOf(); },
    onAuth(cb) { authListeners.push(cb); },
    async signIn(email, password) {
      const r = await sb("/auth/v1/token?grant_type=password", { method: "POST", body: JSON.stringify({ email, password }) }, false);
      if (!r.ok) throw await authError(r, "Sign-in failed");
      setSession(await r.json());
    },
    /** Resolves true when signed in straight away, false when Supabase wants the email confirmed first. */
    async signUp(email, password) {
      const r = await sb("/auth/v1/signup", { method: "POST", body: JSON.stringify({ email, password }) }, false);
      if (!r.ok) throw await authError(r, "Sign-up failed");
      const j = await r.json();
      if (j.access_token) { setSession(j); return true; }
      return false;
    },
    async signOut() { setSession(null); },   // local data is deliberately left alone
    async resetPassword(email) {
      const r = await sb("/auth/v1/recover", { method: "POST", body: JSON.stringify({ email }) }, false);
      if (!r.ok) throw await authError(r, "Couldn't send the reset email");
    },
    /** The cloud copy, or null if this account hasn't saved one yet. */
    async pull() {
      if (!signedIn()) return null;
      const r = await sbAuthed(`/rest/v1/${TABLE}?user_id=eq.${session.user.id}&select=data,updated_at`);
      if (!r.ok) throw await authError(r, `Couldn't read from the cloud (${r.status})`);
      const rows = await r.json();
      return rows.length ? rows[0].data : null;
    },
    async push(data) {
      if (!signedIn()) return;
      const r = await sbAuthed(`/rest/v1/${TABLE}`, {
        method: "POST",
        headers: { Prefer: "resolution=merge-duplicates" },
        body: JSON.stringify([{ user_id: session.user.id, data, updated_at: new Date().toISOString() }])
      });
      if (!r.ok) throw await authError(r, `Couldn't save to the cloud (${r.status})`);
    },
    // ---- friends: profiles with a friend code, requests, accepted friendships
    get uid() { return signedIn() ? session.user.id : null; },
    /** A fetch that carries the user's token and refreshes it if needed; for the app's own Edge Functions. */
    async rawFetch(url, opts = {}) {
      const go = () => fetch(url, Object.assign({}, opts, { headers: Object.assign({}, opts.headers || {}, signedIn() ? { Authorization: `Bearer ${session.access_token}` } : {}) }));
      let r = await go();
      if (r.status === 401 && session && session.refresh_token) {
        const rr = await sb("/auth/v1/token?grant_type=refresh_token", { method: "POST", body: JSON.stringify({ refresh_token: session.refresh_token }) }, false);
        if (rr.ok) { setSession(await rr.json()); r = await go(); }
      }
      return r;
    },
    async rest(path, opts = {}) {
      const r = await sbAuthed(path, opts);
      if (!r.ok) throw await authError(r, `Cloud request failed (${r.status})`);
      const text = await r.text();            // a successful insert comes back empty; don't try to parse nothing
      return text.trim() ? JSON.parse(text) : null;
    },
    async myProfile() { const rows = await this.rest(`/rest/v1/profiles?user_id=eq.${this.uid}&select=*`); return rows[0] || null; },
    async saveProfile(displayName, friendCode) {
      return this.rest(`/rest/v1/profiles`, { method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=representation" },
        body: JSON.stringify([{ user_id: this.uid, display_name: displayName, friend_code: friendCode, updated_at: new Date().toISOString() }]) });
    },
    async findByCode(code) { const rows = await this.rest(`/rest/v1/profiles?friend_code=eq.${encodeURIComponent(code)}&select=user_id,display_name,friend_code`); return rows[0] || null; },
    async profiles(ids) { if (!ids.length) return []; return this.rest(`/rest/v1/profiles?user_id=in.(${ids.join(",")})&select=user_id,display_name,friend_code`); },
    async friendships() { return this.rest(`/rest/v1/friendships?select=*&order=created_at.desc`); },
    async requestFriend(otherId) { return this.rest(`/rest/v1/friendships`, { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify([{ requester: this.uid, addressee: otherId }]) }); },
    async acceptFriend(id) { return this.rest(`/rest/v1/friendships?id=eq.${id}`, { method: "PATCH", body: JSON.stringify({ status: "accepted" }) }); },
    async removeFriend(id) { return this.rest(`/rest/v1/friendships?id=eq.${id}`, { method: "DELETE" }); },
    async sharedMeals() { return this.rest(`/rest/v1/shared_meals?select=*&order=updated_at.desc`); },
    async shareMeal(m) {
      return this.rest(`/rest/v1/shared_meals?on_conflict=owner,meal_id`, { method: "POST", headers: { Prefer: "resolution=merge-duplicates" },
        body: JSON.stringify([{ owner: this.uid, meal_id: m.id, name: m.name, portions: m.portions, kcal_per_portion: m.kcalPerPortion, items: m.items, updated_at: new Date().toISOString() }]) });
    },
    async unshareMeal(mealId) { return this.rest(`/rest/v1/shared_meals?owner=eq.${this.uid}&meal_id=eq.${encodeURIComponent(mealId)}`, { method: "DELETE" }); },
    async publishDay(day) {
      return this.rest(`/rest/v1/days`, { method: "POST", headers: { Prefer: "resolution=merge-duplicates" },
        body: JSON.stringify([{ user_id: this.uid, day: day.date, budget: day.budget, kcal: day.kcal, items: day.items, updated_at: new Date().toISOString() }]) });
    },
    async unpublishDays() { return this.rest(`/rest/v1/days?user_id=eq.${this.uid}`, { method: "DELETE" }); },
    // ---- backups: daily cloud snapshots (kept by a database trigger) and my own shared day summaries
    async backups() { return this.rest(`/rest/v1/cheatday_backups?user_id=eq.${this.uid}&select=id,created_at,data&order=created_at.desc&limit=30`); },
    async myDays() { return this.rest(`/rest/v1/days?user_id=eq.${this.uid}&select=*&order=day.desc&limit=400`); },
    // ---- photos live in the public "photos" bucket, one folder per person, under unguessable names
    async uploadPhoto(dataUrl) {
      if (!signedIn()) throw new Error("Not signed in");
      const blob = await (await fetch(dataUrl)).blob();
      const path = `${session.user.id}/${crypto.randomUUID ? crypto.randomUUID() : Date.now() + "-" + Math.random().toString(36).slice(2)}.jpg`;
      const r = await this.rawFetch(`${SUPABASE_URL}/storage/v1/object/photos/${path}`, { method: "POST", headers: { apikey: SUPABASE_ANON_KEY, "Content-Type": blob.type || "image/jpeg", "x-upsert": "false", "cache-control": "31536000" }, body: blob });
      if (!r.ok) { let m = ""; try { m = (await r.json()).message || ""; } catch (e) {} const err = new Error(m || `Upload failed (${r.status})`); err.status = r.status; throw err; }
      return `${SUPABASE_URL}/storage/v1/object/public/photos/${path}`;
    },
    // ---- reminders and notifications, via the "push" edge function
    async pushCall(action, payload = {}) {
      const r = await this.rawFetch(`${SUPABASE_URL}/functions/v1/push`, { method: "POST", headers: { "Content-Type": "application/json", apikey: SUPABASE_ANON_KEY }, body: JSON.stringify({ action, ...payload }) });
      let data = null; try { data = await r.json(); } catch (e) {}
      if (r.status === 404) { const e = new Error("Reminders aren't set up on the server yet"); e.missing = true; throw e; }
      if (!r.ok) throw new Error((data && (data.error || data.message)) || `HTTP ${r.status}`);
      return data;
    },
    // ---- the leaderboard: each person's level, streaks and weekly goals, readable by friends
    async publishStats(row) { return this.rest(`/rest/v1/stats`, { method: "POST", headers: { Prefer: "resolution=merge-duplicates" }, body: JSON.stringify([{ user_id: this.uid, ...row, updated_at: new Date().toISOString() }]) }); },
    async stats() { return this.rest(`/rest/v1/stats?select=*`); },
    async days(sinceDate) { return this.rest(`/rest/v1/days?day=gte.${sinceDate}&select=*&order=day.desc`); },
    // ---- body metrics (scale readings) and the private token a Shortcut uses to post them
    async bodyRows(since) { return this.rest(`/rest/v1/body_metrics?user_id=eq.${this.uid}&day=gte.${since}&select=*&order=day.asc`); },
    async saveBodyRow(row) { return this.rest(`/rest/v1/body_metrics?on_conflict=user_id,day`, { method: "POST", headers: { Prefer: "resolution=merge-duplicates" }, body: JSON.stringify([{ user_id: this.uid, ...row, updated_at: new Date().toISOString() }]) }); },
    async importToken() { const rows = await this.rest(`/rest/v1/import_tokens?user_id=eq.${this.uid}&select=token`); return rows[0] ? rows[0].token : null; },
    async setImportToken(token) { return this.rest(`/rest/v1/import_tokens?on_conflict=user_id`, { method: "POST", headers: { Prefer: "resolution=merge-duplicates" }, body: JSON.stringify([{ user_id: this.uid, token }]) }); },
    // ---- sending an item to a friend so they can add it with one tap
    async inbox() { return this.rest(`/rest/v1/sends?to_user=eq.${this.uid}&status=eq.new&select=*&order=created_at.desc&limit=20`); },
    async sendItem(toUser, item) { return this.rest(`/rest/v1/sends`, { method: "POST", body: JSON.stringify([{ from_user: this.uid, to_user: toUser, ...item }]) }); },
    async settleSend(id, status) { return this.rest(`/rest/v1/sends?id=eq.${id}&to_user=eq.${this.uid}`, { method: "PATCH", body: JSON.stringify({ status }) }); },
    // ---- a helper (the app's owner) can set a friend's daily budget
    async setBudgetFor(userId, budget) {
      if (budget == null) return this.rest(`/rest/v1/budget_overrides?user_id=eq.${userId}`, { method: "DELETE" });
      return this.rest(`/rest/v1/budget_overrides`, { method: "POST", headers: { Prefer: "resolution=merge-duplicates" }, body: JSON.stringify([{ user_id: userId, budget, set_by: this.uid, updated_at: new Date().toISOString() }]) });
    },
    async budgetFor(userId) { const r = await this.rest(`/rest/v1/budget_overrides?user_id=eq.${userId}&select=*`); return (r || [])[0] || null; },
    async myBudgetOverride() { return this.budgetFor(this.uid); },
    // ---- the feed
    async posts(limit = 40) { return this.rest(`/rest/v1/posts?select=*&order=created_at.desc&limit=${limit}`); },
    async createPost(post) { return this.rest(`/rest/v1/posts`, { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify([{ owner: this.uid, ...post }]) }); },
    async deletePost(id) { return this.rest(`/rest/v1/posts?id=eq.${id}&owner=eq.${this.uid}`, { method: "DELETE" }); },
    async reactions(postIds) { if (!postIds.length) return []; return this.rest(`/rest/v1/reactions?post_id=in.(${postIds.join(",")})&select=post_id,user_id,emoji`); },
    async react(postId, emoji) { return this.rest(`/rest/v1/reactions`, { method: "POST", headers: { Prefer: "resolution=ignore-duplicates" }, body: JSON.stringify([{ post_id: postId, user_id: this.uid, emoji }]) }); },
    async unreact(postId, emoji) { return this.rest(`/rest/v1/reactions?post_id=eq.${postId}&user_id=eq.${this.uid}&emoji=eq.${encodeURIComponent(emoji)}`, { method: "DELETE" }); },
    async comments(postIds) { if (!postIds.length) return []; return this.rest(`/rest/v1/comments?post_id=in.(${postIds.join(",")})&select=*&order=created_at.asc`); },
    async comment(postId, text) { return this.rest(`/rest/v1/comments`, { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify([{ post_id: postId, user_id: this.uid, text }]) }); },
    async deleteComment(id) { return this.rest(`/rest/v1/comments?id=eq.${id}&user_id=eq.${this.uid}`, { method: "DELETE" }); },
    explain(err) {
      const m = String((err && err.message) || err || "").toLowerCase();
      if (m.includes("invalid login") || m.includes("invalid credentials")) return "Email or password isn't right.";
      if (m.includes("already registered") || m.includes("already been registered")) return "There's already an account with that email. Try signing in.";
      if (m.includes("password") && m.includes("least")) return "Password needs at least 6 characters.";
      if (m.includes("valid email") || m.includes("invalid email")) return "That email address doesn't look right.";
      if (m.includes("failed to fetch") || m.includes("network")) return "No connection. Try again when you're online.";
      if (m.includes("rate limit") || m.includes("too many")) return "Too many tries. Wait a minute and try again.";
      if (m.includes("schema cache") || (m.includes("relation") && m.includes("does not exist"))) return "A table is missing in Supabase. Run the SQL from the README.";
      if (m.includes("duplicate key") && m.includes("friendships")) return "You've already sent that person a request.";
      if (m.includes("duplicate key") && m.includes("friend_code")) return "That code clashed; try saving again.";
      return (err && err.message) || "Something went wrong.";
    }
  };
})();
