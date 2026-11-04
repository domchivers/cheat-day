// The owner's Assistant messages that went wrong, through Claude with the app's real Assistant schema and rules
// (copied from native/CheatDays/Model/Assistant.swift), converted the way supabase/functions/ai does. About half a cent.
//   node assistant-check.js
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const source = fs.readFileSync(path.join(__dirname, '../../supabase/functions/ai/index.ts'), 'utf8');
const body = source.match(/function claudeSchema\(s: any\): any \{[\s\S]*?\n\}/)[0].replace(/: any/g, '').replace(/ as any/g, '');
const claudeSchema = new Function(`${body}; return claudeSchema;`)();
const { resolve } = require('./jobs.js');

const n = { type: 'number' }, s = { type: 'string' }, nn = { type: 'number', nullable: true }, ns = { type: 'string', nullable: true };
const obj = (props, nullable = false, desc = '') => ({ type: 'object', properties: props, required: Object.keys(props), ...(nullable ? { nullable: true } : {}), ...(desc ? { description: desc } : {}) });
const arr = (items, desc = '') => ({ type: 'array', items, ...(desc ? { description: desc } : {}) });
const schema = obj({
  reply: { type: 'string', description: "What you'd say back, warm and short (one to three sentences). Always filled." },
  kind: { type: 'string', enum: ['answer', 'estimate', 'plan', 'edit', 'recipe', 'lighter'] },
  estimate: obj({
    name: s, portion_g: n, unit: { type: 'string', enum: ['g', 'ml'] }, kcal_total: n, protein_g: n, carbs_g: n, fat_g: n, notes: s,
    parts: arr(obj({ name: s, usda_name: { type: 'string', description: "the closest USDA FoodData Central SR Legacy description, e.g. 'Chicken, broilers or fryers, breast, meat only, cooked, roasted'" },
      grams: { type: 'number', description: 'as eaten (cooked weight)' }, kcal: n, protein_g: n, carbs_g: n, fat_g: n }), 'each component, including oil, butter and sauces as their own parts'),
  }, true, 'kind=estimate: a food or plate as one portion'),
  plan: obj({ suggestions: arr(obj({ name: s, amount: s, kcal: n, protein_g: n, carbs_g: n, fat_g: n, why: s })) }, true, 'kind=plan: 3 to 5 things for the rest of today'),
  edit: obj({ actions: arr(obj({
    action: { type: 'string', enum: ['add', 'remove', 'update', 'workout'] },
    target: ns, name: ns, grams: { type: 'number', nullable: true, description: 'for add and update: the amount in grams (ml for drinks)' },
    kcal: nn, protein_g: nn, carbs_g: nn, fat_g: nn, minutes: nn, effort: ns, activity: ns,
  })) }, true, "kind=edit: changes to today's list or a workout to log"),
  recipe: obj({ name: s, portions: n, ingredients: arr(obj({ name: s, grams: n, kcal: n, protein_g: n, carbs_g: n, fat_g: n })), steps: arr(s), notes: s }, true, 'kind=recipe: a dish to cook and save as a meal'),
  lighter: obj({ name: s, tips: arr(s), kcal_per_serving: n, protein_g: n, carbs_g: n, fat_g: n }, true, 'kind=lighter: a lighter way to have something'),
});

// Claude's grammar for the schema above is "too large" (every nullable is a union): the slim form the app sends to Claude
// keeps reply and kind required, the five answers optional, and no nulls inside (an unused number is 0, a string "").
function slim(sc) {
  const strip = x => {
    if (Array.isArray(x)) return x.map(strip);
    if (!x || typeof x !== 'object') return x;
    const { nullable, ...rest } = x, out = {};
    for (const [k, v] of Object.entries(rest)) out[k] = k === 'properties' ? Object.fromEntries(Object.entries(v).map(([p, q]) => [p, strip(q)])) : k === 'enum' ? v : strip(v);
    return out;
  };
  const out = strip(sc);
  out.required = ['reply', 'kind'];
  return out;
}

// the rules as the app sends them
const swift = fs.readFileSync(path.join(__dirname, '../../native/CheatDays/Model/Assistant.swift'), 'utf8');
const amounts = fs.readFileSync(path.join(__dirname, '../../native/CheatDays/Model/Sanity.swift'), 'utf8').match(/static let amounts = "([^"]*)"/)[1];
const rules = swift.match(/static let rules = """\n([\s\S]*?)\n\s*"""/)[1].split('\n').map(l => l.trim()).join('\n').replace('\\(Sanity.amounts)', amounts);

const context = 'They live in Australia: use the usual portion sizes there. Today: budget 1650 kcal, eaten 980 kcal ("Aldi BBQ whole chicken" 570 kcal, "Roasted Cauliflower" 113 kcal, "Weet-Bix" 297 kcal), 670 kcal left. Protein so far 74 g of 150 g, carbs 60 g, fat 40 g. Workouts today: none. Weight 82.4 kg.\nRecent days: none yet.\n';
const stop = new Set("a an the and or with on in of for to my me i m s t had have has having ate eat eating some much many how what can is was it its this that these those last left calories calorie cals kcal grams gram g ml kg tsp tbsp cup cups slice slices piece pieces bowl plate good when cutting bulking remove add instead about just only plus also then dinner lunch breakfast snack today yesterday".split(' '));
// the app's AusFoods.named + Assistant.foodData
function foodData(text) {
  const chunks = text.toLowerCase().split(/[^a-z]+/).reduce((a, x) => { if (!x || stop.has(x)) a.push([]); else a[a.length - 1].push(x); return a; }, [[]]).filter(c => c.length), out = [];
  for (const c of chunks) { const taken = new Set(); for (let n = Math.min(3, c.length); n >= 1; n--) for (let i = 0; i + n <= c.length; i++) {
    if ([...Array(n).keys()].some(k => taken.has(i + k))) continue;
    const said = c.slice(i, i + n).join(' '), f = resolve(said); if (!f) continue;
    for (let k = 0; k < n; k++) taken.add(i + k); if (!out.some(o => o.f.name === f.name)) out.push({ said, f }); } }
  if (!out.length) return '';
  const one = x => String(Math.round(x * 10) / 10);
  return 'Food data for what they named, per 100 g, from the official Australian food tables:\n' + out.map(o => `- "${o.said}": ${o.f.name}: ${one(o.f.kcal)} kcal, protein ${one(o.f.p)} g, carbs ${one(o.f.c)} g, fat ${one(o.f.f)} g`).join('\n') +
    "\nWhen one of these is the food they mean, use its numbers exactly (in answers too) and work amounts out from them; never a remembered value. Ignore any that's a different food from what they mean (raw versus cooked, a different dish).\n";
}
const cases = [
  { say: 'How much water melon to have for 88 calories', earlier: '' },
  { say: 'I had 2 eggs on toast with butter and a flat white', earlier: '' },
  // { say: '1/2tsp sesame oil', earlier: 'They: roasted cauliflower 100g with some sesame oil\nYou: Here is your roasted cauliflower. [you worked out: Roasted Cauliflower, 113 kcal]' },
  // { say: 'Sesame oil - 1/2 tsp', earlier: '' },
  { say: '110g cabbage, 170g cucumber', earlier: '' },
  // { say: 'is cucumber good when cutting?', earlier: '' },
];
const PRICE = JSON.parse(source.match(/\[HAIKU\]: (\[[^\]]*\])/)[1]);

(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  for (const c of cases) {
    const text = `You are the assistant inside a cheat-day food diary app called Cheat Days. ${context}${c.earlier ? `Recent conversation:\n${c.earlier}\n` : ''}They now say: "${c.say}"\n${foodData(c.say)}\n${rules}`;
    const t0 = Date.now();
    const r = await client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 4000, messages: [{ role: 'user', content: [{ type: 'text', text }] }],
      output_config: { effort: 'low', format: { type: 'json_schema', schema: claudeSchema(slim(schema)) } } });
    const cost = (r.usage.input_tokens * PRICE[0] + r.usage.output_tokens * PRICE[1]) / 1e6;
    ledger.spent = +(ledger.spent + cost).toFixed(6); ledger.calls++;
    const a = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
    console.log(`\n"${c.say}" → ${a.kind} (${((Date.now() - t0) / 1000).toFixed(1)} s, $${cost.toFixed(5)}): ${a.reply}`);
    const show = (name, g, k, p, cb, f) => {
      const d = resolve(name), db = d && g ? `   data: ${d.name} → ${Math.round(d.kcal * g / 100)} kcal, P ${(d.p * g / 100).toFixed(1)} C ${(d.c * g / 100).toFixed(1)} F ${(d.f * g / 100).toFixed(1)}` : '   data: no match';
      console.log(`  ${name} ${g} g: ${k} kcal, P ${p} C ${cb} F ${f}\n${db}`);
    };
    if (a.estimate) a.estimate.parts.forEach(x => show(x.name, x.grams, x.kcal, x.protein_g, x.carbs_g, x.fat_g));
    if (a.edit) a.edit.actions.forEach(x => show(x.name || x.target, x.grams, x.kcal, x.protein_g, x.carbs_g, x.fat_g));
  }
  fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
  console.log(`\nTest spend so far: $${ledger.spent.toFixed(4)}`);
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
