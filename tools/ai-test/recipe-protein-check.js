// The healthier recipe's wording, today's against the new one (19 Nov), on Haiku as the app asks (job "recipes").
// The owner: a "healthier" protein pizza came back as a diet dish, where theirs keeps a real dough and gets the
// protein from vital wheat gluten. Prints each version's ingredients, totals, and any diet stand-in. About 3 cents.
// Run: node recipe-protein-check.js   (ANTHROPIC_API_KEY in the environment)
const Anthropic = require('@anthropic-ai/sdk').default;
const str = { type: 'string' }, num = { type: 'number' };
const closed = o => ({ additionalProperties: false, ...o });
const ing = { type: 'array', items: closed({ type: 'object', properties: { name: str, amount: str, grams: num, kcal: num, protein_g: num, carbs_g: num, fat_g: num }, required: ['name', 'amount', 'grams', 'kcal', 'protein_g', 'carbs_g', 'fat_g'] }) };
const schema = closed({ type: 'object', properties: { cuisine: str, minutes: num, portions: num,
  recipe: closed({ type: 'object', properties: { ingredients: ing, cookedGrams: num, changes: { type: 'array', items: str, description: "What's lighter than the usual dish, under 12 words each, e.g. 'Half the butter, a splash of milk instead'" } }, required: ['ingredients', 'cookedGrams', 'changes'] }) },
  required: ['cuisine', 'minutes', 'portions', 'recipe'] });

const OLD = "Keep the dish's character but make it lighter or higher in protein (less oil and butter, leaner cuts, more veg, swaps that taste close), with fewer calories than the usual dish, and list the changes.";
const NEW = "Keep it the real dish, made the way it normally is, and raise the protein first with ingredients that keep it that dish: vital wheat gluten or a high-protein flour in a dough or batter, leaner or extra meat, cured meats with less fat, higher-protein cheese or yoghurt in a sauce. Then trim what doesn't change what it is (a little less oil or butter, a lighter cheese). Never swap its base or heart for a diet stand-in: no cauliflower, chicken or egg-white crust for a pizza, no wraps or lettuce for bread, no courgette for pasta, no protein powder in a savoury dish. Fewer calories than the usual dish, or about the same with much more protein, and list the changes.";

const dishes = [
  { name: 'Spicy Pepperoni Protein Pizza', aim: ' One portion should come to about 1152 kcal and 74 g protein: choose realistic amounts that do.' },
  { name: 'Butter chicken', aim: '' },

];
const prompt = (d, base) => `Write the recipe for "${d.name}" for someone in Australia who cooks most nights.
${base}${d.aim} Just the ingredients for now: the method comes after.
If it's really a takeaway order or shop-bought, this is the lighter choice to buy or order.
Portions 1 to 4. Grams are as weighed; kcal and macros per ingredient from standard reference values, so they add up, and each ingredient's kcal ≈ 4 × protein + 4 × carbs + 9 × fat.
Raw meat and fish use their raw values, and never count oil for deep frying in full, only what's absorbed. If the dish's name promises something (a protein brownie), the ingredients must deliver it.
Use what's typical in Australia (cuts, brands and portion sizes there).`;
const diet = /cauliflower|egg white|wrap|tortilla|lettuce|zucchini|courgette|konjac|protein powder|whey|cottage cheese crust|chicken crust|cloud bread|spaghetti squash|shirataki/i;

(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  for (const d of dishes) {
    for (const [label, base] of [['today', OLD], ['new', NEW]]) {
      try {
        const r = await client.messages.create({ model: 'claude-haiku-5-5', max_tokens: 16000, output_config: { format: { type: 'json_schema', schema } },
          messages: [{ role: 'user', content: prompt(d, base) }] });
        if (r.stop_reason !== 'end_turn') console.log(d.name, label, 'stop', r.stop_reason, 'out', r.usage.output_tokens);
        const a = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
        const items = a.recipe.ingredients, n = Math.max(1, a.portions);
        const k = items.reduce((s, i) => s + i.kcal, 0) / n, p = items.reduce((s, i) => s + i.protein_g, 0) / n;
        const swaps = items.filter(i => diet.test(i.name)).map(i => i.name);
        console.log(`\n== ${d.name} · ${label}: a portion ${Math.round(k)} kcal, ${Math.round(p)} g protein (serves ${n})${swaps.length ? '  DIET STAND-IN: ' + swaps.join(', ') : ''}`);
        console.log('   ' + items.map(i => `${i.grams} g ${i.name}`).join('; '));
        console.log('   changes: ' + (a.recipe.changes || []).join(' | '));
      } catch (e) { console.log(d.name, label, 'FAILED', e.status || '', e.message); }
    }
  }
})();
