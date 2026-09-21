// Cheat Days reminders and friend notifications (Web Push).
// Deploy: Supabase dashboard -> Edge Functions -> Deploy a new function -> name it "push", paste this, Deploy,
// then turn OFF "Verify JWT" (the scheduled check calls it without a login; actions that need one check it themselves).
// Needs the push_config and push_subs tables and a cron job (SQL in the README). No secrets to set: the signing keys
// are made on first use and kept in push_config, which only this function can read.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (obj: unknown, status = 200) => new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const APP_URL = "https://domchivers.github.io/cheat-day/";

let keys: { public_key: string; private_key: string } | null = null;
async function vapid() {
  if (keys) return keys;
  const { data } = await admin.from("push_config").select("public_key, private_key").eq("id", 1).maybeSingle();
  if (data) keys = data;
  else {
    const k = webpush.generateVAPIDKeys();
    keys = { public_key: k.publicKey, private_key: k.privateKey };
    await admin.from("push_config").upsert({ id: 1, ...keys });
  }
  webpush.setVapidDetails("mailto:reminders@cheatdays.app", keys.public_key, keys.private_key);
  return keys;
}

type Sub = { endpoint: string; user_id: string; p256dh: string; auth: string; tz: string | null; prefs: any; last_lunch: string | null; last_weigh: string | null };
/** Send to one subscription; a gone subscription (404/410) is removed. */
async function send(sub: Sub, payload: { title: string; body: string; url?: string; tag?: string }) {
  await vapid();
  try {
    await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, JSON.stringify({ url: APP_URL, ...payload }), { TTL: 3600 });
    return true;
  } catch (e) {
    const code = (e as any).statusCode;
    if (code === 404 || code === 410) await admin.from("push_subs").delete().eq("endpoint", sub.endpoint);
    return false;
  }
}
async function sendToUser(userId: string, payload: { title: string; body: string; url?: string; tag?: string }, pref?: string) {
  const { data } = await admin.from("push_subs").select("*").eq("user_id", userId);
  let n = 0;
  for (const s of (data || []) as Sub[]) { if (pref && s.prefs && s.prefs[pref] === false) continue; if (await send(s, payload)) n++; }
  return n;
}
/** Local date and minutes-past-midnight in a time zone. */
function localNow(tz: string | null) {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: tz || "Australia/Melbourne", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(new Date());
  const g = (t: string) => parts.find((p) => p.type === t)?.value || "00";
  return { date: `${g("year")}-${g("month")}-${g("day")}`, mins: +g("hour") * 60 + +g("minute") };
}
const toMins = (hhmm: string) => { const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm || ""); return m ? +m[1] * 60 + +m[2] : null; };

/** Every 15 minutes: lunchtime nudge if nothing's logged, and the weigh-in reminder at the chosen time. */
async function tick() {
  const { data: subs } = await admin.from("push_subs").select("*");
  const list = (subs || []) as Sub[];
  const users = [...new Set(list.map((s) => s.user_id))];
  const days: Record<string, any> = {};
  if (users.length) { const { data } = await admin.from("cheatday").select("user_id, data").in("user_id", users); for (const r of data || []) days[r.user_id] = r.data || {}; }
  let sent = 0;
  for (const s of list) {
    const now = localNow(s.tz), prefs = s.prefs || {}, st = days[s.user_id] || {};
    const loggedToday = st.day && st.day.date === now.date && Array.isArray(st.day.items) && st.day.items.length > 0;
    if (prefs.lunch !== false && now.mins >= 14 * 60 && now.mins < 20 * 60 && s.last_lunch !== now.date) {
      if (!loggedToday && await send(s, { title: "Nothing logged yet today", body: "Take a moment to add what you've had so far.", tag: "lunch" })) sent++;
      await admin.from("push_subs").update({ last_lunch: now.date }).eq("endpoint", s.endpoint);
    }
    const w = toMins(prefs.weigh);
    if (w != null && now.mins >= w && now.mins < w + 180 && s.last_weigh !== now.date) {
      const weighed = Array.isArray(st.body) && st.body.some((r: any) => r.day === now.date && r.weight);
      if (!weighed && await send(s, { title: "Time to weigh in", body: "Step on the scale, then screenshot the result into Cheat Days.", tag: "weigh" })) sent++;
      await admin.from("push_subs").update({ last_weigh: now.date }).eq("endpoint", s.endpoint);
    }
  }
  return { checked: list.length, sent };
}

Deno.serve(async (req) => {
  try { return await handle(req); } catch (e) { return json({ error: `Function error: ${(e as Error).message}` }, 500); }
});

async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let body: any = {}; try { body = await req.json(); } catch {}
  const action = String(body.action || "");
  if (action === "tick") return json(await tick());
  if (action === "key") return json({ publicKey: (await vapid()).public_key });

  // Everything else needs the person's own login
  const user = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } } });
  const { data: { user: me } } = await user.auth.getUser();
  if (!me) return json({ error: "Sign in to use this" }, 401);

  if (action === "subscribe") {
    const sub = body.subscription || {};
    if (!sub.endpoint || !sub.keys?.p256dh || !sub.keys?.auth) return json({ error: "Bad subscription" }, 400);
    await admin.from("push_subs").upsert({ endpoint: sub.endpoint, user_id: me.id, p256dh: sub.keys.p256dh, auth: sub.keys.auth, tz: String(body.tz || ""), prefs: body.prefs || {} }, { onConflict: "endpoint" });
    return json({ ok: true });
  }
  if (action === "prefs") {
    await admin.from("push_subs").update({ prefs: body.prefs || {}, tz: String(body.tz || "") }).eq("user_id", me.id);
    return json({ ok: true });
  }
  if (action === "unsubscribe") {
    if (body.endpoint) await admin.from("push_subs").delete().eq("endpoint", body.endpoint).eq("user_id", me.id);
    else await admin.from("push_subs").delete().eq("user_id", me.id);
    return json({ ok: true });
  }
  if (action === "test") {
    const n = await sendToUser(me.id, { title: "Reminders are on", body: "This is what a Cheat Days reminder looks like.", tag: "test" });
    return json({ ok: true, sent: n });
  }
  if (action === "notify") {
    // A friend reacted, commented or sent food: only between accepted friends
    const to = String(body.to || ""); if (!to || to === me.id) return json({ ok: true, sent: 0 });
    const { data: fs } = await admin.from("friendships").select("id").eq("status", "accepted").or(`and(requester.eq.${me.id},addressee.eq.${to}),and(requester.eq.${to},addressee.eq.${me.id})`).limit(1);
    if (!fs || !fs.length) return json({ error: "Not friends" }, 403);
    const { data: prof } = await admin.from("profiles").select("display_name").eq("user_id", me.id).maybeSingle();
    const who = (prof && prof.display_name) || "A friend", what = String(body.text || "").slice(0, 80);
    const msg = body.kind === "comment" ? { title: `${who} commented`, body: what || "on your post" }
      : body.kind === "send" ? { title: `${who} sent you food`, body: what ? `${what}: tap to add it to your day` : "Tap to add it to your day" }
      : { title: `${who} reacted ${String(body.emoji || "").slice(0, 4)}`, body: what ? `to ${what}` : "to your post" };
    const n = await sendToUser(to, { ...msg, tag: `social-${body.kind || "react"}` }, "social");
    return json({ ok: true, sent: n });
  }
  return json({ error: "Unknown action" }, 400);
}
