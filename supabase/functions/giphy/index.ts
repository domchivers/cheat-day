// GIF and sticker search for the story editor, through GIPHY, with the key kept here (never in the app).
// Deploy: Supabase dashboard -> Edge Functions -> Deploy a new function -> name it "giphy", paste this, Deploy.
// Leave "Verify JWT" on: only signed-in people use it. Needs the secret GIPHY_KEY and the giphy_cache table
// (supabase/giphy.sql).
//
// The free key allows 100 calls an hour for everyone together, so every answer is shared and kept: trending for an
// hour, a search for a day. When GIPHY says no (the limit), the last answer kept is sent, or "limited" so the app falls
// back to its own stickers.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (obj: unknown, status = 200) => new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

type Item = { id: string; url: string; still: string; w: number; h: number };

// what the app needs of each: a small animated GIF (stickers keep their see-through background), its first frame, size
function slim(data: any[]): Item[] {
  return (data || []).map((g: any) => {
    const im = g.images || {}, f = im.fixed_width || {}, s = im.fixed_width_still || {};
    return { id: String(g.id), url: String(f.url || ""), still: String(s.url || ""), w: Number(f.width) || 200, h: Number(f.height) || 200 };
  }).filter((x: Item) => x.url.startsWith("https://"));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  const key = Deno.env.get("GIPHY_KEY");
  if (!key) return json({ items: [], limited: true, why: "GIPHY_KEY isn't set" });
  let body: any = {};
  try { body = await req.json(); } catch { /* empty is fine */ }
  const kind = body.kind === "gifs" ? "gifs" : "stickers";
  const q = String(body.q || "").trim().toLowerCase().slice(0, 50);
  const cacheKey = q ? `search:${kind}:${q}` : `trending:${kind}`;
  const fresh = (q ? 24 : 1) * 3600 * 1000;

  const { data: kept } = await admin.from("giphy_cache").select("data, fetched_at").eq("key", cacheKey).maybeSingle();
  if (kept && Date.now() - new Date(kept.fetched_at).getTime() < fresh) return json({ items: kept.data, cached: true });

  const url = q
    ? `https://api.giphy.com/v1/${kind}/search?api_key=${key}&q=${encodeURIComponent(q)}&limit=36&rating=pg&lang=en`
    : `https://api.giphy.com/v1/${kind}/trending?api_key=${key}&limit=36&rating=pg`;
  try {
    const r = await fetch(url);
    if (!r.ok) {
      console.log(`giphy: ${r.status} for ${cacheKey}`);
      return json({ items: kept?.data || [], limited: r.status === 429 || r.status === 403, stale: !!kept });
    }
    const items = slim((await r.json()).data);
    await admin.from("giphy_cache").upsert({ key: cacheKey, data: items, fetched_at: new Date().toISOString() });
    return json({ items });
  } catch (e) {
    console.log("giphy: " + (e as Error).message);
    return json({ items: kept?.data || [], limited: true, stale: !!kept });
  }
});
