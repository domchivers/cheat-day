// The same 30 plates, each with what a person might type: the foods they can name, no weights.
// Seasonings and traces (under 15 g) are left out, as nobody would list them.
const fs = require('fs');
const base = 'https://storage.googleapis.com/nutrition5k_dataset/nutrition5k_dataset/';
(async () => {
  const plates = JSON.parse(fs.readFileSync('tasks/plates.json', 'utf8')).tasks, rows = new Map();
  for (const cafe of ['cafe1', 'cafe2']) {
    for (const line of (await (await fetch(`${base}metadata/dish_metadata_${cafe}.csv`)).text()).trim().split('\n')) rows.set(line.split(',')[0], line.split(','));
  }
  const tasks = plates.map(p => {
    const c = rows.get(p.id), foods = [];
    for (let i = 6; i + 3 < c.length; i += 7) if (+c[i + 2] >= 15) foods.push(c[i + 1]);
    return { ...p, said: foods.join(', ') };
  });
  fs.writeFileSync('tasks/plates-described.json', JSON.stringify({ source: 'Nutrition5k, CC BY 4.0; the description is the foods over 15 g', tasks }, null, 1));
  console.log(tasks.length); tasks.slice(0, 5).forEach(t => console.log(t.id, '|', t.said));
})();
