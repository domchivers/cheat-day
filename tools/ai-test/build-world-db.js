// Builds data/world-foods.json: other countries' official food tables (open licences, credited in the app's Food data
// sources), in the same shape as food-db.json, for any country to fall back to after its own table and the US dish
// table. From the files in data/raw (downloaded, not committed); a country whose file isn't there is skipped:
//   data/raw/no/foods.json        Norway, Matvaretabellen 2026 (CC BY 4.0), www.matvaretabellen.no/api/en/foods.json
//   data/raw/dk/x                 Denmark, Frida 5.5 (CC BY 4.0), the unzipped xlsx
//   data/raw/fr/x, fr/alim.xml    France, ANSES Ciqual 2025 (Licence Ouverte 2.0), the unzipped xlsx and the English names
//   data/raw/ch/x                 Switzerland, FSVO Swiss food composition database 7.1, the unzipped xlsx
// Usage: node build-world-db.js
const fs = require('fs'), path = require('path');
const { readSheet } = require('./xlsx.js');
const raw = path.join(__dirname, 'data/raw');
const has = p => fs.existsSync(path.join(raw, p));
const round = x => Math.round(x * 10) / 10;
// "4,41", "< 0,5", "traces", "-", "n.d.", "tr." all to numbers: traces and below-limit as 0, missing as undefined
function num(v) {
  if (typeof v === 'number') return v;
  if (v === undefined || v === null) return undefined;
  const s = String(v).trim().replace(',', '.');
  if (/^(traces?|tr\.?)$/i.test(s) || /^</.test(s)) return 0;
  const x = parseFloat(s);
  return Number.isFinite(x) ? x : undefined;
}
const skip = name => /\b(baby food|infant formula|follow-on formula|human milk|breast milk)\b/i.test(name);
const food = (source, key, name, v) => (v.kcal === undefined || !name || skip(name)) ? null : {
  key: String(key), source, name: String(name).trim().replace(/\s+/g, ' '),
  kcal: Math.round(v.kcal), p: round(v.p || 0), c: round(v.c || 0), f: round(v.f || 0), fibre: round(v.fibre || 0), alcohol: round(v.alcohol || 0),
};
const all = [], counts = {};
function add(source, rows) { const ok = rows.filter(Boolean); all.push(...ok); counts[source] = ok.length; }

// Norway: one object per food, the macros among its constituents
if (has('no/foods.json')) {
  const ids = { Protein: 'p', Karbo: 'c', Fett: 'f', Fiber: 'fibre', Alko: 'alcohol' };
  add('NOMatvare2026', JSON.parse(fs.readFileSync(path.join(raw, 'no/foods.json'), 'utf8')).foods.map(x => {
    const v = { kcal: x.calories?.quantity };
    for (const c of x.constituents) if (ids[c.nutrientId] && c.quantity !== undefined) v[ids[c.nutrientId]] = c.quantity;
    return food('NOMatvare2026', x.foodId, x.foodName, v);
  }));
}

// Denmark: Data_Table, the English parameter names on its second row, foods from its fifth (Danish name, English name, id)
if (has('dk/x')) {
  const rows = readSheet(path.join(raw, 'dk/x'), 2), head = rows[1];
  const col = n => { const i = head.findIndex(h => h === n); if (i < 0) throw new Error('Frida: no column ' + n); return i; };
  const c = { kcal: col('Energy (kcal)'), p: col('Protein'), c: col('Available carbohydrates'), f: col('Fat'), fibre: col('Dietary fibre'), alcohol: col('Alcohol') };
  add('DKFrida55', rows.slice(4).filter(r => r && r[1]).map(r => food('DKFrida55', r[2], r[1],
    Object.fromEntries(Object.entries(c).map(([k, i]) => [k, num(r[i])])))));
}

// France: the xlsx's numbers by alim_code, the English names from the XML
if (has('fr/x') && has('fr/alim.xml')) {
  const eng = new Map([...fs.readFileSync(path.join(raw, 'fr/alim.xml'), 'utf8').matchAll(/<alim_code>\s*(\d+)\s*<\/alim_code>[\s\S]*?<alim_nom_eng>\s*([^<]*?)\s*<\/alim_nom_eng>/g)].map(m => [m[1], m[2].replace(/&apos;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&')]));
  const rows = readSheet(path.join(raw, 'fr/x'), 1), head = rows[0].map(h => String(h || '').replace(/\s+/g, ' '));
  const col = re => { const i = head.findIndex(h => re.test(h)); if (i < 0) throw new Error('Ciqual: no column ' + re); return i; };
  const c = { kcal: col(/^Energie, Règlement UE N° 1169 2011 \(kcal/), p: col(/^Protéines, N x facteur de Jones/), c: col(/^Glucides/), f: col(/^Lipides/),
              fibre: col(/^Fibres alimentaires/), alcohol: col(/^Alcool/) };
  const code = head.indexOf('alim_code');
  add('FRCiqual2025', rows.slice(1).filter(r => r && eng.get(String(r[code]).trim())).map(r => food('FRCiqual2025', r[code], eng.get(String(r[code]).trim()),
    Object.fromEntries(Object.entries(c).map(([k, i]) => [k, num(r[i])])))));
}

// Switzerland: Generic Foods, headers on its third row
if (has('ch/x')) {
  const rows = readSheet(path.join(raw, 'ch/x'), 1), head = rows[2];
  const col = n => { const i = head.findIndex(h => h === n); if (i < 0) throw new Error('Swiss: no column ' + n); return i; };
  const c = { kcal: col('Energy, kilocalories (kcal)'), p: col('Protein (g)'), c: col('Carbohydrates, available (g)'), f: col('Fat, total (g)'),
              fibre: col('Dietary fibres (g)'), alcohol: col('Alcohol (g)') };
  add('CHSwiss71', rows.slice(3).filter(r => r && r[3]).map(r => food('CHSwiss71', r[0], r[3],
    Object.fromEntries(Object.entries(c).map(([k, i]) => [k, num(r[i])])))));
}

// Sweden: the Swedish Food Agency's API, fetched food by food into se/foods.json ({ number: { name, values } }), by
// EuroFIR code: ENERC in kcal, PROT, CHO (available), FAT, FIBT, ALC
if (has('se/foods.json')) {
  const codes = { PROT: 'p', CHO: 'c', FAT: 'f', FIBT: 'fibre', ALC: 'alcohol' };
  add('SELivsmedel', Object.entries(JSON.parse(fs.readFileSync(path.join(raw, 'se/foods.json'), 'utf8'))).map(([id, x]) => {
    const v = {};
    for (const n of x.values) {
      if (n.code === 'ENERC' && /kcal/i.test(n.unit)) v.kcal = num(n.value);
      else if (codes[n.code] && /^g$/i.test(n.unit)) v[codes[n.code]] = num(n.value);
    }
    return food('SELivsmedel', id, x.name, v);
  }));
}

// Germany: BLS 4.0 (Max Rubner-Institut, CC BY 4.0), the unzipped data xlsx in de/x, its English "Food name" column
if (has('de/x')) {
  const rows = readSheet(path.join(raw, 'de/x'), 1), head = rows[0];
  const col = start => { const i = head.findIndex(h => String(h || '').startsWith(start)); if (i < 0) throw new Error('BLS: no column ' + start); return i; };
  const c = { kcal: col('ENERCC '), p: col('PROT625 '), c: col('CHO '), f: col('FAT '), fibre: col('FIBT '), alcohol: col('ALC ') };
  const code = col('BLS Code'), name = col('Food name');
  add('DEBLS40', rows.slice(1).filter(r => r && r[name]).map(r => food('DEBLS40', r[code], r[name],
    Object.fromEntries(Object.entries(c).map(([k, i]) => [k, num(r[i])])))));
}

fs.writeFileSync(path.join(__dirname, 'data/world-foods.json'), '[\n' + all.map(f => JSON.stringify(f)).join(',\n') + '\n]\n');
console.log(counts, 'in all', all.length);
