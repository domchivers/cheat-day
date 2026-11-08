// The takeaway check as one of three intents, on many ways of saying it.  node intent-check.js [runs]
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const strict = (s) => { if (s && s.type === 'object') { s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const n = { type: 'number' }, s = { type: 'string' };
const schema = strict({ type: 'object', required: ['intent', 'restaurant', 'area', 'want', 'avoid', 'seen', 'kcal', 'protein'], properties: {
  intent: { type: 'string', enum: ['choose', 'log', 'other'] }, restaurant: s, area: s, want: { type: 'array', items: s }, avoid: { type: 'array', items: s },
  seen: { type: 'array', items: { type: 'object', required: ['name', 'kj'], properties: { name: s, kj: n } } }, kcal: n, protein: n } });
// kept word for word with Takeaway.routeAsk
const ask = (msg, earlier) => `A message to the assistant in a food diary app. What is it?
choose: they're deciding what to have from one particular restaurant, takeaway, café or chain, today or another day, however they put it ("Gami tonight?", "thinking Nando's for lunch tomorrow", "what's good at Guzman for 600 cals", "can I fit a Gami burger in today?", "heading to Maccas, what should I get", "want something from the Gami in Windsor tomorrow, what are my options", "I'd like the burger from Gami with a shake": what they'd like, not what they had).
log: they're telling you what they ate or are eating, to add it ("had a Gami burger for lunch", "Gami chicken burger", "just had Nando's"), or correcting a log.
other: anything else, including choosing food with no particular restaurant ("what should I have for dinner?") and questions.
When the conversation so far was choosing from a restaurant, a reply changing that choice ("no milk left, I want the wings") is choose, with that restaurant.
${earlier ? `The conversation so far:\n${earlier}\n` : ''}Their message: "${msg}"
restaurant: its name as they wrote it, else empty. area: a suburb or city if they said one, else empty. want: menu items they say they want, in their words. avoid: foods they don't want or don't have in ("milk"), in their words. seen: dishes they quote from a menu or delivery app with their energy ("Chicken Burger (2280 kJ)"), each with its kJ (kcal × 4.184 if they gave kcal), else empty. kcal and protein: numbers they gave for what they have left or for this meal ("854 left" is kcal 854), else 0.`;
const cases = [
  ['choose', "Want something from the gami in Windsor tomorrow, what's my options? Lunch thinking"], ['choose', 'Gami tonight?'], ['choose', 'thinking nandos for lunch'],
  ['choose', "what's good at guzman for 600 cals"], ['choose', '854 left, want Gami for dinner'], ['choose', "Grill'd or Nando's tonight, which is better?"],
  ['choose', 'heading to maccas, what should I order'], ['choose', 'can I fit a Gami burger in today?'], ['choose', "I'd like the chicken burger from gami with a shake and ice cream"],
  ['choose', 'ordering uber eats from gami soon'], ['log', 'had a gami chicken burger for lunch'], ['log', 'Gami chicken burger'],
  ['log', 'just ate nandos quarter chicken and chips'], ['log', 'Gami burger 545 kcal'], ['log', '2 eggs and toast'],
  ['other', 'what should I have for dinner?'], ['other', 'how much protein do I need'], ['other', 'my knee hurts after leg press']];
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const ledgerFile = path.join(__dirname, 'results', 'ledger.json'), ledger = JSON.parse(fs.readFileSync(ledgerFile, 'utf8'));
  const runs = Number(process.argv[2] || 2); let wrong = 0, total = 0, spent = 0;
  for (let run = 0; run < runs; run++) {
    const res = await Promise.all(cases.map(([, m]) => client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 4000, messages: [{ role: 'user', content: ask(m, '') }],
      output_config: { effort: 'low', format: { type: 'json_schema', schema } } })));
    res.forEach((r, i) => {
      const j = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join('')); total++;
      spent += (r.usage.input_tokens * 0.1 + r.usage.output_tokens * 0.5) / 1e6;
      const ok = j.intent === cases[i][0]; if (!ok) wrong++;
      if (!ok || run === 0) console.log(`${ok ? 'ok ' : 'XX '} ${cases[i][0].padEnd(6)} got ${j.intent.padEnd(6)} ${j.restaurant || '-'}  "${cases[i][1]}"`);
    });
  }
  ledger.spent = +(ledger.spent + spent).toFixed(6); ledger.calls += total; fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
  console.log(`${total - wrong}/${total} right, $${spent.toFixed(4)}`);
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
