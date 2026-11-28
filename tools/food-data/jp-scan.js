// Japan MEXT Standard Tables of Food Composition 2023 (八訂増補2023, Excel errata of 2026-03-27; PDL 1.0, commercial use allowed
// with the citation and a note that it was edited). One row per food. node jp-scan.js <unpacked xlsx dir>
const fs = require('fs'), path = require('path'), { rows } = require('./xlsx-rows');
const all = [];
const num = s => { if (s == null) return null; const t = String(s).replace(/[()]/g, '').trim(); if (t === 'Tr') return 0; const v = parseFloat(t); return isNaN(v) ? null : v; };
for (const r of rows(process.argv[2], 1).slice(12)) {
  if (!r[1] || !/^\d{5}$/.test(r[1])) continue;
  all.push({ id: r[1], group: r[0], name: (r[3] || '').replace(/\s+/g, ' ').trim(), kcal: num(r[6]), p: num(r[9]), f: num(r[12]), c: num(r[20]) });
}
const groups = {}; for (const f of all) groups[f.group] = (groups[f.group] || 0) + 1;
const dishes = ['ラーメン', 'おにぎり', '牛丼', 'みそ汁', 'ぎょうざ', 'しゅうまい', 'カレー', '天ぷら', 'とんかつ', 'から揚げ', '焼きそば', 'お好み焼き',
  'たこ焼き', 'うどん', 'そば', 'すし', '親子丼', '中華まん', '春巻き', '豆乳', '油揚げ', '納豆', '茶わん蒸し', 'コロッケ', '卵焼き', 'ハンバーグ',
  'チャーハン', '麻婆', '酢豚', 'えびフライ', 'ぎょうざの皮', 'もち', 'たい焼き', 'どら焼き', '大福', 'ビビンバ', 'キムチ', 'トッポッキ'];
const out = [`foods: ${all.length}`, `groups: ${JSON.stringify(groups)}`, `with kcal+P+C+F: ${all.filter(f => [f.kcal, f.p, f.c, f.f].every(v => v != null)).length}`,
  `prepared foods (group 18): ${all.filter(f => f.group === '18').length}`, ''];
for (const d of dishes) {
  const hit = all.filter(f => f.name.includes(d));
  out.push(`${d}: ${hit.length}` + (hit.length ? '  e.g. ' + hit.slice(0, 3).map(f => `${f.name} (${f.kcal ?? '?'} kcal)`).join('; ') : ''));
}
fs.writeFileSync(path.join(__dirname, 'jp-dishes.txt'), out.join('\n'));
fs.writeFileSync(path.join(__dirname, 'jp-foods.json'), JSON.stringify(all));
console.log(out.join('\n'));
