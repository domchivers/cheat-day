// Taiwan's and Japan's tables into the app (28 Nov): the foods picked in tw-select.json / jp-select.json, under the English
// names in tw-names.json / jp-names.json, with their own per-100 g values from tw-foods.json / jp-foods.json (made by
// tw-scan.js and jp-scan.js from the downloaded files). Writes native/CheatDays/Resources/{tw,jp}-foods.json and -aliases.json.
//   node build-asia-db.js
// Licences: Taiwan TFDA, Open Government Data License v1.0 (credit required, see FoodSourcesView); Japan MEXT 2023,
// PDL 1.0 terms (source and "edited" note required).
const fs = require('fs'), path = require('path');
const here = __dirname, res = path.join(here, '..', '..', 'native', 'CheatDays', 'Resources');
const read = f => JSON.parse(fs.readFileSync(path.join(here, f), 'utf8'));

function build(key, source, valuesFile, namesFile) {
  const values = new Map(read(valuesFile).map(f => [f.id, f]));
  const names = read(namesFile);
  const foods = [], aliases = [], seen = new Set();
  let skipped = 0, missing = 0, dupes = 0;
  for (const n of names) {
    if (n.skip) { skipped++; continue; }
    // 'dried' is filler to the app's matcher ('Natto' and 'Natto, dried' looked the same): 'dry' it sees, and keeps out unless said
    const v = values.get(n.id), en = String(n.en || '').replace(/\bdried\b/gi, 'dry').replace(/\s+/g, ' ').trim();
    if (!v || v.kcal == null || !en || /[^\x00-\x7F’–é]/.test(en)) { missing++; continue; }
    if (seen.has(en.toLowerCase())) { dupes++; continue; }
    seen.add(en.toLowerCase());
    const r1 = x => x == null ? 0 : Math.round(x * 10) / 10;
    foods.push({ name: en, source, kcal: Math.round(v.kcal), p: r1(v.p), c: r1(v.c), f: r1(v.f) });
    const aka = (n.aka || []).map(a => String(a).toLowerCase().replace(/[,|]/g, ' ').replace(/\s+/g, ' ').trim()).filter(a => a && /^[\x00-\x7F]+$/.test(a));
    if (aka.length) aliases.push([aka.join('|'), en]);
  }
  fs.writeFileSync(path.join(res, `${key}-foods.json`), JSON.stringify(foods));
  fs.writeFileSync(path.join(res, `${key}-aliases.json`), JSON.stringify(aliases));
  console.log(`${key}: ${foods.length} foods, ${aliases.length} with other names; skipped ${skipped}, no values or bad name ${missing}, duplicate names ${dupes}`);
}
build('tw', 'TFDA2026', 'tw-foods.json', 'tw-names.json');
build('jp', 'MEXT2023', 'jp-foods.json', 'jp-names.json');
