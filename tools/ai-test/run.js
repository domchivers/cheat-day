// Runs jobs on models, scores every answer, keeps every answer and its cost, and stops at the budget.
// node run.js --budget 2 --models haiku,sonnet,opus,gemini --jobs labels,quicklogs --limit 5 --split tune
// Keys come only from the environment: ANTHROPIC_API_KEY and GEMINI_API_KEY. They are never written anywhere.
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const { jobs, split, parse } = require('./jobs.js');

// $ per million tokens. Gemini's free tier costs nothing, and paid prices go in before the cost-per-user table.
const MODELS = {
  haiku: { provider: 'claude', id: 'claude-haiku-5-5', input: 0.10, output: 0.50 },
  'haiku-low': { provider: 'claude', id: 'claude-haiku-5-5', input: 0.10, output: 0.50, effort: 'low' },
  sonnet: { provider: 'claude', id: 'claude-sonnet-5-5', input: 2, output: 10 },
  opus: { provider: 'claude', id: 'claude-opus-5-5', input: 4, output: 20 },
  gemini: { provider: 'gemini', id: 'gemini-3.5-flash', input: 0, output: 0 },
  'gemini-lite': { provider: 'gemini', id: 'gemini-3.5-flash-lite', input: 0, output: 0 },
};
const costOf = (m, u) => (u.input * m.input + u.output * m.output) / 1e6;

function image(file) {
  const data = fs.readFileSync(path.join(__dirname, file)).toString('base64');
  return { data, mime: file.endsWith('.png') ? 'image/png' : 'image/jpeg' };
}

let anthropic;
async function askClaude(model, prompt, img, maxTokens) {
  if (!anthropic) { const Anthropic = require('@anthropic-ai/sdk').default; anthropic = new Anthropic({ baseURL: 'https://api.anthropic.com' }); }   // never a base URL inherited from this shell
  const content = [];
  if (img) content.push({ type: 'image', source: { type: 'base64', media_type: img.mime, data: img.data } });
  content.push({ type: 'text', text: prompt });
  const r = await anthropic.messages.create({ model: model.id, max_tokens: maxTokens, messages: [{ role: 'user', content }], ...(model.effort ? { output_config: { effort: model.effort } } : {}) });
  const text = r.content.filter(b => b.type === 'text').map(b => b.text).join('');
  return { text, stop: r.stop_reason, usage: { input: r.usage.input_tokens, output: r.usage.output_tokens } };
}
async function askGemini(model, prompt, img, maxTokens) {
  const key = process.env.GEMINI_API_KEY; if (!key) throw new Error('GEMINI_API_KEY is not set');
  const parts = []; if (img) parts.push({ inline_data: { mime_type: img.mime, data: img.data } }); parts.push({ text: prompt });
  // the free tier allows a few calls a minute. Thinking counts towards the token limit, so it gets room, at the app's own setting.
  await new Promise(done => setTimeout(done, 8000));
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model.id}:generateContent`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-goog-api-key': key }, body: JSON.stringify({ contents: [{ parts }], generationConfig: { maxOutputTokens: maxTokens * 4, temperature: 0.2, thinkingConfig: { thinkingLevel: 'low' } } }) });
  if (!r.ok) throw Object.assign(new Error('Gemini failed'), { status: r.status });
  const j = await r.json(), u = j.usageMetadata || {};
  return { text: (j.candidates?.[0]?.content?.parts || []).map(p => p.text || '').join(''), stop: j.candidates?.[0]?.finishReason, usage: { input: u.promptTokenCount || 0, output: (u.candidatesTokenCount || 0) + (u.thoughtsTokenCount || 0) } };
}

async function run(opts) {
  const dir = opts.dir || path.join(__dirname, 'results'); fs.mkdirSync(dir, { recursive: true });
  const answersFile = path.join(dir, 'answers.jsonl'), ledgerFile = path.join(dir, 'ledger.json');
  const ledger = fs.existsSync(ledgerFile) ? JSON.parse(fs.readFileSync(ledgerFile, 'utf8')) : { spent: 0, calls: 0 };
  const done = new Set(fs.existsSync(answersFile) ? fs.readFileSync(answersFile, 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l).key) : []);
  const ask = opts.ask || (m => (m.provider === 'claude' ? askClaude : askGemini));
  const models = { ...MODELS, ...(opts.extraModels || {}) };
  let failures = 0, stopped = null, ran = 0;
  outer: for (const job of opts.jobs) {
    const J = jobs[job], tasks = J.tasks().filter(t => !opts.split || split(t.id) === opts.split).slice(0, opts.limit || Infinity);
    for (const t of tasks) for (const name of opts.models) {
      const model = models[name], prompt = J.prompt(t);
      const key = crypto.createHash('sha1').update([job, t.id, name, prompt].join('|')).digest('hex').slice(0, 16);
      if (done.has(key)) continue;
      // the most this call could cost: stop before it rather than after
      const worst = costOf(model, { input: prompt.length / 2 + (J.image ? 3000 : 0), output: J.maxTokens });
      if (ledger.spent + worst > opts.budget) { stopped = `budget: $${ledger.spent.toFixed(4)} spent, the next call could reach $${(ledger.spent + worst).toFixed(4)}, limit $${opts.budget}`; break outer; }
      const img = J.image ? (opts.noImages ? null : image(J.image(t))) : null;
      let rec = { key, job, task: t.id, model: name, modelId: model.id, split: split(t.id), at: new Date().toISOString() };
      try {
        const a = await ask(model)(model, prompt, img, J.maxTokens);
        const cost = costOf(model, a.usage);
        ledger.spent = +(ledger.spent + cost).toFixed(6); ledger.calls++;
        rec = { ...rec, text: a.text, stop: a.stop, usage: a.usage, cost: +cost.toFixed(6) };
        try { const answer = J.text ? { text: a.text } : parse(a.text); rec.answer = answer; rec.score = J.score(t, answer); }
        catch (e) { rec.score = { pass: false, badAnswer: e.message }; }
        failures = 0; ran++;
        fs.appendFileSync(answersFile, JSON.stringify(rec) + '\n');
      } catch (e) {
        // not saved as done, so a later run tries it again; safe text only, in case an error quotes a request
        failures++;
        fs.appendFileSync(path.join(dir, 'errors.log'), `${rec.at} ${job} ${t.id} ${name} ${e.status || ''} ${String(e.name)}\n`);
        if (failures >= 3) { stopped = `three failures in a row, last on ${name}: ${e.status || e.name}`; break outer; }
      }
      fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
    }
  }
  fs.writeFileSync(ledgerFile, JSON.stringify(ledger, null, 1));
  return { ran, spent: ledger.spent, calls: ledger.calls, stopped };
}

function report(dir = path.join(__dirname, 'results'), rescore = false) {
  const rows = fs.readFileSync(path.join(dir, 'answers.jsonl'), 'utf8').trim().split('\n').map(l => JSON.parse(l));
  // scored afresh from the saved answers, so a corrected rule never costs a repeat call
  if (rescore) for (const r of rows) if (r.answer) { const t = jobs[r.job].tasks().find(x => x.id === r.task); if (t) r.score = jobs[r.job].score(t, r.answer); }
  const groups = {};
  for (const r of rows) { const k = `${r.job} | ${r.model} | ${r.split}`; (groups[k] ||= []).push(r); }
  return Object.entries(groups).sort().map(([k, g]) => {
    const scored = g.filter(r => r.score.pass !== null && r.score.scored !== false), passed = scored.filter(r => r.score.pass).length;
    const errs = g.map(r => r.score.error).filter(e => e != null).map(Math.abs).sort((a, b) => a - b);
    const gramErrs = g.map(r => r.score.gramsError).filter(e => e != null).map(Math.abs).sort((a, b) => a - b);
    const cost = g.reduce((s, r) => s + (r.cost || 0), 0);
    return { group: k, n: g.length, scored: scored.length, passed, passRate: scored.length ? Math.round(passed / scored.length * 100) : null, medianError: errs.length ? errs[errs.length >> 1] : null, medianGramsError: gramErrs.length ? gramErrs[gramErrs.length >> 1] : null, costEach: +(cost / g.length).toFixed(5), bad: g.filter(r => r.score.badAnswer).length };
  });
}

function repeatable() {
  const arg = n => { const i = process.argv.indexOf('--' + n); return i < 0 ? undefined : process.argv[i + 1]; };
  return { budget: +arg('budget'), models: (arg('models') || '').split(','), jobs: (arg('jobs') || Object.keys(jobs).join(',')).split(','), limit: +arg('limit') || 0, split: arg('split') };
}
if (require.main === module) {
  const o = repeatable();
  if (process.argv.includes('--rescore')) { console.table(report(undefined, true)); process.exit(0); }
  if (!(o.budget > 0) || !o.models[0]) { console.error('Usage: node run.js --budget 2 --models haiku,sonnet,opus,gemini [--jobs a,b] [--limit 5] [--split tune|final]'); process.exit(1); }
  run(o).then(r => { console.log(r); console.table(report()); });
}
module.exports = { run, report, MODELS, costOf };
