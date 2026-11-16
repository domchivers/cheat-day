// "Half peri peri chicken from Nando's and 125g of their large chips that's weight 237g" (1.3.57, 16 Nov): the
// shop's published large chips (230 g, 533 kcal) replaced the 125 g eaten. shop_items said "Large chips x1", so the
// app counted one whole serve. With NEW=1, shop_items' description asks for the weight they had instead of a count.
// Sonnet, the app's rules, the estimate format as in n5k-run.js (copied from Assistant.swift).   node shop-grams-check.js
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
const shopItems = process.env.NEW
  ? 'with a shop: each thing as the shop sells it and how many, like "Kabana croissant x1; Tiramisu cream cake bites x4"; when they said the weight they had of one, that weight instead of how many ("Large chips 125g"); else empty'
  : 'with a shop: each thing as the shop sells it and how many, like "Kabana croissant x1; Tiramisu cream cake bites x4"; else empty';
const schema = obj({
  reply: { type: 'string', description: "What you'd say back, warm. Logging food or a change: one to three sentences. A question or advice: a proper answer (see the rules). Always filled." },
  kind: { type: 'string', enum: ['answer', 'estimate'] },
  estimate: obj({
    name: s, portion_g: n, unit: { type: 'string', enum: ['g', 'ml'] }, notes: s,
    shop: { type: 'string', description: "the shop, café, bakery or chain it's from, if they said or it shows (a logo, a bag); else empty" },
    size_unsure: { type: 'boolean', description: "true when nothing in the photo shows how big it is, or you can't tell how dense it is" },
    eaten_unsure: { type: 'boolean', description: "true when the only photo shows it finished or part eaten and you can't tell how much they had (the parts are then the full serving)" },
    side_sauce: { type: 'string', description: "the one sauce or condiment usually served on the side with this that you left out because it isn't on the food and they didn't mention it, as a food name (\"Hoisin sauce\"); else empty" },
    shop_items: { type: 'string', description: shopItems },
    parts: { type: 'array', description: 'each component, including oil, butter and the sauces in or on it as their own parts', items: obj({
      name: s, usda_name: s, grams: { type: 'number', description: 'as eaten (cooked weight)' }, kcal: n, protein_g: n, carbs_g: n, fat_g: n, numbers_from: from,
      size: s, tags: s, servings: { type: 'number', description: 'for a brand part: how many of its items or pack servings they had (1 stick = 1); 0 when they gave a weight' } }) },
  }, 'kind=estimate: a food or plate as one portion'),
});
const context = 'They live in Australia: use the usual portion sizes there. Today: budget 2000 kcal, eaten 640 kcal. Protein so far 40 g of 150 g. Workouts today: none.\nRecent days: none yet.\n';
const cases = ["Half peri peri chicken from Nando's and 125g of their large chips that's weight 237g", "Half peri peri chicken and regular chips from Nando's", '2 Kabana croissants from #1000 Bread'];
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  for (const say of cases) for (let i = 0; i < 2; i++) {
    const text = `You are the assistant inside a cheat-day food diary app called Cheat Days. ${context}They now say: "${say}"\n\n${rules}`;
    const r = await client.messages.create({ model: 'claude-sonnet-5-5', max_tokens: 8000, messages: [{ role: 'user', content: text }],
      output_config: { format: { type: 'json_schema', schema: claudeSchema(schema) } } });
    ledger.spent = +(ledger.spent + (r.usage.input_tokens * 2 + r.usage.output_tokens * 10) / 1e6).toFixed(6); ledger.calls++;
    const a = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
    const e = a.estimate || {};
    console.log(`"${say}" → ${a.kind} | shop "${e.shop}" | shop_items "${e.shop_items}" | parts: ${(e.parts || []).map(p => `${p.name} ${p.grams} g`).join(', ')}\n   reply: ${a.reply.slice(0, 140)}`);
  }
  fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
