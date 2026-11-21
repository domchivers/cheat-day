// The takeaway router after a card (21 Nov, PUBCHA): "Any other things? Also don't see boneless option" went to the
// assistant (an empty card) and "Check on DoorDash" gave the same card again. Takeaway.routeAsk as it is against the
// rule that asking for other options, or saying a dish isn't on their app, is choosing again with that dish avoided.
// On Haiku as the app's "quick" job. Under a cent.   node pubcha-route-check.js [runs]
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const strict = (s) => { if (s && s.type === 'object') { s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const n = { type: 'number' }, s = { type: 'string' };
const schema = strict({ type: 'object', required: ['intent', 'restaurant', 'area', 'want', 'avoid', 'seen', 'kcal', 'protein'], properties: {
  intent: { type: 'string', enum: ['choose', 'find', 'log', 'other'] }, restaurant: s, area: s, want: { type: 'array', items: s }, avoid: { type: 'array', items: s },
  seen: { type: 'array', items: { type: 'object', required: ['name', 'kj'], properties: { name: s, kj: n } } }, kcal: n, protein: n } });

const OLD = `When the conversation so far was choosing from a restaurant, a reply changing that choice ("no milk left, I want the wings", "the lamb one instead") is choose, with that restaurant; a question about the order already suggested is other:`;
const NEW = `When the conversation so far was choosing from a restaurant, a reply changing that choice ("no milk left, I want the wings", "the lamb one instead") is choose, with that restaurant; so is asking for other or more options there, or saying a dish suggested isn't on their app or menu, or asking you to look at its menu again ("any other things?", "don't see the boneless option", "check on DoorDash"), with each dish they said they can't see in avoid; a question about the order already suggested is other:`;
// kept word for word with Takeaway.routeAsk (no photo)
const ask = (rule, message, earlier) => `A message to the assistant in a food diary app. What is it?
choose: they're deciding what to have from one particular restaurant, takeaway, café or chain, today or another day, however they put it ("Gami tonight?", "thinking Nando's for lunch tomorrow", "what's good at Guzman for 600 cals", "can I fit a Gami burger in today?", "heading to Maccas, what should I get", "want something from the Gami in Windsor tomorrow, what are my options", "I'd like the burger from Gami with a shake": what they'd like, not what they had).
find: they want you to suggest places to eat, somewhere or of a kind, with no particular restaurant named ("any good lunch spots near me in South Yarra?", "somewhere high protein on Chapel St", "good Thai near work for dinner", "where can I get a healthy lunch in the city?").
log: they're telling you what they ate or are eating, to add it ("had a Gami burger for lunch", "Gami chicken burger", "just had Nando's"), or correcting a log.
other: anything else, including choosing food with no restaurant and no places wanted ("what should I have for dinner?") and questions.
${rule} which sides, sauces, dips, sizes or extras to pick with it, what you'd recommend among its options, or anything about pictures they sent ("which sides should I get?", "what would you recommend on the picks", "from the pictures I sent"). When you suggested places, picking one ("the poke one", "the second") is choose, with that place's name and area.
${earlier ? `The conversation so far:\n${earlier}\n` : ''}Their message: "${message}"
restaurant: its name as they wrote it, else empty. area: a suburb, street or city if they said one, else empty. want: menu items they say they want, in their words, or for find the kind of food they're after ("Thai", "high protein"). avoid: foods they don't want or don't have in ("milk"), in their words. seen: dishes they quote from a menu or delivery app with their energy ("Chicken Burger (2280 kJ)"), each with its kJ (kcal × 4.184 if they gave kcal), else empty. kcal and protein: numbers they gave for what they have left or for this meal ("854 left" is kcal 854), else 0.`;

const first = 'They asked: Want to order from PUBCHA on DoorDash, have 1400kcals to play with also want to hit as much protein, maybe 80 at least\nYou suggested from PUBCHA: Large Fried Boneless Chicken; Ginseng Chicken Soup; Army Stew';
const gami = 'They asked: 854 left, want Gami for dinner\nYou suggested from Gami: Chicken Burger; Original tenders, 4 pcs; Bulgogi rice bowl';
const cases = [
  ['choose', 'Any other things? Also don’t see boneless option', first, 'boneless'],
  ['choose', 'Check on DoorDash', first + '\nThey asked: Any other things? Also don’t see boneless option\nYou: No boneless option is fine, bone-in works.', null],
  ['choose', 'what else is there?', gami, null],
  ['choose', "the tenders aren't on uber eats", gami, 'tenders'],
  ['other', 'which sides should I get?', gami, null],
  ['other', 'what sauce goes with the burger?', gami, null],
  ['other', 'what would you recommend on the picks', gami, null],
  ['choose', 'the bulgogi one instead', gami, null],
  ['log', 'had the chicken burger', gami, null],
];

(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const runs = Number(process.argv[2] || 2);
  for (const [label, rule] of [['old', OLD], ['new', NEW]]) {
    let right = 0, total = 0;
    for (let run = 0; run < runs; run++) {
      const res = await Promise.all(cases.map(([, m, e]) => client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 4000, messages: [{ role: 'user', content: ask(rule, m, e) }],
        output_config: { effort: 'low', format: { type: 'json_schema', schema } } })));
      res.forEach((r, i) => {
        const j = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join('')), [want, msg, , avoid] = cases[i];
        const avoidOk = !avoid || j.avoid.some(a => a.toLowerCase().includes(avoid));
        const ok = j.intent === want && avoidOk; total++; if (ok) right++;
        if (!ok || run === 0) console.log(`${label} ${ok ? 'ok ' : 'XX '} ${want.padEnd(6)} got ${j.intent.padEnd(6)} ${j.restaurant || '-'} avoid=[${j.avoid.join(', ')}]  "${msg}"`);
      });
    }
    console.log(`${label}: ${right}/${total} right\n`);
  }
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
