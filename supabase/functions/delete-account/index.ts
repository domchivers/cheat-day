// Cheat Days: delete the signed-in person's account, as App Store guideline 5.1.1(v) asks, with 30 days to change
// their mind (1.4.75). Needs supabase/account_grace.sql run first.
// Deploy: Supabase dashboard -> Edge Functions -> delete-account -> paste this, Deploy. Leave "Verify JWT" on.
//
// From the app:   POST { confirm: "delete", password }
//   -> the password is checked (401 when wrong), the account is marked to go in 30 days (hidden from everyone else
//      straight away), it's signed out on every device and emailed. { pending: true, delete_after }
//   -> an account with no profile (it never shared anything) is erased at once: { deleted: true }
// Nightly:        POST { sweep: true } with the service role key as the bearer token (Integrations -> Cron ->
//   an Edge Function job, once a day) -> erases every account past its date: { erased: n }
//
// Erasing: 1. their photos in storage (photos/<user id>/...) 2. their rows in the tables made in the dashboard,
// which may not cascade (the ones in supabase/*.sql do) 3. the sign-in itself, which takes every cascading table.
// The email goes out only when RESEND_API_KEY and MAIL_FROM are set in the function's secrets; without them
// everything else still works.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (obj: unknown, status = 200) => new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });
const URL_ = Deno.env.get("SUPABASE_URL")!, SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(URL_, SERVICE);
const GRACE_DAYS = 30;

// table -> the columns that can hold the person's id (a missing table or column is skipped)
const OWN: Record<string, string[]> = {
  days: ["user_id"], cheatday: ["user_id"], cheatday_backups: ["user_id"], body_metrics: ["user_id"], stats: ["user_id"],
  budget_overrides: ["user_id", "set_by"], helper_edits: ["user_id", "helper"], family_links: ["helper", "member"],
  friendships: ["requester", "addressee"], sends: ["from_user", "to_user"], shared_meals: ["owner"],
  comments: ["author", "user_id"], reactions: ["user_id"], posts: ["owner"], push_subs: ["user_id"], profiles: ["user_id"],
};

async function removePhotos(uid: string) {
  const bucket = admin.storage.from("photos");
  for (let round = 0; round < 50; round++) {
    const { data, error } = await bucket.list(uid, { limit: 1000 });
    if (error || !data?.length) return;
    const paths = data.filter((f) => f.name).map((f) => `${uid}/${f.name}`);
    if (!paths.length) return;
    await bucket.remove(paths);
  }
}

// for good: photos, rows, then the sign-in
async function erase(uid: string): Promise<boolean> {
  await removePhotos(uid);
  for (const [table, cols] of Object.entries(OWN)) for (const col of cols) {
    const { error } = await admin.from(table).delete().eq(col, uid);
    if (error && !/does not exist|column|relation|schema cache/i.test(error.message)) console.log("delete", table, col, error.message);
  }
  const { error } = await admin.auth.admin.deleteUser(uid);
  if (error) console.log("deleteUser", uid, error.message);
  return !error;
}

async function email(to: string, when: Date) {
  const key = Deno.env.get("RESEND_API_KEY"), from = Deno.env.get("MAIL_FROM");
  if (!key || !from) { console.log("no mail service set: skipped the deletion email"); return; }
  const date = when.toLocaleDateString("en-AU", { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: "Australia/Sydney" });
  const text = `Your Cheat Days account will be deleted on ${date}.\n\nIf this wasn't you, or you've changed your mind, sign in to the app before then and it won't be deleted.\n\nCheat Days`;
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to, subject: "Your Cheat Days account will be deleted", text }),
  }).catch((e) => { console.log("email failed", String(e)); return null; });
  if (r && !r.ok) console.log("email failed", r.status, await r.text());
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const body = await req.json().catch(() => ({}));

  // the nightly job: only with the service role key
  if (body?.sweep === true) {
    if (token !== SERVICE) return json({ error: "Not allowed" }, 401);
    const { data, error } = await admin.from("profiles").select("user_id").lt("delete_after", new Date().toISOString()).limit(500);
    if (error) return json({ error: error.message }, 500);
    let erased = 0;
    for (const row of data ?? []) if (await erase(row.user_id)) erased++;
    return json({ erased });
  }

  const { data: who, error: authError } = await admin.auth.getUser(token);
  if (authError || !who?.user) return json({ error: "Sign in again, then try deleting your account." }, 401);
  if (body?.confirm !== "delete") return json({ error: "Not confirmed" }, 400);
  // the account's password, checked here too and not only in the app (27 Nov): a wrong one deletes nothing
  const password = typeof body?.password === "string" ? body.password : "";
  if (!password) return json({ error: "Update Cheat Days, then type your password to delete your account." }, 400);
  if (!who.user.email) return json({ error: "That password isn't right." }, 401);
  const check = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error: wrong } = await check.auth.signInWithPassword({ email: who.user.email, password });
  if (wrong) return json({ error: /invalid|credentials/i.test(wrong.message) ? "That password isn't right." : "Couldn't check your password. Try again in a minute." }, 401);
  const uid = who.user.id;
  try {
    const when = new Date(Date.now() + GRACE_DAYS * 86400_000);
    const { data: marked, error } = await admin.from("profiles").update({ delete_after: when.toISOString() })
      .eq("user_id", uid).is("delete_after", null).select("delete_after");
    if (error) throw error;
    let until = marked?.[0]?.delete_after as string | undefined;
    if (!until) {
      // already waiting (asked twice): keep the first date; no profile at all: nothing was shared, so erase now
      const { data: had } = await admin.from("profiles").select("delete_after").eq("user_id", uid).maybeSingle();
      if (!had) return (await erase(uid)) ? json({ deleted: true }) : json({ error: "Couldn't delete the account. Try again in a minute." }, 500);
      until = had.delete_after as string;
    }
    // off every phone (the app signs this one out itself); signing in again within the 30 days cancels it
    await admin.auth.admin.signOut(token, "global").catch((e) => console.log("signOut", String(e)));
    await email(who.user.email, new Date(until));
    return json({ pending: true, delete_after: until });
  } catch (e) {
    console.log("delete-account failed", String(e));
    return json({ error: "Couldn't delete the account. Try again in a minute." }, 500);
  }
});
