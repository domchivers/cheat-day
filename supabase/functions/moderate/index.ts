// Cheat Days moderation: Claude looks at what's about to be posted ("check") and at what's been reported ("report").
// Deploy: Supabase dashboard -> Edge Functions -> Deploy a new function -> name it "moderate", paste this, Deploy.
// Leave "Verify JWT" on: only signed-in people use it. Secret: ANTHROPIC_API_KEY (the same one the "ai" function has).
// Needs supabase/moderation.sql (and ai_usage.sql, which the "ai" function already needs).
//
// check:  { action: "check", kind, text, image }   image: a small JPEG as base64, optional
//         -> { verdict: "ok" | "block" | "unsure", rule, why, seen }
// report: { action: "report", id }                 a row of public.reports the caller made
//         -> { status }                            cleared, removed or human
//
// Two things never go to the AI: anything reported as involving a child (hidden at once, straight to a person), and
// private messages and whole profiles (straight to a person). When the AI can't be reached, a check lets the post
// through and a report goes to a person: nothing is lost by the AI being down.
import { createClient } from "npm:@supabase/supabase-js@2";
import Anthropic from "npm:@anthropic-ai/sdk@1.3.0";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (obj: unknown, status = 200) => new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const MODEL = "claude-haiku-5-5", PRICE = [0.10, 0.50];   // $ per million tokens in and out

// kept word for word with tools/ai-test/moderation-check.js, which tested it against Claude
const rules = (kind: string, reported: string) => `You review content for Cheat Days, a food diary and fitness app with a social feed, used by people aged 14 and up. Decide whether this ${kind} breaks the rules.${reported ? ` Another user reported it as: ${reported}.` : ""}
It breaks the rules when it has:
- nudity or sexual content: genitals, bare buttocks, female nipples, sexual acts, asking for sex, or a sexualised pose. Not this: swimwear, underwear, or shirtless progress and gym photos, breastfeeding, an ordinary photo of a body.
- anything sexual or sexualised involving someone who looks under 18.
- harassment: insults, threats, slurs or humiliation aimed at a person or a group, or telling someone to hurt themselves.
- hate: attacking people for their race, religion, sex, sexuality, gender identity, disability or nationality.
- violence or gore, or praise of it; a real weapon used to threaten.
- dangerous eating advice: promoting starvation, purging or eating far too little as a goal, or shaming someone's body. Not this: ordinary dieting, a calorie deficit, fasting windows, cheat days, someone being honest that they're struggling.
- drugs for sale, a scam, or spam and adverts for other services.
- pretending to be another real person or a company.
Fine: food, meals, recipes, workouts, body progress, jokes between friends, swearing that isn't aimed at anyone, a drink with a meal.
verdict: block only when it clearly breaks a rule; ok when it clearly doesn't; unsure when you can't tell (a joke that might be an insult, a picture too small or dark to read, a revealing photo of someone whose age you can't judge). rule: the one broken, in a few words, else empty. why: one plain sentence to the person who posted it, saying what the problem is; empty when ok. seen: what is there, described neutrally and without graphic detail in under 20 words, for a reviewer who would rather not look at it.`;

const schema = { type: "object", additionalProperties: false, required: ["verdict", "rule", "why", "seen"], properties: {
  verdict: { type: "string", enum: ["ok", "block", "unsure"] }, rule: { type: "string" }, why: { type: "string" }, seen: { type: "string" } } };

type Verdict = { verdict: "ok" | "block" | "unsure"; rule: string; why: string; seen: string };

async function ask(user: string, kind: string, text: string, image: string | null, reported = ""): Promise<Verdict | null> {
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return null;
  const content: any[] = [];
  if (image) content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: image } });
  content.push({ type: "text", text: `${rules(kind, reported)}\n\n${image ? "The picture is above. " : "There is no picture. "}${text.trim() ? `Its words:\n"""${text.slice(0, 3000)}"""` : "It has no words."}` });
  try {
    const client = new Anthropic({ apiKey: key, maxRetries: 1 });
    const r = await client.messages.create({ model: MODEL, max_tokens: 600, messages: [{ role: "user", content }],
      output_config: { effort: "low", format: { type: "json_schema", schema } } } as any);
    const cost = (r.usage.input_tokens * PRICE[0] + r.usage.output_tokens * PRICE[1]) / 1e6;
    await admin.from("ai_usage").insert({ user_id: user, job: "moderate", model: MODEL, input_tokens: r.usage.input_tokens, output_tokens: r.usage.output_tokens, cost });
    // a refusal to answer is "can't tell": a person looks
    if ((r as any).stop_reason === "refusal") return { verdict: "unsure", rule: "", why: "", seen: "The AI declined to look at this." };
    const out = JSON.parse(r.content.filter((b: any) => b.type === "text").map((b: any) => b.text).join(""));
    return ["ok", "block", "unsure"].includes(out.verdict) ? out : null;
  } catch (e) {
    console.log("moderate: " + (e as Error).message);
    return null;
  }
}

// a picture at its address, as base64, when it's a JPEG or PNG of a sensible size
async function fetched(url: string): Promise<string | null> {
  if (!url.startsWith(Deno.env.get("SUPABASE_URL")! + "/storage/v1/object/public/")) return null;   // only this app's own files
  try {
    const r = await fetch(url);
    if (!r.ok || !(r.headers.get("content-type") || "").startsWith("image/")) return null;
    const bytes = new Uint8Array(await r.arrayBuffer());
    if (bytes.length > 4_000_000) return null;
    let s = ""; for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode(...bytes.subarray(i, i + 8192));
    return btoa(s);
  } catch { return null; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  const mine = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } } });
  const { data: { user } } = await mine.auth.getUser();
  if (!user) return json({ error: "Sign in to use this" }, 401);
  let body: any = {};
  try { body = await req.json(); } catch { /* handled below */ }

  // ---- before it's posted
  if (body.action === "check") {
    const text = String(body.text || ""), image = typeof body.image === "string" && body.image.length < 1_500_000 ? body.image : null;
    if (!text.trim() && !image) return json({ verdict: "ok", rule: "", why: "", seen: "" });
    const v = await ask(user.id, String(body.kind || "post").slice(0, 20), text, image);
    return json(v ?? { verdict: "ok", rule: "", why: "", seen: "", unchecked: true });   // the AI can't be reached: it goes through
  }

  // ---- after it's reported
  if (body.action === "report") {
    const { data: rep } = await admin.from("reports").select("*").eq("id", String(body.id || "")).maybeSingle();
    if (!rep || rep.reporter !== user.id) return json({ error: "Not your report" }, 403);
    if (rep.status !== "open") return json({ status: rep.status });
    const set = async (status: string, verdict: unknown) => {
      await admin.from("reports").update({ status, verdict, decided_at: status === "human" ? null : new Date().toISOString() }).eq("id", rep.id);
      return json({ status });
    };
    // anything about a child: out of sight now, and to a person. The AI is never shown it.
    if (rep.category === "child") {
      await admin.rpc("mod_hide", { k: rep.kind, t: rep.target, cat: rep.category, reason: "Hidden while it's reviewed", rep: rep.id, who: "ai" });
      return set("human", { verdict: "unsure", rule: "", why: "", seen: "Reported as involving a child. Hidden, and not shown to the AI." });
    }
    // a private message, or a person as a whole: a person's to judge
    if (!["post", "story", "comment"].includes(rep.kind)) return set("human", { verdict: "unsure", rule: "", why: "", seen: "Not looked at by the AI." });
    const snap = rep.snapshot || {}, text = String(snap.text || ""), media = String(snap.media || "");
    const image = media ? await fetched(media) : null;
    // a video with no picture of it, or a picture that couldn't be read: nothing to judge by
    if (!image && (snap.video || media) && !text.trim()) return set("human", { verdict: "unsure", rule: "", why: "", seen: "A video or picture the AI couldn't open." });
    const v = await ask(user.id, rep.kind, text, image, rep.category || "something wrong");
    if (!v) return set("human", { verdict: "unsure", rule: "", why: "", seen: "The AI couldn't be reached." });
    if (v.verdict === "block") {
      await admin.rpc("mod_hide", { k: rep.kind, t: rep.target, cat: rep.category, reason: v.why || v.rule || "It breaks the rules", rep: rep.id, who: "ai" });
      return set("removed", v);
    }
    // a video is only as good as its one picture: fine there still means a person should look
    if (v.verdict === "ok" && !snap.video) return set("cleared", v);
    return set("human", v);
  }
  return json({ error: "Unknown action" }, 400);
});
