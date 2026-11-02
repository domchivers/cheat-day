// Compares the app's reference.json with Australian data, row by row, and writes data/reference-check.md.
// Each row is matched by hand to its "as bought" entry: untrimmed cuts, raw, skin only where the row says so.
const fs = require('fs'), path = require('path');
const ref = JSON.parse(fs.readFileSync(path.join(__dirname, '../../native/CheatDays/Resources/reference.json'), 'utf8'));
const db = Object.fromEntries(require('./data/food-db.json').map(f => [f.key, f]));
const map = {
  'Kingfish (yellowtail)': ['F004811', 'farmed, with skin; no skinless entry'], 'Snapper': ['F008359'], 'Barramundi': ['F000386', 'farmed'], 'Flathead': ['F003973'], 'Basa': ['F000402'],
  'Cod': ['F003002', 'borrowed from overseas data'], 'Tuna': ['F009303', 'yellowfin, borrowed'], 'Salmon': ['F007827', 'Atlantic'], 'Trout': ['F009271', 'rainbow, farmed'], 'White fish': ['F003956', 'recipe average'],
  'Prawns': ['F007433'], 'Squid': ['F008828'], 'Scallops': ['F008166'], 'Mussels': ['F005968', 'only cooked is listed, so not comparable'],
  'Chicken thigh, skin on': ['F002809'], 'Chicken thigh': ['F002806'], 'Chicken breast': ['F002594'], 'Chicken drumstick': ['F002650', 'with skin'], 'Chicken wing': ['F002852', 'with skin'], 'Chicken mince': ['F002739'],
  'Beef chuck': ['F000527', 'untrimmed'], 'Gravy beef': ['F000518', 'shin, untrimmed'], 'Rump steak': ['F000765', 'untrimmed'], 'Sirloin': ['F000825', 'untrimmed'], 'Scotch fillet': ['F000851', 'untrimmed'], 'Eye fillet': ['F000839', 'untrimmed'],
  'Beef mince, extra lean': ['F000666', 'lower fat'], 'Beef mince, lean': ['F000678', 'regular fat; tiers are my pairing'], 'Beef mince': ['F000655', 'higher fat; tiers are my pairing'],
  'Pork mince': ['F007057'], 'Pork shoulder': ['F006929', 'untrimmed'], 'Pork loin': ['F006993', 'chop, untrimmed'], 'Pork belly': ['F006862', 'rind removed'],
  'Lamb leg': ['F005017', 'untrimmed'], 'Lamb shoulder': ['F005077', 'untrimmed'], 'Lamb mince': ['F005049'],
  'Cocoa powder': ['F002980', 'your Cadbury label (327) wins'], 'Whey protein powder': ['F007491'], 'Brioche bun': ['F010407'],
};
const rows = ref.map(r => {
  const [kcal, p, c, f] = r.v, m = map[r.n], d = m && db[m[0]];
  if (!d) return { name: r.n, kcal, gap: null, note: 'no Australian entry' };
  return { name: r.n, kcal, p, f, au: d, gap: Math.round((kcal - d.kcal) / d.kcal * 100), note: m[1] || '' };
}).sort((a, b) => Math.abs(b.gap ?? -1) - Math.abs(a.gap ?? -1));
const line = r => r.au
  ? `| ${r.name} | ${r.kcal} | ${r.au.kcal} | ${r.gap > 0 ? '+' : ''}${r.gap}% | ${r.p} / ${r.au.p} | ${r.f} / ${r.au.f} | ${r.au.name.trim()} (${r.au.key}, ${r.au.derivation}) | ${r.note} |`
  : `| ${r.name} | ${r.kcal} | none | | | | | ${r.note} |`;
const off = rows.filter(r => r.gap !== null && Math.abs(r.gap) > 15);
fs.writeFileSync(path.join(__dirname, 'data/reference-check.md'),
  `# reference.json against Australian data\n\nSource: FSANZ AFCD Release 3. kcal per 100 g, raw unless noted. ${rows.length} rows, ${off.length} more than 15% off.\n\n| Row | App | AU | Gap | Protein app / AU | Fat app / AU | AU entry | Note |\n|---|---|---|---|---|---|---|---|\n${rows.map(line).join('\n')}\n`);
console.log(`${rows.length} rows, ${off.length} over 15%, ${off.filter(r => r.gap > 0).length} too high, ${off.filter(r => r.gap < 0).length} too low`);
rows.forEach(r => console.log(String(r.gap ?? 'n/a').padStart(5), r.name, r.kcal, r.au ? r.au.kcal : ''));

// --apply writes the Australian numbers into reference.json. Kept as they are: the owner's own label, and rows with no raw entry.
if (process.argv.includes('--apply')) {
  const keep = new Set(['Cocoa powder', 'Mussels', 'Beef brisket']);
  const out = ref.map(r => {
    const m = map[r.n], d = m && db[m[0]];
    return d && !keep.has(r.n) ? { ...r, v: [d.kcal, d.p, d.c, d.f], src: 'AFCD3 ' + m[0] } : { ...r, src: r.n === 'Cocoa powder' ? 'Owner\'s Cadbury label' : 'Unverified: no raw Australian entry' };
  });
  fs.writeFileSync(path.join(__dirname, '../../native/CheatDays/Resources/reference.json'), '[\n' + out.map(r => JSON.stringify(r)).join(',\n') + '\n]\n');
  console.log('applied');
}
