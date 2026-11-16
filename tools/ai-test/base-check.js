// "They do a protein pizza base" after "Thinking protein pepperoni pizza from crust?" (16 Nov): the follow-up came back
// as a dish called "protein pizza base" that Crust's menu didn't have. The route ask (Takeaway.routeAsk, its want rule
// with the new sentence when WAY=1), then Crust's menu for what it gives (menuAsk as in Takeaway.swift).  node base-check.js
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const strict = (s) => { if (s && s.type === 'object') { s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const n = { type: 'number' }, s = { type: 'string' };
const routeSchema = strict({ type: 'object', required: ['kind', 'restaurant', 'area', 'want', 'avoid', 'seen', 'kcal', 'protein'], properties: {
  kind: { type: 'string', enum: ['choose', 'find', 'log', 'other'] }, restaurant: s, area: s, want: { type: 'array', items: s }, avoid: { type: 'array', items: s },
  seen: { type: 'array', items: { type: 'object', required: ['name', 'kj'], properties: { name: s, kj: n } } }, kcal: n, protein: n } });
const way = process.env.WAY ? ` A way of having a dish (a base, a size or a style, "they do a protein base") goes with the dish it's for, from the conversation when they don't name it now ("pepperoni pizza, high protein base").` : '';
const routeAsk = (message, earlier) => `A message to the assistant in a food diary app. What is it?
choose: they're deciding what to have from one particular restaurant, takeaway, café or chain, today or another day, however they put it ("Gami tonight?", "thinking Nando's for lunch tomorrow", "what's good at Guzman for 600 cals", "can I fit a Gami burger in today?", "heading to Maccas, what should I get", "want something from the Gami in Windsor tomorrow, what are my options", "I'd like the burger from Gami with a shake": what they'd like, not what they had).
find: they want you to suggest places to eat, somewhere or of a kind, with no particular restaurant named ("any good lunch spots near me in South Yarra?", "somewhere high protein on Chapel St", "good Thai near work for dinner", "where can I get a healthy lunch in the city?").
log: they're telling you what they ate or are eating, to add it ("had a Gami burger for lunch", "Gami chicken burger", "just had Nando's"), or correcting a log.
other: anything else, including choosing food with no restaurant and no places wanted ("what should I have for dinner?") and questions.
When the conversation so far was choosing from a restaurant, a reply changing that choice ("no milk left, I want the wings", "the lamb one instead") is choose, with that restaurant; a question about the order already suggested is other: which sides, sauces, dips, sizes or extras to pick with it, what you'd recommend among its options, or anything about pictures they sent ("which sides should I get?", "what would you recommend on the picks", "from the pictures I sent"). When you suggested places, picking one ("the poke one", "the second") is choose, with that place's name and area.
${earlier ? `The conversation so far:\n${earlier}\n` : ''}Their message: "${message}"
restaurant: its name as they wrote it, else empty. area: a suburb, street or city if they said one, else empty. want: menu items they say they want, in their words, or for find the kind of food they're after ("Thai", "high protein").${way} avoid: foods they don't want or don't have in ("milk"), in their words. seen: dishes they quote from a menu or delivery app with their energy ("Chicken Burger (2280 kJ)"), each with its kJ (kcal × 4.184 if they gave kcal), else empty. kcal and protein: numbers they gave for what they have left or for this meal ("854 left" is kcal 854), else 0.`;
const earlier = "They asked: Thinking protein pepperoni pizza from crust?\nYou suggested from Crust: Pesto Chicken Club pizza (1329 kcal, 50 g protein) + protein shake";
const cases = [['They do a protein pizza base', earlier], ['Thinking protein pepperoni pizza from crust?', ''], ['the lamb one instead', earlier], ['which sides should I get?', earlier], ['can I get it on the gluten free base?', earlier]];
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  for (const [m, e] of cases) for (let i = 0; i < 2; i++) {
    const r = await client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 1500, messages: [{ role: 'user', content: routeAsk(m, e) }],
      output_config: { effort: 'low', format: { type: 'json_schema', schema: routeSchema } } });
    ledger.spent = +(ledger.spent + (r.usage.input_tokens * 0.1 + r.usage.output_tokens * 0.5) / 1e6).toFixed(6); ledger.calls++;
    const a = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
    console.log(`"${m}" → ${a.kind} ${a.restaurant} want ${JSON.stringify(a.want)}`);
  }
  fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
