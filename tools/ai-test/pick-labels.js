// Fetches candidate Australian nutrition label photos with their Open Food Facts numbers (ODbL / CC BY-SA).
// Candidates still need reading by eye: only labels confirmed that way become tasks.
const fs = require('fs');
const UA = { 'User-Agent': 'CheatDaysBenchmark/1.0' };
const folder = code => code.length > 8 ? code.padStart(13, '0').replace(/^(...)(...)(...)(.*)$/, '$1/$2/$3/$4') : code;
(async () => {
  const out = [];
  for (let page = 1; page <= 12 && out.length < 60; page++) {
    const j = await (await fetch(`https://search.openfoodfacts.org/search?q=countries_tags:%22en:australia%22&page=${page}&page_size=100&fields=code,product_name,brands,nutriments,images`, { headers: UA })).json();
    for (const h of j.hits || []) {
      if (out.length >= 60) break;
      const n = h.nutriments || {}, sel = (h.images || {}).nutrition_en;
      if (!sel || !sel.rev || !(sel.sizes?.full?.w >= 900) || n['energy-kj_100g'] == null && n['energy-kcal_100g'] == null || n.proteins_100g == null) continue;
      const im = await fetch(`https://images.openfoodfacts.org/images/products/${folder(h.code)}/nutrition_en.${sel.rev}.full.jpg`, { headers: UA });
      if (!im.ok) continue;
      const buf = Buffer.from(await im.arrayBuffer()); if (buf.length < 30000 || buf.length > 4e6) continue;
      const file = `photos/labels/${h.code}.jpg`; fs.writeFileSync(file, buf);
      out.push({ id: h.code, name: h.product_name, brand: h.brands, photo: file, kcal: n['energy-kcal_100g'] ?? Math.round(n['energy-kj_100g'] / 4.184), kj: n['energy-kj_100g'], p: n.proteins_100g, c: n.carbohydrates_100g, f: n.fat_100g });
    }
  }
  fs.writeFileSync('tasks/labels-candidates.json', JSON.stringify(out, null, 1));
  console.log(out.length); out.forEach(o => console.log(o.id, '|', o.name, '|', o.kj, o.kcal, o.p, o.c, o.f));
})();
