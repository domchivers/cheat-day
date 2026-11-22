// A receipt and its follow-up through the app's own rules and photo format, and ordinary named meals as controls.
//   node receipt-app-check.js receipt.jpg [runs]      VARIANT=name adds variants/<name>.txt to the rules
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const read = f => fs.readFileSync(path.join(__dirname, f), 'utf8').replace(/\r/g, '');
const fn = read('../../supabase/functions/ai/index.ts').match(/function claudeSchema\(s: any\): any \{[\s\S]*?\n\}/)[0].replace(/: any/g, '').replace(/ as any/g, '');
const claudeSchema = new Function(`${fn}; return claudeSchema;`)();
const schema = new Function(read('n5k-run.js').match(/const n = \{ type: 'number' \}[\s\S]*?\n}\);\n/)[0] + 'return schema;')();
const props = schema.properties.estimate.properties.parts.items.properties;
const swift = read('../../native/CheatDays/Model/Assistant.swift');
props.tags.description = swift.match(/"tags": \["type": "string", "description": "([^"]*)"/)[1];
const amounts = read('../../native/CheatDays/Model/Sanity.swift').match(/static let amounts = "([^"]*)"/)[1];
const rules = swift.match(/static let rules = """\n([\s\S]*?)\n\s*"""/)[1].replace(/^ {4}/gm, '').replace('\(Sanity.amounts)', () => amounts)
  + (process.env.VARIANT ? '\n' + read(`variants/${process.env.VARIANT}.txt`).trim() : '');
const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
const context = 'They live in Australia: use the usual portion sizes there. Today: budget 2000 kcal, eaten 666 kcal, 1334 kcal left. Protein so far 42 g of 150 g. Workouts today: none.\n';
async function ask(img, text, effort = process.env.EFFORT) {
  const content = [{ type: 'text', text: `You are the assistant inside a cheat-day food diary app called Cheat Days.\n${rules}` }, ...(img ? [img] : []), { type: 'text', text: context + text }];
  const t0 = Date.now();
  const r = await client.messages.create({ model: 'claude-sonnet-5-5', max_tokens: 12000, messages: [{ role: 'user', content }], output_config: { ...(effort ? { effort } : {}), format: { type: 'json_schema', schema: claudeSchema(schema) } } });
  if (img) console.log(`  Claude took ${((Date.now() - t0) / 1000).toFixed(1)} s, ${r.usage.output_tokens} tokens out, ${r.stop_reason}`);
  return JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
}
const total = (a, k = 'kcal') => Math.round((a.estimate?.parts ?? []).reduce((t, p) => t + p[k], 0));
const controls = [['Big Mac from Maccas', 564], ['10 chicken McNuggets from Maccas, no sauce', 450], ['grilled chicken breast 200g and 150g steamed rice, cooked at home', 525],
  ['2 eggs on toast with a teaspoon of butter, at home', 355], ['6 pieces salmon nigiri from a sushi shop', 340], ['Subway six inch turkey, no cheese, no sauce', 280]];
(async () => {
  const runs = Number(process.argv[3] || 3);
  const img = { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: fs.readFileSync(process.argv[2]).toString('base64') } };
  await Promise.all(Array.from({ length: runs }, async (_, i) => {
    const talk = "They: From this place\nYou: Thanks, I can see it's Noodle & BBQ in Carnegie, a Northwest Chinese place known for hand-pulled noodles and lamb skewers.\n";
    const a = await ask(img, `Recent conversation:\n${talk}They now say: "Everything we ordered"\n`);
    const card = (a.estimate?.parts ?? []).map(p => `${p.name} ${Math.round(p.grams)} g ${Math.round(p.kcal)} kcal`).join('; ');
    const b = await ask(img, `Recent conversation:\n${talk}They: Everything we ordered\nYou: ${a.reply} [you worked out: ${a.estimate?.name}, ${total(a)} kcal: ${card}]\nThey now say: "Wanted the stinky tofu for myself everything else around half or what do you recommend?" (about the photos from earlier)\n`);
    const out = [`receipt ${i + 1}: full ${total(a)} kcal P${total(a, 'protein_g')} -> share ${total(b)} kcal P${total(b, 'protein_g')}`];
    for (const p of b.estimate?.parts ?? []) out.push(`   ${p.name} | ${Math.round(p.grams)} g ${Math.round(p.kcal)} kcal P${Math.round(p.protein_g)} | ${p.tags}`);
    out.push('   reply: ' + b.reply);
    console.log(out.join('\n'));
  }));
  if (!process.env.PHOTO_ONLY) await Promise.all(controls.map(async ([said, usual]) => {
    const got = await Promise.all(Array.from({ length: runs }, () => ask(null, `They now say: "${said}"\n`)));
    console.log(`control: ${said}: ${got.map(a => total(a)).join(', ')} (usual about ${usual}) | ${got[0].estimate?.parts?.map(p => p.tags).join(' / ')}`);
  }));
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
