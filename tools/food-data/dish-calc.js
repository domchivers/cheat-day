// Our own values for dishes no usable table has (28 Nov): each dish worked out from a typical recipe, ingredient by
// ingredient, from tables the app may use (AFCD, USDA SR Legacy, Taiwan TFDA, Japan MEXT), then spread over the cooked
// weight. Recipes are in recipes/*.json; nothing is copied from a restricted table (those are only ever used to check).
//   node dish-calc.js            -> built-dishes.json and built-dishes.txt (with any ingredient it couldn't find)
//   node dish-calc.js thai.json  -> just that file, printed, to check a recipe while writing it
//
// A recipe file is a JSON array of dishes:
// { "dish": "Pad thai, chicken",          // the name the app matches by: the dish first, details after a comma
//   "cuisine": "Thai", "aka": ["phad thai"],
//   "serving_g": 350,                      // a usual takeaway or restaurant serving, cooked
//   "ingredients": [                       // raw (as bought) weights for one batch
//     { "food": "Noodles, rice, dried", "g": 100 },            // a table entry's name (or close to it)
//     { "food": "Chicken, thigh, lean, raw", "g": 120 },
//     { "food": "Oil, peanut", "g": 15, "note": "what stays in the dish" },
//     { "food": "Fish sauce", "g": 15, "table": "us" } ],      // table: au (default), us, tw, jp
//   "cooked_g": 520,                       // the batch's weight once cooked, if it isn't the sum (water lost or taken up)
//   "notes": "rice noodles soaked and stir-fried; oil is what's absorbed, not the wok's full amount" }
const fs = require('fs'), path = require('path');
const here = __dirname, res = path.join(here, '..', '..', 'native', 'CheatDays', 'Resources'), data = path.join(here, '..', 'ai-test', 'data');
const { resolveIn } = require('../ai-test/tables.js');
const load = p => JSON.parse(fs.readFileSync(p, 'utf8'));
const exact = {
  au: load(path.join(data, 'food-db.json')), us: load(path.join(data, 'us-foods.json')),
  tw: fs.existsSync(path.join(res, 'tw-foods.json')) ? load(path.join(res, 'tw-foods.json')) : [],
  jp: fs.existsSync(path.join(res, 'jp-foods.json')) ? load(path.join(res, 'jp-foods.json')) : [],
  // the world ingredients the tables lacked (build-ingredients.js): gochujang, candlenut, kecap manis…
  ing: fs.existsSync(path.join(res, 'ing-foods.json')) ? load(path.join(res, 'ing-foods.json')) : [],
};
function find(ing) {
  const t = ing.table || 'au', name = ing.food.trim().toLowerCase();
  const hit = exact[t].find(f => f.name.trim().toLowerCase() === name);
  if (hit) return { food: hit, how: 'exact' };
  if (t === 'au' || t === 'us') { const r = resolveIn(t, ing.food); if (r) return { food: r, how: 'matched' }; }
  return null;
}
const dir = path.join(here, 'recipes');
const files = process.argv[2] ? [process.argv[2]] : fs.readdirSync(dir).filter(f => f.endsWith('.json'));
const out = [], lines = [];
for (const file of files) {
  for (const d of load(path.join(dir, path.basename(file)))) {
    let k = 0, p = 0, c = 0, f = 0, raw = 0; const missing = [], used = [];
    for (const ing of d.ingredients) {
      raw += ing.g;
      const hit = find(ing);
      if (!hit) { missing.push(ing.food + (ing.table ? ` (${ing.table})` : '')); continue; }
      const x = hit.food, m = ing.g / 100;
      k += (x.kcal || 0) * m; p += (x.p || 0) * m; c += (x.c || 0) * m; f += (x.f || 0) * m;
      used.push(`${ing.g} g ${ing.food}${hit.how === 'matched' && x.name !== ing.food ? ` -> ${x.name}` : ''}`);
    }
    const cooked = d.cooked_g || raw, per = v => Math.round(v / cooked * 1000) / 10;
    const row = { name: d.dish, cuisine: d.cuisine, aka: d.aka || [], serving_g: d.serving_g, kcal: Math.round(k / cooked * 100), p: per(p), c: per(c), f: per(f),
                  source: 'built', missing };
    out.push(row);
    lines.push(`${row.name} [${row.cuisine}]: ${row.kcal} kcal, P${row.p} C${row.c} F${row.f} per 100 g; serving ${d.serving_g} g = ${Math.round(row.kcal * d.serving_g / 100)} kcal`
      + (missing.length ? `\n   MISSING: ${missing.join('; ')}` : '') + (process.argv[2] ? '\n   ' + used.join('\n   ') : ''));
  }
}
if (!process.argv[2]) { fs.writeFileSync(path.join(here, 'built-dishes.json'), JSON.stringify(out, null, 1)); fs.writeFileSync(path.join(here, 'built-dishes.txt'), lines.join('\n')); }
console.log(lines.join('\n'));
console.log(`\n${out.length} dishes, ${out.filter(r => r.missing.length).length} with missing ingredients`);
