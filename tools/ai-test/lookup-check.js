// Can Claude look a packaged food's label up on the web and still answer in the app's JSON?  node lookup-check.js [model] [tool]
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const model = process.argv[2] || 'claude-haiku-5-5', tool = process.argv[3] || 'web_search_20250305';
const schema = { type: 'object', additionalProperties: false, required: ['found', 'serving_g', 'kcal', 'protein_g', 'carbs_g', 'fat_g', 'source'],
  properties: { found: { type: 'boolean' }, serving_g: { type: 'number' }, kcal: { type: 'number' }, protein_g: { type: 'number' }, carbs_g: { type: 'number' }, fat_g: { type: 'number' }, source: { type: 'string' } } };
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  const t0 = Date.now();
  const r = await client.messages.create({ model, max_tokens: 3000,
    tools: [{ type: tool, name: 'web_search', max_uses: 2, user_location: { type: 'approximate', country: 'AU' } }, ...(process.argv[5] ? [{ type: process.argv[5], name: 'web_fetch', max_uses: 2 }] : [])],
    messages: [{ role: 'user', content: `Find the nutrition panel for this packaged food sold in Australia: "${process.argv[4] || 'Monarc Mini Mango Frozen Yogurt Stick'}". Give the numbers per serving exactly as the label says (the brand\'s own site or a supermarket listing). found false if you cannot find a real label.` }],
    output_config: { ...(model.includes('haiku') ? { effort: 'low' } : {}), format: { type: 'json_schema', schema } } });
  const price = model.includes('sonnet') ? [2, 10] : [0.1, 0.5], searches = r.usage.server_tool_use?.web_search_requests ?? 0;
  const cost = (r.usage.input_tokens * price[0] + r.usage.output_tokens * price[1]) / 1e6 + searches * 0.01;
  ledger.spent = +(ledger.spent + cost).toFixed(6); ledger.calls++; fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
  console.log(model, tool, r.stop_reason, `${((Date.now() - t0) / 1000).toFixed(1)} s`, `$${cost.toFixed(4)}`, `searches ${searches}`, `in ${r.usage.input_tokens}`);
  console.log(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
  console.log(`Test spend so far: $${ledger.spent.toFixed(4)}`);
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
