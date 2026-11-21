// The menu lookup for a small place that publishes nothing (21 Nov, PUBCHA): it gave "Large Fried Boneless Chicken",
// which wasn't on the owner's DoorDash. Takeaway.menuAsk as it is against it with "only items read on a page".
// On Haiku with the menu job's tools, as the server sends it. A few cents a run.   node pubcha-menu-check.js [runs] [restaurant]
const Anthropic = require('@anthropic-ai/sdk').default;
const strict = (s) => { if (s && s.type === 'object') { s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const n = { type: 'number' }, s = { type: 'string' };
const menuSchema = strict({ type: 'object', required: ['found', 'restaurant', 'source', 'items'], properties: {
  found: { type: 'boolean' }, restaurant: s, source: s,
  items: { type: 'array', items: { type: 'object', required: ['name', 'kind', 'published', 'kj', 'kcal', 'protein_g', 'carbs_g', 'fat_g'], properties: {
    name: s, kind: { type: 'string', enum: ['main', 'side', 'drink', 'dessert'] }, published: { type: 'string', enum: ['full', 'energy', 'none'] },
    kj: n, kcal: n, protein_g: n, carbs_g: n, fat_g: n } } } } });
const ONLY = ` Only list items you read named on a page or in search results for this place, under the names it uses there; never add a dish you'd expect a place like it to sell. When you found only a few, list only those.`;
// kept word for word with Takeaway.menuAsk (no area, want or seen)
const ask = (r, extra) => `Find the current menu of "${r}", a restaurant, takeaway or chain in Australia, and the nutrition it publishes. Look first for the nutrition it publishes itself: chains in Australia list kJ (often protein too) on their own website's menu or nutrition page, or a nutrition PDF; search the web for "${r} nutrition information" first, then open its own page or PDF from those results with web_fetch (a page can only be opened once a search has shown it) and read each item's numbers from it. DoorDash, Uber Eats and Menulog pages usually can't be opened, but their search results show the current menu's item names and often kJ in each name ("Chicken Burger (2280 kJ)"): use them for names and any kJ shown. List up to 30 of its items, mains first, each as one serving as sold (with its size or pieces in the name, "Original tenders, 4 pcs").${extra}
For each item: published is full when the restaurant gives its calories and protein, energy when it gives only kJ or kcal, none when it gives nothing. kj: exactly as published, else 0. kcal: as published, else kJ ÷ 4.184, else your estimate. protein_g, carbs_g and fat_g: as published, else your honest estimate from what the item is and its usual portion. kind: main, side, drink or dessert.
found false if you can't find its menu at all. source: where the numbers came from, a few words. When its own figures and a delivery listing's kJ disagree, the delivery listing is today's menu: use its number. Never guess a kJ: an item whose energy you didn't read on a page has kj 0 and published none.`;

(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const runs = Number(process.argv[2] || 1), r = process.argv[3] || 'PUBCHA';
  for (const [label, extra] of [['old', ''], ['new', ONLY]]) {
    for (let k = 0; k < runs; k++) {
      const res = await client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 12000, messages: [{ role: 'user', content: ask(r, extra) }],
        tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 3, user_location: { type: 'approximate', country: 'AU' } }, { type: 'web_fetch_20250910', name: 'web_fetch', max_uses: 3 }],
        output_config: { effort: 'low', format: { type: 'json_schema', schema: menuSchema } } });
      const urls = [];
      for (const b of res.content) {
        if (b.type === 'server_tool_use') urls.push(`${b.name}: ${JSON.stringify(b.input).slice(0, 90)}`);
        if (b.type === 'web_search_tool_result' && Array.isArray(b.content)) urls.push('   ' + b.content.slice(0, 5).map(x => x.url).join('  '));
      }
      const j = JSON.parse(res.content.filter(b => b.type === 'text').map(b => b.text).join('') || '{}');
      console.log(`\n=== ${label} run ${k + 1}: found ${j.found}, ${j.items?.length ?? 0} items · ${j.source}`);
      urls.forEach(u => console.log('  ' + u));
      for (const i of j.items ?? []) console.log(`    ${i.kind.padEnd(7)} ${i.name} · ${Math.round(i.kcal)} kcal · P${Math.round(i.protein_g)} · ${i.published}`);
    }
  }
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
