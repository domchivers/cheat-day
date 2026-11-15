// Nutrition5k's weighed plates (CC BY 4.0, Thames et al., CVPR 2021) through Claude the way the app sends a photo:
// Sonnet, the app's real rules, the photo-only format (reply, kind, estimate). Each answer is saved with the weighed
// truth; the fixtures for the Mac's offline replay test (DatasetReplayTests) are written from them.
//   node n5k-run.js <dataset dir> [limit]      (answers already saved aren't asked again)
// A trial rule: VARIANT=name (rules in variants/<name>.txt, added to the app's) and HALF=tune|check (even or odd plates).
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const source = fs.readFileSync(path.join(__dirname, '../../supabase/functions/ai/index.ts'), 'utf8');
const body = source.match(/function claudeSchema\(s: any\): any \{[\s\S]*?\n\}/)[0].replace(/: any/g, '').replace(/ as any/g, '');
const claudeSchema = new Function(`${body}; return claudeSchema;`)();
const swift = fs.readFileSync(path.join(__dirname, '../../native/CheatDays/Model/Assistant.swift'), 'utf8');
const amounts = fs.readFileSync(path.join(__dirname, '../../native/CheatDays/Model/Sanity.swift'), 'utf8').match(/static let amounts = "([^"]*)"/)[1];
const rules = swift.match(/static let rules = """\n([\s\S]*?)\n\s*"""/)[1].split('\n').map(l => l.trim()).join('\n').replace('\\(Sanity.amounts)', amounts);

const n = { type: 'number' }, s = { type: 'string' };
const obj = (props, desc = '') => ({ type: 'object', properties: props, required: Object.keys(props), ...(desc ? { description: desc } : {}) });
const from = { type: 'string', enum: ['label', 'them', 'brand', 'estimate'], description: 'label: worked out from a nutrition label in the photos or chat; them: numbers they gave; brand: a specific packaged product (brand and name) with no label to hand, your best guess; estimate: otherwise' };
// as Assistant.full's estimate (native/CheatDays/Model/Assistant.swift), sent as format(photos: true)
const schema = obj({
  reply: { type: 'string', description: "What you'd say back, warm. Logging food or a change: one to three sentences. A question or advice: a proper answer (see the rules). Always filled." },
  kind: { type: 'string', enum: ['answer', 'estimate'] },
  estimate: obj({
    name: s, portion_g: n, unit: { type: 'string', enum: ['g', 'ml'] }, notes: s,
    shop: { type: 'string', description: "the shop, café, bakery or chain it's from, if they said or it shows (a logo, a bag); else empty" },
    size_unsure: { type: 'boolean', description: "true when nothing in the photo shows how big it is, or you can't tell how dense it is" },
    eaten_unsure: { type: 'boolean', description: "true when the only photo shows it finished or part eaten and you can't tell how much they had (the parts are then the full serving)" },
    side_sauce: { type: 'string', description: "the one sauce or condiment usually served on the side with this that you left out because it isn't on the food and they didn't mention it, as a food name (\"Hoisin sauce\"); else empty" },
    shop_items: { type: 'string', description: 'with a shop: each thing as the shop sells it and how many, like "Kabana croissant x1; Tiramisu cream cake bites x4"; else empty' },
    parts: { type: 'array', description: 'each component, including oil, butter and the sauces in or on it as their own parts', items: obj({
      name: s, usda_name: { type: 'string', description: "the closest USDA FoodData Central SR Legacy description, e.g. 'Chicken, broilers or fryers, breast, meat only, cooked, roasted'" },
      grams: { type: 'number', description: 'as eaten (cooked weight)' }, kcal: n, protein_g: n, carbs_g: n, fat_g: n, numbers_from: from,
      size: { type: 'string', description: 'from a photo: the size you judged it at and what against, a few words ("4 bites, about 5 × 5 × 4 cm, against the box"); else empty' },
      tags: { type: 'string', description: 'comma-separated, only these words and only those that apply: homemade, bought, natural, processed, raw, cooked, fried, baked, grilled, boiled, steamed, skin on, skin off, plain, filled, coated, reduced fat' },
      servings: { type: 'number', description: 'for a brand part: how many of its items or pack servings they had (1 stick = 1); 0 when they gave a weight' } }) },
  }, 'kind=estimate: a food or plate as one portion'),
});
const context = 'They live in Australia: use the usual portion sizes there. Today: budget 2000 kcal, eaten 640 kcal. Protein so far 40 g of 150 g. Workouts today: none.\nRecent days: none yet.\n';
const say = 'Lunch';
const variant = process.env.VARIANT || '', extra = variant ? '\n' + fs.readFileSync(path.join(__dirname, 'variants', variant + '.txt'), 'utf8').trim() : '';

(async () => {
  const dir = process.argv[2], limit = Number(process.argv[3] || 1e9);
  const picked = JSON.parse(fs.readFileSync(path.join(dir, 'picked.json'), 'utf8')).filter((_, i) => process.env.HALF === 'tune' ? i % 2 === 0 : process.env.HALF === 'check' ? i % 2 === 1 : true).slice(0, limit);
  const answersFile = path.join(dir, variant ? `answers-${variant}.json` : 'answers.json');
  const answers = fs.existsSync(answersFile) ? JSON.parse(fs.readFileSync(answersFile, 'utf8')) : {};
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  let spent = 0;
  const todo = picked.filter(d => !answers[d.id]);
  for (let i = 0; i < todo.length; i += 4) {
    await Promise.all(todo.slice(i, i + 4).map(async d => {
      const text = `You are the assistant inside a cheat-day food diary app called Cheat Days. ${context}They now say: "${say}" (1 photo)\n\n${rules}${extra}`;
      const img = { type: 'image', source: { type: 'base64', media_type: 'image/png', data: fs.readFileSync(path.join(dir, 'photos', d.id + '.png')).toString('base64') } };
      try {
        const r = await client.messages.create({ model: 'claude-sonnet-5-5', max_tokens: 12000, messages: [{ role: 'user', content: [img, { type: 'text', text }] }],
          output_config: { format: { type: 'json_schema', schema: claudeSchema(schema) } } });
        spent += (r.usage.input_tokens * 2 + r.usage.output_tokens * 10) / 1e6; ledger.calls++;
        answers[d.id] = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
        const e = answers[d.id].estimate, k = e.parts.reduce((a, p) => a + p.kcal, 0);
        console.log(`${d.id}: truth ${d.kcal.toFixed(0)} kcal ${d.grams.toFixed(0)} g · AI ${k.toFixed(0)} kcal ${e.parts.reduce((a, p) => a + p.grams, 0).toFixed(0)} g · ${e.name}`);
      } catch (err) { console.log(`${d.id}: FAILED ${err.status} ${err.error?.error?.message || err.message}`); }
    }));
    fs.writeFileSync(answersFile, JSON.stringify(answers, null, 1));
  }
  ledger.spent = +(ledger.spent + spent).toFixed(6); fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
  console.log(`$${spent.toFixed(3)} this run, ${todo.length} plates`);
})().catch(e => { console.error('FAILED', e.message); process.exit(1); });
