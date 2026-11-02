// 50 dishes. `like` finds the same kind of finished dish in Australian data, the check on a recipe's calories per 100 g.
const fs = require('fs');
const all = require('./data/food-db.json');
const dishes = [
  ['Spaghetti bolognese', /^Pasta.*(bolognese|meat.*sauce)/i], ['Beef lasagne', /^Lasagne.*beef|^Lasagne.*meat/i], ['Beef and vegetable stir fry', /stir.?fr.*beef|^Beef.*stir.?fr.*veg/i], ['Chicken and vegetable stir fry', /chicken.*stir.?fr|stir.?fr.*chicken/i], ['Butter chicken', /curry.*chicken.*dairy|curry.*chicken.*cream/i],
  ['Thai green chicken curry', /curry.*chicken|chicken.*curry/i], ['Beef massaman curry', /curry.*beef|beef.*curry/i], ['Lamb rogan josh', /curry.*lamb|lamb.*curry/i], ['Chickpea and spinach curry', /^curry,.*(chickpea|legume)/i], ['Chicken fried rice', /fried.*rice|rice.*fried/i],
  ['Pad thai with prawns', /pad thai|noodle.*prawn|noodle.*fried/i], ['Beef burger with cheese', /burger.*beef.*cheese|burger.*cheese/i], ['Chicken schnitzel', /schnitzel.*chicken|chicken.*schnitzel|chicken.*crumbed/i], ['Fish and chips', /fish.*batter|fish.*crumbed.*fried/i], ['Salmon with roast vegetables', /salmon.*(baked|grilled|cooked)/i],
  ['Grilled barramundi with salad', /barramundi.*(grilled|baked)/i], ['Beef chilli con carne', /chilli con carne|^Beef.*chilli/i], ['Beef stew with potatoes', /stew.*beef|beef.*stew|casserole.*beef|beef.*casserole/i], ['Roast chicken with potatoes', /ready meal, roast chicken/i], ['Roast lamb leg', /lamb, leg roast, untrimmed, roasted/i],
  ['Pork belly with rice', /pork.*belly.*(baked|roast)/i], ['Sausages and mash', /^sausage, beef, (fried|grilled)/i], ['Chicken caesar salad', /salad.*caesar|caesar/i], ['Greek salad', /salad.*greek|greek.*salad/i], ['Tuna pasta bake', /pasta.*tuna|tuna.*pasta/i],
  ['Macaroni cheese', /macaroni.*cheese|pasta.*cheese/i], ['Carbonara', /carbonara/i], ['Pesto pasta', /pasta dish.*pesto/i], ['Margherita pizza, homemade', /pizza.*(cheese|margherita|plain)/i], ['Chicken quesadilla', /quesadilla|burrito.*chicken/i],
  ['Beef tacos', /^taco, soft|^taco,.*beef/i], ['Pumpkin soup', /soup.*pumpkin|pumpkin.*soup/i], ['Minestrone', /minestrone|soup, vegetable, (homemade|canned)/i], ['Chicken noodle soup', /soup.*chicken.*noodle|chicken.*noodle.*soup|soup.*chicken/i], ['Vegetable omelette', /omelette/i],
  ['Scrambled eggs on toast', /scrambled/i], ['Pancakes with maple syrup', /pancake/i], ['Porridge with banana', /porridge/i], ['Smashed avocado on toast', /avocado.*(toast|bread)|^Toast.*avocado/i], ['Protein smoothie', /smoothie|milkshake|protein.*shake/i],
  ['Protein brownie', /brownie/i], ['Chocolate chip cookies', /biscuit.*chocolate chip|cookie/i], ['Banana bread', /banana.*(bread|cake)/i], ['Apple crumble', /crumble/i], ['Pavlova', /pavlova/i],
  ['Beef gyudon', /gyudon/i], ['Chicken katsu curry', /katsu/i], ['Vietnamese beef pho', /\bpho\b|soup.*noodle.*beef|noodle.*beef/i], ['Bibimbap', /bibimbap/i], ['Sushi rolls with salmon', /sushi/i],
];
const tasks = [], problems = [];
dishes.forEach(([name, like], i) => {
  // a stir fry or curry recipe comes without the rice or noodles it's served with, so it isn't compared with one that has them
  const servedPlain = !/rice|noodle|pho|pasta|spaghetti|lasagne|macaroni|carbonara|pesto|sushi|bibimbap|pad thai/i.test(name);
  const m = all.filter(f => like.test(f.name) && f.kcal > 20 && !(servedPlain && /rice|noodle|pasta/i.test(f.name)) && !/^sauce|seasoning|dry mix|instant|separable|liver|shell|\braw\b|condensed|biscuit, savoury|dough|powder|^vegan/i.test(f.name)).sort((a, b) => (a.source > b.source ? 1 : -1));
  if (!m.length) problems.push(name);
  const kcals = m.slice(0, 12).map(f => f.kcal).sort((a, b) => a - b);
  tasks.push({ id: `dish${String(i + 1).padStart(2, '0')}`, name, promise: /protein/i.test(name), range: kcals.length ? [kcals[0], kcals[kcals.length - 1]] : null, like: m.slice(0, 12).map(f => `${f.key} ${f.name.trim()} ${f.kcal}`) });
});
fs.writeFileSync('tasks/recipes.json', JSON.stringify({ source: 'Finished-dish check from FSANZ AUSNUT 2023 and AFCD Release 3', tasks }, null, 1));
console.log('recipes', tasks.length, 'with no Australian dish:', problems);
tasks.forEach(t => console.log(t.name, '|', t.range, '|', t.like.slice(0, 3).map(s => s.slice(8, 48)).join(' ; ')));
