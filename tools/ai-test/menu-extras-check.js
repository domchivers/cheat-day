// A restaurant's menu with its add-ons (extra chicken, an extra patty) listed as kind "extra", so an order can be a
// dish plus what makes up the protein.  node menu-extras-check.js "Zeus Street Greek" [seen;seen]
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const strict = (s) => { if (s && s.type === 'object') { s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const n = { type: 'number' }, s = { type: 'string' };
const menuSchema = strict({ type: 'object', required: ['found', 'restaurant', 'source', 'items'], properties: {
  found: { type: 'boolean' }, restaurant: s, source: s,
  items: { type: 'array', items: { type: 'object', required: ['name', 'kind', 'published', 'kj', 'kcal', 'protein_g', 'carbs_g', 'fat_g'], properties: {
    name: s, kind: { type: 'string', enum: ['main', 'side', 'drink', 'dessert', 'extra'] }, published: { type: 'string', enum: ['full', 'energy', 'none'] },
    kj: n, kcal: n, protein_g: n, carbs_g: n, fat_g: n } } } } });
// kept word for word with Takeaway.menuAsk
const menuAsk = (r, area, want, seen = []) => `Find the current menu of "${r}"${area ? ` in ${area}` : ''}, a restaurant, takeaway or chain in Australia, and the nutrition it publishes. Look first at its listing on DoorDash, Uber Eats or Menulog, which has the full current menu and where chains put kJ in each item's name ("Chicken Burger (2280 kJ)"), then its own website or nutrition PDF.${want.length ? ` They want: ${want.join(', ')}. Make sure those dishes are in the list if it sells them, with the kJ its listing shows today, not an old menu's.` : ''}${seen.length ? ` They read these on its listing today: ${seen.join(', ')}. List each with exactly that kJ, and estimate its protein, carbs and fat for that energy.` : ''} List up to 30 of its items, mains first, each as one serving as sold (with its size or pieces in the name, "Original tenders, 4 pcs"). Then up to 6 of the add-ons it sells for its dishes that add protein (extra chicken, extra meat, an extra patty, an egg, halloumi, falafel), each as one add, as kind extra.
For each item: published is full when the restaurant gives its calories and protein, energy when it gives only kJ or kcal, none when it gives nothing. kj: exactly as published, else 0. kcal: as published, else kJ ÷ 4.184, else your estimate. protein_g, carbs_g and fat_g: as published, else your honest estimate from what the item is and its usual portion. kind: main, side, drink or dessert, or extra for an add-on to a dish that isn't ordered by itself ("Add Chicken", "Extra Patty").
found false if you can't find its menu at all. source: where the numbers came from, a few words. Open the restaurant's DoorDash or Uber Eats store page with web_fetch and read the kJ from the item names there. When sources disagree, the delivery listing is today's menu: use its number. Never guess a kJ: an item whose energy you didn't read on a page has kj 0 and published none.`;
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  const restaurant = process.argv[2] || 'Zeus Street Greek', seen = (process.argv[3] || '').split(';').filter(Boolean);
  const t0 = Date.now();
  const r = await client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 12000, messages: [{ role: 'user', content: menuAsk(restaurant, '', [], seen) }],
    tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 3, user_location: { type: 'approximate', country: 'AU' } }, { type: 'web_fetch_20250910', name: 'web_fetch', max_uses: 3 }],
    output_config: { effort: 'low', format: { type: 'json_schema', schema: menuSchema } } });
  const searches = r.usage.server_tool_use?.web_search_requests ?? 0, cost = (r.usage.input_tokens * 0.1 + r.usage.output_tokens * 0.5) / 1e6 + searches * 0.01;
  ledger.spent = +(ledger.spent + cost).toFixed(6); ledger.calls++; fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
  const j = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
  console.log(`${restaurant}: ${r.stop_reason} ${((Date.now() - t0) / 1000).toFixed(1)} s $${cost.toFixed(4)} searches ${searches} found ${j.found} source: ${j.source}`);
  const by = {}; for (const i of j.items) (by[i.kind] = by[i.kind] || []).push(i);
  for (const k of Object.keys(by)) { console.log(`-- ${k} (${by[k].length})`); for (const i of by[k].slice(0, k === 'extra' ? 10 : 6)) console.log(`   ${i.published.padEnd(6)} ${String(i.kj).padStart(5)} kJ ${String(Math.round(i.kcal)).padStart(4)} kcal P${i.protein_g}  ${i.name}`); }
  console.log(`Test spend so far: $${ledger.spent.toFixed(4)}`);
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
