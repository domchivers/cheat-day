// Cheat Days AI relay: lets signed-in users call Gemini with ONE shared key that only lives here as a secret.
// Deploy: Supabase dashboard -> Edge Functions -> Deploy a new function -> name it "ai", paste this, Deploy.
// Then Edge Functions -> Secrets -> add GEMINI_API_KEY (a free key from https://aistudio.google.com).
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response("POST only", { status: 405, headers: cors });

  // Only people signed in to the app may use the shared key.
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new Response(JSON.stringify({ error: "Sign in to use this" }), { status: 401, headers: { ...cors, "Content-Type": "application/json" } });

  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) return new Response(JSON.stringify({ error: "GEMINI_API_KEY secret not set" }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });

  const body = await req.text();   // the app sends a ready-made Gemini generateContent request
  const wanted = new URL(req.url).searchParams.get("model") || "gemini-3.6-flash";
  const model = /^[a-z0-9.-]+$/.test(wanted) ? wanted : "gemini-3.6-flash";
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-goog-api-key": key },
    body,
  });
  return new Response(await r.text(), { status: r.status, headers: { ...cors, "Content-Type": "application/json" } });
});
