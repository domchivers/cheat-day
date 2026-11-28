// built-dishes.json (from dish-calc.js) into the app: Resources/built-foods.json and built-aliases.json. node build-own-dishes.js
const fs = require('fs'), path = require('path');
const res = path.join(__dirname, '..', '..', 'native', 'CheatDays', 'Resources');
const built = JSON.parse(fs.readFileSync(path.join(__dirname, 'built-dishes.json'), 'utf8'));
const seen = new Set(), foods = [], aliases = [];
// ingredients worked out from recipes (recipes/ing_*.json) go in the ingredients table, not here
const ing = new Set(); for (const f of fs.readdirSync(path.join(__dirname, 'recipes')).filter(f => /^ing_.*.json$/.test(f))) for (const d of JSON.parse(fs.readFileSync(path.join(__dirname, 'recipes', f), 'utf8'))) ing.add(d.dish);
for (const d of built) {
  const n = d.name.replace(/\s+/g, ' ').trim();
  if (ing.has(d.name) || d.missing.length || !/^[\x00-\x7F]+$/.test(n) || seen.has(n.toLowerCase())) continue;
  seen.add(n.toLowerCase());
  foods.push({ name: n, source: 'CheatDays2026', kcal: d.kcal, p: d.p, c: d.c, f: d.f });
  const aka = (d.aka || []).map(a => String(a).toLowerCase().replace(/[,|]/g, ' ').replace(/\s+/g, ' ').trim()).filter(a => a && /^[\x00-\x7F]+$/.test(a));
  if (aka.length) aliases.push([aka.join('|'), n]);
}
fs.writeFileSync(path.join(res, 'built-foods.json'), JSON.stringify(foods));
fs.writeFileSync(path.join(res, 'built-aliases.json'), JSON.stringify(aliases));
console.log(`built: ${foods.length} dishes, ${aliases.length} with other names`);
