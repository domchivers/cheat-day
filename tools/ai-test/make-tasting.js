// A side-by-side sheet with the model names hidden. The letters are shuffled per item; the key stays in results/.
// Usage: node make-tasting.js <output.html>
const fs = require('fs');
const { jobs, parse } = require('./jobs.js');
const rows = fs.readFileSync('results/answers.jsonl', 'utf8').trim().split('\n').map(l => JSON.parse(l));
const models = ['haiku', 'sonnet', 'opus'], key = {};
const hash = s => { let h = 11; for (const c of s) h = (h * 131 + c.charCodeAt(0)) % 1000003; return h; };
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/\*\*(.+?)\*\*/g, '<b>$1</b>').replace(/\n/g, '<br>');
const get = (job, task, m) => { const r = rows.find(x => x.job === job && x.task === task && x.model === m); if (!r) return null; if (r.answer) return r.answer; try { return parse(r.text); } catch { return null; } };
const order = id => { const a = [...models].sort((p, q) => hash(id + p) - hash(id + q)); key[id] = Object.fromEntries(a.map((m, i) => ['ABC'[i], m])); return a; };
const block = (id, title, body) => `<section data-id="${id}"><h2><span class="tag">${id}</span> ${esc(title)}</h2><div class="grid">${order(id).map((m, i) => `<article class="card" data-letter="${'ABC'[i]}"><button type="button" class="pick" id="${id}-${'ABC'[i]}" aria-pressed="false">Pick ${'ABC'[i]}</button>${body(m)}</article>`).join('')}</div></section>`;
const pick = (job, want) => want.map(id => jobs[job].tasks().find(t => t.id === id));
const recipe = t => m => { const a = get('recipes', t.id, m); if (!a) return 'No answer'; const list = a.ingredients || [], kcal = list.reduce((s, i) => s + (i.kcal || 0), 0), p = list.reduce((s, i) => s + (i.protein_g || 0), 0), n = a.portions || 1; return `<p class="m">${Math.round(kcal / n)} kcal, ${Math.round(p / n)} g protein a portion. Serves ${n}.</p><ul>${list.map(i => `<li>${esc(i.grams)} g ${esc(i.name)}</li>`).join('')}</ul>`; };
const plan = t => m => { const a = get('plans', t.id, m); if (!a) return 'No answer'; return `<p class="m">${Math.round((a.slots || []).reduce((s, x) => s + (x.kcal || 0), 0))} kcal planned</p><ul>${(a.slots || []).map(x => `<li><b>${esc(x.time)} ${esc(x.title)}</b><br>${esc(x.detail || '')} <span class="m">${esc(x.kcal)} kcal, ${esc(x.protein)} g protein</span></li>`).join('')}</ul>`; };
const chat = t => m => { const a = get('chats', t.id, m); return a ? `<p>${esc(a.text)}</p>` : 'No answer'; };
const R = pick('recipes', ['dish05', 'dish01', 'dish41', 'dish07', 'dish14', 'dish45']), P = pick('plans', ['plan01', 'plan05', 'plan09', 'plan17']), C = pick('chats', ['chat03', 'chat07', 'chat13', 'chat20']);
const total = R.length + P.length + C.length;
const html = `<title>Cheat Days Tasting</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>
/* A plain score sheet: one question at a time, three answers side by side, a running tally at the foot. */
:root { --bg: #f4f6f8; --card: #ffffff; --fg: #17202b; --muted: #5c6b7a; --line: #d5dce3; --accent: #1d5fa8; --on-accent: #ffffff; --tag: #8a5a12; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg: #0b0f15; --card: #141c27; --fg: #eaf0f6; --muted: #9dacbb; --line: #2b3745; --accent: #8cc2fa; --on-accent: #0c1622; --tag: #f5b963; color-scheme: dark } }
:root[data-theme="dark"] { --bg: #0b0f15; --card: #141c27; --fg: #eaf0f6; --muted: #9dacbb; --line: #2b3745; --accent: #8cc2fa; --on-accent: #0c1622; --tag: #f5b963; color-scheme: dark }
body { background: var(--bg); color: var(--fg); font: 16px/1.45 -apple-system, "Segoe UI", Roboto, Arial, sans-serif; padding-block: 20px 110px; padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)) }
main { max-width: 1100px; margin: 0 auto; display: grid; gap: 28px }
h1 { font-size: 28px; margin: 0 0 6px; text-wrap: balance } h2 { font-size: 18px; margin: 0 0 10px; text-wrap: balance } .tag { color: var(--tag); font-variant-numeric: tabular-nums; margin-right: 4px }
.intro { max-width: 65ch; margin: 0 } .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(270px, 1fr)); gap: 10px }
.card { background: var(--card); border: 1.5px solid var(--line); border-radius: 12px; padding: 12px; min-width: 0 } .card.on { border-color: var(--accent) }
.pick { display: block; width: 100%; font: inherit; font-weight: 700; padding: 10px; border-radius: 9px; border: 1.5px solid var(--accent); background: transparent; color: var(--accent); cursor: pointer; margin-bottom: 10px }
.pick[aria-pressed="true"] { background: var(--accent); color: var(--on-accent) } .pick:focus-visible, #copy:focus-visible { outline: 3px solid var(--tag); outline-offset: 2px }
ul { margin: 6px 0 0; padding-left: 18px } li { margin-bottom: 4px } .m { color: var(--muted); font-size: 14px; margin: 0 } p { margin: 0 0 8px; overflow-wrap: anywhere }
footer { position: fixed; left: 0; right: 0; bottom: 0; background: var(--card); border-top: 1px solid var(--line); padding: 10px max(16px, env(safe-area-inset-right, 0px)) calc(10px + env(safe-area-inset-bottom, 0px)) max(16px, env(safe-area-inset-left, 0px)); display: flex; gap: 10px; align-items: center }
#tally { flex: 1; min-width: 0; font-size: 14px; overflow-wrap: anywhere; user-select: all } #copy { font: inherit; font-weight: 700; padding: 10px 14px; border-radius: 9px; border: 0; background: var(--accent); color: var(--on-accent); cursor: pointer }
</style>
<main><header><h1>Which would you want?</h1><p class="intro">Tap your favourite for each one, then copy your picks and paste them into the chat. The letters are shuffled each time, so a letter isn't always the same AI. Recipes show ingredients only, so judge them as a dish you'd want to cook. Chat answers are on the same kind of question you might ask the app.</p></header>
${R.map((t, i) => block(`R${i + 1}`, t.name, recipe(t))).join('')}${P.map((t, i) => block(`P${i + 1}`, `"${t.say}" (${t.room} kcal available)`, plan(t))).join('')}${C.map((t, i) => block(`C${i + 1}`, t.text, chat(t))).join('')}</main>
<footer><div id="tally" aria-live="polite"></div><button type="button" id="copy">Copy picks</button></footer>
<script>
const picks = (() => { try { return JSON.parse(localStorage.getItem('picks') || '{}'); } catch { return {}; } })();
const tally = document.getElementById('tally'), copy = document.getElementById('copy');
const text = () => Object.keys(picks).map(k => k + ' ' + picks[k]).join(', ');
function draw() {
  document.querySelectorAll('section').forEach(s => s.querySelectorAll('.card').forEach(c => {
    const on = picks[s.dataset.id] === c.dataset.letter;
    c.classList.toggle('on', on); c.querySelector('.pick').setAttribute('aria-pressed', on);
  }));
  const n = Object.keys(picks).length;
  tally.textContent = n ? n + ' of ${total}: ' + text() : '0 of ${total} picked';
  try { localStorage.setItem('picks', JSON.stringify(picks)); } catch {}
}
document.querySelectorAll('section').forEach(s => s.addEventListener('click', e => {
  const b = e.target.closest('.pick'); if (!b) return;
  const l = b.closest('.card').dataset.letter, id = s.dataset.id;
  if (picks[id] === l) delete picks[id]; else picks[id] = l;
  draw();
}));
copy.addEventListener('click', () => {
  navigator.clipboard.writeText(text()).then(() => { copy.textContent = 'Copied'; setTimeout(() => { copy.textContent = 'Copy picks'; }, 1500); })
    .catch(() => { getSelection().selectAllChildren(tally); copy.textContent = 'Copy the text'; });
});
draw();
</script>`;
fs.writeFileSync(process.argv[2], html);
fs.writeFileSync('results/tasting-key.json', JSON.stringify(key, null, 1));
console.log(R.map(t => t.name).join(', '), html.length);
