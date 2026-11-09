// Haiku or Sonnet for photo estimates: the app's own rules and photo format (Assistant.swift), the same plates on both,
// scored against Nutrition5k's measured kcal and weight. Stops at the budget.  node photo-model-check.js [plates each way] [budget $]
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const source = fs.readFileSync(path.join(__dirname, '../../supabase/functions/ai/index.ts'), 'utf8');
const body = source.match(/function claudeSchema\(s: any\): any \{[\s\S]*?\n\}/)[0].replace(/: any/g, '').replace(/ as any/g, '');
const claudeSchema = new Function(`${body}; return claudeSchema;`)();
const swift = fs.readFileSync(path.join(__dirname, '../../native/CheatDays/Model/Assistant.swift'), 'utf8');
const amounts = fs.readFileSync(path.join(__dirname, '../../native/CheatDays/Model/Sanity.swift'), 'utf8').match(/static let amounts = "([^"]*)"/)[1];
const rules = swift.match(/static let rules = """\n([\s\S]*?)\n\s*"""/)[1].split('\n').map(l => l.trim()).join('\n').replace('\\(Sanity.amounts)', amounts);

// Assistant.format(photos: true): reply, kind answer or estimate, and the estimate as the app asks for it
const n = { type: 'number' }, s = { type: 'string' };
const obj = (props, desc = '') => ({ type: 'object', properties: props, required: Object.keys(props), ...(desc ? { description: desc } : {}) });
const from = { type: 'string', enum: ['label', 'them', 'brand', 'estimate'], description: 'label: worked out from a nutrition label in the photos or chat; them: numbers they gave; brand: a specific packaged product (brand and name) with no label to hand, your best guess; estimate: otherwise' };
const schema = obj({
  reply: { type: 'string', description: "What you'd say back, warm. Logging food or a change: one to three sentences. A question or advice: a proper answer (see the rules). Always filled." },
  kind: { type: 'string', enum: ['answer', 'estimate'] },
  estimate: obj({
    name: s, portion_g: n, unit: { type: 'string', enum: ['g', 'ml'] }, notes: s,
    shop: { type: 'string', description: "the shop, café, bakery or chain it's from, if they said or it shows (a logo, a bag); else empty" },
    size_unsure: { type: 'boolean', description: 'true when nothing in the photo shows how big it is, or you can\'t tell how dense it is' },
    eaten_unsure: { type: 'boolean', description: "true when the only photo shows it finished or part eaten and you can't tell how much they had (the parts are then the full serving)" },
    side_sauce: { type: 'string', description: 'the one sauce or condiment usually served on the side with this that you left out because it isn\'t on the food and they didn\'t mention it, as a food name ("Hoisin sauce"); else empty' },
    shop_items: { type: 'string', description: 'with a shop: each thing as the shop sells it and how many, like "Kabana croissant x1; Tiramisu cream cake bites x4"; else empty' },
    parts: { type: 'array', description: 'each component, including oil, butter and the sauces in or on it as their own parts', items: obj({
      name: s, usda_name: { type: 'string', description: "the closest USDA FoodData Central SR Legacy description, e.g. 'Chicken, broilers or fryers, breast, meat only, cooked, roasted'" },
      grams: { type: 'number', description: 'as eaten (cooked weight)' }, kcal: n, protein_g: n, carbs_g: n, fat_g: n, numbers_from: from,
      size: { type: 'string', description: 'from a photo: the size you judged it at and what against, a few words ("4 bites, about 5 × 5 × 4 cm, against the box"); else empty' },
      tags: { type: 'string', description: 'comma-separated, only these words and only those that apply: homemade, bought, natural, processed, raw, cooked, fried, baked, grilled, boiled, steamed, skin on, skin off, plain, filled, coated, reduced fat' },
      servings: { type: 'number', description: 'for a brand part: how many of its items or pack servings they had (1 stick = 1); 0 when they gave a weight' } }) },
  }, 'kind=estimate: a food or plate as one portion'),
});
const context = 'They live in Australia: use the usual portion sizes there. Today: budget 2350 kcal, eaten 425 kcal (Breakfast: "Protein Yogurt Bowl" 295 g 425 kcal), 1925 kcal left. Protein so far 40 g of 180 g, carbs 30 g, fat 10 g. Workouts today: none. Weight 80 kg.\n';
const MODELS = { haiku: { id: 'claude-haiku-5-5', price: [0.10, 0.50], effort: 'low' }, sonnet: { id: 'claude-sonnet-5-5', price: [2, 10] } };

(async () => {
  const each = Number(process.argv[2] || 12), budget = Number(process.argv[3] || 1.5);
  const plates = JSON.parse(fs.readFileSync(path.join(__dirname, 'tasks/plates-described.json'), 'utf8')).tasks.filter(t => fs.existsSync(path.join(__dirname, t.photo)));
  // the same plates twice: once with what's on them said, once just the photo, as most people send it
  const cases = [...plates.slice(0, each).map(t => ({ t, said: t.said, way: 'described' })), ...plates.slice(each, each * 2).map(t => ({ t, said: "What's this?", way: 'photo only' }))];
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  let spent = 0; const rows = [];
  outer: for (const c of cases) for (const [name, m] of Object.entries(MODELS)) {
    if (spent > budget) { console.log(`stopped at the budget: $${spent.toFixed(3)}`); break outer; }
    const img = { type: 'image', source: { type: 'base64', media_type: c.t.photo.endsWith('.png') ? 'image/png' : 'image/jpeg', data: fs.readFileSync(path.join(__dirname, c.t.photo)).toString('base64') } };
    const text = `You are the assistant inside a cheat-day food diary app called Cheat Days.\n${rules}\n${context}They now say: "${c.said}"`;
    try {
      const r = await client.messages.create({ model: m.id, max_tokens: 4000, messages: [{ role: 'user', content: [img, { type: 'text', text }] }],
        output_config: { ...(m.effort ? { effort: m.effort } : {}), format: { type: 'json_schema', schema: claudeSchema(schema) } } });
      const cost = (r.usage.input_tokens * m.price[0] + r.usage.output_tokens * m.price[1]) / 1e6; spent += cost;
      ledger.spent = +(ledger.spent + cost).toFixed(6); ledger.calls++;
      const a = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
      const parts = a.estimate?.parts || [], kcal = parts.reduce((x, p) => x + (p.kcal || 0), 0), grams = parts.reduce((x, p) => x + (p.grams || 0), 0);
      const row = { plate: c.t.id, way: c.way, model: name, kcal: Math.round(kcal), want: c.t.kcal, err: c.t.kcal ? Math.round((kcal - c.t.kcal) / c.t.kcal * 100) : null,
                    gErr: c.t.grams ? Math.round((grams - c.t.grams) / c.t.grams * 100) : null, cost };
      rows.push(row);
      console.log(`${c.way.padEnd(10)} ${name.padEnd(6)} ${String(row.kcal).padStart(4)} vs ${String(c.t.kcal).padStart(4)} kcal (${row.err > 0 ? '+' : ''}${row.err}%) grams ${row.gErr > 0 ? '+' : ''}${row.gErr}%  $${cost.toFixed(4)}  ${a.estimate?.name || a.kind}`);
    } catch (e) { console.log(`${c.way} ${name} FAILED ${e.status || ''} ${e.error?.error?.message || e.message}`); }
  }
  fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
  const med = xs => { const v = xs.filter(x => x != null).map(Math.abs).sort((a, b) => a - b); return v.length ? v[v.length >> 1] : null; };
  console.log('\nway        model  plates within20%  median kcal err  median grams err  cost each');
  for (const way of ['described', 'photo only']) for (const name of Object.keys(MODELS)) {
    const g = rows.filter(r => r.way === way && r.model === name); if (!g.length) continue;
    console.log(`${way.padEnd(10)} ${name.padEnd(6)} ${String(g.length).padStart(6)} ${String(g.filter(r => Math.abs(r.err) <= 20).length).padStart(9)}  ${String(med(g.map(r => r.err))).padStart(14)}%  ${String(med(g.map(r => r.gErr))).padStart(15)}%  $${(g.reduce((x, r) => x + r.cost, 0) / g.length).toFixed(4)}`);
  }
  console.log(`\nThis run: $${spent.toFixed(3)}. Test spend so far: $${ledger.spent.toFixed(4)}`);
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
