// A label only becomes a task when a blind reading of the photo agrees with Open Food Facts' numbers.
const fs = require('fs');
const cand = JSON.parse(fs.readFileSync('tasks/labels-candidates.json', 'utf8')), blind = JSON.parse(fs.readFileSync('tasks/labels-blind.json', 'utf8'));
const tasks = [], off = [];
for (const b of blind) {
  if (b.skip) continue;
  const c = cand.find(x => x.id === b.id); if (!c) continue;
  const kcal = b.unit === 'kJ' ? b.energy / 4.184 : b.energy;
  const agree = Math.abs(kcal - c.kcal) <= Math.max(c.kcal * 0.03, 3) && [['p', 'p'], ['c', 'c'], ['f', 'f']].every(([k]) => Math.abs(b[k] - c[k]) <= 0.6);
  if (agree) tasks.push({ id: b.id, name: c.name, photo: c.photo, kcal: Math.round(kcal), p: b.p, c: b.c, f: b.f, printed: `${b.energy} ${b.unit} per ${b.basis}` });
  else off.push(`${b.id} ${c.name}: photo ${Math.round(kcal)}/${b.p}/${b.c}/${b.f}, recorded ${Math.round(c.kcal)}/${c.p}/${c.c}/${c.f}`);
}
fs.writeFileSync('tasks/labels.json', JSON.stringify({ source: 'Photos and numbers from Open Food Facts (ODbL / CC BY-SA), each confirmed by a blind reading of the photo', tasks }, null, 1));
console.log(`agree ${tasks.length}, disagree ${off.length}, skipped ${blind.filter(b => b.skip).length}`); console.log(off.join('\n'));
