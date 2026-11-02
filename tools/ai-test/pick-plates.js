// Picks 30 weighed dishes from Nutrition5k (CC BY 4.0) across the calorie range and fetches their overhead photos.
const fs = require('fs');
const base = 'https://storage.googleapis.com/nutrition5k_dataset/nutrition5k_dataset/';
(async () => {
  const dishes = [];
  for (const cafe of ['cafe1', 'cafe2']) {
    const csv = await (await fetch(`${base}metadata/dish_metadata_${cafe}.csv`)).text();
    for (const line of csv.trim().split('\n')) {
      const c = line.split(','), [id, kcal, mass, fat, carb, protein] = c;
      const names = []; for (let i = 7; i < c.length; i += 7) names.push(c[i]);
      dishes.push({ id, kcal: +kcal, grams: +mass, f: +fat, c: +carb, p: +protein, items: names });
    }
  }
  const usable = dishes.filter(d => d.kcal >= 120 && d.kcal <= 1200 && d.grams >= 80 && d.items.length >= 3 && d.kcal / d.grams * 100 < 900).sort((a, b) => a.id.localeCompare(b.id));
  // even spread: 6 calorie bands, first dishes per band in a fixed shuffled order
  const hash = s => { let h = 7; for (const ch of s) h = (h * 31 + ch.charCodeAt(0)) % 1000003; return h; };
  usable.sort((a, b) => hash(a.id) - hash(b.id));
  const bands = [[120, 250], [250, 350], [350, 450], [450, 600], [600, 800], [800, 1200]], out = [];
  for (const [lo, hi] of bands) {
    let got = 0;
    for (const d of usable.filter(x => x.kcal >= lo && x.kcal < hi)) {
      if (got === 5) break;
      const n = +d.id.replace('dish_', ''); if (out.some(o => Math.abs(+o.id.replace('dish_', '') - n) < 3600)) continue;
      const r = await fetch(`${base}imagery/realsense_overhead/${d.id}/rgb.png`);
      if (!r.ok) continue;
      fs.writeFileSync(`photos/plates/${d.id}.png`, Buffer.from(await r.arrayBuffer()));
      out.push({ id: d.id, photo: `photos/plates/${d.id}.png`, kcal: Math.round(d.kcal), grams: Math.round(d.grams), p: +d.p.toFixed(1), c: +d.c.toFixed(1), f: +d.f.toFixed(1), items: d.items });
      got++;
    }
  }
  fs.writeFileSync('tasks/plates.json', JSON.stringify({ source: 'Nutrition5k, CC BY 4.0, Google Research (CVPR 2021)', tasks: out }, null, 1));
  console.log(`dishes ${dishes.length}, usable ${usable.length}, picked ${out.length}`);
  out.forEach(d => console.log(d.id, d.kcal, d.grams, d.items.join(', ').slice(0, 90)));
})();
