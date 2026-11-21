// The cheat day planner asked for protein (21 Nov: "Need 130g protein" got three protein shakes added to a cheat day).
// The rule as it is against the rule with protein the tasty way, on Sonnet as the app sends it (job "chat"). A few cents.
//   node cheat-protein-check.js
const fs = require('fs'), path = require('path'), Anthropic = require('@anthropic-ai/sdk').default;
const source = fs.readFileSync(path.join(__dirname, '../../supabase/functions/ai/index.ts'), 'utf8');
const body = source.match(/function claudeSchema\(s: any\): any \{[\s\S]*?\n\}/)[0].replace(/: any/g, '').replace(/ as any/g, '');
const claudeSchema = new Function(`${body}; return claudeSchema;`)();

const n = { type: 'number' }, s = { type: 'string' };
const obj = (props, desc = '') => ({ type: 'object', properties: props, required: Object.keys(props), ...(desc ? { description: desc } : {}) });
const part = obj({ name: { type: 'string', description: 'a plain food name as a food table has it, e.g. "Chicken thigh, fried", "Bread roll, white"' },
  grams: { type: 'number', description: 'as eaten (cooked weight)' }, kcal: n, protein: n, carbs: n, fat: n });
const slot = obj({ time: { type: 'string', description: '24-hour time like 15:30' }, title: s, detail: { type: 'string', description: "Under 12 words: what's in it. Empty for a saved meal" },
  kcal: n, protein: n, carbs: n, fat: n, workout: { type: 'boolean' }, saved: { type: 'string', description: 'The exact name of the saved meal this is, or empty' },
  parts: { type: 'array', items: part, description: "The dish's main parts as eaten, each with its grams and its own numbers; the slot's numbers are these added up. Empty for a saved meal or a workout" } });
const schema = obj({ title: { type: 'string', description: "A short title for the plan, from what's in it" }, reply: { type: 'string', description: 'Under 20 words, friendly: what you did or changed' },
  slots: { type: 'array', items: slot }, options: { type: 'array', items: slot, description: 'For an open request: 3 more dishes to choose from, not in the plan. Empty when they named what they want' } });

const OLD = `If they ask to reach their protein, reach it with what they asked for plus as little as possible, and say what you added.`;
const NEW = `If they ask to reach their protein, or for an amount of it, reach it with what they asked for plus as few real dishes as it takes, and say what you added. It's a cheat day: the protein comes the tasty way, from proper dishes that are rich in it (a steak, a burger, fried chicken, a kebab, Korean BBQ, a loaded burrito), never protein shakes, powder or bars unless they ask for those by name, and never the same dish twice. If that goes over the calories available, that's fine; say so.`;

const prompt = (said, rule, plan) => `You're planning a cheat day together with someone in Australia. It should feel like a treat, not a diet.
It's 16:20 today: every slot's time is after 16:20.
Already logged today, never list these: Chinese breakfast: tea eggs, youtiao and soy milk (1050 kcal).
About 2200 kcal are available for the slots. Protein still to reach today: 139 g.
Their saved meals, newest first, with their real numbers: Protein brownie: 430 kcal, 78 g protein. If they mean one of these ("my brownie"), use it, the newest that fits, set saved to its exact name and use exactly those numbers. Something added to a saved meal (a frosting) is its own slot, and the saved meal stays as it is.
Foods they love: burgers, Korean food, desserts. Never include: nothing. What they often have for dinner: chicken and rice, beef hotpot.
${plan ? `The plan so far:\n${plan}\nKeep every slot exactly as it is unless they ask to change it, or a change they asked for can't work without it, and if so say so in reply.` : ''}
They now say: "${said}"
Rules. Plan ONLY what they asked for. Never fill the day or use up the calories unless they ask: unused calories are theirs to enjoy, and the app shows them. If they ask to leave an amount free, make the slots leave about that much. ${rule} Only add a workout if they ask (workout true, kcal 0). If they ask for something open rather than naming dishes (a cuisine, a mood, "something sweet", "ideas"), put your one best pick in slots and 3 more real dishes of that kind in options for them to choose from; they aren't in the plan until they add one. When they name what they want, options is empty. Name real dishes and orders. Numbers come from standard reference values, never raised to fit. Never suggest skipping meals or making up for it tomorrow.
`;
const bingsu = '21:15 Mango bingsu (470 kcal, 9 g protein)';
const cases = [
  ['Need 130g protein', bingsu],
  ['More protein', bingsu],
  ['Hit my protein, I want fried chicken tonight', ''],
  ['Add a protein shake to hit my protein', bingsu],
];

(async () => {
  const client = new Anthropic({ baseURL: 'https://api.anthropic.com' });
  for (const [said, plan] of cases) {
    console.log(`\n=== "${said}"${plan ? ' (bingsu planned)' : ''}`);
    for (const [label, rule] of [['old', OLD], ['new', NEW]]) {
      const r = await client.messages.create({ model: 'claude-sonnet-5-5', max_tokens: 4000, messages: [{ role: 'user', content: prompt(said, rule, plan) }],
        output_config: { format: { type: 'json_schema', schema: claudeSchema(schema) } } });
      const a = JSON.parse(r.content.filter(b => b.type === 'text').map(b => b.text).join(''));
      const k = a.slots.reduce((t, x) => t + x.kcal, 0), p = a.slots.reduce((t, x) => t + x.protein, 0);
      console.log(`  ${label}: ${a.reply}`);
      for (const x of a.slots) console.log(`     ${x.time} ${x.title}: ${Math.round(x.kcal)} kcal, P ${Math.round(x.protein)}`);
      console.log(`     = ${Math.round(k)} kcal, ${Math.round(p)} g protein in the slots`);
    }
  }
})();
