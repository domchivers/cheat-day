// Taiwan TFDA food composition (data.gov.tw 8543, Open Government Data License v1.0): one row per food per nutrient.
// Folds it into one row per food with kcal, protein, carbs, fat per 100 g, then looks for everyday dishes by name.
// node tw-scan.js <path to 20_2.csv>   (writes tw-foods.json and tw-dishes.txt next to this script)
const fs = require('fs'), path = require('path');
const file = process.argv[2];
const text = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');

// a CSV line with quoted fields
function split(line) {
  const out = []; let cur = '', q = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (q) { if (ch === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += ch; }
    else if (ch === '"') q = true; else if (ch === ',') { out.push(cur); cur = ''; } else cur += ch;
  }
  out.push(cur); return out;
}
const lines = text.split(/\r?\n/).filter(Boolean);
const head = split(lines[0]);
const col = n => head.indexOf(n);
const C = { cat: col('食品分類'), id: col('整合編號'), name: col('樣品名稱'), alias: col('俗名'), en: col('樣品英文名稱'),
            desc: col('內容物描述'), item: col('分析項'), unit: col('含量單位'), per100: col('每100克含量') };
const foods = new Map(), items = new Map();
for (const l of lines.slice(1)) {
  const r = split(l), id = r[C.id];
  if (!id) continue;
  let f = foods.get(id);
  if (!f) { f = { id, cat: r[C.cat], name: r[C.name], alias: r[C.alias], en: r[C.en], desc: r[C.desc] }; foods.set(id, f); }
  const item = r[C.item], v = parseFloat(r[C.per100]);
  items.set(item, (items.get(item) || 0) + 1);
  if (isNaN(v)) continue;
  if (item === '修正熱量') f.kcal = v; else if (item === '熱量' && f.kcal == null) f.kcal = v;
  if (item === '粗蛋白') f.p = v;
  if (item === '粗脂肪') f.f = v;
  if (item === '總碳水化合物') f.c = v;
}
const all = [...foods.values()];
const cats = {}; for (const f of all) cats[f.cat] = (cats[f.cat] || 0) + 1;
const dishes = ['油條', '豆漿', '包子', '茶葉蛋', '豆花', '粥', '水餃', '小籠包', '叉燒', '炒飯', '珍珠奶茶', '蛋餅', '飯糰', '滷肉飯',
  '牛肉麵', '蘿蔔糕', '燒賣', '粽子', '鍋貼', '刈包', '鹹酥雞', '臭豆腐', '蚵仔煎', '便當', '拉麵', '壽司', '泡菜', '燒餅', '饅頭',
  '蔥油餅', '肉圓', '芋圓', '米粉', '雞排', '豆腐', '炒麵', '餛飩', '咖哩', '月餅', '奶茶'];
let out = [`foods: ${all.length}`, `categories: ${JSON.stringify(cats)}`, `with English names: ${all.filter(f => f.en).length}`,
  `with kcal+P+C+F: ${all.filter(f => f.kcal != null && f.p != null && f.c != null && f.f != null).length}`, ''];
for (const d of dishes) {
  const hit = all.filter(f => (f.name + '|' + f.alias).includes(d));
  out.push(`${d}: ${hit.length}` + (hit.length ? '  e.g. ' + hit.slice(0, 4).map(f => `${f.name} / ${f.en || '-'} (${f.kcal ?? '?'} kcal)`).join('; ') : ''));
}
fs.writeFileSync(path.join(__dirname, 'tw-dishes.txt'), out.join('\n'));
fs.writeFileSync(path.join(__dirname, 'tw-foods.json'), JSON.stringify(all));
console.log(out.join('\n'));
