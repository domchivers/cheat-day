// Cheat Days food lookup: checks the AI's calorie guesses against USDA FoodData Central (free, public-domain data).
// Deploy: Supabase dashboard -> Edge Functions -> Deploy a new function -> name it "food", paste this, Deploy.
// Then Edge Functions -> Secrets -> add FDC_API_KEY (a free key from https://fdc.nal.usda.gov/api-key-signup).
// The app sends {foods: ["Chicken, broilers or fryers, breast, meat only, cooked, roasted", ...]} (up to 10)
// and gets back, for each, the closest generic food per 100 g, or null.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const STOP = new Set(["and", "or", "with", "without", "of", "the", "a", "in", "raw", "nfs", "ns"]);
const words = (s: string) => s.toLowerCase().split(/[^a-z]+/).filter((w) => w.length > 1 && !STOP.has(w));

type Nutrient = { nutrientNumber?: string; value?: number };
type Food = { description: string; fdcId: number; foodNutrients: Nutrient[] };
const val = (f: Food, ...nums: string[]) => { for (const n of nums) { const x = f.foodNutrients.find((y) => y.nutrientNumber === n); if (x && x.value != null) return x.value; } return null; };

async function lookup(query: string, key: string) {
  const url = `https://api.nal.usda.gov/fdc/v1/foods/search?query=${encodeURIComponent(query)}&dataType=Foundation,SR%20Legacy&pageSize=12&api_key=${key}`;
  const r = await fetch(url);
  if (!r.ok) return null;
  const foods: Food[] = (await r.json()).foods || [];
  // USDA's own ranking is loose, so pick the description that shares the most words with the query
  const want = words(query);
  let best: Food | null = null, bestScore = -1;
  for (const f of foods) {
    if (val(f, "208", "957", "958") == null) continue;
    const have = new Set(words(f.description));
    const hits = want.filter((w) => have.has(w) || have.has(w.replace(/s$/, ""))).length;
    const score = hits / Math.max(want.length, 1) - 0.02 * Math.max(have.size - hits, 0);
    if (score > bestScore) { best = f; bestScore = score; }
  }
  if (!best || bestScore < 0.5) return null;   // nothing close enough: let the app keep the AI's numbers
  return { name: best.description, fdcId: best.fdcId, kcal100: val(best, "208", "957", "958"), p100: val(best, "203"), c100: val(best, "205"), f100: val(best, "204") };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response("POST only", { status: 405, headers: cors });
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return json({ error: "Sign in to use this" }, 401);
  const key = Deno.env.get("FDC_API_KEY");
  if (!key) return json({ error: "FDC_API_KEY secret not set" }, 500);
  const body = await req.json().catch(() => ({}));
  const foods: string[] = Array.isArray(body.foods) ? body.foods.slice(0, 10).map((x: unknown) => String(x).slice(0, 120)) : [];
  const results = await Promise.all(foods.map((q) => lookup(q, key).catch(() => null)));
  return json({ results });
});
