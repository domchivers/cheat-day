// Each job: its tasks, the prompt, and how an answer is scored. The rules here were set before any model ran.
const fs = require('fs'), path = require('path');
const food = require('./data/food-db.json');
const sheet = name => JSON.parse(fs.readFileSync(path.join(__dirname, 'tasks', name + '.json'), 'utf8')).tasks;
const within = (got, want, share, floor = 0) => typeof got === 'number' && Math.abs(got - want) <= Math.max(want * share, floor);
const atwater = x => 4 * (x.protein ?? x.protein_g ?? 0) + 4 * (x.carbs ?? x.carbs_g ?? 0) + 9 * (x.fat ?? x.fat_g ?? 0);

// finds a food by its words: raw unless the name says cooked, Australian measured data first, the plainest name first
const filler = new Set(['fresh', 'chopped', 'sliced', 'diced', 'large', 'small', 'medium', 'finely', 'peeled', 'boneless', 'skinless', 'lean', 'of', 'and', 'for', 'to', 'taste', 'grated', 'minced', 'crushed', 'dried', 'ground', 'whole', 'extra', 'virgin', 'cubed', 'thinly', 'roughly', 'optional', 'brushed', 'washed']);
const words = s => s.toLowerCase().replace(/[^a-z ]/g, ' ').split(/\s+/).filter(w => w && !filler.has(w)).map(w => w.replace(/(oes|ies|s)$/, m => (m === 'ies' ? 'y' : m === 'oes' ? 'o' : '')));
const index = food.map(f => ({ f, w: new Set(words(f.name)), raw: /\braw\b|uncooked/i.test(f.name) }));
// the everyday name of a common ingredient comes first. Otherwise the food's own kind must be the ingredient's last
// word ("vegetable oil" never finds puff pastry made with it), or it stays unknown and isn't scored
const alias = new Map();
for (const [names, foodName] of JSON.parse(fs.readFileSync(path.join(__dirname, 'aliases.json'), 'utf8'))) {
  const f = food.find(x => x.name.trim() === foodName); if (!f) throw new Error('alias has no food: ' + foodName);
  names.split('|').forEach(n => alias.set(words(n).join(' '), f));
}
// how it's cooked counts ("pan fried, no oil" is the no-added-fat fried potato, not boiled), and a variety only when
// they named it (the table lists potatoes as coliban, desiree, sebago…; a plain potato is the plain one). Same in tables.js and FoodTable.
const METHODS = ['boiled', 'fried', 'baked', 'roast', 'grilled', 'steamed', 'microwaved'];
function narrow(name, hits, want) {
  let n = name.toLowerCase();
  for (const [said, row] of [['fry', 'fried'], ['boil', 'boiled'], ['bake', 'baked'], ['grill', 'grilled'], ['steam', 'steamed']])
    n = n.replace(new RegExp(`\\b${said}(ing)?\\b`, 'g'), row);   // "will pan fry" is fried
  let h = hits;
  const keep = test => { const k = h.filter(x => test(x.f.name.toLowerCase())); if (k.length) h = k; };   // only when something's left
  keep(f => words(f.split(',')[0]).join(' ') === want.join(' '));   // a potato is a potato, not a sweet potato
  for (const m of METHODS) if (n.includes(m)) keep(f => f.includes(m));
  if (/\b(no|without)\s+(added\s+)?(oil|fat|butter)\b/.test(n)) keep(f => f.includes('no added fat'));
  else if (/\b(with|in)\s+(\w+\s+)?(oil|fat|butter)\b/.test(n)) keep(f => /added fat/.test(f) && !f.includes('no added fat'));
  keep(f => { const v = f.match(/\b(coliban|desiree|sebago|pontiac|kipfler|nicola|new|pale skin|red skin)\b/); return !v || n.includes(v[1]); });
  return h;
}
function resolve(name) {
  const want = words(name.split(/[,(]/)[0]);
  if (!want.length) return null;
  const cooked = /cooked|boil|grill|roast|fried|fry|bake|steam/i.test(name);
  const named = alias.get(want.join(' '));
  const dry = /\b(dry|dried|uncooked)\b/i.test(name);
  // "potato, boiled" isn't the raw potato, and dried noodles aren't boiled ones
  if (named && !(cooked && /\braw\b|uncooked/i.test(named.name)) && !(dry && /\b(boiled|cooked|drained)\b/i.test(named.name))) return named;
  const head = want[want.length - 1];
  const hits = narrow(name, index.filter(x => {
    if (!want.every(w => x.w.has(w))) return false;
    const parts = x.f.name.split(','), kind = words(parts[0]), lead = words(parts.slice(0, 2).join(' '));
    return kind.includes(head) || kind.includes(want[0]) || want.every(w => lead.includes(w));   // "Salmon fillet", "Beef, rump steak"
  }), want);
  if (!hits.length) return null;
  const rank = x => (x.raw === !cooked ? 0 : 100) + (x.f.source === 'AFCD3' ? 0 : 20) + x.w.size * 2;
  return hits.sort((a, b) => rank(a) - rank(b))[0].f;
}

const JSON_ONLY = 'Reply with one JSON object only, no other text.';
const jobs = {
  labels: {
    tasks: () => sheet('labels'), image: t => t.photo, maxTokens: 1500,
    prompt: () => `This is a photo of a nutrition table. Read the per-100 g or per-100 mL column. Convert kJ to kcal if needed (kcal = kJ / 4.184). Use null for anything you can't read. ${JSON_ONLY} {"kcal_per_100":number|null,"protein":number|null,"carbs":number|null,"fat":number|null}`,
    score: (t, a) => { const kcal = within(a.kcal_per_100, t.kcal, 0.1, 5), macros = within(a.protein, t.p, 0.1, 1) && within(a.carbs, t.c, 0.1, 1) && within(a.fat, t.f, 0.1, 1); return { pass: kcal && macros, kcalOk: kcal, macrosOk: macros, error: pct(a.kcal_per_100, t.kcal) }; },
  },
  quicklogs: {
    tasks: () => sheet('quicklogs'), maxTokens: 1500,
    prompt: t => `Someone in Australia typed this into a food diary: "${t.text}". Work out what they ate, using the weights they gave. ${JSON_ONLY} {"kcal":number,"protein":number,"carbs":number,"fat":number}`,
    score: (t, a) => ({ pass: within(a.kcal, t.kcal, 0.1, 10), proteinOk: within(a.protein, t.p, 0.15, 2), error: pct(a.kcal, t.kcal) }),
  },
  plates: {
    tasks: () => sheet('plates'), image: t => t.photo, maxTokens: 2500,
    prompt: () => `Estimate this plate of food. List each item you can see with your guess of its cooked weight, then the total for everything on the plate. ${JSON_ONLY} {"items":[{"name":string,"grams":number,"kcal":number}],"kcal":number,"protein":number,"carbs":number,"fat":number}`,
    // the dish's weight is measured, but its calories use generic per-gram values with little or no cooking oil, so they can read low.
    // The weight is what the app needs from a photo once the database supplies the numbers, so it's scored as well.
    score: (t, a) => {
      const grams = Array.isArray(a.items) ? a.items.reduce((s, i) => s + (i.grams || 0), 0) : null;
      return { pass: within(a.kcal, t.kcal, 0.2), proteinOk: within(a.protein, t.p, 0.3, 3), gramsOk: within(grams, t.grams, 0.2), gramsError: pct(grams, t.grams), error: pct(a.kcal, t.kcal) };
    },
  },
  recipes: {
    tasks: () => sheet('recipes'), maxTokens: 6000,
    prompt: t => `Write the recipe for "${t.name}" for someone in Australia who cooks at home. Grams as weighed: raw meat and fish use raw values, and count only the oil absorbed when deep frying. Numbers per ingredient, each kcal close to 4 x protein + 4 x carbs + 9 x fat. If the name promises something (a protein brownie), the ingredients must deliver it. ${JSON_ONLY} {"portions":number,"cookedGrams":number,"ingredients":[{"name":string,"grams":number,"kcal":number,"protein_g":number,"carbs_g":number,"fat_g":number}]}`,
    score: (t, a) => {
      const list = Array.isArray(a.ingredients) ? a.ingredients : [];
      const found = list.map(i => ({ i, f: resolve(String(i.name || '')) }));
      const kcal = list.reduce((s, i) => s + (i.kcal || 0), 0), protein = list.reduce((s, i) => s + (i.protein_g || 0), 0);
      const known = found.filter(x => x.f), knownShare = kcal ? known.reduce((s, x) => s + (x.i.kcal || 0), 0) / kcal : 0;
      const dbKcal = found.reduce((s, x) => s + (x.f ? x.f.kcal * (x.i.grams || 0) / 100 : x.i.kcal || 0), 0);
      const addsUp = list.length > 0 && list.every(i => (i.kcal || 0) < 15 || within(atwater(i), i.kcal, 0.2, 8));
      // how far its calories are from the data, as a share of the dish: one spoon of tomato paste shouldn't fail a lasagne
      const knownKcal = known.reduce((s, x) => s + (x.i.kcal || 0), 0);
      const numbersOff = knownKcal ? known.reduce((s, x) => s + Math.abs((x.i.kcal || 0) - x.f.kcal * (x.i.grams || 0) / 100), 0) / knownKcal : 1;
      const numbersOk = list.length > 0 && numbersOff <= 0.15;
      const per100 = a.cookedGrams > 0 ? dbKcal / a.cookedGrams * 100 : null;
      // these have no comparable Australian entry: the entries are the meat alone, no sides, or a normal brownie, not a protein one
      const noMatch = /stir fry|rogan|salmon with|barramundi|roast chicken|roast lamb|pork belly|sausages and|protein brownie|chickpea/i.test(t.name);
      const dishOk = !noMatch && t.range && per100 != null ? per100 >= t.range[0] * 0.7 && per100 <= t.range[1] * 1.3 : null;
      const promiseOk = !t.promise || (kcal > 0 && protein * 4 / kcal >= 0.2);
      return { pass: addsUp && numbersOk && dishOk !== false && promiseOk, addsUp, numbersOk, numbersOff: +numbersOff.toFixed(2), dishOk, promiseOk, knownShare: +knownShare.toFixed(2), scored: knownShare >= 0.7, per100: per100 && Math.round(per100) };
    },
  },
  plans: {
    tasks: () => sheet('plans'), maxTokens: 4000,
    prompt: t => `You're planning a cheat day with someone in Australia. It should feel like a treat, not a diet. It's ${t.now} today: every slot's time is after that. About ${t.room} kcal are available for the slots.${t.protein ? ` Protein still to reach today: ${t.protein} g.` : ''} Their saved meals with real numbers: ${t.saved.length ? JSON.stringify(t.saved) : 'none'}. If they mean one, set saved to its exact name and use exactly those numbers. Foods they love: ${t.loves}. Never include: ${t.avoid}. They say: "${t.say}". Plan ONLY what they asked for and never use up the calories unless they ask. If they ask to leave an amount free, leave about that much. ${JSON_ONLY} {"slots":[{"time":"HH:MM","title":string,"detail":string,"kcal":number,"protein":number,"carbs":number,"fat":number,"saved":string}]}`,
    score: (t, a) => {
      const slots = Array.isArray(a.slots) ? a.slots : [], kcal = slots.reduce((s, x) => s + (x.kcal || 0), 0), protein = slots.reduce((s, x) => s + (x.protein || 0), 0);
      const inRoom = kcal > 0 && kcal <= t.room * 1.05, leavesFree = !t.free || kcal <= t.room - t.free * 0.7;
      const asksProtein = /protein/i.test(t.say), proteinOk = !asksProtein || !t.protein || protein >= t.protein * 0.9;
      const times = slots.every(x => String(x.time) > t.now);
      const text = slots.map(x => `${x.title} ${x.detail}`).join(' ').toLowerCase();
      const plain = text.replace(/dairy.free[^.;]*|ice cream sundae|peanut butter/g, ' ');   // "dairy-free ice cream" is what they asked for
      const banned = t.avoid.split(',').map(w => w.trim().toLowerCase().replace(/s$/, '')).filter(w => new RegExp(`\\b${w}`).test(plain) && !new RegExp(`(no|free|without|non)[- ]*${w}`).test(plain));
      const saved = !t.mustUse || (() => { const s = slots.find(x => x.saved === t.mustUse), real = t.saved.find(m => m.name === t.mustUse); return s && within(s.kcal, real.kcal, 0.02, 5); })();
      const addsUp = slots.every(x => (x.kcal || 0) < 50 || /beer|wine|cocktail|spritz|cider/i.test(`${x.title} ${x.detail}`) || within(atwater(x), x.kcal, 0.25, 30));   // alcohol's energy isn't in its macros
      const onlyAsked = !t.maxSlots || slots.length <= t.maxSlots;   // "plan ONLY what they asked for"
      return { pass: inRoom && leavesFree && proteinOk && times && !banned.length && !!saved && addsUp && onlyAsked, onlyAsked, inRoom, leavesFree, proteinOk, times, banned, saved: !!saved, addsUp, kcal: Math.round(kcal) };
    },
  },
  chats: {
    tasks: () => sheet('chats'), maxTokens: 1500, text: true,
    prompt: t => `You are the assistant inside a cheat-day food diary app, talking to someone in Australia. Be brief, friendly and practical, and never promote crash diets or unsafe restriction. They ask: "${t.text}"`,
    score: () => ({ pass: null, manual: true }),
  },
};
// the same plates with the app's photo sizing rule (Assistant.rules, 7 Nov 2026): sized against what's in the shot
jobs.sized = {
  ...jobs.plates,
  prompt: () => `Estimate this plate of food. Size each food against something of known size in the shot before giving grams (a side plate is about 18 cm across, a dinner plate 27 cm, a mug 9 cm, a small takeaway box 12 cm inside, a fork 19 cm, a hand 9 cm wide). Never assume a standard portion: café items vary a lot. List each item you can see with your guess of its cooked weight, then the total for everything on the plate. ${JSON_ONLY} {"items":[{"name":string,"grams":number,"kcal":number}],"kcal":number,"protein":number,"carbs":number,"fat":number}`,
};
// the same plates, with what the person says is on them
jobs.described = {
  ...jobs.plates, tasks: () => sheet('plates-described'),
  prompt: t => `Estimate this plate of food. The person says it's: "${t.said}". Trust what they say about what the foods are, and judge the amounts from the photo. List each item with your guess of its cooked weight, then the total for everything on the plate. ${JSON_ONLY} {"items":[{"name":string,"grams":number,"kcal":number}],"kcal":number,"protein":number,"carbs":number,"fat":number}`,
};
const pct = (got, want) => (typeof got === 'number' && want ? Math.round((got - want) / want * 100) : null);

// every task keeps its place for good: about 30% are held back for the final score
const hash = s => { let h = 7; for (const c of s) h = (h * 31 + c.charCodeAt(0)) % 1000003; return h; };
const split = id => (hash(id) % 10 < 3 ? 'final' : 'tune');
// the first complete JSON object, so a note written after it doesn't lose a good answer. The app will ask for structured output instead.
const parse = text => {
  const s = String(text);
  for (let start = s.indexOf('{'); start >= 0; start = s.indexOf('{', start + 1)) {
    let depth = 0, quoted = false;
    for (let i = start; i < s.length; i++) {
      const c = s[i];
      if (quoted) { if (c === '\\') i++; else if (c === '"') quoted = false; continue; }
      if (c === '"') quoted = true; else if (c === '{') depth++;
      else if (c === '}' && --depth === 0) { try { return JSON.parse(s.slice(start, i + 1)); } catch { break; } }
    }
  }
  throw new Error('no JSON');
};
module.exports = { jobs, split, parse, resolve, within, words, narrow };
