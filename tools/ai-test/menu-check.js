// The takeaway planner's two asks, as the app sends them: is this message choosing from a restaurant (Haiku, no tools),
// and that restaurant's menu with what it publishes (Haiku with two web searches).  node menu-check.js [restaurant] [message]
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const restaurant = process.argv[2] || 'Gami', message = process.argv[3] || '854 left, want Gami for dinner. What should I get?';
const strict = (s) => { if (s && s.type === 'object') { s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const n = { type: 'number' }, s = { type: 'string' };
const routeSchema = strict({ type: 'object', required: ['takeaway', 'restaurant', 'area', 'want', 'avoid', 'seen', 'kcal', 'protein'], properties: {
  seen: { type: 'array', items: { type: 'object', required: ['name', 'kj'], properties: { name: s, kj: n } } },
  takeaway: { type: 'boolean' }, restaurant: s, area: s, want: { type: 'array', items: s }, avoid: { type: 'array', items: s }, kcal: n, protein: n } });
const menuSchema = strict({ type: 'object', required: ['found', 'restaurant', 'source', 'items'], properties: {
  found: { type: 'boolean' }, restaurant: s, source: s,
  items: { type: 'array', items: { type: 'object', required: ['name', 'kind', 'published', 'kj', 'kcal', 'protein_g', 'carbs_g', 'fat_g'], properties: {
    name: s, kind: { type: 'string', enum: ['main', 'side', 'drink', 'dessert'] }, published: { type: 'string', enum: ['full', 'energy', 'none'] },
    kj: n, kcal: n, protein_g: n, carbs_g: n, fat_g: n } } } } });
// kept word for word with Takeaway.swift
const routeAsk = (msg, earlier, photo = '') => `A message to the assistant in a food diary app${photo ? `, with a photo of ${photo}` : ''}. Is it about what to order or eat next from one particular restaurant, takeaway or chain: asking (\"want Gami for dinner, what should I get?\", \"what can I have at Nando's for 700 kcal\") or saying what they'd like from it (\"854 left, want Gami for dinner, the chicken burger with a shake\")? Food they already ate (\"had a Gami burger for lunch\"), or a recipe, is not. When the conversation so far was choosing from a restaurant, a reply changing that choice (\"no milk left, I want the wings\") counts too, with that restaurant.
${earlier ? `The conversation so far:\n${earlier}\n` : ''}Their message: \"${msg}\"
restaurant: its name as they wrote it, else empty. area: a suburb or city if they said one, else empty. want: menu items they say they want, in their words. avoid: foods they don't want or don't have in (\"milk\"), in their words. seen: dishes they quote from a menu or delivery app with their energy (\"Chicken Burger (2280 kJ)\"), each with its kJ (kcal × 4.184 if they gave kcal), else empty. kcal and protein: numbers they gave for what they have left or for this meal (\"854 left\" is kcal 854), else 0.`;
const menuAsk = (r, area, want, seen = []) => `Find the current menu of \"${r}\"${area ? ` in ${area}` : ''}, a restaurant, takeaway or chain in Australia, and the nutrition it publishes. Look first at its listing on DoorDash, Uber Eats or Menulog, which has the full current menu and where chains put kJ in each item's name (\"Chicken Burger (2280 kJ)\"), then its own website or nutrition PDF.${want.length ? ` They want: ${want.join(', ')}. Make sure those dishes are in the list if it sells them, with the kJ its listing shows today, not an old menu's.` : ''}${seen.length ? ` They read these on its listing today: ${seen.join(', ')}. List each with exactly that kJ, and estimate its protein, carbs and fat for that energy.` : ''} List up to 30 of its items, mains first, each as one serving as sold (with its size or pieces in the name, \"Original tenders, 4 pcs\").
For each item: published is full when the restaurant gives its calories and protein, energy when it gives only kJ or kcal, none when it gives nothing. kj: exactly as published, else 0. kcal: as published, else kJ Ã· 4.184, else your estimate. protein_g, carbs_g and fat_g: as published, else your honest estimate from what the item is and its usual portion. kind: main, side, drink or dessert.
found false if you can't find its menu at all. source: where the numbers came from, a few words.`;
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  async function ask(label, content, schema, tools) {
    const t0 = Date.now();
    const r = await client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 12000, messages: [{ role: 'user', content }],
      ...(tools ? { tools } : {}), output_config: { effort: 'low', format: { type: 'json_schema', schema } } });
    const searches = r.usage.server_tool_use?.web_search_requests ?? 0;
    const cost = (r.usage.input_tokens * 0.1 + r.usage.output_tokens * 0.5) / 1e6 + searches * 0.01;
    ledger.spent = +(ledger.spent + cost).toFixed(6); ledger.calls++; fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
    console.log(`\n== ${label}: ${r.stop_reason} ${((Date.now() - t0) / 1000).toFixed(1)} s $${cost.toFixed(4)} searches ${searches} in ${r.usage.input_tokens} out ${r.usage.output_tokens}`);
    return JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
  }
  const page = 'a menu page from Gami showing Chicken Burger (2280 kJ), Gami Chips (3042 kJ), Cheese Snowy Chips (2550 kJ)';
  for (const m of ['This burger for dinner', 'Had this for lunch']) console.log(m, '+ page →', JSON.stringify(await ask('route+photo', routeAsk(m, '', page), routeSchema)));
  for (const [m, e] of [[message, ''], ['854 left, want Gami for dinner. Chicken Burger (2280 kJ) with a shake and ice cream', ''], ['what should I get for dinner?', ''], ['had a gami chicken burger for lunch', ''],
                        ['No milk left, and I want the wings', `They asked: ${message}\nYou suggested from Gami: Chicken Burger + protein shake + Kenny's ice cream`]]) {
    console.log(m, 'â†’', JSON.stringify(await ask('route', routeAsk(m, e), routeSchema)));
  }
  if (process.argv[4] === 'route') return;
  const menu = await ask('menu', menuAsk(restaurant, '', (process.argv[5] || '').split(',').filter(Boolean), (process.argv[6] || '').split(';').filter(Boolean)), menuSchema,
    [{ type: 'web_search_20250305', name: 'web_search', max_uses: 2, user_location: { type: 'approximate', country: 'AU' } }]);
  console.log(menu.found, menu.restaurant, '|', menu.source, '|', menu.items.length, 'items');
  for (const i of menu.items) console.log(`${i.kind.padEnd(7)} ${i.published.padEnd(6)} ${String(i.kj).padStart(5)} kJ ${String(Math.round(i.kcal)).padStart(5)} kcal P${i.protein_g} C${i.carbs_g} F${i.fat_g}  ${i.name}`);
  console.log(`Test spend so far: $${ledger.spent.toFixed(4)}`);
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
