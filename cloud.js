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
    explain(err) {
      const m = String((err && err.message) || err || "").toLowerCase();
      if (m.includes("invalid login") || m.includes("invalid credentials")) return "Email or password isn't right.";
      if (m.includes("already registered") || m.includes("already been registered")) return "There's already an account with that email. Try signing in.";
      if (m.includes("password") && m.includes("least")) return "Password needs at least 6 characters.";
      if (m.includes("valid email") || m.includes("invalid email")) return "That email address doesn't look right.";
      if (m.includes("failed to fetch") || m.includes("network")) return "No connection. Try again when you're online.";
      if (m.includes("rate limit") || m.includes("too many")) return "Too many tries. Wait a minute and try again.";
      if (m.includes("relation") && m.includes("does not exist")) return "The cheatday table isn't in Supabase yet. See the README.";
      return (err && err.message) || "Something went wrong.";
    }
  };
})();
