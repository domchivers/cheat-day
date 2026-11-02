// Scores every saved answer afresh, costs nothing, and prints the final table for each model.
const fs = require('fs');
const { jobs, split, parse } = require('./jobs.js');
const rows = fs.readFileSync('results/answers.jsonl', 'utf8').trim().split('\n').map(l => JSON.parse(l));
const median = a => { a = a.filter(x => x != null).map(Math.abs).sort((p, q) => p - q); return a.length ? a[a.length >> 1] : null; };
const out = {};
for (const r of rows) {
  let answer = r.answer; if (!answer && !jobs[r.job].text) { try { answer = parse(r.text); } catch {} }
  const t = jobs[r.job].tasks().find(x => x.id === r.task);
  const s = answer && t ? jobs[r.job].score(t, answer) : { pass: false, badAnswer: true };
  const g = (out[`${r.job}|${r.model}`] ||= { all: [], cost: 0 });
  g.all.push({ s, final: split(r.task) === 'final' }); g.cost += r.cost || 0;
}
const counted = a => a.filter(x => x.s.pass !== null && x.s.scored !== false);
for (const k of Object.keys(out).sort()) {
  const g = out[k], all = counted(g.all), fin = counted(g.all.filter(x => x.final));
  console.log(k.padEnd(24), 'pass', `${all.filter(x => x.s.pass).length}/${all.length}`.padEnd(7), 'held back', `${fin.filter(x => x.s.pass).length}/${fin.length}`.padEnd(6),
    'kcal miss', String(median(g.all.map(x => x.s.error))).padEnd(5), 'weight within 20%', String(g.all.filter(x => x.s.gramsOk).length).padEnd(3), 'unusable', g.all.filter(x => x.s.badAnswer).length, 'each', `${(g.cost / g.all.length * 100).toFixed(3)}c`);
}
