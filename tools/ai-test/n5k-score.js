// Scores saved Nutrition5k answers against the scale, AI alone (before the app's checks): mean error and lean for
// calories, grams, protein, carbs and fat.  HALF=tune|check  node n5k-score.js <dataset dir> [variant ...]  ('' = the app's rules)
const fs = require('fs'), path = require('path');
const dir = process.argv[2], variants = process.argv.length > 3 ? process.argv.slice(3) : [''];
const picked = JSON.parse(fs.readFileSync(path.join(dir, 'picked.json'), 'utf8'))
  .filter((_, i) => process.env.HALF === 'tune' ? i % 2 === 0 : process.env.HALF === 'check' ? i % 2 === 1 : true);
const keys = [['kcal', 'kcal', 'kcal'], ['grams', 'grams', 'grams'], ['protein', 'protein', 'protein_g'], ['carbs', 'carbs', 'carbs_g'], ['fat', 'fat', 'fat_g']];
for (const v of variants) {
  const a = JSON.parse(fs.readFileSync(path.join(dir, v ? `answers-${v}.json` : 'answers.json'), 'utf8'));
  const ds = picked.filter(d => a[d.id]?.estimate?.parts?.length);
  const line = keys.map(([label, t, k]) => {
    const err = ds.map(d => { const s = a[d.id].estimate.parts.reduce((x, p) => x + (p[k] || 0), 0), tr = Math.max(d[t], 1); return (s - tr) / tr; });
    return `${label} ${(err.reduce((x, e) => x + Math.abs(e), 0) / err.length * 100).toFixed(0)}% (lean ${(err.reduce((x, e) => x + e, 0) / err.length * 100).toFixed(0)})`;
  });
  const within = ds.filter(d => Math.abs(a[d.id].estimate.parts.reduce((x, p) => x + p.kcal, 0) - d.kcal) / d.kcal <= 0.2).length;
  console.log(`${(v || 'app rules').padEnd(10)} ${ds.length} plates · ${line.join(' · ')} · kcal within 20%: ${within}`);
}
