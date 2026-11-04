// The food table for each of the app's countries, matched the way jobs.js matches the Australian one (and the app's
// FoodTables.swift): an everyday name from that country's aliases first, otherwise the food's own kind must match.
//   const { resolveIn } = require('./tables.js'); resolveIn('uk', 'courgette')
const fs = require('fs'), path = require('path');
const filler = new Set(['fresh', 'chopped', 'sliced', 'diced', 'large', 'small', 'medium', 'finely', 'peeled', 'boneless', 'skinless', 'lean', 'of', 'and', 'for', 'to', 'taste', 'grated', 'minced', 'crushed', 'dried', 'ground', 'whole', 'extra', 'virgin', 'cubed', 'thinly', 'roughly', 'optional']);
const words = s => s.toLowerCase().replace(/[^a-z ]/g, ' ').split(/\s+/).filter(w => w && !filler.has(w)).map(w => w.replace(/(oes|ies|s)$/, m => (m === 'ies' ? 'y' : m === 'oes' ? 'o' : '')));
const files = { au: ['food-db.json', 'aliases.json', 'AFCD3'], uk: ['uk-foods.json', 'uk-aliases.json', 'CoFID2021'], us: ['us-foods.json', 'us-aliases.json', 'SRLegacy'] };
const tables = {};
function table(country) {
  if (tables[country]) return tables[country];
  const [db, al, main] = files[country];
  const food = JSON.parse(fs.readFileSync(path.join(__dirname, 'data', db), 'utf8'));
  const index = food.map(f => ({ f, w: new Set(words(f.name)), raw: /\braw\b|uncooked/i.test(f.name), kind: words(f.name.split(',')[0]), lead: words(f.name.split(',').slice(0, 2).join(' ')) }));
  const alias = new Map(), file = path.join(__dirname, al);
  for (const [names, foodName] of fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : []) {
    const f = food.find(x => x.name.trim() === foodName); if (!f) throw new Error(`${al}: no food ${foodName}`);
    names.split('|').forEach(n => alias.set(words(n).join(' '), f));
  }
  return (tables[country] = { food, index, alias, main });
}
function resolveIn(country, name) {
  const t = table(country), want = words(name.split(/[,(]/)[0]);
  if (!want.length) return null;
  const named = t.alias.get(want.join(' '));
  if (named) return named;
  const cooked = /cooked|boiled|grilled|roast|fried|baked|steamed/i.test(name), head = want[want.length - 1];
  const hits = t.index.filter(x => want.every(w => x.w.has(w)) && (x.kind.includes(head) || x.kind.includes(want[0]) || want.every(w => x.lead.includes(w))));
  if (!hits.length) return null;
  const rank = x => (x.raw === !cooked ? 0 : 100) + (x.f.source === t.main ? 0 : 20) + x.w.size * 2;
  return hits.sort((a, b) => rank(a) - rank(b))[0].f;
}
module.exports = { resolveIn, words };
