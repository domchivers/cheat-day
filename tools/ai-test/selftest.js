// Proves the test tool with fake models, no key and no spending: right answers pass, wrong ones fail,
// the budget stops it, and a rerun doesn't repeat or lose anything.
const assert = require('assert'), fs = require('fs'), os = require('os'), path = require('path');
const { jobs, split, resolve } = require('./jobs.js');
const { run, report } = require('./run.js');
const fresh = () => fs.mkdtempSync(path.join(os.tmpdir(), 'ai-test-'));
const usage = { input: 1000, output: 1000 };
const reply = o => async () => ({ text: JSON.stringify(o), stop: 'end_turn', usage });
const pricey = { input: 1, output: 9 };   // $0.01 a call
const fake = fn => ({ extraModels: { fake: { provider: 'fake', id: 'fake', ...pricey } }, ask: () => fn, models: ['fake'] });
let checks = 0; const ok = (v, m) => { assert.ok(v, m); checks++; };

(async () => {
  // quick logs: exact and just inside pass, 25% out and rubbish fail
  const log = jobs.quicklogs.tasks()[0];
  ok(jobs.quicklogs.score(log, { kcal: log.kcal, protein: log.p }).pass, 'exact log passes');
  ok(jobs.quicklogs.score(log, { kcal: log.kcal * 1.08 }).pass, '8% off passes');
  ok(!jobs.quicklogs.score(log, { kcal: log.kcal * 1.25 }).pass, '25% off fails');
  ok(!jobs.quicklogs.score(log, { kcal: 'lots' }).pass, 'text fails');

  // plates use the wider 20%
  const plate = { kcal: 500, p: 30 };
  ok(jobs.plates.score(plate, { kcal: 590, protein: 30 }).pass, '18% off passes');
  ok(!jobs.plates.score(plate, { kcal: 650, protein: 30 }).pass, '30% off fails');
  ok(jobs.plates.score({ ...plate, grams: 300 }, { kcal: 500, items: [{ grams: 280 }] }).gramsOk, 'close plate weight passes');
  ok(!jobs.plates.score({ ...plate, grams: 300 }, { kcal: 500, items: [{ grams: 500 }] }).gramsOk, 'wrong plate weight fails');
  ok(!jobs.plans.score({ room: 2000, now: '09:00', avoid: 'x', saved: [], say: 'Dinner', maxSlots: 1 }, { slots: [{ time: '12:00', title: 'A', detail: '', kcal: 400, protein: 20, carbs: 50, fat: 13 }, { time: '18:00', title: 'B', detail: '', kcal: 400, protein: 20, carbs: 50, fat: 13 }] }).pass, 'planning more than was asked fails');
  ok(jobs.recipes.score({ promise: false, range: null }, { cookedGrams: 300, ingredients: [{ name: 'Chicken breast', grams: 300, kcal: 294, protein_g: 67.5, carbs_g: 0, fat_g: 2.4 }, { name: 'Tomato paste', grams: 70, kcal: 68, protein_g: 3, carbs_g: 11, fat_g: 0.5 }] }).numbersOk, 'one small ingredient off is not a fail');
  ok(resolve('Water').kcal === 0, 'water has no calories');

  // labels need the macros too
  const label = { kcal: 400, p: 10, c: 50, f: 20 };
  ok(jobs.labels.score(label, { kcal_per_100: 400, protein: 10, carbs: 50, fat: 20 }).pass, 'right label passes');
  ok(!jobs.labels.score(label, { kcal_per_100: 400, protein: 30, carbs: 50, fat: 20 }).pass, 'wrong protein fails');
  ok(!jobs.labels.score(label, { kcal_per_100: 400, protein: null, carbs: 50, fat: 20 }).pass, 'unread fails');

  // recipes: the food finder, then good and bad recipes
  ok(/Chicken, breast/.test(resolve('Chicken breast').name), 'finds chicken breast: ' + resolve('Chicken breast').name);
  ok(/Salmon/.test(resolve('Salmon fillet, skin on').name), 'finds salmon');
  ok(/Oil, olive/.test(resolve('olive oil').name), 'finds olive oil');
  ok(/raw/i.test(resolve('Chicken thigh').name), 'chicken is raw unless it says cooked');
  ok(resolve('zzzqqq') === null, 'nonsense finds nothing');
  const finds = [['Vegetable oil', /^Oil, canola/], ['Spaghetti', /^Pasta, white wheat flour, dry/], ['Cream', /^Cream, thickened/], ['Plain flour', /^Flour, wheat, white, plain/], ['Beef mince', /mince, regular/], ['Chicken thigh fillets', /thigh, lean flesh, raw/], ['Garlic cloves', /^Garlic/], ['Tinned tomatoes', /canned/], ['Basmati rice', /^Rice, white, uncooked/], ['Cooked basmati rice', /boiled/], ['Soy sauce', /^Sauce, soy/], ['Carrots', /^Carrot, mature/], ['Potatoes', /^Potato/], ['Eggs', /^Egg, chicken, whole, raw/], ['Sugar', /^Sugar, white/], ['Whole milk', /regular fat \(~3.5%\)/], ['Parmesan', /parmesan/], ['Large brown onion, diced', /^Onion/], ['Salmon fillet', /^Salmon/], ['Kingfish', /^Kingfish/], ['Rump steak', /rump/i], ['Greek yoghurt', /^Yoghurt/], ['Cocoa powder', /^Cocoa/]];
  for (const [name, want] of finds) { const f = resolve(name); ok(f && want.test(f.name), `${name} found ${f && f.name}`); }
  for (const name of ['Vanilla essence', 'Saffron threads', 'Puff oil']) { const f = resolve(name); ok(!f || !/pastry|mustard/i.test(f.name), `${name} found ${f && f.name}`); }
  const dish = { name: 'Test', promise: false, range: [100, 200] };
  const good = { cookedGrams: 300, ingredients: [{ name: 'Chicken breast', grams: 300, kcal: 294, protein_g: 67.5, carbs_g: 0, fat_g: 2.4 }, { name: 'Olive oil', grams: 10, kcal: 88, protein_g: 0, carbs_g: 0, fat_g: 10 }] };
  const g = jobs.recipes.score(dish, good);
  ok(g.pass && g.scored, 'good recipe passes: ' + JSON.stringify(g));
  ok(!jobs.recipes.score(dish, { ...good, ingredients: [{ ...good.ingredients[0], kcal: 700, fat_g: 47 }] }).numbersOk, 'chicken at double its calories fails');
  ok(!jobs.recipes.score(dish, { ...good, ingredients: [{ ...good.ingredients[0], kcal: 100 }] }).addsUp, "kcal that doesn't match its macros fails");
  ok(!jobs.recipes.score(dish, { ...good, cookedGrams: 60 }).dishOk, 'implausible finished dish fails');
  ok(!jobs.recipes.score({ ...dish, promise: true }, { ...good, ingredients: [{ name: 'Olive oil', grams: 50, kcal: 442, protein_g: 0, carbs_g: 0, fat_g: 50 }] }).promiseOk, 'protein dish with no protein fails');
  ok(jobs.recipes.score(dish, { cookedGrams: 100, ingredients: [{ name: 'zzzqqq', grams: 100, kcal: 100, protein_g: 25, carbs_g: 0, fat_g: 0 }] }).scored === false, 'unknown foods are left unscored, not passed');

  // plans
  const P = { room: 2000, protein: 100, now: '09:00', avoid: 'mushrooms', saved: [{ name: 'Brownie', kcal: 320 }], say: 'Hit my protein', mustUse: 'Brownie', free: 500 };
  const slot = o => ({ time: '12:00', title: 'Burger', detail: 'with chips', kcal: 800, protein: 100, carbs: 50, fat: 40, saved: '', ...o });
  const brownie = slot({ title: 'Brownie', kcal: 320, protein: 20, carbs: 30, fat: 13.5, saved: 'Brownie' });
  ok(jobs.plans.score(P, { slots: [slot(), brownie] }).pass, 'good plan passes');
  ok(!jobs.plans.score(P, { slots: [slot({ kcal: 2500, carbs: 300, fat: 65 }), brownie] }).inRoom, 'over the calories fails');
  ok(!jobs.plans.score(P, { slots: [slot({ kcal: 1600, carbs: 200, fat: 44 }), brownie] }).leavesFree, "doesn't leave the free calories");
  ok(!jobs.plans.score(P, { slots: [slot({ protein: 10, carbs: 80, fat: 50 }), brownie] }).proteinOk, 'missed protein fails');
  ok(!jobs.plans.score(P, { slots: [slot({ time: '08:00' }), brownie] }).times, 'a time already passed fails');
  ok(jobs.plans.score(P, { slots: [slot({ detail: 'mushroom sauce' }), brownie] }).banned.length, 'a food they never eat fails');
  ok(!jobs.plans.score(P, { slots: [slot(), { ...brownie, kcal: 600, carbs: 100 }] }).saved, 'saved meal with changed numbers fails');

  // budget: 10 calls allowed at $0.01 each, then it stops before overspending
  let dir = fresh(), calls = 0;
  let r = await run({ dir, budget: 0.1, jobs: ['quicklogs'], ...fake(async () => { calls++; return { text: '{"kcal":1}', usage }; }) });
  ok(r.stopped && /budget/.test(r.stopped), 'budget stops it: ' + r.stopped);
  ok(r.spent <= 0.1, `never over budget: ${r.spent}`);
  ok(calls > 0 && calls < 11, `stopped early: ${calls} calls`);

  // resuming: no repeats, no lost answers, the spend carries over
  const before = calls;
  r = await run({ dir, budget: 0.1, jobs: ['quicklogs'], ...fake(async () => { calls++; return { text: '{"kcal":1}', usage }; }) });
  ok(calls === before, 'a rerun at the same budget spends nothing more');
  r = await run({ dir, budget: 10, jobs: ['quicklogs'], ...fake(async () => { calls++; return { text: '{"kcal":1}', usage }; }) });
  ok(calls === jobs.quicklogs.tasks().length, `every task once: ${calls}`);
  const lines = fs.readFileSync(path.join(dir, 'answers.jsonl'), 'utf8').trim().split('\n');
  ok(new Set(lines.map(l => JSON.parse(l).key)).size === lines.length, 'no duplicates');
  ok(Math.abs(r.spent - calls * 0.01) < 1e-6, `the ledger adds up: ${r.spent}`);

  // failures: three in a row stop it, and they aren't saved as answers, so a retry finds them
  dir = fresh();
  r = await run({ dir, budget: 1, jobs: ['quicklogs'], ...fake(async () => { const e = new Error('secret-key-text'); e.status = 500; throw e; }) });
  ok(/three failures/.test(r.stopped), 'three failures stop it');
  ok(!fs.existsSync(path.join(dir, 'answers.jsonl')), 'failures are not answers');
  ok(!fs.readFileSync(path.join(dir, 'errors.log'), 'utf8').includes('secret-key-text'), 'error text is not logged');
  ok(r.spent === 0, 'failures cost nothing');

  // nonsense from a model scores as a fail, not a crash
  dir = fresh();
  await run({ dir, budget: 1, jobs: ['quicklogs'], limit: 1, ...fake(async () => ({ text: 'I cannot help', usage })) });
  const row = report(dir)[0];
  ok(row.bad === 1 && row.passed === 0, 'a bad answer counts as a fail');

  // a known perfect model and a known wrong one score 100 and 0
  dir = fresh();
  const byText = Object.fromEntries(jobs.quicklogs.tasks().map(t => [t.text, t]));
  const answerFor = (fix) => async (_m, prompt) => { const t = Object.values(byText).find(x => prompt.includes(`"${x.text}"`)); return { text: JSON.stringify({ kcal: t.kcal * fix, protein: t.p }), usage }; };
  await run({ dir, budget: 5, jobs: ['quicklogs'], ...fake(answerFor(1)) });
  ok(report(dir).every(x => x.passRate === 100), 'perfect model scores 100');
  dir = fresh();
  await run({ dir, budget: 5, jobs: ['quicklogs'], ...fake(answerFor(1.5)) });
  ok(report(dir).every(x => x.passRate === 0), 'wrong model scores 0');

  // held-back tasks really are held back: about 30%, and none in both groups
  for (const j of ['quicklogs', 'plates', 'recipes', 'plans', 'chats']) {
    const ids = jobs[j].tasks().map(t => t.id), fin = ids.filter(i => split(i) === 'final').length, share = fin / ids.length;
    ok(share > 0.1 && share < 0.5, `${j} held back ${Math.round(share * 100)}%`);
  }
  console.log(`All ${checks} checks passed.`);
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
