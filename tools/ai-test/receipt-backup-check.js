// The real 22 Nov history: the backup model's low card, then the follow-up. NOTE=1 marks that card as a backup's rough guess,
// as the app now does. VARIANT=name adds a trial rule.   node receipt-backup-check.js receipt.jpg [runs]
const fs = require('fs'), path = require('path');
let src = fs.readFileSync(path.join(__dirname, 'receipt-app-check.js'), 'utf8').replace(/\r/g, '').split('const controls =')[0];
src += `
(async () => {
  const note = process.env.NOTE ? ' [a backup model made that card and its sizes and calories can be far off: size and count every part afresh now, keeping only which dishes they are and the share they say]' : '';
  const card = 'Tofu skin skewers, grilled 100 g 160 kcal; Spicy lamb skewers, grilled 250 g 400 kcal; Spicy squid legs, grilled 120 g 210 kcal; Small lamb chops, grilled 120 g 241 kcal; Roasted tofu 120 g 192 kcal; Grilled Changsha stinky tofu 80 g 93 kcal; Grilled yam pasta 100 g 130 kcal; Bean curd and enoki mushroom rolls 100 g 130 kcal; Northwest saute spicy chicken noodles 750 g 850 kcal';
  const text = "Recent conversation:\\nThey: Everything we ordered\\nYou: Since it's a huge feast meant for sharing, let me know what share you had. [you worked out: Noodle & BBQ order, 2406 kcal: " + card + "]" + note
    + '\\nThey now say: "' + (process.env.SAY || 'Wanted the stinky tofu for myself everything else around half or what do you recommend?') + '" (about the photos from earlier)\\n';
  const img = { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: fs.readFileSync(process.argv[2]).toString('base64') } };
  await Promise.all(Array.from({ length: Number(process.argv[3] || 4) }, async (_, i) => {
    const b = await ask(img, text);
    console.log(['share ' + (i + 1) + ': ' + total(b) + ' kcal P' + total(b, 'protein_g'), '   parts: ' + b.estimate.parts.map(p => p.name + ' ' + Math.round(p.kcal)).join('; '), '   reply: ' + b.reply].join('\\n'));
  }));
})().catch(e => { console.error('FAILED', e.status, e.error?.error?.message || e.message); process.exit(1); });`;
new Function('require', '__dirname', 'process', 'console', src)(require, __dirname, process, console);
