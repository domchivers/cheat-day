// Cheat Days body import: an iOS Shortcut (or anything else) posts scale readings here with a private token.
// Deploy: Supabase dashboard -> Edge Functions -> Deploy a new function -> name it "body-import", paste this, Deploy,
// then in the function's settings turn OFF "Verify JWT" (the Shortcut has no login; the token is the secret).
// Body: { "token": "...", "date": "2026-09-21" (optional), "weight": 78.4, "fat": 18.2, "lean": 64.1, "muscle": ..., "water": ..., "bone": ..., "visceral": ..., "bmr": ..., "age": ..., "bmi": ... }
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (obj: unknown, status = 200) => new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });
const num = (v: unknown): number | null => { const n = typeof v === "string" ? parseFloat(v.replace(/[^0-9.\-]/g, "")) : Number(v); return isFinite(n) ? n : null; };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Send JSON" }, 400); }
  const token = String(body.token || "").trim();
  if (!/^[A-Za-z0-9_-]{16,}$/.test(token)) return json({ error: "Missing token" }, 401);

  // The service role looks the token up; nothing else reaches the database with it.
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: owner } = await admin.from("import_tokens").select("user_id").eq("token", token).maybeSingle();
  if (!owner) return json({ error: "Unknown token" }, 401);

  const date = /^\d{4}-\d{2}-\d{2}$/.test(String(body.date || "")) ? String(body.date) : new Date().toISOString().slice(0, 10);
  const row: Record<string, unknown> = { user_id: owner.user_id, day: date, updated_at: new Date().toISOString() };
  let fat = num(body.fat); if (fat != null && fat <= 1) fat = fat * 100;     // Health stores body fat as a fraction
  let water = num(body.water); if (water != null && water <= 1) water = water * 100;
  const fields: Record<string, number | null> = { weight: num(body.weight), fat, lean: num(body.lean), muscle: num(body.muscle), water, bone: num(body.bone), visceral: num(body.visceral), bmr: num(body.bmr), age: num(body.age), bmi: num(body.bmi) };
  let any = false;
  for (const [k, v] of Object.entries(fields)) if (v != null && v > 0) { row[k] = v; any = true; }
  if (!any) return json({ error: "No readings in the request" }, 400);

  const { error } = await admin.from("body_metrics").upsert(row, { onConflict: "user_id,day" });
  if (error) return json({ error: error.message }, 500);
  return json({ ok: true, day: date, saved: Object.keys(fields).filter((k) => row[k] != null) });
});
