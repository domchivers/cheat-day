// Other names that would send a search to the wrong food (28 Nov): the app looks other names up before a table's own rows,
// so "mochi" went to daifuku, "manju" to a filled castella manju, "beef noodle soup" to pho. An other name is dropped when,
// read the app's way (FoodTable.words: filler words like dried, fresh, whole gone, plurals cut), it's the plain name of
// another entry in the table, or it names more than one entry.
const filler = new Set(['fresh', 'chopped', 'sliced', 'diced', 'large', 'small', 'medium', 'finely', 'peeled', 'boneless', 'skinless', 'lean', 'of', 'and', 'for', 'to', 'taste', 'grated', 'minced', 'crushed', 'dried', 'ground', 'whole', 'extra', 'virgin', 'cubed', 'thinly', 'roughly', 'optional', 'brushed', 'washed']);
const key = s => s.toLowerCase().replace(/[^a-z ]/g, ' ').split(/\s+/).filter(x => x && !filler.has(x))
  .map(x => x.endsWith('oes') ? x.slice(0, -3) + 'o' : x.endsWith('ies') ? x.slice(0, -3) + 'y' : x.endsWith('s') ? x.slice(0, -1) : x).join(' ');
const lead = name => key(name.split(/[,(]/)[0]);

function cleanAliases(foods, aliases) {
  const plainOf = new Map();
  for (const f of foods) { const l = lead(f.name); if (!plainOf.has(l)) plainOf.set(l, f.name); }
  const targets = new Map();
  for (const [a, t] of aliases) for (const x of a.split('|')) { const k = key(x); if (!targets.has(k)) targets.set(k, new Set()); targets.get(k).add(t); }
  let dropped = 0;
  const out = [];
  for (const [a, t] of aliases) {
    const keep = a.split('|').filter(x => {
      const k = key(x), owner = plainOf.get(k);
      const ok = k && !(owner && owner !== t && lead(t) !== k) && targets.get(k).size === 1;
      if (!ok) dropped++;
      return ok;
    });
    if (keep.length) out.push([keep.join('|'), t]);
  }
  return { aliases: out, dropped };
}
module.exports = { cleanAliases };
