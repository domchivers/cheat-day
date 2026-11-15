// The quick look at photos (Assistant.spot): a packaged food's label must not be read as a menu (its per-100 g energy
// as a dish), or the takeaway planner goes looking for the brand's "menu" online. old = the wording the app had, new =
// with labels ruled out.  node spot-label-check.js "said" photo.jpg [photo.jpg ...]   RUNS=3
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const strict = (s) => { if (s && s.type === 'object') { s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const listing = {
  old: 'when a photo is a menu or a delivery-app page: each dish on it with the energy it shows, kJ as printed (kcal × 4.184 if it shows kcal); else empty',
  new: "when a photo is a menu or a delivery-app page: each dish on it with the energy it shows, kJ as printed (kcal × 4.184 if it shows kcal); else empty. Never a packaged food's label or nutrition table: its energy per 100 g or per serving isn't a dish on a menu",
};
const ask = {
  old: (said) => `Someone logging food in a diary sent these photos and said: "${said}". List the foods and drinks you can see, and the shop if they named one or a logo shows. If a photo is a menu or a delivery-app page, list its dishes with the energy shown for each.`,
  new: (said) => `Someone logging food in a diary sent these photos and said: "${said}". List the foods and drinks you can see, and the shop if they named one or a logo shows. If a photo is a menu or a delivery-app page, list its dishes with the energy shown for each. A packet's label or nutrition table isn't a menu: leave the listing empty for it, and the shop empty unless they named a shop or café.`,
};
const schema = (w) => strict({ type: 'object', required: ['foods', 'shop', 'listing'], properties: {
  foods: { type: 'array', items: { type: 'string' }, description: 'each food or drink you can see, by its everyday name ("croissant", "kabana", "cream cake")' },
  shop: { type: 'string', description: 'the shop, café or bakery if they said it or a logo or bag shows it; else empty' },
  listing: { type: 'array', description: listing[w], items: { type: 'object', required: ['name', 'kj'], properties: { name: { type: 'string' }, kj: { type: 'number' } } } } } });
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  const said = process.argv[2], files = process.argv.slice(3), runs = Number(process.env.RUNS || 3);
  const imgs = files.map(f => ({ type: 'image', source: { type: 'base64', media_type: /\.png$/i.test(f) ? 'image/png' : 'image/jpeg', data: fs.readFileSync(f).toString('base64') } }));
  let spent = 0;
  for (const w of ['old', 'new']) {
    const out = await Promise.all(Array.from({ length: runs }, () => client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 4000,
      output_config: { effort: 'low', format: { type: 'json_schema', schema: schema(w) } }, messages: [{ role: 'user', content: [...imgs, { type: 'text', text: ask[w](said) }] }] })));
    for (const r of out) {
      spent += (r.usage.input_tokens * 0.1 + r.usage.output_tokens * 0.5) / 1e6;
      const j = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
      console.log(`${w}: listing ${j.listing.length ? 'XX ' + JSON.stringify(j.listing) : 'empty'} · shop "${j.shop}" · foods ${j.foods.join(', ')}`);
    }
  }
  ledger.spent = +(ledger.spent + spent).toFixed(6); ledger.calls += runs * 2; fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
  console.log(`$${spent.toFixed(4)}`);
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
