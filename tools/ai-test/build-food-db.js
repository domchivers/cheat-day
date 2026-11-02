// Builds data/food-db.json from the unzipped FSANZ AFCD Release 3 and AUSNUT 2023 spreadsheets.
// Usage: node build-food-db.js <folder holding x-afcd and x-ausnut>
const fs = require('fs'), path = require('path');
const { readSheet } = require('./xlsx.js');
const round = x => Math.round(x * 10) / 10;
function load(dir, source, keyCol, carbName) {
  const rows = readSheet(dir, 2), head = rows[2].map(h => String(h).replace(/\s+/g, ' ').trim());
  const col = name => { const i = head.findIndex(h => h.startsWith(name)); if (i < 0) throw new Error(`${source}: no column ${name}`); return i; };
  const c = { kj: col('Energy with dietary fibre'), p: col('Protein (g)'), f: head.findIndex(h => h.startsWith('Fat, total') || h.startsWith('Total fat')), carb: col(carbName), fibre: head.findIndex(h => /dietary fibre \(g\)/i.test(h)), alcohol: col('Alcohol (g)') };
  const name = head.findIndex(h => /^food name$/i.test(h)), derivation = col('Derivation');
  return rows.slice(3).filter(r => r && r[name] && typeof r[c.kj] === 'number').map(r => ({
    key: String(r[keyCol]), source, name: r[name], derivation: r[derivation],
    kcal: Math.round(r[c.kj] / 4.184), p: round(r[c.p] || 0), c: round(r[c.carb] || 0), f: round(r[c.f] || 0), fibre: round(r[c.fibre] || 0), alcohol: round(r[c.alcohol] || 0),
  }));
}
const root = process.argv[2];
const afcd = load(path.join(root, 'x-afcd'), 'AFCD3', 0, 'Available carbohydrate, with sugar alcohols');
const ausnut = load(path.join(root, 'x-ausnut'), 'AUSNUT2023', 1, 'Available carbohydrate, with sugar alcohols');
const seen = new Set(afcd.map(f => f.key));
const foods = [...afcd, ...ausnut.filter(f => !seen.has(f.key))];
fs.mkdirSync(path.join(__dirname, 'data'), { recursive: true });
fs.writeFileSync(path.join(__dirname, 'data/food-db.json'), '[\n' + foods.map(f => JSON.stringify(f)).join(',\n') + '\n]\n');
console.log(`AFCD ${afcd.length}, AUSNUT ${ausnut.length}, combined ${foods.length}`);
