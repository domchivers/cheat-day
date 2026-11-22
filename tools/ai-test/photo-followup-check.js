// 22 Nov: "it forgot I added the photo". A receipt's follow-up went to the takeaway planner. The turn through the router,
// and with a photo given, through the careful answer with the app's own rules. A few cents.
//   node photo-followup-check.js [runs] [receipt.jpg]
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const read = f => fs.readFileSync(path.join(__dirname, '../../native/CheatDays/Model', f), 'utf8').replace(/\r/g, '');
const strict = (s) => { if (s && s.type === 'object') { s.required = Object.keys(s.properties); s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const n = { type: 'number' }, s = { type: 'string' };

const prompt = read('Takeaway.swift').match(/static func routeAsk\([^\n]*\n\s*"""\n([\s\S]*?)\n\s*"""/)[1].replace(/^ {8}/gm, '');
const route = (message, earlier) => prompt.split('\n').map(l =>
  l.startsWith('A message to the assistant') ? 'A message to the assistant in a food diary app. What is it?'
  : l.includes('earlier.isEmpty') ? `The conversation so far:\n${earlier}\nTheir message: "${message}"`
  : l.replace(/\\\(photo\.isEmpty.*\)\s*$/, '').replace(/\\"/g, '"')).join('\n');
const routeSchema = strict({ type: 'object', properties: {
  intent: { type: 'string', enum: ['choose', 'find', 'log', 'other'] }, restaurant: s, area: s, want: { type: 'array', items: s }, avoid: { type: 'array', items: s },
  seen: { type: 'array', items: { type: 'object', properties: { name: s, kj: n } } }, kcal: n, protein: n } });

const menuReply = "Thanks, I can read the menu now. With **1334 kcal and about 108 g protein left**, this is what I'd order:\n- **Signature Northwest lamb kebabs, 5 skewers ($18.8).** Your best protein for the calories, roughly 300 to 400 kcal";
const receiptReply = "Since it's a huge feast meant for sharing, let me know roughly how much of each dish or what share of the table you had so I can narrow down your exact portion. Check it below and tap Add to put it on today's list.";
const earlier = ['They asked: From this place', "You: Thanks, I can see it's Noodle & BBQ in Carnegie, a Northwest Chinese place known for hand-pulled noodles and lamb skewers.",
  'They asked: Here’s the menu', 'You: ' + menuReply.slice(0, 200), 'They asked: Everything we ordered', 'You: ' + receiptReply.slice(0, 200)].join('\n');
const said = 'Wanted the stinky tofu for myself everything else around half or what do you recommend?';
const cases = [said, 'what do you recommend?', 'half the noodles for me', 'any other places near here?', 'Gami tomorrow instead?'];

(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const runs = Number(process.argv[2] || 4);
  const ask = async (content, schema, model, system) => JSON.parse((await client.messages.create({ model, max_tokens: 6000, ...(system ? { system } : {}),
    messages: [{ role: 'user', content }], output_config: { effort: 'low', format: { type: 'json_schema', schema } } })).content.filter(b => b.type === 'text').map(b => b.text).join(''));
  for (let i = 0; i < runs; i++) {
    const got = await Promise.all(cases.map(m => ask(route(m, earlier), routeSchema, 'claude-haiku-5-5')));
    got.forEach((j, k) => console.log(`route ${i + 1}: "${cases[k].slice(0, 50)}" -> ${j.intent} restaurant="${j.restaurant}" want=[${j.want}]`));
  }
  if (!process.argv[3]) return;
  const amounts = read('Sanity.swift').match(/static let amounts = "([^"]*)"/)[1];
  const rules = read('Assistant.swift').match(/static let rules = """\n([\s\S]*?)\n\s*"""/)[1].replace(/^ {4}/gm, '').replace('\\(Sanity.amounts)', () => amounts);
  // the estimate-only format a message with photos gets
  const schema = strict({ type: 'object', properties: { reply: s, kind: { type: 'string', enum: ['answer', 'estimate'] }, estimate: { type: 'object', properties: {
    name: s, portion_g: n, shop: s, parts: { type: 'array', items: { type: 'object', properties: { name: s, grams: n, kcal: n, protein_g: n, carbs_g: n, fat_g: n, size: s } } } } } } });
  const card = 'Tofu skin skewers, grilled 100 g 160 kcal; Spicy lamb skewers, grilled 250 g 580 kcal; Spicy squid legs, grilled 120 g 140 kcal; Small lamb chops, grilled 120 g 290 kcal; Roasted tofu 120 g 160 kcal; Grilled Changsha stinky tofu 80 g 100 kcal; Grilled yam pasta 100 g 130 kcal; Bean curd and enoki mushroom rolls 100 g 130 kcal; Northwest saute spicy chicken noodles 750 g 850 kcal';
  const text = `They live in Australia: use the usual portion sizes there. Today: budget 2000 kcal, eaten 666 kcal, 1334 kcal left. Protein so far 42 g of 150 g.\n`
    + `Recent conversation:\nThey: Here’s the menu\nYou: ${menuReply}\nThey: Everything we ordered\nYou: ${receiptReply} [you worked out: Shared Noodle & BBQ order, 2540 kcal: ${card}]\n`
    + `They now say: "${said}" (about the photos from earlier)\n`;
  const photo = { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: fs.readFileSync(process.argv[3]).toString('base64') } };
  for (let i = 0; i < Math.min(runs, 3); i++) {
    const a = await ask([photo, { type: 'text', text }], schema, 'claude-sonnet-5-5', `You are the assistant inside a cheat-day food diary app called Cheat Days.\n${rules}`);
    const parts = a.estimate.parts;
    console.log(`\nanswer ${i + 1}: ${a.kind}: ${a.reply}`);
    for (const p of parts) console.log(`  ${p.name} ${p.grams} g ${p.kcal} kcal P${p.protein_g} | ${p.size}`);
    console.log(`  total ${parts.reduce((t, p) => t + p.kcal, 0)} kcal P${parts.reduce((t, p) => t + p.protein_g, 0)}`);
  }
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
