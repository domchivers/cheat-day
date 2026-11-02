// Tries the app's real recipe request on Claude with different settings: tokens, time and whether the answer is complete. About 2 cents.
const Anthropic = require('@anthropic-ai/sdk').default;
const str = { type: 'string' }, num = { type: 'number' };
const closed = o => ({ additionalProperties: false, ...o });
const ing = { type: 'array', items: closed({ type: 'object', properties: { name: str, amount: str, grams: num, kcal: num, protein_g: num, carbs_g: num, fat_g: num }, required: ['name', 'amount', 'grams', 'kcal', 'protein_g', 'carbs_g', 'fat_g'] }) };
const version = c => closed({ type: 'object', properties: { ingredients: ing, cookedGrams: num, ...(c ? { changes: { type: 'array', items: str } } : {}) }, required: c ? ['ingredients', 'changes'] : ['ingredients'] });
const schema = closed({ type: 'object', properties: { cuisine: str, minutes: num, portions: num, authentic: version(false), healthier: version(true) }, required: ['cuisine', 'minutes', 'portions', 'authentic', 'healthier'] });
const prompt = `Write the recipe for "Butter chicken" for someone in Australia who cooks most nights.
authentic: how it's really made in its home cuisine, true to the dish, with ingredients they can buy there. Just the ingredients for now: the method comes after.
healthier: the same dish with its character kept, lighter or higher in protein, and list the changes.
Portions 1 to 4. Grams are as weighed; kcal and macros per ingredient from standard reference values, so they add up, and each ingredient's kcal = 4 x protein + 4 x carbs + 9 x fat.
Raw meat and fish use their raw values, and never count oil for deep frying in full, only what's absorbed. Use what's typical in Australia.`;
const tries = [
  ['haiku default', { model: 'claude-haiku-5-5', output_config: { format: { type: 'json_schema', schema } } }],
  ['haiku effort low', { model: 'claude-haiku-5-5', output_config: { effort: 'low', format: { type: 'json_schema', schema } } }],
  ['sonnet effort low', { model: 'claude-sonnet-5-5', output_config: { effort: 'low', format: { type: 'json_schema', schema } } }],
];
(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  for (const [label, opts] of tries) {
    const t = Date.now();
    try {
      const r = await client.messages.create({ ...opts, max_tokens: 8000, messages: [{ role: 'user', content: prompt }] });
      const text = r.content.filter(b => b.type === 'text').map(b => b.text).join('');
      let ok = 'not JSON'; try { const a = JSON.parse(text); ok = `${a.authentic.ingredients.length} + ${a.healthier.ingredients.length} ingredients, serves ${a.portions}`; } catch {}
      console.log(label, '|', r.stop_reason, '| out', r.usage.output_tokens, '| text chars', text.length, '|', Date.now() - t, 'ms |', ok, '| kinds', r.content.map(b => b.type).join(','));
      if (r.stop_reason === 'max_tokens') console.log('  tail:', JSON.stringify(text.slice(-160)));
    } catch (e) { console.log(label, 'FAILED', e.status, e.error?.error?.message || e.name); }
  }
})();
