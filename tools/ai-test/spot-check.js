// The quick look at photos, as the app sends it (Assistant.spot), with the menu listing it now reads too.  node spot-check.js photo.png "said"
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const strict = (s) => { if (s && s.type === 'object') { s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const schema = strict({ type: 'object', required: ['foods', 'shop', 'listing'], properties: {
  foods: { type: 'array', items: { type: 'string' }, description: 'each food or drink you can see, by its everyday name ("croissant", "kabana", "cream cake")' },
  shop: { type: 'string', description: 'the shop, café or bakery if they said it or a logo or bag shows it; else empty' },
  listing: { type: 'array', description: 'when a photo is a menu or a delivery-app page: each dish on it with the energy it shows, kJ as printed (kcal × 4.184 if it shows kcal); else empty',
    items: { type: 'object', required: ['name', 'kj'], properties: { name: { type: 'string' }, kj: { type: 'number' } } } } } });
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  const img = fs.readFileSync(process.argv[2]).toString('base64'), said = process.argv[3] || 'This burger for dinner';
  const t0 = Date.now();
  const r = await client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 12000, output_config: { effort: 'low', format: { type: 'json_schema', schema } },
    messages: [{ role: 'user', content: [{ type: 'image', source: { type: 'base64', media_type: 'image/png', data: img } },
      { type: 'text', text: `Someone logging food in a diary sent these photos and said: "${said}". List the foods and drinks you can see, and the shop if they named one or a logo shows. If a photo is a menu or a delivery-app page, list its dishes with the energy shown for each.` }] }] });
  const cost = (r.usage.input_tokens * 0.1 + r.usage.output_tokens * 0.5) / 1e6;
  ledger.spent = +(ledger.spent + cost).toFixed(6); ledger.calls++; fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
  console.log(r.stop_reason, `${((Date.now() - t0) / 1000).toFixed(1)} s $${cost.toFixed(4)}`);
  console.log(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
