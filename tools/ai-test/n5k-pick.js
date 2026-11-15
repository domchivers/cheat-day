// Picks ~N real plates from Nutrition5k's test split (CC BY 4.0, Thames et al., CVPR 2021) and downloads their overhead
// photo: whole plates (3+ ingredients, 200 g+), one per plate (the dataset scans plates as they're built up), with the
// weighed truth.  node n5k-pick.js <dataset dir> [N=100]   → <dir>/picked.json + <dir>/photos/<dish>.png
const fs = require('fs'), path = require('path');
const dir = process.argv[2], N = Number(process.argv[3] || 100);
const B = 'https://storage.googleapis.com/nutrition5k_dataset/nutrition5k_dataset';
const test = new Set(fs.readFileSync(path.join(dir, 'dish_ids/splits/rgb_test_ids.txt'), 'utf8').split(/\s+/).filter(Boolean));
const rows = ['dish_metadata_cafe1.csv', 'dish_metadata_cafe2.csv'].flatMap(f => fs.readFileSync(path.join(dir, 'metadata', f), 'utf8').split('\n').filter(Boolean));
const dishes = rows.map(l => {
  const c = l.split(','), ing = [];
  for (let i = 6; i + 6 < c.length; i += 7) ing.push({ name: c[i + 1], grams: +c[i + 2], kcal: +c[i + 3], fat: +c[i + 4], carbs: +c[i + 5], protein: +c[i + 6] });
  return { id: c[0], kcal: +c[1], grams: +c[2], fat: +c[3], carbs: +c[4], protein: +c[5], ing };
}).filter(d => test.has(d.id) && d.ing.length >= 3 && d.grams >= 200 && d.kcal >= 150 && d.ing.every(i => i.name && !/^ingr_/.test(i.name)));
// one per plate: of dishes whose ingredients are a subset of another's, keep the fullest
dishes.sort((a, b) => b.ing.length - a.ing.length);
const kept = [];
for (const d of dishes) {
  const names = new Set(d.ing.map(i => i.name));
  if (kept.some(k => d.ing.every(i => k.names.has(i.name)) && Math.abs(+k.id.slice(5) - +d.id.slice(5)) < 3600)) continue;
  kept.push({ ...d, names });
}
// spread over the range of sizes, not just the biggest plates
kept.sort((a, b) => a.kcal - b.kcal);
const step = Math.max(1, kept.length / (N * 1.4));
const pool = kept.filter((_, i) => Math.floor(i / step) !== Math.floor((i - 1) / step) || i === 0);
(async () => {
  fs.mkdirSync(path.join(dir, 'photos'), { recursive: true });
  const out = [];
  for (const d of pool) {
    if (out.length >= N) break;
    const file = path.join(dir, 'photos', d.id + '.png');
    if (!fs.existsSync(file)) {
      const r = await fetch(`${B}/imagery/realsense_overhead/${d.id}/rgb.png`);
      if (!r.ok) continue;   // not every dish has an overhead photo
      fs.writeFileSync(file, Buffer.from(await r.arrayBuffer()));
    }
    const { names, ...rest } = d; out.push(rest);
  }
  fs.writeFileSync(path.join(dir, 'picked.json'), JSON.stringify(out, null, 1));
  const mb = out.reduce((s, d) => s + fs.statSync(path.join(dir, 'photos', d.id + '.png')).size, 0) / 1e6;
  console.log(`${kept.length} whole plates in the test split; picked ${out.length}, photos ${mb.toFixed(1)} MB; kcal ${out[0]?.kcal.toFixed(0)}–${out.at(-1)?.kcal.toFixed(0)}`);
})();
