// Builds data/uk-foods.json (PHE CoFID 2021, McCance and Widdowson's) and data/us-foods.json (USDA FoodData Central
// SR Legacy) in the same shape as food-db.json, from the files in data/raw (downloaded, not committed):
//   data/raw/uk/x-cofid  the unzipped CoFID 2021 .xlsx
//   data/raw/us/sr/...   the unzipped SR Legacy CSV
// Usage: node build-country-db.js
const fs = require('fs'), path = require('path');
const { readSheet } = require('./xlsx.js');
const round = x => Math.round(x * 10) / 10;
const n = v => { const x = parseFloat(v); return Number.isFinite(x) ? x : 0; };   // "Tr" (trace) and "N" (not measured) count as 0
const out = (file, foods) => fs.writeFileSync(path.join(__dirname, 'data', file), '[\n' + foods.map(f => JSON.stringify(f)).join(',\n') + '\n]\n');

// UK: the Proximates sheet, headers on the first row, foods from the fourth
const raw = path.join(__dirname, 'data/raw');
const rows = readSheet(path.join(raw, 'uk/x-cofid'), 4), head = rows[0];
const col = name => { const i = head.findIndex(h => h && String(h).startsWith(name)); if (i < 0) throw new Error('CoFID: no column ' + name); return i; };
const c = { code: col('Food Code'), name: col('Food Name'), p: col('Protein (g)'), f: col('Fat (g)'), carb: col('Carbohydrate (g)'), kcal: col('Energy (kcal)'), alcohol: col('Alcohol (g)'), fibre: col('AOAC fibre (g)') };
const uk = rows.slice(3).filter(r => r && r[c.name] && !/weighed (whole|with)/i.test(r[c.name]) && Number.isFinite(parseFloat(r[c.kcal]))).map(r => ({
  key: String(r[c.code]), source: 'CoFID2021', name: String(r[c.name]).trim(),
  kcal: Math.round(n(r[c.kcal])), p: round(n(r[c.p])), c: round(n(r[c.carb])), f: round(n(r[c.f])), fibre: round(n(r[c.fibre])), alcohol: round(n(r[c.alcohol])),
}));
out('uk-foods.json', uk);

// US: food.csv for the names, food_nutrient.csv for the numbers
const sr = path.join(raw, 'us/sr', fs.readdirSync(path.join(raw, 'us/sr')).find(d => d.startsWith('FoodData_Central_sr_legacy')));
const csv = file => fs.readFileSync(path.join(sr, file), 'utf8').split(/\r?\n/).slice(1).filter(Boolean)
  .map(line => [...line.matchAll(/"((?:[^"]|"")*)"|([^,]+)|(?<=,)(?=,|$)/g)].map(m => (m[1] ?? m[2] ?? '').replace(/""/g, '"')));
const want = { 1008: 'kcal', 1003: 'p', 1005: 'c', 1004: 'f', 1079: 'fibre', 1018: 'alcohol' }, values = new Map();
for (const [, id, nutrient, amount] of csv('food_nutrient.csv')) {
  const k = want[nutrient]; if (!k) continue;
  if (!values.has(id)) values.set(id, {});
  values.get(id)[k] = n(amount);
}
const us = csv('food.csv').filter(([id]) => values.get(id)?.kcal !== undefined).map(([id, , name]) => {
  const v = values.get(id);
  return { key: id, source: 'SRLegacy', name: name.trim(), kcal: Math.round(v.kcal), p: round(v.p || 0), c: round(v.c || 0), f: round(v.f || 0), fibre: round(v.fibre || 0), alcohol: round(v.alcohol || 0) };
});
out('us-foods.json', us);
console.log(`UK ${uk.length}, US ${us.length}`);
