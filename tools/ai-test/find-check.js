// Finding places: the router with its fourth intent (find), on many ways of saying it, then the places search itself
// (Haiku with web search and fetch, as the menu job runs it).  node find-check.js [runs] [area] [want]   ONLY=route skips the search
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const strict = (s) => { if (s && s.type === 'object') { s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const n = { type: 'number' }, s = { type: 'string' };
const routeSchema = strict({ type: 'object', required: ['intent', 'restaurant', 'area', 'want', 'avoid', 'seen', 'kcal', 'protein'], properties: {
  intent: { type: 'string', enum: ['choose', 'find', 'log', 'other'] }, restaurant: s, area: s, want: { type: 'array', items: s }, avoid: { type: 'array', items: s },
  seen: { type: 'array', items: { type: 'object', required: ['name', 'kj'], properties: { name: s, kj: n } } }, kcal: n, protein: n } });
const findSchema = strict({ type: 'object', required: ['found', 'places'], properties: { found: { type: 'boolean' },
  places: { type: 'array', items: { type: 'object', required: ['name', 'area', 'cuisine', 'dish', 'published', 'kj', 'kcal', 'protein_g', 'carbs_g', 'fat_g'], properties: {
    name: s, area: s, cuisine: s, dish: s, published: { type: 'string', enum: ['full', 'energy', 'none'] }, kj: n, kcal: n, protein_g: n, carbs_g: n, fat_g: n } } } } });
// kept word for word with Takeaway.routeAsk and Takeaway.findAsk
const routeAsk = (msg, earlier) => `A message to the assistant in a food diary app. What is it?
choose: they're deciding what to have from one particular restaurant, takeaway, café or chain, today or another day, however they put it ("Gami tonight?", "thinking Nando's for lunch tomorrow", "what's good at Guzman for 600 cals", "can I fit a Gami burger in today?", "heading to Maccas, what should I get", "want something from the Gami in Windsor tomorrow, what are my options", "I'd like the burger from Gami with a shake": what they'd like, not what they had).
find: they want you to suggest places to eat, somewhere or of a kind, with no particular restaurant named ("any good lunch spots near me in South Yarra?", "somewhere high protein on Chapel St", "good Thai near work for dinner", "where can I get a healthy lunch in the city?").
log: they're telling you what they ate or are eating, to add it ("had a Gami burger for lunch", "Gami chicken burger", "just had Nando's"), or correcting a log.
other: anything else, including choosing food with no restaurant and no places wanted ("what should I have for dinner?") and questions.
When the conversation so far was choosing from a restaurant, a reply changing that choice ("no milk left, I want the wings") is choose, with that restaurant. When you suggested places, picking one ("the poke one", "the second") is choose, with that place's name and area.
${earlier ? `The conversation so far:\n${earlier}\n` : ''}Their message: "${msg}"
restaurant: its name as they wrote it, else empty. area: a suburb, street or city if they said one, else empty. want: menu items they say they want, in their words, or for find the kind of food they're after ("Thai", "high protein"). avoid: foods they don't want or don't have in ("milk"), in their words. seen: dishes they quote from a menu or delivery app with their energy ("Chicken Burger (2280 kJ)"), each with its kJ (kcal × 4.184 if they gave kcal), else empty. kcal and protein: numbers they gave for what they have left or for this meal ("854 left" is kcal 854), else 0.`;
const findAsk = (area, want, meal, kcal, protein) => `Find 4 real restaurants, cafés or takeaways in or near ${area}, Australia, for ${meal.toLowerCase()}${want.length ? `, for someone after ${want.join(', ')}` : ''}. For each, the one order from its current menu that gets to ${protein} g protein or more within about ${kcal} kcal: one dish when a dish has that much protein, else a dish with what makes up the protein from the same menu (double meat, extra pieces of chicken, a second small main, a protein side), up to three items. The protein matters most: where the menu can reach ${protein} g, the order reaches it; where it can't, give the order with the most protein you can within the calories. Always give 4 places. Search the web for places there; delivery listings on DoorDash, Uber Eats or Menulog have the current menu, often with kJ in each item's name ("Chicken Bowl (2280 kJ)"). Only list places you found on a page, in that area, still trading.
For each place: name as it calls itself. area: its street or suburb, a few words. cuisine: one or two words. dish: the order as named on its menu, items joined with " + " ("Grilled Chicken Bowl + Extra Chicken"). published is full when the place gives the calories and protein of every item in the order, energy when it gives only their kJ or kcal, none when any item has nothing. kj: the items' published kJ added up, else 0. kcal: as published added up, else kJ ÷ 4.184, else your honest estimate. protein_g, carbs_g and fat_g: for the whole order, as published, else your honest estimate from what each item is and its usual portion. Never guess a kJ: an order with an item whose energy you didn't read on a page has kj 0 and published none.
found false if you couldn't find places there.`;
const picked = 'They asked: any good lunch spots in South Yarra?\nYou suggested these places: Poke Bros (Chapel St), Jimmy Grants (Toorak Rd), Pho Hung Vuong (Chapel St), Guzman y Gomez (Toorak Rd)';
const cases = [
  ['find', "Any good lunch spots near me in South Yarra that's healthy and high protein?"], ['find', 'somewhere high protein on chapel st'], ['find', 'good thai near work for dinner'],
  ['find', 'where can I get a healthy lunch in the city?'], ['find', 'any poke places in Richmond'], ['find', 'need dinner ideas near Prahran, takeaway'],
  ['choose', 'Gami tonight?'], ['choose', "Want something from the gami in Windsor tomorrow, what's my options? Lunch thinking"], ['choose', 'heading to maccas, what should I order'],
  ['choose', "I'd like the chicken burger from gami with a shake and ice cream"], ['choose', 'the poke one', picked], ['choose', 'the second one for lunch', picked],
  ['log', 'had a gami chicken burger for lunch'], ['log', 'just ate nandos quarter chicken and chips'], ['log', '2 eggs and toast'],
  ['other', 'what should I have for dinner?'], ['other', 'how much protein do I need'], ['other', 'is pho healthy?']];
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  const save = (c) => { ledger.spent = +(ledger.spent + c).toFixed(6); ledger.calls++; fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1)); };
  const runs = Number(process.argv[2] || 3); let wrong = 0, total = 0, spent = 0;
  for (let run = 0; run < runs; run++) {
    const res = await Promise.all(cases.map(([, m, e]) => client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 4000, messages: [{ role: 'user', content: routeAsk(m, e || '') }],
      output_config: { effort: 'low', format: { type: 'json_schema', schema: routeSchema } } })));
    res.forEach((r, i) => {
      const j = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join('')); total++;
      const c = (r.usage.input_tokens * 0.1 + r.usage.output_tokens * 0.5) / 1e6; spent += c; save(c);
      const ok = j.intent === cases[i][0] && (cases[i][2] ? /poke|jimmy/i.test(j.restaurant) : true); if (!ok) wrong++;
      if (!ok || run === 0) console.log(`${ok ? 'ok ' : 'XX '} ${cases[i][0].padEnd(6)} got ${j.intent.padEnd(6)} r:${j.restaurant || '-'} a:${j.area || '-'} w:${j.want.join('/') || '-'}  "${cases[i][1]}"`);
    });
  }
  console.log(`route: ${total - wrong}/${total} right, $${spent.toFixed(4)}`);
  if (process.env.ONLY === 'route') return;
  const area = process.argv[3] || 'South Yarra', want = (process.argv[4] || 'healthy,high protein').split(',').filter(Boolean);
  const t0 = Date.now();
  const r = await client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 12000, messages: [{ role: 'user', content: findAsk(area, want, 'Lunch', 700, 45) }],
    tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 3, user_location: { type: 'approximate', country: 'AU' } }, { type: 'web_fetch_20250910', name: 'web_fetch', max_uses: 3 }],
    output_config: { effort: 'low', format: { type: 'json_schema', schema: findSchema } } });
  for (const b of r.content) if (b.type === 'server_tool_use') console.log('  tool:', b.name, JSON.stringify(b.input).slice(0, 140));
  const searches = r.usage.server_tool_use?.web_search_requests ?? 0, cost = (r.usage.input_tokens * 0.1 + r.usage.output_tokens * 0.5) / 1e6 + searches * 0.01; save(cost);
  const j = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
  console.log(`\nfind ${area}: ${r.stop_reason} ${((Date.now() - t0) / 1000).toFixed(1)} s $${cost.toFixed(4)} searches ${searches} found ${j.found}`);
  for (const p of j.places) console.log(`${p.published.padEnd(6)} ${String(p.kj).padStart(5)} kJ ${String(Math.round(p.kcal)).padStart(4)} kcal P${p.protein_g}  ${p.name} (${p.area}, ${p.cuisine}): ${p.dish}`);
  console.log(`Test spend so far: $${ledger.spent.toFixed(4)}`);
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
