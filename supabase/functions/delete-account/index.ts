// Cheat Days: delete the signed-in person's account and everything in it, as App Store guideline 5.1.1(v) asks.
// Deploy: Supabase dashboard -> Edge Functions -> Deploy a new function -> name it "delete-account", paste this, Deploy.
// Leave "Verify JWT" on: it only ever deletes the caller, worked out from their own sign-in token.
//
// POST { confirm: "delete", password }  ->  { deleted: true }   or   { error } (401 when the password is wrong)
//
// 1. their photos in storage (photos/<user id>/...)
// 2. their rows in the tables made in the dashboard, which may not cascade (the ones in supabase/*.sql do)
// 3. the sign-in itself: every table that references auth.users with on delete cascade goes with it
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (obj: unknown, status = 200) => new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: who, error: authError } = await admin.auth.getUser(token);
  if (authError || !who?.user) return json({ error: "Sign in again, then try deleting your account." }, 401);
  const body = await req.json().catch(() => ({}));
  if (body?.confirm !== "delete") return json({ error: "Not confirmed" }, 400);
  // the account's password, checked here too and not only in the app (27 Nov): a wrong one deletes nothing
  const password = typeof body?.password === "string" ? body.password : "";
  if (!password) return json({ error: "Update Cheat Days, then type your password to delete your account." }, 400);
  if (!who.user.email) return json({ error: "That password isn't right." }, 401);
  const check = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error: wrong } = await check.auth.signInWithPassword({ email: who.user.email, password });
  if (wrong) return json({ error: /invalid|credentials/i.test(wrong.message) ? "That password isn't right." : "Couldn't check your password. Try again in a minute." }, 401);
  const uid = who.user.id;
  try {
    await removePhotos(uid);
    for (const [table, cols] of Object.entries(OWN)) for (const col of cols) {
      const { error } = await admin.from(table).delete().eq(col, uid);
      if (error && !/does not exist|column|relation|schema cache/i.test(error.message)) console.log("delete", table, col, error.message);
    }
    const { error } = await admin.auth.admin.deleteUser(uid);
    if (error) return json({ error: "Couldn't delete the account. Try again in a minute." }, 500);
    return json({ deleted: true });
  } catch (e) {
    console.log("delete-account failed", String(e));
    return json({ error: "Couldn't delete the account. Try again in a minute." }, 500);
  }
});
