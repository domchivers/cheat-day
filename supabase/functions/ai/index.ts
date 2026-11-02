// Cheat Days AI relay: lets signed-in users call Claude (and, for older versions of the apps, Gemini) with keys that only live here as secrets.
// Deploy: Supabase dashboard -> Edge Functions -> Deploy a new function -> name it "ai", paste this, Deploy.
// Secrets: ANTHROPIC_API_KEY for Claude, GEMINI_API_KEY for Gemini. Optional: AI_MODELS, like {"recipes":"claude-sonnet-5-5"}, changes a job's model
// without a new build; AI_DAILY_CALLS changes the limit per person. Needs the table in supabase/ai_usage.sql.
import { createClient } from "npm:@supabase/supabase-js@2";
import Anthropic from "npm:@anthropic-ai/sdk@1.3.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const HAIKU = "claude-haiku-5-5", SONNET = "claude-sonnet-5-5";
// from the tests in tools/ai-test and the owner's side-by-side picks
const MODELS: Record<string, string> = { recipes: HAIKU, plans: HAIKU, labels: HAIKU, logs: HAIKU, quick: HAIKU, chat: SONNET, photos: SONNET, careful: SONNET };
const PRICES: Record<string, [number, number]> = { [HAIKU]: [0.10, 0.50], [SONNET]: [2, 10] };   // $ per million tokens in and out

function chosenModel(job: string): string | null {
  let extra: Record<string, string> = {};
  try { extra = JSON.parse(Deno.env.get("AI_MODELS") || "{}"); } catch { /* a bad setting falls back to the defaults */ }
  const model = extra[job] || MODELS[job];
  return model && PRICES[model] ? model : null;
}

// the app's schemas are written Gemini's way: Claude wants nullable as anyOf, and every object closed
function claudeSchema(s: any): any {
  if (Array.isArray(s)) return s.map(claudeSchema);
  if (!s || typeof s !== "object") return s;
  const { nullable, ...rest } = s, out: any = {};
  for (const [k, v] of Object.entries(rest)) out[k] = k === "properties" ? Object.fromEntries(Object.entries(v as any).map(([p, q]) => [p, claudeSchema(q)])) : k === "enum" ? v : claudeSchema(v);
  if (out.type === "object") out.additionalProperties = false;
  return nullable ? { anyOf: [out, { type: "null" }] } : out;
}

// the app's parts are a list of {text} and {inline_data}
function claudeContent(parts: any[]): any[] {
  return parts.map((p) => p.inline_data
    ? { type: "image", source: { type: "base64", media_type: p.inline_data.mime_type, data: p.inline_data.data } }
    : { type: "text", text: String(p.text ?? "") });
}

async function askClaude(req: Request, user: { id: string }, job: string) {
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return json({ error: "ANTHROPIC_API_KEY secret not set" }, 503);
  const model = chosenModel(job);
  if (!model) return json({ error: "Unknown job" }, 400);
  const { parts, schema, maxTokens } = await req.json();
  if (!Array.isArray(parts) || !parts.length || parts.length > 6) return json({ error: "Bad request" }, 400);

  // nobody can run up the bill: a limit per person per day, counted in the service-only table
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const limit = Number(Deno.env.get("AI_DAILY_CALLS")) || 200;
  const since = new Date(Date.now() - 86400000).toISOString();
  const { count, error: countError } = await admin.from("ai_usage").select("id", { count: "exact", head: true }).eq("user_id", user.id).gte("at", since);
  if (countError) return json({ error: "Usage table not ready" }, 503);
  if ((count ?? 0) >= limit) return json({ error: "daily limit" }, 429);

  const started = Date.now();
  const client = new Anthropic({ apiKey: key, maxRetries: 1 });
  try {
    // Haiku thinks at length over every ingredient's sums: a butter chicken took 31 s and most of 8,000 tokens by default,
    // 18 s and half that at low effort, and the database corrects the numbers afterwards anyway
    const config: any = { ...(model === HAIKU ? { effort: "low" } : {}), ...(schema ? { format: { type: "json_schema", schema: claudeSchema(schema) } } : {}) };
    const r = await client.messages.create({
      model, max_tokens: Math.min(Number(maxTokens) || 4000, 12000),
      messages: [{ role: "user", content: claudeContent(parts) }],
      ...(Object.keys(config).length ? { output_config: config } : {}),
    } as any);
    const [pIn, pOut] = PRICES[model], input = r.usage.input_tokens, output = r.usage.output_tokens;
    await admin.from("ai_usage").insert({ user_id: user.id, job, model, input_tokens: input, output_tokens: output, cost: (input * pIn + output * pOut) / 1e6, ms: Date.now() - started, stop: r.stop_reason });
    const text = r.content.filter((b: any) => b.type === "text").map((b: any) => b.text).join("");
    if (r.stop_reason === "refusal") return json({ error: "refused" }, 422);
    if (r.stop_reason === "max_tokens") return json({ error: "too long" }, 502);
    return json({ text, model });
  } catch (e: any) {
    // never the error's own text, which could quote the request
    return json({ error: "Claude failed", status: e?.status ?? 0 }, e?.status === 429 || e?.status === 529 ? 503 : 502);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response("POST only", { status: 405, headers: cors });

  // Only people signed in to the app may use the shared keys.
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return json({ error: "Sign in to use this" }, 401);

  const job = new URL(req.url).searchParams.get("job");
  if (job) return askClaude(req, user, job);

  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) return json({ error: "GEMINI_API_KEY secret not set" }, 500);

  const body = await req.text();   // the app sends a ready-made Gemini generateContent request
  const wanted = new URL(req.url).searchParams.get("model") || "gemini-3.8-flash";
  const model = /^[a-z0-9.-]+$/.test(wanted) ? wanted : "gemini-3.8-flash";
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-goog-api-key": key },
    body,
  });
  return new Response(await r.text(), { status: r.status, headers: { ...cors, "Content-Type": "application/json" } });
});
