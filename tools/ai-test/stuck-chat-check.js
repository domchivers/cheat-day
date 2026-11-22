// The owner's 22 Nov chat that "was doing so well then got stuck": its turns through the router, and the menu lookups
// for the place it wouldn't look up. The prompts are read out of Takeaway.swift, so they can't drift from the app's.
// Haiku, as the "quick" and "menu" jobs. A few cents.   node stuck-chat-check.js [runs] [menus]
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const src = fs.readFileSync(path.join(__dirname, '../../native/CheatDays/Model/Takeaway.swift'), 'utf8');

/** The text of a Swift func's """ string, as Swift gives it, with each interpolation replaced by fill(expression). */
function promptOf(name, fill) {
  const at = src.indexOf(`static func ${name}(`), a = src.indexOf('"""', at), b = src.indexOf('"""', a + 3);
  if (at < 0 || a < 0 || b < 0) throw new Error('no ' + name);
  const raw = src.slice(a + 4, b).replace(/\r/g, '').replace(/^ {8}/gm, '').trimEnd();
  let out = '';
  for (let i = 0; i < raw.length; i++) {
    if (raw[i] !== '\\') { out += raw[i]; continue; }
    if (raw[i + 1] !== '(') { out += raw[i + 1] === 'n' ? '\n' : raw[i + 1]; i++; continue; }
    let depth = 1, j = i + 2;
    for (; depth; j++) { if (raw[j] === '(') depth++; else if (raw[j] === ')') depth--; }
    out += fill(raw.slice(i + 2, j - 1));
    i = j - 1;
  }
  return out;
}
const routeAsk = (message, earlier, photo = '') => promptOf('routeAsk', x =>
  x === 'message' ? message : x.includes('photo.isEmpty') ? (!photo ? '' : x.includes('with a photo of') ? ', with a photo of ' + photo
    : ' With a photo of a menu or delivery-app page, naming a dish on it for a meal ("this burger for dinner") is choose, unless they say they had or ate it.')
  : x.includes('earlier') ? (earlier ? `The conversation so far:\n${earlier}\n` : '') : '');
const menuAsk = (restaurant, area) => promptOf('menuAsk', x =>
  x === 'restaurant' ? restaurant : x === 'Plan.country' ? 'Australia' : x.startsWith('area') ? (area ? ` in ${area}` : '') : '');

const strict = (s) => { if (s && s.type === 'object') { s.additionalProperties = false; Object.values(s.properties).forEach(strict); } if (s && s.items) strict(s.items); return s; };
const n = { type: 'number' }, s = { type: 'string' };
const routeSchema = strict({ type: 'object', required: ['intent', 'restaurant', 'area', 'want', 'avoid', 'seen', 'kcal', 'protein'], properties: {
  intent: { type: 'string', enum: ['choose', 'find', 'log', 'other'] }, restaurant: s, area: s, want: { type: 'array', items: s }, avoid: { type: 'array', items: s },
  seen: { type: 'array', items: { type: 'object', required: ['name', 'kj'], properties: { name: s, kj: n } } }, kcal: n, protein: n } });
const menuSchema = strict({ type: 'object', required: ['found', 'restaurant', 'source', 'items', 'tips'], properties: {
  found: { type: 'boolean' }, restaurant: s, source: s, tips: { type: 'array', items: s },
  items: { type: 'array', items: { type: 'object', required: ['name', 'kind', 'published', 'kj', 'kcal', 'protein_g', 'carbs_g', 'fat_g'], properties: {
    name: s, kind: { type: 'string', enum: ['main', 'side', 'drink', 'dessert'] }, published: { type: 'string', enum: ['full', 'energy', 'none'] },
    kj: n, kcal: n, protein_g: n, carbs_g: n, fat_g: n } } } } });

// the chat as Takeaway.answer hands it over: the last six turns
const zam = [
  "They asked: Any places to recommend other than Nando’s",
  "You suggested these places: Nando's (Melbourne), Red Rooster (Melbourne), KFC (Melbourne), Zambrero (Melbourne)",
  'They asked: KFC',
  'You suggested from KFC: 6 Pieces Hot & Crispy + 3 Original Tenders; 5 Original Tenders + ½ 6 Pieces Hot & Crispy',
  'They asked: Zambrero',
  'You suggested from Zambrero: Classic Big Bowl + Signature Bowl; Quesadilla + Classic Big Bowl',
].join('\n');
const thai = [
  'They asked: No wings on DoorDash',
  "You: No wings, no problem. Here's just the Proper Cheesesteak on its own. It's the menu photo, so I sized it against the basket.",
  'They asked: From Thai social?',
  'You suggested from Thai Social: Stewed Pork Hock with Stewed Egg + Goong Ob Woonsen',
  'They asked: Meatworks Co',
  'You suggested from Meatworks Co: Beef Brisket Mayura Wagyu Signature Series + Smoked Chicken Drumsticks; St Louis BBQ Pork Ribs + Smoked Chicken Drumsticks',
].join('\n');
const stuck = thai + '\nThey asked: Bbq noodle bar? Think maybe on google it’s Noodle & BBQ\nYou: I couldn\'t find Bbq noodle bar\'s menu online.';
const photoThenPlace = "They asked: Sparrows Philly cheesesteak\nYou suggested from Sparrows: Proper Cheesesteak + Plain wings\nThey asked: No wings on DoorDash\nYou: No wings, no problem. Here's just the Proper Cheesesteak on its own.";
const planned = 'They asked: Sparrows Philly cheesesteak\nYou suggested from Sparrows: Proper Cheesesteak + Plain wings; Proper Cheesesteak';
const cases = [
  ['No wings on DoorDash', planned, "the place's page on the app they order from"],
  ['Any other suggestions', zam],
  ['Sparrows Philly cheesesteak', zam],
  ['Meatworks Co', photoThenPlace],
  ['Bbq noodle bar? Think maybe on google it’s Noodle & BBQ', thai],
  ['Bbq noodle bar? Think maybe on google it’s Noodle & BBQ', photoThenPlace],
  ['Bbq noodle bar is a new place on DoorDash', stuck.split('\n').slice(-6).join('\n')],
];

(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  const runs = Number(process.argv[2] || 3);
  for (let run = 0; run < runs; run++) {
    const got = await Promise.all(cases.map(([m, e, photo]) => client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 4000,
      messages: [{ role: 'user', content: routeAsk(m, e, photo) }], output_config: { effort: 'low', format: { type: 'json_schema', schema: routeSchema } } })));
    got.forEach((r, i) => {
      const j = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
      console.log(`route ${run + 1}: "${cases[i][0]}" -> ${j.intent} restaurant="${j.restaurant}" area="${j.area}" want=[${j.want}] avoid=[${j.avoid}] kcal=${j.kcal} protein=${j.protein}`);
    });
  }
  if (process.argv[3] !== 'menus') return;
  for (const [r, area] of [['Bbq noodle bar', ''], ['Bbq noodle bar', 'Melbourne'], ['Noodle & BBQ', 'Melbourne']]) {
    const res = await client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 12000, messages: [{ role: 'user', content: menuAsk(r, area) }],
      tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 3, user_location: { type: 'approximate', country: 'AU' } }, { type: 'web_fetch_20250910', name: 'web_fetch', max_uses: 3 }],
      output_config: { effort: 'low', format: { type: 'json_schema', schema: menuSchema } } });
    let j = {};
    try { j = JSON.parse(res.content.filter(b => b.type === 'text').map(b => b.text).join('')); } catch (e) { j = { source: 'unparsed: ' + e.message }; }
    console.log(`menu "${r}" ${area || '(no area)'}: found=${j.found} as "${j.restaurant}" items=${j.items?.length ?? 0} · ${j.source}`);
    for (const i of (j.items ?? []).slice(0, 8)) console.log(`    ${i.kind} ${i.name} · ${i.kcal} kcal · P${i.protein_g}`);
    for (const b of res.content) if (b.type === 'server_tool_use') console.log('    tool: ' + JSON.stringify(b.input).slice(0, 110));
  }
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
