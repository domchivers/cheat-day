// The world ingredients the tables lacked (28 Nov workflow) into the app: single published values from
// ingredients/raw_*.json (USDA FoodData Central, measured studies, product labels; only entries the checker kept) and the
// mixed ones worked out from recipes/ing_*.json by dish-calc. Writes Resources/ing-foods.json and ing-aliases.json.
//   node dish-calc.js && node build-ingredients.js
const fs = require('fs'), path = require('path');
const here = __dirname, res = path.join(here, '..', '..', 'native', 'CheatDays', 'Resources');
const ascii = s => /^[\x00-\x7F]+$/.test(s);
const foods = [], aliases = [], seen = new Set(), sources = {};
let dropped = 0;
function add(name, kcal, p, c, f, aka, source) {
  const n = String(name).replace(/\bdried\b/gi, 'dry').replace(/\s+/g, ' ').trim();   // 'dried' is filler to the app's matcher
  if (!n || !ascii(n) || seen.has(n.toLowerCase()) || !(kcal >= 0)) { dropped++; return; }
  seen.add(n.toLowerCase());
  const r1 = x => Math.round((+x || 0) * 10) / 10;
  foods.push({ name: n, source, kcal: Math.round(kcal), p: r1(p), c: r1(c), f: r1(f) });
  const a = (aka || []).map(x => String(x).toLowerCase().replace(/[,|]/g, ' ').replace(/\s+/g, ' ').trim()).filter(x => x && ascii(x));
  if (a.length) aliases.push([a.join('|'), n]);
  sources[source] = (sources[source] || 0) + 1;
}
const dir = path.join(here, 'ingredients');
for (const file of fs.readdirSync(dir).filter(f => /^raw_.*\.json$/.test(f))) {
  for (const r of JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'))) {
    // a value the checker couldn't confirm stays out
    if (r.checked === false) { dropped++; continue; }
    add(r.name, r.kcal, r.p, r.c, r.f, r.aka, /fdc\.nal\.usda|fooddata/i.test(r.source_url || '') ? 'USDA-FDC' : 'published');
  }
}
const built = path.join(here, 'built-dishes.json');
if (fs.existsSync(built)) {
  const ingNames = new Set();
  for (const f of fs.readdirSync(path.join(here, 'recipes')).filter(f => /^ing_.*\.json$/.test(f)))
    for (const d of JSON.parse(fs.readFileSync(path.join(here, 'recipes', f), 'utf8'))) ingNames.add(d.dish);
  for (const d of JSON.parse(fs.readFileSync(built, 'utf8')))
    if (ingNames.has(d.name) && !d.missing.length) add(d.name, d.kcal, d.p, d.c, d.f, d.aka, 'CheatDays2026');
}
fs.writeFileSync(path.join(res, 'ing-foods.json'), JSON.stringify(foods));
fs.writeFileSync(path.join(res, 'ing-aliases.json'), JSON.stringify(aliases));
console.log(`ingredients: ${foods.length} (${JSON.stringify(sources)}), ${aliases.length} with other names, ${dropped} left out`);
