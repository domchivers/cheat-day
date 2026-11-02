// 30 quick logs with answers from Australian data. The grams are stated, or are in the wording a person would use
// and written here beside it, so a wrong answer can only come from the model or the data.
const fs = require('fs');
const all = require('./data/food-db.json');
const byName = s => { const m = all.filter(f => f.name.trim() === s); if (m.length < 1) throw new Error('no food: ' + s); return m[0]; };
const logs = [
  ['200 g chicken breast, raw weight', [['Chicken, breast, lean flesh, raw', 200]]],
  ['150g raw atlantic salmon fillet', [['Salmon, Atlantic, fillet, raw', 150]]],
  ['250 g regular beef mince before cooking', [['Beef, mince, regular fat, raw', 250]]],
  ['200g raw flathead fillet', [['Flathead, fillet, raw', 200]]],
  ['300g raw rump steak', [['Beef, rump steak, untrimmed, raw', 300]]],
  ['2 large poached eggs (55 g each)', [['Egg, chicken, whole, poached', 110]]],
  ['2 hard boiled eggs, about 100g total, and 2 slices white toast, 60g total', [['Egg, chicken, whole, hard-boiled', 100], ['Bread, from white flour, toasted', 60]]],
  ['250 ml full cream milk, weighs 258 g', [['Milk, cow, fluid, regular fat (~3.5%)', 258]]],
  ['a peeled banana, 120 g', [['Banana, cavendish, peeled, raw', 120]]],
  ['200g cooked white rice', [['Rice, white, boiled or rice cooker, no added salt', 200]]],
  ['300g boiled pasta, plain', [['Pasta, white wheat flour, boiled from dry, no added salt', 300]]],
  ['50g rolled oats, dry', [['Oats, rolled, uncooked', 50]]],
  ['40g cheddar', [['Cheese, cheddar, natural, regular fat', 40]]],
  ['10 g butter', [['Butter, plain, salted', 10]]],
  ['1 tbsp olive oil, 14 g', [['Oil, olive', 14]]],
  ['half a hass avocado, 80g flesh', [['Avocado, hass, raw', 80]]],
  ['30g smooth peanut butter', [['Peanut butter, smooth & crunchy, added sugar & salt', 30]]],
  ['200g cherry tomatoes', [['Tomato, cherry, raw', 200]]],
  ['150g boiled broccoli', [['Broccoli, fresh, boiled, drained', 150]]],
  ['a tablespoon of honey, 20 g', [['Honey', 20]]],
  ['375 ml can of cola, regular, about 390 g', [['Soft drink, cola flavour', 390]]],
  ['a 375 ml full strength beer, about 375 g', [['Beer, full strength (alcohol 4-4.9% v/v)', 375]]],
  ['150g glass of red wine', [['Wine, red', 150]]],
  ['large flat white, 350 g, full cream milk', [['Coffee, flat white/latte/cappuccino, from ground coffee beans, with regular fat cow\'s milk', 350]]],
  ['95g tin of tuna in brine, drained', [['Tuna, canned in brine, drained', 95]]],
  ['150g hot chips from a fish and chip shop', [['Potato, chips, regular, independent takeaway outlet, deep fried, blended oil, salted', 150]]],
  ['50g milk chocolate', [['Chocolate, milk', 50]]],
  ['2 beef sausages, 150g raw total', [['Sausage, beef, raw', 150]]],
  ['200g chicken breast raw, 150g cooked white rice and 100g boiled broccoli', [['Chicken, breast, lean flesh, raw', 200], ['Rice, white, boiled or rice cooker, no added salt', 150], ['Broccoli, fresh, boiled, drained', 100]]],
  ['2 poached eggs 110g, 60g toast, 80g avocado and 10g butter', [['Egg, chicken, whole, poached', 110], ['Bread, from white flour, toasted', 60], ['Avocado, hass, raw', 80], ['Butter, plain, salted', 10]]],
];
const out = logs.map(([text, parts], i) => {
  const items = parts.map(([n, g]) => { const f = byName(n); return { key: f.key, name: f.name.trim(), grams: g, kcal: f.kcal * g / 100, p: f.p * g / 100, c: f.c * g / 100, f: f.f * g / 100 }; });
  const sum = k => Math.round(items.reduce((t, it) => t + it[k], 0) * 10) / 10;
  return { id: `log${String(i + 1).padStart(2, '0')}`, text, sources: items.map(it => `${it.key} ${it.name} ${it.grams} g`), kcal: Math.round(sum('kcal')), p: sum('p'), c: sum('c'), f: sum('f') };
});
fs.writeFileSync('tasks/quicklogs.json', JSON.stringify({ source: 'FSANZ AFCD Release 3', tasks: out }, null, 1));
console.log('quick logs', out.length);
