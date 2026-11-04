// Will Claude take the label reader's and scale reader's schemas (a dozen top-level nullable fields)? The Assistant's
// nested nullables were "too large". About a tenth of a cent.   node flat-schema-check.js
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const source = fs.readFileSync(path.join(__dirname, '../../supabase/functions/ai/index.ts'), 'utf8');
const body = source.match(/function claudeSchema\(s: any\): any \{[\s\S]*?\n\}/)[0].replace(/: any/g, '').replace(/ as any/g, '');
const claudeSchema = new Function(`${body}; return claudeSchema;`)();
const n = d => ({ type: 'number', nullable: true, description: d }), s = d => ({ type: 'string', nullable: true, description: d });
const label = { type: 'object', properties: {
  photo_shows: { type: 'string', enum: ['nutrition_table', 'pack', 'neither'] }, numbers_from: { type: 'string', enum: ['printed', 'estimate'] },
  piece_weight: n('g of one piece'), kcal_per_piece: n('kcal in one piece'), name: { type: 'string' }, brand: s('brand'), unit: { type: 'string', enum: ['g', 'ml'] },
  kcal_per_100: n('kcal per 100'), serving_size: n('serving g'), kcal_per_serving: n('kcal per serving'), pack_size: n('pack g'), pieces_per_pack: n('pieces'),
  protein_per_100: n('protein'), carbs_per_100: n('carbs'), fat_per_100: n('fat'), piece_name: s('piece name'), is_nutrition_label: { type: 'boolean' },
} };
label.required = Object.keys(label.properties);
const scale = { type: 'object', properties: {} };
for (const k of ['weight', 'fat', 'muscle', 'water', 'bone', 'visceral', 'age', 'bmi']) scale.properties[k] = n(k);
scale.properties.date = s('YYYY-MM-DD'); scale.properties.time = s('HH:MM');
scale.required = Object.keys(scale.properties);
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  for (const [name, schema, q] of [['label', label, 'A Tim Tam original biscuit pack, nothing readable.'], ['scale', scale, 'Screen shows: Weight 82.4 kg, Body fat 21.3 %, 4 Nov 2026 07:12']]) {
    const r = await client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 1000, messages: [{ role: 'user', content: [{ type: 'text', text: q }] }],
      output_config: { effort: 'low', format: { type: 'json_schema', schema: claudeSchema(schema) } } });
    console.log(name, r.stop_reason, r.content.filter(b => b.type === 'text').map(b => b.text).join('').slice(0, 300));
  }
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });
