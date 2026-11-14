// Places for a meal with a lot of protein asked for: does each suggestion get to the protein, with the wording the app
// has now (old) and the wording that lets an order be a dish plus what makes up the protein (new)?
// node find-protein-check.js [runs] [area] [kcal] [protein]
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const strict = (s) => { if (s && s.type === 'object') { s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const n = { type: 'number' }, s = { type: 'string' };
const findSchema = strict({ type: 'object', required: ['found', 'places'], properties: { found: { type: 'boolean' },
  places: { type: 'array', items: { type: 'object', required: ['name', 'area', 'cuisine', 'dish', 'published', 'kj', 'kcal', 'protein_g', 'carbs_g', 'fat_g'], properties: {
    name: s, area: s, cuisine: s, dish: s, published: { type: 'string', enum: ['full', 'energy', 'none'] }, kj: n, kcal: n, protein_g: n, carbs_g: n, fat_g: n } } } } });
const tail = `For each place: name as it calls itself. area: its street or suburb, a few words. cuisine: one or two words.`;
const asks = {
  old: (area, want, meal, kcal, protein) => `Find 4 real restaurants, cafés or takeaways in or near ${area}, Australia, for ${meal.toLowerCase()}${want.length ? `, for someone after ${want.join(', ')}` : ''}. For each, the one dish on its current menu that best fits about ${kcal} kcal with ${protein} g protein or more. Search the web for places there; delivery listings on DoorDash, Uber Eats or Menulog have the current menu, often with kJ in each item's name ("Chicken Bowl (2280 kJ)"). Only list places you found on a page, in that area, still trading.
${tail} dish: as named on its menu, one serving. published is full when the place gives that dish's calories and protein, energy when it gives only kJ or kcal, none when it gives nothing. kj: exactly as published, else 0. kcal: as published, else kJ ÷ 4.184, else your honest estimate. protein_g, carbs_g and fat_g: as published, else your honest estimate from what the dish is and its usual portion. Never guess a kJ: a dish whose energy you didn't read on a page has kj 0 and published none.
found false if you couldn't find places there.`,
  new: (area, want, meal, kcal, protein) => `Find 4 real restaurants, cafés or takeaways in or near ${area}, Australia, for ${meal.toLowerCase()}${want.length ? `, for someone after ${want.join(', ')}` : ''}. For each, the one order from its current menu that gets to ${protein} g protein or more within about ${kcal} kcal: one dish when a dish has that much protein, else a dish with what makes up the protein from the same menu (double meat, extra pieces of chicken, a second small main, a protein side), up to three items. The protein matters most: where the menu can reach ${protein} g, the order reaches it; where it can't, give the order with the most protein you can within the calories. Always give 4 places. Search the web for places there; delivery listings on DoorDash, Uber Eats or Menulog have the current menu, often with kJ in each item's name ("Chicken Bowl (2280 kJ)"). Only list places you found on a page, in that area, still trading.
${tail} dish: the order as named on its menu, items joined with " + " ("Grilled Chicken Bowl + Extra Chicken"). published is full when the place gives the calories and protein of every item in the order, energy when it gives only their kJ or kcal, none when any item has nothing. kj: the items' published kJ added up, else 0. kcal: as published added up, else kJ ÷ 4.184, else your honest estimate. protein_g, carbs_g and fat_g: for the whole order, as published, else your honest estimate from what each item is and its usual portion. Never guess a kJ: an order with an item whose energy you didn't read on a page has kj 0 and published none.
found false if you couldn't find places there.`,
  mixed: (area, want, meal, kcal, protein) => `Find 4 real restaurants, cafés or takeaways in or near ${area}, Australia, for ${meal.toLowerCase()}${want.length ? `, for someone after ${want.join(', ')}` : ''}. For each, one order from its current menu for about ${kcal} kcal. At least two of the four orders get to ${protein} g protein or more within those calories: one dish when a dish has that much protein, else a dish with what makes up the protein from the same menu (double meat, extra pieces of chicken, a second small main, a protein side), up to three items. The others can be a single dish that suits the calories, with as much protein as a dish there has, for some choice. Always give 4 places, of different kinds of food where you can. Search the web for places there; delivery listings on DoorDash, Uber Eats or Menulog have the current menu, often with kJ in each item's name ("Chicken Bowl (2280 kJ)"). Only list places you found on a page, in that area, still trading.
${tail} dish: the order as named on its menu, items joined with " + " ("Grilled Chicken Bowl + Extra Chicken"). published is full when the place gives the calories and protein of every item in the order, energy when it gives only their kJ or kcal, none when any item has nothing. kj: the items' published kJ added up, else 0. kcal: as published added up, else kJ ÷ 4.184, else your honest estimate. protein_g, carbs_g and fat_g: for the whole order, as published, else your honest estimate from what each item is and its usual portion. Never guess a kJ: an order with an item whose energy you didn't read on a page has kj 0 and published none.
found false if you couldn't find places there.`,
};
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  const save = (c) => { ledger.spent = +(ledger.spent + c).toFixed(6); ledger.calls++; fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1)); };
  const runs = Number(process.argv[2] || 2), area = process.argv[3] || 'Melbourne', kcal = Number(process.argv[4] || 1000), protein = Number(process.argv[5] || 70);
  const which = (process.env.ONLY || 'old,new').split(',');
  const jobs = [];
  for (const w of which) for (let i = 0; i < runs; i++) jobs.push((async () => {
    const t0 = Date.now();
    const r = await client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 12000, messages: [{ role: 'user', content: asks[w](area, [], 'Dinner', kcal, protein) }],
      tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 3, user_location: { type: 'approximate', country: 'AU' } }, { type: 'web_fetch_20250910', name: 'web_fetch', max_uses: 3 }],
      output_config: { effort: 'low', format: { type: 'json_schema', schema: findSchema } } });
    const searches = r.usage.server_tool_use?.web_search_requests ?? 0, cost = (r.usage.input_tokens * 0.1 + r.usage.output_tokens * 0.5) / 1e6 + searches * 0.01; save(cost);
    const j = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
    const lines = [`\n${w} run ${i + 1}: ${r.stop_reason} ${((Date.now() - t0) / 1000).toFixed(1)} s $${cost.toFixed(4)} searches ${searches} found ${j.found}`];
    let hit = 0;
    for (const p of j.places) {
      const k = p.kj > 0 ? p.kj / 4.184 : p.kcal, ok = p.protein_g >= protein * 0.9 && k <= kcal * 1.15; if (ok) hit++;
      const sane = p.protein_g * 4 + p.carbs_g * 4 + p.fat_g * 9;
      lines.push(`${ok ? 'HIT ' : '--  '}${p.published.padEnd(6)} ${String(p.kj).padStart(5)} kJ ${String(Math.round(k)).padStart(4)} kcal P${p.protein_g} C${p.carbs_g} F${p.fat_g} (macros make ${Math.round(sane)})  ${p.name} (${p.area}): ${p.dish}`);
    }
    lines.push(`   ${hit}/${j.places.length} reach ${protein} g within ${kcal} kcal`);
    return { w, hit, n: j.places.length, text: lines.join('\n') };
  })());
  const out = await Promise.all(jobs);
  for (const o of out) console.log(o.text);
  for (const w of which) { const mine = out.filter(o => o.w === w); console.log(`${w}: ${mine.reduce((a, o) => a + o.hit, 0)}/${mine.reduce((a, o) => a + o.n, 0)} reach it`); }
  console.log(`Test spend so far: $${ledger.spent.toFixed(4)}`);
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
