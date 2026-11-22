// A receipt's calories from the photo alone, with no earlier card to lean on.   node receipt-blind-check.js receipt.jpg [runs]
const fs = require('fs'), Anthropic = require('@anthropic-ai/sdk').default;
const n = { type: 'number' }, s = { type: 'string' };
const strict = x => { if (x.type === 'object') { x.required = Object.keys(x.properties); x.additionalProperties = false; Object.values(x.properties).forEach(strict); } if (x.items) strict(x.items); return x; };
const schema = strict({ type: 'object', properties: { parts: { type: 'array', items: { type: 'object', properties: {
  name: s, grams: n, kcal_low: n, kcal: n, kcal_high: n, protein_g: n, basis: s } } } } });
const ask = `This is a delivery receipt from a Northwest Chinese noodle and barbecue restaurant in Melbourne. For each of the nine items, in the receipt's order, estimate the WHOLE serving as sold, edible cooked weight, including the oil, marinade and sauce it is normally cooked or brushed with. Use the Chinese names to identify the cut and dish, and the pieces and price to judge the size. Give a likely kcal, a realistic low and high, protein, and a short basis.`;
(async () => {
  const image = { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: fs.readFileSync(process.argv[2]).toString('base64') } };
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const runs = Number(process.argv[3] || 4);
  for (const model of ['claude-opus-5-5', 'claude-sonnet-5-5']) {
    const got = await Promise.all(Array.from({ length: runs }, () => client.messages.create({ model, max_tokens: 8000,
      messages: [{ role: 'user', content: [image, { type: 'text', text: ask }] }], output_config: { format: { type: 'json_schema', schema } } })));
    got.forEach((r, i) => {
      const parts = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join('')).parts;
      const mine = p => /stinky|臭豆腐/i.test(p.name) ? 1 : 0.5, sum = f => Math.round(parts.reduce((t, p) => t + p[f] * mine(p), 0));
      console.log(`${model} run ${i + 1}: ${parts.length} items; share ${sum('kcal')} kcal (${sum('kcal_low')}-${sum('kcal_high')}), P${sum('protein_g')}`);
      for (const p of parts) console.log(`   ${mine(p) * 100}% ${p.name}: ${Math.round(p.grams * mine(p))} g ${Math.round(p.kcal * mine(p))} kcal P${Math.round(p.protein_g * mine(p))}${i ? '' : ' | ' + p.basis}`);
    });
  }
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
