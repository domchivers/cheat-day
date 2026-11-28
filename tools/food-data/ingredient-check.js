// Which of a list of ingredients the app's tables already have (28 Nov). For each name (and its other names), the closest
// entries in every table the app ships, so a person or agent can judge "covered" or "missing".
//   node ingredient-check.js <list.json>     list: [{ "name": "Gochujang", "aka": ["korean chilli paste"] }, ...]
const fs = require('fs'), path = require('path');
const R = path.join(__dirname, '..', '..', 'native', 'CheatDays', 'Resources');
const tables = { AU: 'aus-foods', UK: 'uk-foods', US: 'us-foods', USdishes: 'dishes-foods', EU: 'world-foods', TW: 'tw-foods', JP: 'jp-foods', OWN: 'built-foods', ING: 'ing-foods' };
const loaded = Object.entries(tables).filter(([, f]) => fs.existsSync(path.join(R, f + '.json')))
  .map(([k, f]) => [k, JSON.parse(fs.readFileSync(path.join(R, f + '.json'), 'utf8'))]);
const aliasFiles = { TW: 'tw-aliases', JP: 'jp-aliases', OWN: 'built-aliases', ING: 'ing-aliases' };
const words = s => s.toLowerCase().replace(/[^a-z ]/g, ' ').split(/\s+/).filter(w => w.length > 1).map(w => w.replace(/(ies|es|s)$/, m => m === 'ies' ? 'y' : ''));
const list = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
for (const item of list) {
  const names = [item.name, ...(item.aka || [])];
  const hits = [];
  for (const [k, rows] of loaded) {
    let al = [];
    const af = aliasFiles[k] && path.join(R, aliasFiles[k] + '.json');
    if (af && fs.existsSync(af)) al = JSON.parse(fs.readFileSync(af, 'utf8'));
    for (const n of names) {
      const w = words(n); if (!w.length) continue;
      for (const r of rows) {
        const rw = new Set(words(r.name));
        if (w.every(x => rw.has(x))) hits.push(`${k}: ${r.name} (${r.kcal} kcal)`);
      }
      for (const [a, target] of al) if (a.split('|').some(x => x === n.toLowerCase())) hits.push(`${k} (other name): ${target}`);
    }
  }
  const uniq = [...new Set(hits)];
  console.log(`${item.name}: ${uniq.length ? uniq.slice(0, 6).join(' | ') + (uniq.length > 6 ? ` (+${uniq.length - 6} more)` : '') : 'NONE'}`);
}
