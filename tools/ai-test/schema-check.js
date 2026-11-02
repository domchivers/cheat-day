// Checks the conversion in supabase/functions/ai on real Claude calls, using a schema shaped like the Assistant's. About 1 cent.
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const source = fs.readFileSync(path.join(__dirname, '../../supabase/functions/ai/index.ts'), 'utf8');
const body = source.match(/function claudeSchema\(s: any\): any \{[\s\S]*?\n\}/)[0].replace(/: any/g, '').replace(/ as any/g, '');
const claudeSchema = new Function(`${body}; return claudeSchema;`)();
const n = { type: 'number' }, s = { type: 'string' }, nn = { type: 'number', nullable: true };
const obj = (props, extra = {}) => ({ type: 'object', properties: props, required: Object.keys(props), ...extra });
const schema = obj({
  kind: { type: 'string', enum: ['answer', 'estimate'] }, reply: s,
  estimate: obj({ name: s, grams: nn, unit: { type: 'string', enum: ['g', 'ml'], nullable: true }, parts: { type: 'array', items: obj({ name: s, kcal: n }) } }, { nullable: true, description: 'kind=estimate only' }),
});
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  for (const model of ['claude-haiku-5-5', 'claude-sonnet-5-5']) for (const q of ['What is protein?', 'I had 2 boiled eggs and toast']) {
    const r = await client.messages.create({ model, max_tokens: 1500, messages: [{ role: 'user', content: [{ type: 'text', text: q }] }], output_config: { format: { type: 'json_schema', schema: claudeSchema(schema) } } });
    const a = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
    console.log(model, '|', q, '|', r.stop_reason, '| kind', a.kind, '| estimate', a.estimate === null ? 'null' : a.estimate && a.estimate.parts.length + ' parts', '|', r.usage.input_tokens, r.usage.output_tokens);
  }
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.name); process.exit(1); });
