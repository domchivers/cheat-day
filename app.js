/* Cheat Days — spend your cheat-day calories on purpose.
 * Everything lives in localStorage on this device. The only network calls are
 * barcode lookups (Open Food Facts) and label photos (Anthropic, only if you've
 * entered an API key in Settings). */
"use strict";

const APP_VERSION = "68";   // keep in step with ?v= in index.html and CACHE in sw.js
const STORE_KEY = "cheatday.v1";
const CLAUDE_MODEL = "claude-opus-5";
const RECENT_MAX = 15;
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

// ---------------------------------------------------------------- state

function localDate(d = new Date()) {
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}
function load() {
  const base = { budget: 1600, apiKey: "", geminiKey: "", day: { date: localDate(), items: [] }, history: [], recent: [], meals: [], presetUses: {}, mealDraft: null, shareDay: true, sharedMealIds: [], goals: { p: null, c: null, f: null }, chats: [], notes: "", weightKg: null, eatBack: false, recentWorkouts: [], exercises: {} };
  try { const raw = localStorage.getItem(STORE_KEY); if (raw) Object.assign(base, JSON.parse(raw)); } catch (e) {}
  if (!Array.isArray(base.recent)) base.recent = [];
  if (!Array.isArray(base.meals)) base.meals = [];
  if (!base.presetUses || typeof base.presetUses !== "object") base.presetUses = {};
  if (!Array.isArray(base.sharedMealIds)) base.sharedMealIds = [];
  if (base.shareDay == null) base.shareDay = true;
  if (!base.goals || typeof base.goals !== "object") base.goals = { p: null, c: null, f: null };
  if (!Array.isArray(base.chats)) base.chats = [];
  if (!Array.isArray(base.recentWorkouts)) base.recentWorkouts = [];
  if (!base.exercises || typeof base.exercises !== "object") base.exercises = {};
  if (!Array.isArray(base.day.workouts)) base.day.workouts = [];
  if (!Array.isArray(base.routines)) base.routines = [];
  if (!Array.isArray(base.body)) base.body = [];
  if (!base.weekGoals || typeof base.weekGoals !== "object") base.weekGoals = { under: 5, protein: 4, workouts: 3, log: 7 };
  if (!Array.isArray(base.seenBadges)) base.seenBadges = [];
  if (!Array.isArray(base.goalWins)) base.goalWins = [];
  if (typeof base.postCount !== "number") base.postCount = 0;
  if (base.session && typeof base.session !== "object") base.session = null;
  return base;
}
function save(sync = true) {
  if (sync) state.updatedAt = Date.now();
  try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch (e) { toast("Couldn't save (storage blocked?)"); }
  if (sync) schedulePush();
}
const state = load();
const usedKcal = () => state.day.items.reduce((s, it) => s + it.kcal, 0);
const burnedKcal = () => (state.day.workouts || []).reduce((s, w) => s + (w.kcal || 0), 0);
const budgetToday = () => state.budget + (state.eatBack ? burnedKcal() : 0);   // the day's allowance, stretched by workouts only if asked

// ---------------------------------------------------------------- helpers

/** An in-app dialog in place of the browser's confirm() and prompt(). Resolves true/false, or the text (null on cancel). */
function ask(text, opts = {}) {
  return new Promise((resolve) => {
    const wrap = $("#ask-dialog"), input = $("#dlg-input");
    const title = opts.title || (String(text).split("\n")[0].length <= 60 && String(text).includes("\n") ? "" : "");
    $("#dlg-text").textContent = String(text);
    $("#dlg-ok").textContent = opts.ok || "OK";
    $("#dlg-cancel").textContent = opts.cancel || "Cancel";
    $("#dlg-ok").classList.toggle("danger", /^(delete|remove|discard|decline|dismiss)/i.test(String(text)));
    const chips = $("#dlg-choices"); chips.innerHTML = ""; chips.classList.toggle("hidden", !opts.choices);
    $("#dlg-ok").classList.toggle("hidden", !!opts.choices);
    input.classList.toggle("hidden", !opts.input);
    if (opts.input) { input.value = opts.value == null ? "" : String(opts.value); input.type = "text"; input.inputMode = opts.number ? "numeric" : "text"; input.pattern = opts.number ? "[0-9]*" : ""; }
    wrap.classList.remove("hidden");
    const done = (v) => { wrap.classList.add("hidden"); $("#dlg-ok").onclick = $("#dlg-cancel").onclick = null; input.onkeydown = null; resolve(v); };
    if (opts.choices) for (const ch of opts.choices) { const b = document.createElement("button"); b.textContent = ch.label; b.classList.toggle("on", ch.value === opts.value); b.onclick = () => done(ch.value); chips.appendChild(b); }
    $("#dlg-ok").onclick = () => done(opts.input ? input.value : true);
    $("#dlg-cancel").onclick = () => done(opts.input ? null : false);
    wrap.onclick = (e) => { if (e.target === wrap) done(opts.input ? null : false); };
    // Focus right away, inside the tap that opened the dialog, so the phone's keyboard comes up with it
    if (opts.input) { input.focus(); input.onkeydown = (e) => { if (e.key === "Enter") done(input.value); }; }
    else if (!opts.choices) setTimeout(() => $("#dlg-ok").focus(), 60);
  });
}
const askText = (text, value) => ask(text, { input: true, value, ok: "Save" });
/** Pick a number from chips: no keyboard, one tap. Resolves the number, or null on cancel. */
const askNumber = (text, value, min, max, offLabel) => ask(text, { value, choices: Array.from({ length: max - min + 1 }, (_, i) => ({ value: min + i, label: min + i === 0 && offLabel ? offLabel : String(min + i) })) });
function toast(msg, ms = 2800) {
  const t = $("#toast");
  t.textContent = msg; t.classList.remove("hidden");
  clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.add("hidden"), ms);
}
function busy(text) {
  const b = $("#busy");
  if (text === false) { b.classList.add("hidden"); return; }
  $("#busy-text").textContent = text; b.classList.remove("hidden");
}
const fmt = (n, dp = 0) => (n == null || !isFinite(n)) ? "–" : Number(n.toFixed(dp)).toLocaleString();
const fmt1 = (n) => (n == null || !isFinite(n)) ? "–" : String(Math.abs(n) >= 10 ? Math.round(n) : Math.round(n * 10) / 10);
const num = (v) => { const n = parseFloat(v); return isFinite(n) && n > 0 ? n : null; };
const nz = (v) => { const n = parseFloat(v); return isFinite(n) && n >= 0 ? n : null; };   // like num, but 0 counts
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
const plural = (n, word) => `${word}${n >= 1.95 ? "s" : ""}`;

/** Target kcal → grams / servings / pieces for an item. */
function amountsFor(item, kcal) {
  const out = { kcal, unit: item.unit || "g" };
  let kcalPer100 = item.kcalPer100;
  if (!kcalPer100 && item.kcalPerServing && item.servingSize) kcalPer100 = item.kcalPerServing / item.servingSize * 100;
  if (kcalPer100) out.grams = kcal / kcalPer100 * 100;
  if (item.kcalPerServing) out.servings = kcal / item.kcalPerServing;
  else if (item.servingSize && out.grams != null) out.servings = out.grams / item.servingSize;
  if (item.packSize && out.grams != null) {
    out.packFraction = out.grams / item.packSize;
    if (item.piecesPerPack) out.pieces = out.packFraction * item.piecesPerPack;
  }
  return out;
}
/** Protein / carbs / fat for this amount of the item, or nulls when the item doesn't carry them. */
function macrosFor(item, kcal) {
  const a = amountsFor(item, kcal);
  const g = a.grams, sv = a.servings;
  if (g != null && item.p100 != null) return { p: g * item.p100 / 100, c: g * (item.c100 || 0) / 100, f: g * (item.f100 || 0) / 100 };
  if (sv != null && item.pServ != null) return { p: sv * item.pServ, c: sv * (item.cServ || 0), f: sv * (item.fServ || 0) };
  return { p: null, c: null, f: null };
}
function macroText(m, long = false) {
  if (!m || m.p == null) return "";
  const r = (n) => Math.round(n);
  return long ? `Protein <b>${r(m.p)} g</b> · Carbs <b>${r(m.c)} g</b> · Fat <b>${r(m.f)} g</b>` : `P ${r(m.p)} · C ${r(m.c)} · F ${r(m.f)}`;
}
function sumMacros(items) {
  const t = { p: 0, c: 0, f: 0 }; let missing = 0;
  for (const it of items) { const m = macrosFor(it, it.kcal || 0); if (m.p == null) missing++; else { t.p += m.p; t.c += m.c; t.f += m.f; } }
  return { ...t, missing };
}
function shortAmounts(item) {
  const a = amountsFor(item, item.kcal), parts = [];
  if (item.unitLabel && a.servings != null) parts.push(`${fmt1(a.servings)} ${plural(a.servings, item.unitLabel)}`);
  else {
    if (a.grams != null) parts.push(`${fmt1(a.grams)} ${a.unit}`);
    if (a.pieces != null) parts.push(`${fmt1(a.pieces)} pcs`);
    else if (a.servings != null) parts.push(`${fmt1(a.servings)} serv`);
  }
  parts.push(item.shareLabel);
  const mt = macroText(macrosFor(item, item.kcal));
  if (mt) parts.push(mt);
  return parts.join(" · ");
}
const BASIS_KEYS = ["name", "brand", "source", "unit", "unitLabel", "kcalPer100", "servingSize", "kcalPerServing", "packSize", "piecesPerPack", "image", "photo", "mealId", "p100", "c100", "f100", "pServ", "cServ", "fServ"];
function basisOf(obj) {
  const b = {};
  for (const k of BASIS_KEYS) if (obj[k] != null && obj[k] !== "") b[k] = obj[k];
  if (b.image && String(b.image).startsWith("data:")) delete b.image;   // never store photos
  return b;
}

// ---------------------------------------------------------------- router

const VIEWS = ["home", "budget", "settings", "history", "friends", "feed", "compose", "workouts", "exercise", "goals", "body", "ask", "chats", "scan", "search", "meals", "meal", "details", "share"];
let stack = ["home"];
function show(view) {
  for (const v of VIEWS) $(`#view-${v}`).classList.toggle("hidden", v !== view);
  document.body.dataset.view = view;
  window.scrollTo(0, 0);
  if (view !== "scan") stopCamera();
  if (view === "home") renderHome();
  if (view === "settings") renderSettings();
  if (view === "budget") { $("#b-budget").value = state.budget; $$("#budget-chips button").forEach((b) => b.classList.toggle("on", +b.dataset.b === state.budget)); const g = state.goals || {}; $("#b-p").value = g.p ?? ""; $("#b-c").value = g.c ?? ""; $("#b-f").value = g.f ?? ""; $("#b-notes").value = state.notes || ""; $("#b-weight").value = state.weightKg || ""; }
  if (view === "scan") startCamera();
  if (view === "search") openSearch();
  if (view === "meals") renderMeals();
  if (view === "friends") renderFriends();
  if (view === "history") renderHistory();
  if (view === "ask") renderAsk();
  if (view === "workouts") renderWorkouts();
  if (view === "exercise") renderExercise();
  if (view === "goals") renderGoals();
  if (view === "body") renderBody();
  if (view === "feed") renderFeed();
  if (view === "compose") renderCompose();
  $$("#tabbar button").forEach((b) => b.classList.toggle("on", b.dataset.tab === view));
  if (view === "chats") renderChats();
  if (view === "meal") renderMeal();
}
function go(view) { stack.push(view); show(view); }
$$("#tabbar button").forEach((b) => b.onclick = () => { const v = b.dataset.tab; if (stack[stack.length - 1] === "share") editId = null; stack = v === "home" ? ["home"] : ["home", v]; show(v); });
function back() { if (stack[stack.length - 1] === "share") editId = null; stack.pop(); if (!stack.length) stack = ["home"]; show(stack[stack.length - 1]); }
function home() { pick = null; editId = null; stack = ["home"]; show("home"); }

document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-go]"); if (b) { const v = b.dataset.go; v === "manual" ? openManual() : go(v); return; }
  if (e.target.closest("[data-back]")) back();
});

// ---------------------------------------------------------------- home

/** A new calendar day: file today under History and start clean. Runs on open, on return, and on every home render. */
function archiveDay() {
  if (!state.day.items.length && !(state.day.workouts || []).length) return;
  const m = sumMacros(state.day.items);
  state.history.unshift({ date: state.day.date, budget: budgetToday(), kcal: usedKcal(), items: state.day.items.map((it) => ({ ...basisOf(it), kcal: it.kcal, shareLabel: it.shareLabel })),
    p: Math.round(m.p), c: Math.round(m.c), f: Math.round(m.f), burned: burnedKcal(), workouts: (state.day.workouts || []).map((w) => ({ name: w.name, minutes: w.minutes, kcal: w.kcal, lifts: w.lifts || [] })) });
  state.history = state.history.slice(0, 120);
  state.history.slice(14).forEach((h) => { if (Array.isArray(h.items)) h.items.forEach((it) => { delete it.photo; }); });
}
function rollDay() {
  if (state.day.date === localDate()) return false;
  archiveDay();
  state.day = { date: localDate(), items: [], workouts: [] };
  save();
  return true;
}
function renderHome() {
  rollDay();
  const used = usedKcal(), budget = budgetToday(), left = budget - used, burned = burnedKcal();
  $("#home-used").textContent = fmt(used);
  $("#home-budget").textContent = state.eatBack && burned ? `${fmt(state.budget)} + ${fmt(burned)}` : fmt(state.budget);
  const bar = $("#home-bar");
  bar.style.width = `${Math.min(100, budget > 0 ? used / budget * 100 : 0)}%`;
  bar.classList.toggle("over", left < 0);
  const hb = $("#home-burned");
  hb.classList.toggle("hidden", !burned);
  hb.textContent = burned ? `Burned ${fmt(burned)} kcal in ${(state.day.workouts || []).length} workout${state.day.workouts.length === 1 ? "" : "s"}${state.eatBack ? ", added to your budget" : ""}` : "";
  if ($("#workouts-sub")) $("#workouts-sub").textContent = burned ? `${(state.day.workouts || []).map((w) => w.name).join(", ")} · ${fmt(burned)} kcal` : "Log a walk, a run or a gym session and see what it burned";
  const mac = sumMacros(state.day.items);
  const g = state.goals || {};
  const tile = (label, v, goal) => `<span class="tile"><b>${Math.round(v)} g</b><small>${label}</small>${goal ? `<span class="goal">of ${goal} g</span><span class="bar"><span style="width:${Math.min(100, v / goal * 100)}%" class="${v > goal * 1.1 ? "over" : ""}"></span></span>` : ""}</span>`;
  const anyGoal = g.p || g.c || g.f;
  $("#home-macros").innerHTML = (state.day.items.length || anyGoal)
    ? tile("Protein", mac.p, g.p) + tile("Carbs", mac.c, g.c) + tile("Fat", mac.f, g.f) + (mac.missing ? `<span class="note">${mac.missing} item${mac.missing === 1 ? " has" : "s have"} no macros (added before macros existed, or none on the pack).</span>` : "")
    : "";

  const list = $("#home-list"); list.innerHTML = "";
  for (const it of state.day.items) list.appendChild(itemRow(it));
  $("#home-empty").classList.toggle("hidden", state.day.items.length > 0);
  // Nothing yet today: show yesterday as a reminder of where you left off
  const y = !state.day.items.length && state.history.find((h) => h.date === dateMinus(1));
  const yc = $("#home-yesterday");
  if (y) {
    const items = Array.isArray(y.items) ? y.items : [];
    yc.innerHTML = `<div class="top"><b>Yesterday</b><span class="kcal ${y.kcal > y.budget ? "over" : "ok"}">${fmt(y.kcal)} / ${fmt(y.budget)} kcal</span></div>
      <span class="bar"><span style="width:${y.budget ? Math.min(100, y.kcal / y.budget * 100) : 0}%" class="${y.kcal > y.budget ? "over" : ""}"></span></span>
      <div class="muted tiny" style="margin-top:6px">${items.length ? esc(items.map((it) => it.name).slice(0, 4).join(", ")) + (items.length > 4 ? ` and ${items.length - 4} more` : "") : ""} · <u>see history</u></div>`;
    yc.classList.remove("hidden");
  } else { yc.classList.add("hidden"); yc.innerHTML = ""; }
  renderQuick();
  refreshInbox(false);
  renderLevelCard();
}
function iconFor(source) {
  return { barcode: "barcode", label: "camera", quick: "plus", search: "search", claude: "search", meal: "meal" }[source] || "pen";
}
function itemRow(it) {
  const li = document.createElement("li");
  const pic = it.photo || it.image;
  const thumb = pic ? `<img class="thumb-sm" src="${esc(pic)}" alt="">` : `<span class="thumb-sm"><svg><use href="#i-${iconFor(it.source)}"/></svg></span>`;
  li.innerHTML = `${thumb}
    <div class="body"><div class="name">${esc(it.name || "Unnamed")}</div><div class="detail">${esc(shortAmounts(it))}</div></div>
    <div class="kcal">${fmt(it.kcal)}</div>
    <button class="del" aria-label="Remove">✕</button>`;
  li.querySelector(".del").onclick = async (e) => { e.stopPropagation(); if (!await ask(`Remove "${it.name}" from today?`)) return; state.day.items = state.day.items.filter((x) => x.id !== it.id); save(); renderHome(); };
  li.querySelector(".body").onclick = () => { editId = it.id; draft = { ...basisOf(it), note: "" }; openShare(it.kcal); };
  li.style.cursor = "pointer";
  return li;
}

// --- quick add: presets from presets.js, saved meals, and everything you've added before; most-used first
const LS_QUICK_OPEN = "cheatday.quickOpen";
function quickEntries() {
  const presets = (typeof PRESETS !== "undefined" ? PRESETS : []).map((p) => ({
    key: "preset:" + p.name, preset: true, uses: state.presetUses[p.name] || 0, lastUsed: "",
    basis: { name: p.name, source: "quick", unit: "ml", unitLabel: p.unit || "serving", kcalPerServing: Math.round(p.kcal), pServ: nz(p.protein), cServ: nz(p.carbs), fServ: nz(p.fat) },
    detail: p.detail || "", lastKcal: Math.round(p.kcal), lastShareLabel: `${fmt(Math.round(p.kcal) / state.budget * 100, 1)}% of the day`
  }));
  const meals = state.meals.map((m) => {
    const b = mealBasis(m), kcal = Math.round(b.kcalPerServing || 0);
    return { key: "meal:" + m.id, meal: true, uses: m.uses || 0, lastUsed: m.lastUsed || "", basis: b,
      detail: `1 portion of ${m.portions || 1} · ${fmt(kcal)} kcal`, lastKcal: kcal, lastShareLabel: `${fmt(kcal / state.budget * 100, 1)}% of the day` };
  });
  return presets.concat(meals, state.recent.map((r) => ({ ...r, uses: r.uses || 0 })))
    .sort((a, b) => (b.uses - a.uses) || String(b.lastUsed || "").localeCompare(String(a.lastUsed || "")));
}
function renderQuick() {
  const list = $("#quick-list"); list.innerHTML = "";
  const entries = quickEntries();
  let open = false; try { open = localStorage.getItem(LS_QUICK_OPEN) === "1"; } catch (e) {}
  $("#quick-toggle").classList.toggle("open", open);
  list.classList.toggle("hidden", !open);
  $("#quick-hint").classList.toggle("hidden", !open || entries.length === 0);
  $("#quick-sub").textContent = entries.length ? `${entries.length} thing${entries.length === 1 ? "" : "s"} you have often` : "Things you add come back here";
  for (const q of entries) {
    const li = document.createElement("li");
    const b = q.basis;
    const detail = q.detail || shortAmounts({ ...b, kcal: q.lastKcal, shareLabel: q.lastShareLabel });
    const qp = b.photo || b.image;
    const thumb = qp ? `<img class="thumb-sm" src="${esc(qp)}" alt="">` : `<span class="thumb-sm ${q.meal ? "tone-peach" : ""}"><svg><use href="#i-${iconFor(b.source)}"/></svg></span>`;
    li.innerHTML = `${thumb}
      <div class="body"><div class="name">${esc(b.name)}</div><div class="detail">${esc(detail)}</div></div>
      <div class="kcal">${fmt(q.lastKcal)}</div><button class="add" aria-label="Add"><svg><use href="#i-plus"/></svg></button>`;
    li.querySelector(".add").onclick = (e) => { e.stopPropagation(); addToDay(b, q.lastKcal, q.lastShareLabel); toast(`Added ${b.name} · ${fmt(q.lastKcal)} kcal`); };
    li.querySelector(".body").onclick = () => { draft = { ...b, note: "" }; openShare(q.lastKcal); };
    if (!q.preset && !q.meal) longPress(li, async () => {
      if (await ask(`Remove "${b.name}" from Quick add?`)) { state.recent = state.recent.filter((r) => r.key !== q.key); save(); renderQuick(); }
    });
    list.appendChild(li);
  }
}
$("#quick-toggle").onclick = () => {
  const open = $("#quick-list").classList.contains("hidden");
  try { localStorage.setItem(LS_QUICK_OPEN, open ? "1" : "0"); } catch (e) {}
  renderQuick();
};
function longPress(el, fn) {
  let t = null;
  const start = () => { t = setTimeout(() => { t = null; fn(); }, 650); };
  const cancel = () => { if (t) clearTimeout(t); t = null; };
  el.addEventListener("pointerdown", start);
  for (const ev of ["pointerup", "pointerleave", "pointercancel", "pointermove"]) el.addEventListener(ev, cancel);
  el.addEventListener("contextmenu", (e) => e.preventDefault());
}
function rememberRecent(basis, kcal, shareLabel) {
  const key = (basis.name + "|" + (basis.brand || "")).toLowerCase();
  const old = state.recent.find((r) => r.key === key);
  state.recent = state.recent.filter((r) => r.key !== key);
  state.recent.unshift({ key, basis, lastKcal: kcal, lastShareLabel: shareLabel, lastUsed: new Date().toISOString(), uses: ((old && old.uses) || 0) + 1 });
  state.recent = state.recent.slice(0, RECENT_MAX);
}
function addToDay(basis, kcal, shareLabel) {
  kcal = Math.round(kcal);
  state.day.items.push({ id: uid(), ...basisOf(basis), kcal, shareLabel, addedAt: new Date().toISOString() });
  if (basis.source === "quick") state.presetUses[basis.name] = (state.presetUses[basis.name] || 0) + 1;
  else if (basis.source === "meal") { const m = state.meals.find((x) => x.id === basis.mealId); if (m) { m.uses = (m.uses || 0) + 1; m.lastUsed = new Date().toISOString(); } }
  else rememberRecent(basisOf(basis), kcal, shareLabel);
  save(); renderHome();
}

// ---------------------------------------------------------------- meals: a cake or a curry as one thing

let mealDraft = null;   // the meal on the editor screen
let pick = null;        // set while choosing an ingredient: { replaceId } (null: adding to the day as usual)
let editId = null;      // set while changing something already on today's list
let openRow = null;

function mealTotals(meal) {
  let kcal = 0, grams = 0, allWeighed = true;
  for (const it of meal.items || []) {
    kcal += it.kcal || 0;
    const g = it.grams != null ? it.grams : amountsFor(it, it.kcal || 0).grams;
    if (g != null) grams += g; else allWeighed = false;
  }
  const m = sumMacros(meal.items || []);
  return { kcal, grams, allWeighed, p: m.p, c: m.c, f: m.f, macroMissing: m.missing };
}
function mealBasis(meal) {
  const t = mealTotals(meal), portions = num(meal.portions) || 1;
  return {
    name: meal.name || "Meal", source: "meal", mealId: meal.id, unit: "g", photo: meal.photo || null,
    kcalPer100: t.grams ? t.kcal / t.grams * 100 : null,
    servingSize: t.grams ? t.grams / portions : null,
    kcalPerServing: t.kcal / portions, unitLabel: "portion",
    p100: t.grams ? t.p / t.grams * 100 : null, c100: t.grams ? t.c / t.grams * 100 : null, f100: t.grams ? t.f / t.grams * 100 : null,
    pServ: t.p / portions, cServ: t.c / portions, fServ: t.f / portions
  };
}
function newMeal() { return { id: uid(), name: "", portions: 4, items: [], saved: false }; }
function mealChanged() { state.mealDraft = mealDraft; save(false); renderMeal(); }

function renderMeals() {
  const list = $("#meals-list"); list.innerHTML = "";
  if (state.mealDraft && !state.mealDraft.saved && (state.mealDraft.items.length || state.mealDraft.name)) {
    const li = document.createElement("li");
    li.className = "warn";
    li.innerHTML = `<span class="thumb-sm tone-peach"><svg><use href="#i-meal"/></svg></span><div class="body"><div class="name">${esc(state.mealDraft.name || "Unsaved meal")}</div><div class="detail">Not saved yet · tap to carry on</div></div><button class="del" aria-label="Discard">✕</button>`;
    li.querySelector(".body").onclick = () => { mealDraft = state.mealDraft; go("meal"); };
    li.querySelector(".del").onclick = async (e) => { e.stopPropagation(); if (await ask(`Discard the unsaved "${state.mealDraft.name || "meal"}"?`)) { state.mealDraft = null; mealDraft = null; save(false); renderMeals(); } };
    list.appendChild(li);
  }
  for (const m of state.meals) {
    const t = mealTotals(m), portions = num(m.portions) || 1;
    const li = document.createElement("li");
    li.innerHTML = `${m.photo ? `<img class="thumb-sm" src="${esc(m.photo)}" alt="">` : `<span class="thumb-sm tone-peach"><svg><use href="#i-meal"/></svg></span>`}
      <div class="body"><div class="name">${esc(m.name)}</div><div class="detail">${portions} portion${portions === 1 ? "" : "s"} · ${fmt(t.kcal / portions)} kcal each · ${m.items.length} ingredient${m.items.length === 1 ? "" : "s"}</div></div>
      <button class="add" aria-label="Add a portion to today"><svg><use href="#i-plus"/></svg></button>
      <button class="del" aria-label="Delete meal">✕</button>`;
    li.querySelector(".add").onclick = (e) => { e.stopPropagation(); draft = { ...mealBasis(m), note: "" }; openShare(); };
    li.querySelector(".del").onclick = (e) => { e.stopPropagation(); deleteMeal(m); };
    li.querySelector(".body").onclick = () => { mealDraft = JSON.parse(JSON.stringify(m)); mealDraft.saved = true; go("meal"); };
    list.appendChild(li);
  }
  $("#meals-intro").classList.toggle("hidden", state.meals.length > 0);
}
$("#meals-new").onclick = () => { mealDraft = newMeal(); state.mealDraft = mealDraft; save(false); go("meal"); };

function showMealPhoto() {
  const m = mealDraft, img = $("#m-photo"), has = !!(m && m.photo);
  img.classList.toggle("hidden", !has); if (has) img.src = m.photo;
  $("#m-photo-remove").classList.toggle("hidden", !has);
  $("#m-photo-cam").textContent = has ? "📷 Retake" : "📷 Photo";
}
async function attachMealPhoto(file) { try { mealDraft.photo = await thumbFrom(file); state.mealDraft = mealDraft; save(false); showMealPhoto(); } catch (e) { toast("Couldn't read that photo"); } }
$("#m-photo-cam").onclick = () => $("#file-meal-cam").click();
$("#m-photo-lib").onclick = () => $("#file-meal-lib").click();
$("#file-meal-cam").addEventListener("change", (e) => { const f = e.target.files[0]; e.target.value = ""; if (f) attachMealPhoto(f); });
$("#file-meal-lib").addEventListener("change", (e) => { const f = e.target.files[0]; e.target.value = ""; if (f) attachMealPhoto(f); });
$("#m-photo-remove").onclick = () => { delete mealDraft.photo; state.mealDraft = mealDraft; save(false); showMealPhoto(); };
function renderMeal() {
  if (!mealDraft) mealDraft = state.mealDraft || newMeal();
  const m = mealDraft;
  showMealPhoto();
  if (document.activeElement !== $("#m-q")) { $("#m-q").value = ""; $("#m-results").innerHTML = ""; $("#m-noresult").classList.add("hidden"); }
  if (!renderMeal.lastId || renderMeal.lastId !== m.id) $("#m-lighter-out").innerHTML = "";
  renderMeal.lastId = m.id;
  $("#meal-title").textContent = m.saved ? "Edit meal" : "New meal";
  $("#meal-delete").classList.toggle("hidden", !m.saved);
  if (document.activeElement !== $("#m-name")) $("#m-name").value = m.name || "";
  if (document.activeElement !== $("#m-portions")) $("#m-portions").value = m.portions || "";
  const list = $("#m-items"); list.innerHTML = "";
  for (const it of m.items) {
    const li = document.createElement("li");
    li.className = "ingredient" + (it.unresolved ? " warn" : "");
    const g = it.grams != null ? it.grams : amountsFor(it, it.kcal || 0).grams;
    const bits = [];
    if (g != null) bits.push(`${fmt1(g)} ${it.unit || "g"}`);
    if (it.fromText) bits.push(`from "${it.fromText}"`);
    if (it.unresolved) bits.push("tap to pick what this is");
    if (it.brand) bits.unshift(it.brand);
    const thumb = it.image ? `<img class="thumb-sm" src="${esc(it.image)}" alt="">` : `<span class="thumb-sm"><svg><use href="#i-${iconFor(it.source)}"/></svg></span>`;
    li.innerHTML = `${thumb}<div class="body"><div class="name">${esc(it.name)}</div><div class="detail">${esc(bits.join(" · "))}</div></div><div class="kcal">${fmt(it.kcal || 0)}</div>`;
    if (openRow === it.id) {
      const actions = document.createElement("div");
      actions.className = "row-actions";
      actions.innerHTML = `<button data-act="amount" ${it.unresolved ? "disabled" : ""}>Amount</button><button data-act="swap">${it.unresolved ? "Pick it" : "Swap product"}</button><button data-act="remove" class="danger">Remove</button>`;
      li.appendChild(actions);
    }
    li.onclick = async (e) => {
      const act = e.target.closest("[data-act]");
      if (act) {
        e.stopPropagation();
        if (act.dataset.act === "remove") { if (!await ask(`Remove "${it.name}" from this meal?`)) return; m.items = m.items.filter((x) => x.id !== it.id); openRow = null; mealChanged(); }
        if (act.dataset.act === "amount") { pick = { replaceId: it.id }; draft = { ...basisOf(it), note: "" }; openShare(it.kcal); }
        if (act.dataset.act === "swap") { pick = { replaceId: it.id, prefill: it.fromText || it.name }; go("search"); }
        return;
      }
      openRow = openRow === it.id ? null : it.id; renderMeal();
    };
    list.appendChild(li);
  }
  $("#m-empty").classList.toggle("hidden", m.items.length > 0);
  if (document.activeElement !== $("#m-steps")) $("#m-steps").value = (Array.isArray(m.steps) ? m.steps : []).join("\n");
  const t = mealTotals(m), portions = num(m.portions) || 1;
  $("#m-total-kcal").textContent = fmt(t.kcal);
  $("#m-total-sub").textContent = t.grams ? `about ${fmt(t.grams)} g` : "";
  $("#m-per-portion").innerHTML = m.items.length ? `<div>each of <b>${portions}</b> portion${portions === 1 ? "" : "s"}: <b>${fmt(t.kcal / portions)}</b> kcal${t.grams ? ` (${fmt(t.grams / portions)} g)` : ""}</div>` : "";
  $("#m-macros").innerHTML = m.items.length ? `Per portion: ${macroText({ p: t.p / portions, c: t.c / portions, f: t.f / portions }, true)}${t.macroMissing ? ` <span class="tiny">(${t.macroMissing} ingredient${t.macroMissing === 1 ? "" : "s"} without macros)</span>` : ""}` : "";
  $("#m-use").classList.toggle("hidden", !m.saved);
  $("#m-share").classList.toggle("hidden", !m.saved);
  $("#m-post").classList.toggle("hidden", !(m.saved && window.cloud && window.cloud.user));
  $("#m-lighter").classList.toggle("hidden", !m.items.length);
  $("#m-ask-row").classList.toggle("hidden", !m.items.length);
  const canFriends = m.saved && window.cloud && window.cloud.user;
  $("#m-share-friends").classList.toggle("hidden", !canFriends);
  $("#m-share-friends").textContent = state.sharedMealIds.includes(m.id) ? "Stop sharing with friends" : "Share with friends";
  $("#m-save").textContent = m.saved ? "Save changes" : "Save meal";
}
$("#m-name").addEventListener("input", (e) => { mealDraft.name = e.target.value; state.mealDraft = mealDraft; save(false); });
$("#m-portions").addEventListener("input", (e) => { mealDraft.portions = num(e.target.value) || mealDraft.portions; state.mealDraft = mealDraft; save(false); renderMeal(); });
const stepsFromBox = () => $("#m-steps").value.split(/\n+/).map((l) => l.replace(/^\s*(?:\d+[.)]|[-*])\s*/, "").trim()).filter(Boolean);
$("#m-steps").addEventListener("input", () => { mealDraft.steps = stepsFromBox(); state.mealDraft = mealDraft; save(false); });
$("#m-add-scan").onclick = () => { pick = { replaceId: null }; go("scan"); };
$("#m-type").onclick = () => { pick = { replaceId: null }; openManual(); };
// Ingredient search right on the editor: type, tap a result, say how much, and you're back here.
$("#m-q").addEventListener("input", (e) => {
  const query = e.target.value.trim(), list = $("#m-results"); list.innerHTML = "";
  const rows = query ? searchLocal(query).slice(0, 8) : [];
  $("#m-noresult").classList.toggle("hidden", !(query.length >= 2 && rows.length === 0));
  for (const row of rows) {
    const item = foodItem(row), li = resultRow(item, "tone-coral");
    li.onclick = () => { pick = { replaceId: null }; draft = { ...item }; openShare(); };
    list.appendChild(li);
  }
});
$("#m-q").addEventListener("keydown", (e) => { if (e.key === "Enter") e.target.blur(); });
$("#m-paste-toggle").onclick = () => { $("#m-paste-wrap").classList.toggle("hidden"); $("#m-paste").focus(); };
$("#m-paste-go").onclick = () => {
  const lines = $("#m-paste").value.split(/\n+/).map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return;
  let matched = 0;
  for (const line of lines) { const it = ingredientFromText(line); if (!it.unresolved) matched++; mealDraft.items.push(it); }
  $("#m-paste").value = ""; $("#m-paste-wrap").classList.add("hidden");
  mealChanged();
  toast(matched === lines.length ? `Matched all ${lines.length}. Tap any to swap for a brand.` : `Matched ${matched} of ${lines.length}. Tap the highlighted ones to pick what they are.`, 5000);
};
$("#m-save").onclick = () => {
  const m = mealDraft;
  m.name = $("#m-name").value.trim();
  if (!m.name) { toast("Give the meal a name first"); $("#m-name").focus(); return; }
  if (!m.items.length) { toast("Add at least one ingredient"); return; }
  if (m.items.some((it) => it.unresolved)) { toast("Pick what the highlighted ingredients are first"); return; }
  m.portions = num($("#m-portions").value) || 1;
  m.steps = stepsFromBox();
  m.saved = true; m.updatedAt = new Date().toISOString();
  const i = state.meals.findIndex((x) => x.id === m.id);
  if (i >= 0) state.meals[i] = m; else state.meals.unshift(m);
  state.mealDraft = null;
  save(); toast(`Saved ${m.name}`); renderMeal();
};
// Share a meal as a link: the whole recipe travels inside the address, no server needed.
const b64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64url = (str) => Uint8Array.from(atob(str.replace(/-/g, "+").replace(/_/g, "/")), (ch) => ch.charCodeAt(0));
async function encodeMeal(m) {
  const items = m.items.map((it) => ({ ...basisOf(it), kcal: it.kcal, grams: it.grams }));
  const bytes = new TextEncoder().encode(JSON.stringify({ v: 1, name: m.name, portions: m.portions, items, steps: m.steps || [], photo: m.photo || null }));
  if (window.CompressionStream) {
    const cs = new CompressionStream("gzip"); const w = cs.writable.getWriter(); w.write(bytes); w.close();
    return "g" + b64url(new Uint8Array(await new Response(cs.readable).arrayBuffer()));
  }
  return "p" + b64url(bytes);
}
async function decodeMeal(code) {
  let bytes = unb64url(code.slice(1));
  if (code[0] === "g") {
    const ds = new DecompressionStream("gzip"); const w = ds.writable.getWriter(); w.write(bytes); w.close();
    bytes = new Uint8Array(await new Response(ds.readable).arrayBuffer());
  }
  const m = JSON.parse(new TextDecoder().decode(bytes));
  if (!m || !m.name || !Array.isArray(m.items)) throw new Error("bad meal");
  return m;
}
$("#m-share").onclick = async () => {
  const m = state.meals.find((x) => x.id === mealDraft.id) || mealDraft;
  const url = `${location.origin}${location.pathname}#meal=${await encodeMeal(m)}`;
  const t = mealTotals(m), portions = num(m.portions) || 1;
  const text = `${m.name}: ${portions} portion${portions === 1 ? "" : "s"}, ${fmt(t.kcal / portions)} kcal each. Open in Cheat Days:`;
  try {
    if (navigator.share) { await navigator.share({ title: m.name, text, url }); return; }
    await navigator.clipboard.writeText(url); toast("Link copied. Send it to whoever you like.");
  } catch (e) { if (e && e.name !== "AbortError") { try { await navigator.clipboard.writeText(url); toast("Link copied."); } catch (e2) { toast("Couldn't share on this browser"); } } }
};
async function importMealFromLink() {
  const h = new URLSearchParams(location.hash.slice(1)), code = h.get("meal");
  if (!code) return;
  history.replaceState(null, "", location.pathname);
  let m;
  try { m = await decodeMeal(code); } catch (e) { toast("That meal link didn't open"); return; }
  const t = mealTotals(m), portions = num(m.portions) || 1;
  if (!await ask(`Add "${m.name}" to your meals?\n\n${m.items.length} ingredients, ${portions} portion${portions === 1 ? "" : "s"}, ${fmt(t.kcal / portions)} kcal each.`)) return;
  state.meals.unshift({ id: uid(), name: m.name, portions, items: m.items.map((it) => ({ ...it, id: uid() })), steps: m.steps || [], photo: m.photo || null, saved: true, shared: true, updatedAt: new Date().toISOString() });
  save(); toast(`Added ${m.name}`); stack = ["home", "meals"]; show("meals");
}
$("#m-share-friends").onclick = async () => {
  const c = window.cloud; if (!c || !c.user) return;
  const m = state.meals.find((x) => x.id === mealDraft.id) || mealDraft;
  busy("Talking to the cloud…");
  try {
    if (state.sharedMealIds.includes(m.id)) {
      await c.unshareMeal(m.id); state.sharedMealIds = state.sharedMealIds.filter((x) => x !== m.id); toast("No longer shared");
    } else {
      const t = mealTotals(m), portions = num(m.portions) || 1;
      await c.shareMeal({ id: m.id, name: m.name, portions, kcalPerPortion: Math.round(t.kcal / portions), items: m.items.map((it) => ({ ...basisOf(it), kcal: it.kcal, grams: it.grams })).concat(Array.isArray(m.steps) && m.steps.length ? [{ _steps: m.steps }] : []) });
      state.sharedMealIds.push(m.id); toast("Shared. Friends will see it under From friends.");
    }
    save(); renderMeal();
  } catch (err) { toast("Couldn't share: " + c.explain(err), 5000); }
  busy(false);
};

// Make a meal lighter: Claude proposes swaps and smaller amounts, and it can be saved as a new meal
const LIGHTER_SCHEMA = {
  type: "object",
  properties: {
    summary: { type: "string", description: "Two or three sentences: what changed and what it does to the taste" },
    new_name: { type: "string", description: "Name for the lighter version, e.g. 'Carrot cake (lighter)'" },
    ingredients: { type: "array", items: { type: "object", properties: {
      name: { type: "string" }, grams: { type: "number", description: "amount in g (ml for liquids)" },
      kcal: { type: "number" }, protein_g: { type: "number" }, carbs_g: { type: "number" }, fat_g: { type: "number" },
      change: { type: "string", description: "'kept', 'less', 'swapped for X', or 'removed'" }
    }, required: ["name", "grams", "kcal", "protein_g", "carbs_g", "fat_g", "change"], additionalProperties: false } }
  },
  required: ["summary", "new_name", "ingredients"],
  additionalProperties: false
};
function renderMealLighter(m, t, portions, r) {
  const items = (r.ingredients || []).filter((x) => !/removed/i.test(x.change)).map((x) => {
    const grams = num(x.grams) || 100, kcal = Math.round(nz(x.kcal) || 0);
    const hit = searchLocal(x.name)[0];
    const base = hit ? { ...basisOf(foodItem(hit)) } : { name: x.name, source: "claude", unit: "g" };
    base.name = x.name;
    base.kcalPer100 = grams ? Math.round(kcal / grams * 100) : null;
    base.p100 = Math.round((nz(x.protein_g) || 0) / grams * 1000) / 10; base.c100 = Math.round((nz(x.carbs_g) || 0) / grams * 1000) / 10; base.f100 = Math.round((nz(x.fat_g) || 0) / grams * 1000) / 10;
    return { id: uid(), ...base, kcal, grams, fromText: x.change };
  });
  const after = items.reduce((a, it) => a + it.kcal, 0);
  const out = $("#m-lighter-out");
  const diff = (1 - after / t.kcal) * 100;
  out.innerHTML = `<div class="plan-card"><p><b>${fmt(t.kcal / portions)} → ${fmt(after / portions)} kcal a portion</b> (${Math.abs(diff) < 1 ? "about the same" : diff > 0 ? fmt(diff) + "% less" : fmt(-diff) + "% more"})</p><p>${esc(r.summary)}</p>
    <ul class="list">${(r.ingredients || []).map((x) => `<li><div class="body"><div class="name">${esc(x.name)}</div><div class="detail">${fmt(x.grams)} g · ${fmt(x.kcal)} kcal · ${esc(x.change)}</div></div></li>`).join("")}</ul>
    ${chatBox("mlight", "Change something? e.g. keep the butter, drop the walnuts")}
    <button class="btn primary" id="m-lighter-save">Save as "${esc(r.new_name || (m.name + " (lighter)"))}"</button></div>`;
  wireChat(out, "mlight", (answer) => renderMealLighter(m, t, portions, answer));
  out.querySelector("#m-lighter-save").onclick = () => {
    state.meals.unshift({ id: uid(), name: r.new_name || `${m.name} (lighter)`, portions, items, steps: Array.isArray(m.steps) ? m.steps.slice() : [], saved: true, updatedAt: new Date().toISOString(), lighterOf: m.id });
    save(); toast("Saved as a new meal"); stack = ["home", "meals"]; show("meals");
  };
}
$("#m-lighter").onclick = () => mealAsk("Make it noticeably lower in calories while keeping it recognisably the same dish and still enjoyable. Prefer swaps people actually have (lighter dairy, less oil or butter, leaner cuts, less sugar, more veg, smaller amounts of the richest items). Aim for at least 20% fewer calories if achievable without ruining it.");
$("#m-ask-go").onclick = () => { const t = $("#m-ask").value.trim(); if (t) { $("#m-ask").value = ""; mealAsk(t); } };
$("#m-ask").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.target.blur(); $("#m-ask-go").click(); } });
async function mealAsk(instruction) {
  if (!aiAvailable()) { aiHelp(); return; }
  const m = mealDraft, t = mealTotals(m), portions = num(m.portions) || 1;
  const lines = m.items.map((it) => { const g = it.grams != null ? it.grams : amountsFor(it, it.kcal || 0).grams; return `${it.name}: ${g != null ? Math.round(g) + " g" : "?"}, ${it.kcal} kcal`; }).join("\n");
  const prompt = `${(state.notes || "").trim() ? `About this person: ${state.notes.trim()}\n` : ""}Here is a recipe called "${m.name || "meal"}" making ${portions} portions, ${fmt(t.kcal)} kcal in total (${fmt(t.kcal / portions)} per portion):
${lines}

The person asks: "${instruction}"
Return the full new ingredient list with realistic amounts and honest kcal and macro figures per ingredient, marking each as kept, less, more, swapped or removed, and a name for the new version (new_name). Say in the summary what changed and what it does to the taste.`;
  busy("Thinking…");
  try {
    const r = await askAI(LIGHTER_SCHEMA, [{ type: "text", text: prompt }]);
    busy(false);
    chats.mlight = { schema: LIGHTER_SCHEMA, basePrompt: prompt, turns: [{ ask: "(first version)", answer: r }] };
    renderMealLighter(m, t, portions, r);
  } catch (err) { busy(false); toast(err.message || "Claude couldn't lighten that", 5000); }
};

$("#m-post").onclick = () => {
  const m = state.meals.find((x) => x.id === mealDraft.id) || mealDraft, t = mealTotals(m), portions = num(m.portions) || 1;
  const hasMac = (t.p || 0) + (t.c || 0) + (t.f || 0) > 0;
  openCompose({ kind: "meal", name: m.name, kcal: Math.round(t.kcal / portions), portions, p: hasMac ? Math.round(t.p / portions) : null, c: hasMac ? Math.round(t.c / portions) : null, f: hasMac ? Math.round(t.f / portions) : null,
    meal: { name: m.name, portions, items: m.items.map((it) => ({ ...basisOf(it), kcal: it.kcal, grams: it.grams })), steps: m.steps || [] } }, m.photo || null);
};
$("#m-use").onclick = () => { const m = state.meals.find((x) => x.id === mealDraft.id) || mealDraft; draft = { ...mealBasis(m), note: "" }; openShare(); };
async function deleteMeal(m) {
  if (!await ask(`Delete "${m.name}"?

Days it was already added to keep their numbers.`)) return false;
  state.meals = state.meals.filter((x) => x.id !== m.id);
  if (mealDraft && mealDraft.id === m.id) { mealDraft = null; state.mealDraft = null; }
  save(); toast(`Deleted ${m.name}`); return true;
}
$("#meal-delete").onclick = async () => { if (await deleteMeal(mealDraft)) { stack = ["home", "meals"]; show("meals"); } };
/** Where a chosen ingredient goes, then back to the editor. */
function mealTakeIngredient(basis, kcal) {
  const m = mealDraft || state.mealDraft || newMeal(); mealDraft = m;
  const a = amountsFor(basis, kcal);
  const it = { id: uid(), ...basisOf(basis), kcal: Math.round(kcal), grams: a.grams != null ? Math.round(a.grams * 10) / 10 : null };
  const i = pick && pick.replaceId ? m.items.findIndex((x) => x.id === pick.replaceId) : -1;
  if (i >= 0) { it.fromText = m.items[i].fromText; m.items[i] = it; } else m.items.push(it);
  pick = null; openRow = null;
  state.mealDraft = m; save(false);
  stack = ["home", "meals", "meal"]; show("meal");
}
function returnToMeal() { pick = null; stack = ["home", "meals", "meal"]; show("meal"); }

// "200g plain flour", "3 eggs", "plain flour 200 g", "1 tbsp honey" -> an ingredient matched to the food list
const UNIT_G = { g: 1, gram: 1, grams: 1, kg: 1000, ml: 1, l: 1000, litre: 1000, litres: 1000, liter: 1000, liters: 1000, tbsp: 15, tablespoon: 15, tablespoons: 15, tsp: 5, teaspoon: 5, teaspoons: 5, cup: 240, cups: 240, oz: 28.35, lb: 453.6, lbs: 453.6 };
const FILLER = /\b(large|medium|small|fresh|chopped|diced|sliced|grated|plain|self[- ]raising|caster|granulated|unsalted|salted|softened|melted|ripe|light|dark|brown|ground|crushed|finely|roughly|of|a|an|the|some|x)\b/gi;
function parseIngredient(line) {
  let t = line.replace(/^\s*(?:[-*\u2022]|\d+[.)])\s+/, "").trim();
  const frac = (x) => { x = x.replace(",", ".").replace(/\s/g, ""); const u = { "½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1 / 3, "⅔": 2 / 3 }[x]; if (u) return u; if (x.includes("/")) { const [a, b] = x.split("/"); return +a / +b; } return +x; };
  const numRe = "(\\d+(?:[.,]\\d+)?(?:\\s*/\\s*\\d+)?|[½¼¾⅓⅔])", unitRe = "(kg|g|grams?|ml|l|litres?|liters?|tbsp|tablespoons?|tsp|teaspoons?|cups?|oz|lbs?)";
  let m;
  if ((m = t.match(new RegExp(`^${numRe}\\s*(?:${unitRe}\\b\\.?)?\\s*(?:of\\s+)?(.+)$`, "i")))) return { qty: frac(m[1]), unit: (m[2] || "").toLowerCase(), name: m[3].trim() };
  if ((m = t.match(new RegExp(`^(.+?)\\s*[,:x×-]?\\s*${numRe}\\s*(?:${unitRe})?\\.?$`, "i")))) return { qty: frac(m[2]), unit: (m[3] || "").toLowerCase(), name: m[1].trim() };
  return { qty: null, unit: "", name: t };
}
function matchFood(name) {
  const tries = [name, name.replace(FILLER, " ").replace(/\s+/g, " ").trim()];
  const words = tries[1].split(" ").filter(Boolean);
  for (let i = 1; i < words.length; i++) tries.push(words.slice(i).join(" "));            // drop leading words: "free range eggs" -> "eggs"
  for (let i = words.length - 1; i > 0; i--) tries.push(words.slice(0, i).join(" "));     // drop trailing words: "butter softened" -> "butter"
  for (const t of tries) { if (!t) continue; const hit = searchLocal(t)[0]; if (hit) return hit; }
  return null;
}
function ingredientFromText(line) {
  const parsed = parseIngredient(line);
  const hit = matchFood(parsed.name);
  if (!hit) return { id: uid(), name: parsed.name || line, source: "manual", unit: "g", kcal: 0, grams: null, fromText: line, unresolved: true };
  const food = foodItem(hit);
  let grams;
  if (parsed.qty && UNIT_G[parsed.unit]) grams = parsed.qty * UNIT_G[parsed.unit];
  else if (parsed.qty && food.servingSize) grams = parsed.qty * food.servingSize;   // "3 eggs"
  else if (food.servingSize) grams = food.servingSize;
  else grams = 100;
  return { id: uid(), ...basisOf(food), kcal: Math.round(grams * food.kcalPer100 / 100), grams: Math.round(grams * 10) / 10, fromText: line };
}

// ---------------------------------------------------------------- history

const histOpen = new Set();
function renderHistory() {
  const list = $("#history-list"); list.innerHTML = "";
  const wk = state.history.filter((h) => h.date >= dateMinus(6)), tr = trainingDays(7);
  const eaten = wk.reduce((a, h) => a + (h.kcal || 0), 0) + usedKcal(), burned = tr.reduce((a, d) => a + d.burned, 0), n = tr.reduce((a, d) => a + d.count, 0);
  const daysCounted = wk.length + (state.day.items.length ? 1 : 0);
  $("#history-week").classList.toggle("hidden", !daysCounted && !n);
  $("#history-week").innerHTML = `<b>Last 7 days</b><span>${daysCounted ? `${fmt(eaten / Math.max(1, daysCounted))} kcal a day on average` : "nothing eaten logged"}${n ? ` · ${n} workout${n === 1 ? "" : "s"}, ${fmt(burned)} kcal burned` : " · no workouts"}</span>`;
  const days = state.history.slice().sort((a, b) => String(b.date).localeCompare(String(a.date)));
  $("#history-empty").classList.toggle("hidden", days.length > 0);
  const today = localDate();
  for (const d of days) {
    const card = document.createElement("div");
    card.className = "card day-card";
    const label = d.date === dateMinus(1) ? "Yesterday" : new Date(d.date + "T12:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
    const over = d.kcal > d.budget, pct = d.budget ? Math.min(100, d.kcal / d.budget * 100) : 0;
    const items = Array.isArray(d.items) ? d.items : [];
    const count = typeof d.items === "number" ? d.items : items.length;
    let body = "";
    if (items.length) {
      body = histOpen.has(d.date)
        ? `<ul class="ate">${items.map((it) => `<li><span>${it.photo ? `<img class="pic" src="${esc(it.photo)}" alt="">` : ""}${esc(it.name)}</span><b>${fmt(it.kcal)}</b></li>`).join("")}</ul><button class="btn mint ate-btn" data-act="toggle">Hide</button>`
        : `<div class="items muted tiny">${esc(items.map((it) => it.name).slice(0, 3).join(", "))}${items.length > 3 ? ` and ${items.length - 3} more` : ""}</div><button class="btn mint ate-btn" data-act="toggle">What I had (${items.length}) ▾</button>`;
    } else if (count) body = `<div class="muted tiny">${count} item${count === 1 ? "" : "s"} (logged before history kept the details)</div>`;
    card.innerHTML = `<div class="top"><b>${esc(label)}</b><span class="kcal ${over ? "over" : "ok"}">${fmt(d.kcal)} / ${fmt(d.budget)} kcal</span></div>${d.burned ? `<div class="burned tiny">Burned ${fmt(d.burned)} kcal: ${esc((d.workouts || []).map((w) => w.name).join(", "))}</div>` : ""}
      <span class="bar"><span style="width:${pct}%" class="${over ? "over" : ""}"></span></span>
      ${d.p != null ? `<div class="macros">${macroText({ p: d.p, c: d.c, f: d.f }, true)}</div>` : ""}${body}`;
    const tog = card.querySelector("[data-act=toggle]");
    if (tog) tog.onclick = () => { if (histOpen.has(d.date)) histOpen.delete(d.date); else histOpen.add(d.date); renderHistory(); };
    list.appendChild(card);
  }
}

// ---------------------------------------------------------------- budget

$("#budget-chips").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  $("#b-budget").value = b.dataset.b;
  $$("#budget-chips button").forEach((x) => x.classList.toggle("on", x === b));
});
$("#b-budget").addEventListener("input", () => $$("#budget-chips button").forEach((x) => x.classList.toggle("on", +x.dataset.b === +$("#b-budget").value)));
$("#budget-suggest").onclick = () => {
  const b = num($("#b-budget").value) || state.budget;
  $("#b-p").value = Math.round(b * 0.30 / 4); $("#b-c").value = Math.round(b * 0.40 / 4); $("#b-f").value = Math.round(b * 0.30 / 9);
};
$("#budget-save").onclick = () => {
  const b = num($("#b-budget").value);
  if (!b) { toast("Budget needs to be a number of kcal"); return; }
  state.budget = Math.round(b);
  state.goals = { p: num($("#b-p").value) ? Math.round(num($("#b-p").value)) : null, c: num($("#b-c").value) ? Math.round(num($("#b-c").value)) : null, f: num($("#b-f").value) ? Math.round(num($("#b-f").value)) : null };
  state.notes = $("#b-notes").value.trim();
  state.weightKg = num($("#b-weight").value) || null;
  save(); toast(`Budget set to ${fmt(state.budget)} kcal`); home();
};

// ---------------------------------------------------------------- settings

function renderSettings() {
  $("#s-budget").value = state.budget;
  $("#s-apikey").value = state.apiKey;
  $("#s-geminikey").value = state.geminiKey || "";
  $("#s-ai-status").textContent = (window.cloud && window.cloud.user && aiProxyState === "yes") ? "Using the shared key from the app's server: nothing to add here." : state.geminiKey ? "Using your Gemini key (free)." : state.apiKey ? "Using your Anthropic key." : "No key yet. A free Google Gemini key from aistudio.google.com is enough.";
  $("#s-version").textContent = APP_VERSION;
  $("#s-eatback").checked = !!state.eatBack;
  renderAccount();
  const d = state.day.date;
  $("#s-day").textContent = d === localDate() ? "Today" : new Date(d + "T12:00").toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "short" });
}
$("#settings-save").onclick = () => {
  const b = num($("#s-budget").value);
  if (!b) { toast("Budget needs to be a number of kcal"); return; }
  state.budget = Math.round(b);
  state.apiKey = $("#s-apikey").value.trim();
  state.geminiKey = $("#s-geminikey").value.trim();
  save(); toast("Saved"); home();
};
$("#s-eatback").addEventListener("change", (e) => { state.eatBack = e.target.checked; save(); toast(state.eatBack ? "Workouts now stretch your budget" : "Budget stays put; workouts still recorded"); });
$("#btn-update").onclick = async () => {
  busy("Fetching the latest version…");
  try {
    if ("serviceWorker" in navigator) {
      const regs = await navigator.serviceWorker.getRegistrations();
      await Promise.all(regs.map((r) => r.unregister()));
    }
    if (window.caches) {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
    }
  } catch (e) { console.warn("update", e); }
  location.replace(location.pathname + "?fresh=" + Date.now());   // bypasses any lingering HTTP cache too
};
$("#btn-new-day").onclick = async () => {
  if (state.day.items.length && !await ask("Start a fresh day now? Today's list goes into History.")) return;
  archiveDay();
  state.day = { date: localDate(), items: [], workouts: [] };
  save(); toast("New day started"); home();
};


// ---------------------------------------------------------------- friends: codes, requests, each other's day, the week, shared meals

let fr = { profile: null, friendships: [], people: {}, days: [], meals: [] };
const frOpen = new Set();   // friends whose full day is unfolded
const dateMinus = (n) => { const d = new Date(); d.setDate(d.getDate() - n); return localDate(d); };
function makeFriendCode(name) {
  const letters = (name || "").replace(/[^a-z]/gi, "").slice(0, 3).toUpperCase().padEnd(3, "X");
  return `${letters}-${1000 + Math.floor(Math.random() * 9000)}`;
}
async function ensureProfile() {
  const c = window.cloud;
  let prof = await c.myProfile();
  if (!prof) {
    const name = (c.user.email || "").split("@")[0];
    for (let i = 0; i < 3 && !prof; i++) {
      try { prof = (await c.saveProfile(name, makeFriendCode(name)))[0]; } catch (e) { if (i === 2) throw e; }
    }
  }
  fr.profile = prof;
}
async function renderFriends() {
  const c = window.cloud, signed = !!(c && c.user);
  $("#fr-signin").classList.toggle("hidden", signed);
  $("#fr-body").classList.toggle("hidden", !signed);
  if (!signed) return;
  $("#fr-share-day").checked = !!state.shareDay;
  publishDay();
  busy("Fetching your friends…");
  try {
    await ensureProfile();
    fr.friendships = await c.friendships();
    const ids = new Set();
    for (const f of fr.friendships) { ids.add(f.requester); ids.add(f.addressee); }
    ids.delete(c.uid);
    const people = await c.profiles([...ids]);
    fr.people = {}; for (const p of people) fr.people[p.user_id] = p;
    fr.days = await c.days(dateMinus(6));
    fr.meals = await c.sharedMeals();
  } catch (err) { busy(false); toast("Friends aren't set up yet: " + c.explain(err), 6000); return; }
  busy(false);
  drawFriends();
}
const personName = (id) => (fr.people[id] && fr.people[id].display_name) || "Someone";
const initials = (name) => (name || "?").split(/\s+/).map((w) => w[0]).join("").slice(0, 2).toUpperCase();
const avatar = (id, name, big = false) => { let h = 0; for (const ch of String(id)) h = (h * 31 + ch.charCodeAt(0)) >>> 0; return `<span class="avatar a${(h % 6) + 1}${big ? " big" : ""}">${esc(initials(name))}</span>`; };
function drawFriends() {
  const c = window.cloud, me = c.uid;
  if (document.activeElement !== $("#fr-name")) $("#fr-name").value = fr.profile.display_name || "";
  $("#fr-avatar").outerHTML = avatar(me, fr.profile.display_name, true).replace('class="', 'id="fr-avatar" class="');
  $("#fr-code").textContent = fr.profile.friend_code;
  // requests
  const pending = fr.friendships.filter((f) => f.status === "pending" && f.addressee === me);
  const sent = fr.friendships.filter((f) => f.status === "pending" && f.requester === me);
  const pl = $("#fr-pending"); pl.innerHTML = "";
  $("#fr-pending-wrap").classList.toggle("hidden", !pending.length && !sent.length);
  for (const f of pending) {
    const li = document.createElement("li");
    li.innerHTML = `${avatar(f.requester, personName(f.requester))}<div class="body"><div class="name">${esc(personName(f.requester))}</div><div class="detail">wants to be friends</div></div>
      <button class="add" aria-label="Accept"><svg><use href="#i-plus"/></svg></button><button class="del" aria-label="Decline">✕</button>`;
    li.querySelector(".add").onclick = async () => { try { await c.acceptFriend(f.id); toast(`You and ${personName(f.requester)} are friends`); renderFriends(); } catch (e) { toast(c.explain(e)); } };
    li.querySelector(".del").onclick = async () => { if (!await ask(`Decline ${personName(f.requester)}'s request?`)) return; try { await c.removeFriend(f.id); renderFriends(); } catch (e) { toast(c.explain(e)); } };
    pl.appendChild(li);
  }
  for (const f of sent) {
    const li = document.createElement("li");
    li.innerHTML = `${avatar(f.addressee, personName(f.addressee))}<div class="body"><div class="name">${esc(personName(f.addressee))}</div><div class="detail">request sent · waiting for them</div></div><button class="del" aria-label="Cancel">✕</button>`;
    li.querySelector(".del").onclick = async () => { if (!await ask(`Cancel the request to ${personName(f.addressee)}?`)) return; try { await c.removeFriend(f.id); renderFriends(); } catch (e) { toast(c.explain(e)); } };
    pl.appendChild(li);
  }
  // friends today
  const friends = fr.friendships.filter((f) => f.status === "accepted").map((f) => ({ id: f.id, uid: f.requester === me ? f.addressee : f.requester }));
  const today = localDate();
  const fl = $("#fr-list"); fl.innerHTML = "";
  
  const dayLabel = (day) => day === today ? "today" : day === dateMinus(1) ? "yesterday" : new Date(day + "T12:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
  for (const f of friends) {
    // Their most recent shared day: people don't tap "New day" at midnight, so "today" is whatever they last shared.
    const d = fr.days.filter((x) => x.user_id === f.uid).sort((a, b) => String(b.day).localeCompare(String(a.day)))[0];
    const card = document.createElement("div");
    card.className = "card friend-card";
    let right = `<span class="kcal muted">nothing shared this week</span>`, bar = "", items = "";
    if (d) {
      const over = d.kcal > d.budget, pct = d.budget ? Math.min(100, d.kcal / d.budget * 100) : 0;
      right = `<span class="kcal ${over ? "over" : "ok"}">${fmt(d.kcal)} / ${fmt(d.budget)}</span><span class="when">${dayLabel(String(d.day))}</span>`;
      bar = `<span class="bar"><span style="width:${pct}%" class="${over ? "over" : ""}"></span></span>`;
      const list = Array.isArray(d.items) ? d.items : [];
      if (!list.length) items = `<div class="items">nothing eaten yet</div>`;
      else if (frOpen.has(f.uid)) items = `<ul class="ate">${list.map((it) => `<li><span>${esc(it.name)}</span><b>${fmt(it.kcal)}</b></li>`).join("")}</ul><button class="btn mint ate-btn" data-act="toggle">Hide</button>`;
      else items = `<div class="items">${esc(list.map((it) => it.name).slice(0, 3).join(", "))}${list.length > 3 ? ` and ${list.length - 3} more` : ""}</div><button class="btn mint ate-btn" data-act="toggle">What they ate (${list.length}) ▾</button>`;
    }
    card.innerHTML = `${avatar(f.uid, personName(f.uid))}<div class="body"><div class="name"><span>${esc(personName(f.uid))}</span>${right}</div>${bar}${items}</div><button class="del" aria-label="Remove friend">✕</button>`;
    const tog = card.querySelector("[data-act=toggle]");
    if (tog) tog.onclick = (e) => { e.stopPropagation(); if (frOpen.has(f.uid)) frOpen.delete(f.uid); else frOpen.add(f.uid); drawFriends(); };
    card.querySelector(".del").onclick = async () => { if (!await ask(`Remove ${personName(f.uid)} as a friend?`)) return; try { await c.removeFriend(f.id); renderFriends(); } catch (e) { toast(c.explain(e)); } };
    fl.appendChild(card);
  }
  $("#fr-empty").classList.toggle("hidden", friends.length > 0);
  // the week
  const byUser = {};
  for (const d of fr.days) { (byUser[d.user_id] = byUser[d.user_id] || []).push(d); }
  if (!byUser[me] && state.shareDay) byUser[me] = [{ user_id: me, day: today, budget: state.budget, kcal: usedKcal() }];
  const rows = Object.entries(byUser).map(([uid, ds]) => {
    const onBudget = ds.filter((d) => d.kcal <= d.budget).length;
    const pct = ds.reduce((a, d) => a + (d.budget ? d.kcal / d.budget : 0), 0) / ds.length * 100;
    return { uid, name: uid === me ? "You" : personName(uid), days: ds.length, onBudget, pct };
  }).sort((a, b) => (b.onBudget - a.onBudget) || (a.pct - b.pct));
  const wl = $("#fr-week"); wl.innerHTML = "";
  rows.forEach((r, i) => {
    const row = document.createElement("div");
    row.className = "row";
    row.innerHTML = `<span class="medal m${i + 1}">${i + 1}</span>${avatar(r.uid, r.uid === me ? fr.profile.display_name : r.name)}
      <div class="who"><b>${esc(r.name)}</b><small>${r.onBudget} of ${r.days} day${r.days === 1 ? "" : "s"} on budget</small></div>
      <div class="score"><b>${fmt(r.pct)}%</b><small>of budget used</small></div>`;
    wl.appendChild(row);
  });
  if (!rows.length) wl.innerHTML = `<div class="row muted">Nobody has shared a day yet this week.</div>`;
  // meals from friends
  const ml = $("#fr-meals"); ml.innerHTML = "";
  const theirs = fr.meals.filter((m) => m.owner !== me);
  for (const m of theirs) {
    const card = document.createElement("div");
    card.className = "card meal-card";
    card.innerHTML = `<span class="thumb-sm tone-peach"><svg><use href="#i-meal"/></svg></span><div class="body"><div class="name">${esc(m.name)}</div><div class="detail">${m.portions} portion${m.portions == 1 ? "" : "s"} · ${fmt(m.kcal_per_portion)} kcal each · ${(m.items || []).filter((it) => it && !it._steps).length} ingredients</div><div class="by">${avatar(m.owner, personName(m.owner))} ${esc(personName(m.owner))}</div></div><button class="add" aria-label="Copy to my meals"><svg><use href="#i-plus"/></svg></button>`;
    card.querySelector(".add").onclick = async () => {
      if (state.meals.some((x) => x.copiedFrom === m.id) && !await ask(`You already have "${m.name}". Add another copy?`)) return;
      const stepsRow = (m.items || []).find((it) => it && it._steps);
      state.meals.unshift({ id: uid(), name: m.name, portions: +m.portions || 1, items: (m.items || []).filter((it) => it && !it._steps).map((it) => ({ ...it, id: uid() })), steps: stepsRow ? stepsRow._steps : [], saved: true, copiedFrom: m.id, updatedAt: new Date().toISOString() });
      save(); toast(`${m.name} is in your meals`);
    };
    ml.appendChild(card);
  }
  $("#fr-meals-empty").classList.toggle("hidden", theirs.length > 0);
}
$("#fr-refresh").onclick = () => renderFriends();
$("#fr-add-toggle").onclick = () => { $("#fr-add-wrap").classList.toggle("hidden"); $("#fr-add").focus(); };
$("#fr-name").addEventListener("change", async () => {
  const c = window.cloud, name = $("#fr-name").value.trim();
  if (!name || !fr.profile) return;
  try { fr.profile = (await c.saveProfile(name, fr.profile.friend_code))[0]; toast("Name saved"); drawFriends(); } catch (e) { toast(c.explain(e)); }
});
$("#fr-share-code").onclick = async () => {
  const code = fr.profile.friend_code, text = `Add me on Cheat Days: my friend code is ${code}. ${location.origin}${location.pathname}`;
  try { if (navigator.share) await navigator.share({ text }); else { await navigator.clipboard.writeText(text); toast("Copied. Send it to a friend."); } } catch (e) {}
};
$("#fr-share-day").addEventListener("change", (e) => {
  state.shareDay = e.target.checked; save();
  if (!state.shareDay && window.cloud) window.cloud.unpublishDays().catch(() => {});
  toast(state.shareDay ? "Friends can see your day" : "Your day is private again");
});
$("#fr-add-go").onclick = async () => {
  const c = window.cloud, code = $("#fr-add").value.trim().toUpperCase().replace(/\s+/g, "");
  if (!code) return;
  busy("Looking for that code…");
  try {
    const p = await c.findByCode(code);
    if (!p) { busy(false); toast("No one has that code. Check it with them."); return; }
    if (p.user_id === c.uid) { busy(false); toast("That's your own code"); return; }
    await c.requestFriend(p.user_id);
    busy(false); $("#fr-add").value = ""; $("#fr-add-wrap").classList.add("hidden"); toast(`Request sent to ${p.display_name || "them"}`); renderFriends();
  } catch (err) { busy(false); toast(c.explain(err), 5000); }
};
$("#fr-add").addEventListener("keydown", (e) => { if (e.key === "Enter") $("#fr-add-go").click(); });



// ---------------------------------------------------------------- follow-up chat under an AI result ("no egg", "cut it further")
const chats = {};   // key -> { schema, basePrompt, turns: [{ask, answer}] }
function chatBox(key, placeholder) {
  return `<div class="chat"><input type="text" id="chat-${key}" placeholder="${esc(placeholder)}" autocapitalize="sentences"><button class="btn primary slim" data-chat="${key}">Send</button></div>`;
}
function wireChat(container, key, onAnswer) {
  const input = container.querySelector(`#chat-${key}`), btn = container.querySelector(`[data-chat="${key}"]`);
  const send = async () => {
    const ask = input.value.trim(); if (!ask) return;
    const c = chats[key]; if (!c) return;
    const history = c.turns.map((t, i) => `Your answer ${i + 1}: ${JSON.stringify(t.answer)}\nThey said: "${t.ask}"`).join("\n\n");
    const prompt = `${c.basePrompt}\n\n${history ? history + "\n\n" : ""}Now they say: "${ask}"\nRevise your previous answer to do what they ask, keep everything else consistent, and return the complete updated answer in the same format.`;
    busy("Revising…");
    try {
      const answer = await askAI(c.schema, [{ type: "text", text: prompt }]);
      busy(false);
      c.turns.push({ ask, answer });
      onAnswer(answer);
    } catch (err) { busy(false); toast(err.message || "Couldn't revise that", 5000); }
  };
  btn.onclick = send;
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.target.blur(); send(); } });
}


// ---------------------------------------------------------------- "Just tell it": edit the day in plain words

const TALK_SCHEMA = {
  type: "object",
  properties: {
    reply: { type: "string", description: "One friendly sentence back to the person; if nothing needs changing, say what you understood or answer their question" },
    actions: { type: "array", items: { type: "object", properties: {
      action: { type: "string", enum: ["add", "remove", "update", "set_budget", "workout"] },
      target: { type: ["string", "null"], description: "For remove/update: the exact name of the existing item from the list" },
      minutes: { type: ["number", "null"], description: "For workout: how long" }, effort: { type: ["string", "null"], enum: ["easy", "moderate", "hard", null], description: "For workout" },
      activity: { type: ["string", "null"], description: "For workout: one of Walk, Run, Cycle, Swim, Gym weights, HIIT, Yoga / stretch, Football, Tennis / padel, Hike, Rowing, Elliptical, Dance, Boxing, Climbing, Other" },
      lifts: { type: ["array", "null"], description: "For a gym workout: the exercises", items: { type: "object", properties: { exercise: { type: "string" }, sets: { type: "number" }, reps: { type: "number" }, kg: { type: "number" } }, required: ["exercise", "sets", "reps", "kg"], additionalProperties: false } },
      name: { type: ["string", "null"], description: "For add: what the food is" },
      grams: { type: ["number", "null"], description: "amount in g or ml if known" },
      count: { type: ["number", "null"], description: "how many pieces/servings if that's how they said it" },
      kcal: { type: ["number", "null"], description: "your best estimate of kcal for the amount (add) or the corrected total (update)" },
      protein_g: { type: ["number", "null"] }, carbs_g: { type: ["number", "null"] }, fat_g: { type: ["number", "null"] },
      budget: { type: ["number", "null"], description: "for set_budget" }
    }, required: ["action", "target", "name", "grams", "count", "kcal", "protein_g", "carbs_g", "fat_g", "budget", "minutes", "effort", "activity", "lifts"], additionalProperties: false } }
  },
  required: ["reply", "actions"],
  additionalProperties: false
};
$("#talk-go").onclick = () => talk();
$("#talk").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.target.blur(); talk(); } });
async function talk() {
  const text = $("#talk").value.trim(); if (!text) return;
  if (!aiAvailable()) { aiHelp(); return; }
  const list = state.day.items.map((it) => `- "${it.name}": ${it.kcal} kcal${(() => { const a = amountsFor(it, it.kcal); return a.grams != null ? `, ${Math.round(a.grams)} ${it.unit || "g"}` : ""; })()}`).join("\n") || "(nothing yet)";
  const prompt = `You maintain someone's food diary for today. Budget ${state.budget} kcal, eaten ${usedKcal()} kcal so far. Today's list:\n${list}\n\nThey say: "${text}"\n\nTurn that into actions on the list. Use "update" with the corrected total kcal (and amount) when they say they had more or less of an existing item; "remove" to take one off; "add" for new things with a realistic kcal estimate for the amount; "set_budget" if they change the day's budget; "workout" when they did exercise (activity from the list, minutes, effort, and for gym sessions the lifts as sets × reps at kg). Match targets to the exact names in the list. If they're only asking a question, return no actions and answer in reply.`;
  busy("Working out what you meant…");
  let r;
  try { r = await askAI(TALK_SCHEMA, [{ type: "text", text: prompt }]); busy(false); }
  catch (err) { busy(false); toast(err.message || "Didn't catch that", 5000); return; }
  $("#talk").value = "";
  const acts = (r.actions || []).map(planTalkAction).filter(Boolean);
  const out = $("#talk-out");
  if (!acts.length) { out.innerHTML = `<div class="talk-card"><p>${esc(r.reply || "Nothing to change.")}</p></div>`; return; }
  out.innerHTML = `<div class="talk-card"><p>${esc(r.reply || "Here's what I'll do:")}</p><ul>${acts.map((a) => `<li>${esc(a.label)}</li>`).join("")}</ul>
    <div class="btn-row"><button class="btn primary" id="talk-apply">Apply</button><button class="btn mint" id="talk-cancel">Cancel</button></div></div>`;
  out.querySelector("#talk-cancel").onclick = () => { out.innerHTML = ""; };
  out.querySelector("#talk-apply").onclick = () => { for (const a of acts) a.run(); save(); renderHome(); out.innerHTML = ""; toast("Done"); };
}
/** Turn one model action into a label + a function that does it, using our own food data where we have it. */
function planTalkAction(a) {
  if (a.action === "workout") {
    const type = (ACTIVITIES.find((x) => x[0].toLowerCase() === String(a.activity || "").toLowerCase()) || ["Other"])[0];
    const minutes = num(a.minutes) || 30, effort = ["easy", "moderate", "hard"].includes(a.effort) ? a.effort : "moderate";
    const lifts = Array.isArray(a.lifts) ? a.lifts.filter((l) => l && l.exercise).map((l) => ({ exercise: l.exercise, sets: num(l.sets) || 1, reps: num(l.reps) || 1, kg: nz(l.kg) || 0 })) : [];
    const name = a.name || type;
    return { label: `Log workout: ${name}, ${minutes} min ${effort} (about ${fmt(burnFor(type, minutes, effort))} kcal)${lifts.length ? `, ${lifts.length} exercise${lifts.length === 1 ? "" : "s"}` : ""}`, run: () => logWorkout({ type, name, minutes, effort, lifts }) };
  }
  const findItem = (t) => { if (!t) return null; const tl = t.toLowerCase(); return state.day.items.find((it) => it.name.toLowerCase() === tl) || state.day.items.find((it) => it.name.toLowerCase().includes(tl) || tl.includes(it.name.toLowerCase())); };
  if (a.action === "set_budget" && num(a.budget)) {
    const b = Math.round(a.budget);
    return { label: `Set today's budget to ${fmt(b)} kcal`, run: () => { state.budget = b; } };
  }
  if (a.action === "remove") {
    const it = findItem(a.target); if (!it) return null;
    return { label: `Remove ${it.name} (${fmt(it.kcal)} kcal)`, run: () => { state.day.items = state.day.items.filter((x) => x.id !== it.id); } };
  }
  if (a.action === "update") {
    const it = findItem(a.target); if (!it) return null;
    let kcal = null;
    const c = conv(it);
    if (num(a.count) && c.countKcal) kcal = a.count * c.countKcal;
    else if (num(a.grams) && c.kcalPer100) kcal = a.grams * c.kcalPer100 / 100;
    else if (num(a.kcal)) kcal = a.kcal;
    if (!kcal) return null;
    kcal = Math.round(kcal);
    return { label: `${it.name}: ${fmt(it.kcal)} → ${fmt(kcal)} kcal`, run: () => { it.kcal = kcal; it.shareLabel = `${fmt(kcal / state.budget * 100, 1)}% of the day`; } };
  }
  if (a.action === "add" && a.name) {
    const hit = searchLocal(a.name)[0];
    let basis, kcal;
    if (hit) {
      basis = foodItem(hit); const c = conv(basis);
      if (num(a.count) && c.countKcal) kcal = a.count * c.countKcal;
      else if (num(a.grams) && c.kcalPer100) kcal = a.grams * c.kcalPer100 / 100;
      else if (num(a.kcal)) kcal = a.kcal;
      else if (c.countKcal) kcal = c.countKcal;
    } else {
      basis = blankItem("claude"); basis.name = a.name; basis.unit = "g";
      basis.kcalPerServing = Math.round(num(a.kcal) || 0); basis.unitLabel = "portion";
      if (num(a.grams)) { basis.servingSize = Math.round(a.grams); basis.kcalPer100 = Math.round(basis.kcalPerServing / a.grams * 100); }
      basis.pServ = nz(a.protein_g) || 0; basis.cServ = nz(a.carbs_g) || 0; basis.fServ = nz(a.fat_g) || 0;
      kcal = basis.kcalPerServing;
    }
    if (!kcal) return null;
    kcal = Math.round(kcal);
    const amt = num(a.count) ? `${a.count} ${plural(a.count, basis.unitLabel || "serving")}` : num(a.grams) ? `${Math.round(a.grams)} ${basis.unit || "g"}` : "";
    return { label: `Add ${basis.name}${amt ? `, ${amt}` : ""} (${fmt(kcal)} kcal)`, run: () => addToDay(basis, kcal, `${fmt(kcal / state.budget * 100, 1)}% of the day`) };
  }
  return null;
}


// ---------------------------------------------------------------- tweak one item in words, on the How much? screen
const ITEM_TALK_SCHEMA = {
  type: "object",
  properties: {
    reply: { type: "string", description: "One short sentence on what changed" },
    name: { type: "string", description: "Updated name if the change deserves it, else the same name" },
    kcal: { type: "number", description: "Revised kcal for the amount they are having" },
    protein_g: { type: "number" }, carbs_g: { type: "number" }, fat_g: { type: "number" }
  },
  required: ["reply", "name", "kcal", "protein_g", "carbs_g", "fat_g"],
  additionalProperties: false
};
$("#item-talk-go").onclick = () => itemTalk();
$("#item-talk").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.target.blur(); itemTalk(); } });
async function itemTalk() {
  const text = $("#item-talk").value.trim(); if (!text || !draft) return;
  if (!aiAvailable()) { aiHelp(); return; }
  const kcal = amountKcal ? Math.round(amountKcal) : (draft.kcalPerServing || 0);
  const m = macrosFor(draft, kcal), a = amountsFor(draft, kcal);
  const facts = [`${kcal} kcal`, a.grams != null ? `${Math.round(a.grams)} ${draft.unit || "g"}` : null, m.p != null ? `protein ${Math.round(m.p)} g, carbs ${Math.round(m.c)} g, fat ${Math.round(m.f)} g` : null, draft.note ? `note: ${draft.note}` : null].filter(Boolean).join("; ");
  const prompt = `Food diary entry: "${draft.name}"${draft.brand ? ` (${draft.brand})` : ""}, currently logged as ${facts}.\nThey say: "${text}"\nRevise the entry for what they actually had: give the new kcal and macros for the amount they are having, with a realistic estimate for anything added or left out. Keep the name unless the change is big enough to deserve a new one.`;
  busy("Revising…");
  try {
    const r = await askAI(ITEM_TALK_SCHEMA, [{ type: "text", text: prompt }]);
    busy(false);
    const newKcal = Math.round(num(r.kcal) || kcal);
    // Re-base the item so grams stay sensible and the macros follow the revised figures
    const grams = a.grams != null ? a.grams : (draft.servingSize || 100);
    draft.name = r.name || draft.name;
    draft.kcalPer100 = Math.round(newKcal / grams * 100);
    draft.kcalPerServing = draft.servingSize ? Math.round(draft.kcalPer100 * draft.servingSize / 100) : newKcal;
    draft.p100 = Math.round((nz(r.protein_g) || 0) / grams * 1000) / 10; draft.c100 = Math.round((nz(r.carbs_g) || 0) / grams * 1000) / 10; draft.f100 = Math.round((nz(r.fat_g) || 0) / grams * 1000) / 10;
    delete draft.pServ; delete draft.cServ; delete draft.fServ;
    draft.note = ((draft.note || "") + " Tweaked: " + text).trim();
    $("#share-name").textContent = draft.name;
    setAmount(newKcal, "kcal"); $("#a-kcal").value = newKcal;
    $("#item-talk").value = "";
    const note = $("#item-talk-note"); note.textContent = `${r.reply || "Updated."} (${fmt(kcal)} → ${fmt(newKcal)} kcal)`; note.classList.remove("hidden");
  } catch (err) { busy(false); toast(err.message || "Couldn't revise that", 5000); }
}

// ---------------------------------------------------------------- Assistant: one conversation for everything

const ASSIST_SCHEMA = {
  type: "object",
  properties: {
    reply: { type: "string", description: "What you'd say back, warm and short (one to three sentences). Always filled." },
    kind: { type: "string", enum: ["answer", "estimate", "plan", "edit", "recipe", "lighter"], description: "What the person wants" },
    estimate: { type: ["object", "null"], description: "kind=estimate: a food or plate as one portion", properties: {
      name: { type: "string" }, portion_g: { type: "number" }, unit: { type: "string", enum: ["g", "ml"] },
      kcal_total: { type: "number" }, protein_g: { type: "number" }, carbs_g: { type: "number" }, fat_g: { type: "number" },
      confidence: { type: "string", enum: ["high", "medium", "low"] }, notes: { type: "string" }
    }, required: ["name", "portion_g", "unit", "kcal_total", "protein_g", "carbs_g", "fat_g", "confidence", "notes"], additionalProperties: false },
    plan: { type: ["object", "null"], description: "kind=plan: things for the rest of the day", properties: {
      suggestions: { type: "array", items: { type: "object", properties: {
        name: { type: "string" }, amount: { type: "string" }, kcal: { type: "number" }, protein_g: { type: "number" }, carbs_g: { type: "number" }, fat_g: { type: "number" }, why: { type: "string" }
      }, required: ["name", "amount", "kcal", "protein_g", "carbs_g", "fat_g", "why"], additionalProperties: false } }
    }, required: ["suggestions"], additionalProperties: false },
    edit: { type: ["object", "null"], description: "kind=edit: changes to today's list", properties: {
      actions: { type: "array", items: { type: "object", properties: {
        action: { type: "string", enum: ["add", "remove", "update", "set_budget", "workout"] },
        target: { type: ["string", "null"] }, name: { type: ["string", "null"] }, grams: { type: ["number", "null"] }, count: { type: ["number", "null"] },
        kcal: { type: ["number", "null"] }, protein_g: { type: ["number", "null"] }, carbs_g: { type: ["number", "null"] }, fat_g: { type: ["number", "null"] }, budget: { type: ["number", "null"] },
        minutes: { type: ["number", "null"] }, effort: { type: ["string", "null"], enum: ["easy", "moderate", "hard", null] }, activity: { type: ["string", "null"] },
        lifts: { type: ["array", "null"], items: { type: "object", properties: { exercise: { type: "string" }, sets: { type: "number" }, reps: { type: "number" }, kg: { type: "number" } }, required: ["exercise", "sets", "reps", "kg"], additionalProperties: false } }
      }, required: ["action", "target", "name", "grams", "count", "kcal", "protein_g", "carbs_g", "fat_g", "budget", "minutes", "effort", "activity", "lifts"], additionalProperties: false } }
    }, required: ["actions"], additionalProperties: false },
    recipe: { type: ["object", "null"], description: "kind=recipe: a dish they can cook and save as a meal", properties: {
      name: { type: "string" }, portions: { type: "number" },
      ingredients: { type: "array", items: { type: "object", properties: {
        name: { type: "string" }, grams: { type: "number", description: "g, or ml for liquids" }, kcal: { type: "number" }, protein_g: { type: "number" }, carbs_g: { type: "number" }, fat_g: { type: "number" }
      }, required: ["name", "grams", "kcal", "protein_g", "carbs_g", "fat_g"], additionalProperties: false } },
      steps: { type: "array", items: { type: "string" }, description: "short numbered method steps" },
      notes: { type: "string" }
    }, required: ["name", "portions", "ingredients", "steps", "notes"], additionalProperties: false },
    lighter: { type: ["object", "null"], description: "kind=lighter: a lighter way to have a named thing", properties: {
      name: { type: "string" }, tips: { type: "array", items: { type: "string" } }, serving_size: { type: "number" },
      kcal_per_serving: { type: "number" }, protein_g: { type: "number" }, carbs_g: { type: "number" }, fat_g: { type: "number" }
    }, required: ["name", "tips", "serving_size", "kcal_per_serving", "protein_g", "carbs_g", "fat_g"], additionalProperties: false }
  },
  required: ["reply", "kind", "estimate", "plan", "edit", "recipe", "lighter"],
  additionalProperties: false
};
let askTurns = [];       // {role: "me"|"bot", text, kind, result?}
let askFiles = [];       // photos waiting to go with the next message (dish, menu, leftovers...)
let chatId = null;       // the saved chat this conversation belongs to
const WELCOME = `<b>Ask me anything about your day.</b><br>Photograph a plate and tell me what it is. Ask for a plan for the rest of today, a recipe that fits, a lighter version of something, or tell me what you actually ate and I'll fix the list.`;

function renderAsk() {
  $("#ask-nokey").classList.toggle("hidden", aiAvailable());
  showAskPreview();
  if (!$("#ask-thread").children.length) { $("#ask-thread").innerHTML = `<div class="bubble bot">${WELCOME}</div>`; }
  scrollThread();
  setTimeout(() => $("#ask-text").focus(), 80);
}
function scrollThread() { const t = $("#ask-thread"); const go = () => { t.scrollTop = t.scrollHeight; }; go(); requestAnimationFrame(go); setTimeout(go, 120); setTimeout(go, 400); }
/** Save this conversation (text only, no photos) so it can be reopened later. */
function saveChat() {
  if (!askTurns.length) return;
  if (!chatId) chatId = uid();
  const first = askTurns.find((t) => t.role === "me");
  const rec = { id: chatId, title: (first ? first.text : "Chat").slice(0, 60), when: new Date().toISOString(), turns: askTurns.slice(-40) };
  const i = state.chats.findIndex((c) => c.id === chatId);
  if (i >= 0) state.chats[i] = rec; else state.chats.unshift(rec);
  state.chats = state.chats.slice(0, 30);
  save();
}
function newChat() { askTurns = []; chatId = null; askFiles = []; showAskPreview(); $("#ask-thread").innerHTML = `<div class="bubble bot">${WELCOME}</div>`; }
function openChat(rec) {
  askTurns = rec.turns.slice(); chatId = rec.id; askFiles = [];
  $("#ask-thread").innerHTML = "";
  for (const t of askTurns) {
    if (t.role === "me") bubble("me", esc(t.text));
    else if (t.result) renderAssistant(t.result, null); else bubble("bot", esc(t.text));
  }
  stack = ["home", "ask"]; show("ask");
}
function renderChats() {
  const list = $("#chats-list"); list.innerHTML = "";
  $("#chats-empty").classList.toggle("hidden", state.chats.length > 0);
  for (const c of state.chats) {
    const li = document.createElement("li");
    const when = new Date(c.when);
    li.innerHTML = `<span class="thumb-sm"><svg><use href="#i-spark"/></svg></span><div class="body"><div class="name">${esc(c.title)}</div><div class="detail">${c.turns.filter((t) => t.role === "me").length} message${c.turns.length === 1 ? "" : "s"} · ${when.toLocaleDateString(undefined, { day: "numeric", month: "short" })} ${when.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })}</div></div><button class="del" aria-label="Delete chat">✕</button>`;
    li.querySelector(".body").onclick = () => openChat(c);
    li.querySelector(".del").onclick = async (e) => { e.stopPropagation(); if (!await ask(`Delete this chat?`)) return; state.chats = state.chats.filter((x) => x.id !== c.id); if (chatId === c.id) newChat(); save(); renderChats(); };
    list.appendChild(li);
  }
}
$("#ask-chats").onclick = () => go("chats");
function showAskPreview() {
  const wrap = $("#ask-preview"); wrap.innerHTML = "";
  if (!askFiles.length) { wrap.classList.add("hidden"); $("#ask-text").placeholder = "e.g. A5 wagyu nigiri, 2 pieces"; return; }
  askFiles.forEach((f, i) => {
    const d = document.createElement("div"); d.className = "shot";
    d.innerHTML = `<img alt=""><b>${i + 1}</b><button aria-label="Remove">✕</button>`;
    d.querySelector("img").src = URL.createObjectURL(f);
    d.querySelector("button").onclick = () => { askFiles.splice(i, 1); showAskPreview(); };
    wrap.appendChild(d);
  });
  wrap.classList.remove("hidden");
  $("#ask-text").placeholder = askFiles.length > 1 ? "What are they? e.g. the dish, the menu, what I left" : "What is it, and how much?";
}
function addAskFiles(list) { for (const f of list) if (askFiles.length < 5) askFiles.push(f); showAskPreview(); setTimeout(() => $("#ask-text").focus(), 100); }
function bubble(role, html) {
  const el = document.createElement("div");
  el.className = `bubble ${role}`; el.innerHTML = html;
  $("#ask-thread").appendChild(el);
  scrollThread();
  return el;
}
$("#ask-clear").onclick = () => { newChat(); toast("New chat"); };
$("#ask-photo").onclick = () => { if (!aiAvailable()) { aiHelp(); return; } $("#file-ask").click(); };
$("#file-ask").addEventListener("change", (e) => { const fs = Array.from(e.target.files || []); e.target.value = ""; if (fs.length) addAskFiles(fs); });
$("#ask-library").onclick = () => { if (!aiAvailable()) { aiHelp(); return; } $("#file-ask-lib").click(); };
$("#file-ask-lib").addEventListener("change", (e) => { const fs = Array.from(e.target.files || []); e.target.value = ""; if (fs.length) addAskFiles(fs); });
$("#ask-send").onclick = () => sendAsk();
$("#ask-text").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.target.blur(); sendAsk(); } });
$("#ask-chips").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  const q = b.dataset.ask;
  if (q === "photo") { $("#ask-photo").click(); return; }
  if (q === "library") { $("#ask-library").click(); return; }
  if (q === "fits") { showFits(); return; }
  $("#ask-text").value = q; sendAsk();
});

function dayContext() {
  const d = dayGaps(), g = state.goals || {};
  const eaten = state.day.items.map((it) => `"${it.name}" ${it.kcal} kcal`).join(", ") || "nothing yet";
  const past = state.history.slice(0, 3).map((h) => `${h.date}: ${h.kcal}/${h.budget} kcal${Array.isArray(h.items) && h.items.length ? ` (${h.items.slice(0, 6).map((it) => it.name).join(", ")}${h.items.length > 6 ? "…" : ""})` : ""}`).join("; ") || "none yet";
  const meals = state.meals.slice(0, 12).map((m) => { const t = mealTotals(m), n = num(m.portions) || 1; return `"${m.name}" (${n} portions, ${fmt(t.kcal / n)} kcal each: ${(m.items || []).slice(0, 8).map((it) => `${it.name} ${it.grams != null ? Math.round(it.grams) + " g" : ""}`).join(", ")})`; }).join("; ") || "none";
  const notes = (state.notes || "").trim();
  const wk = (state.day.workouts || []).map((w) => `${w.name} ${w.minutes} min (${w.kcal} kcal)`).join(", ") || "none";
  return `${notes ? `About this person, in their own words (respect it in every suggestion): ${notes}\n` : ""}Today: budget ${budgetToday()} kcal${state.eatBack ? " (includes calories burned)" : ""}, eaten ${usedKcal()} kcal (${eaten}), ${d.left} kcal left. Workouts today: ${wk}; weight ${state.weightKg || "unknown"} kg. Macro goals: protein ${g.p || "none"} g, carbs ${g.c || "none"} g, fat ${g.f || "none"} g; so far protein ${Math.round(d.mac.p)} g, carbs ${Math.round(d.mac.c)} g, fat ${Math.round(d.mac.f)} g.
Recent days: ${past}.
Things they often have: ${quickEntries().slice(0, 8).map((q) => q.basis.name).join(", ") || "unknown"}.
Their saved meals, with ingredients: ${meals}. If they ask to change one of these, return kind=recipe with the SAME name and the full revised ingredient list.
Lifting: ${liftingSummary()}. Workout routines: ${(state.routines || []).map((r) => `"${r.name}" (${r.exercises.map((e) => e.exercise).join(", ")})`).join("; ") || "none"}. Recent training days: ${trainingDays(14).map((d) => `${d.date}: ${d.names.join(", ")}`).join("; ") || "none"}.`;
}
async function sendAsk() {
  const text = $("#ask-text").value.trim(), files = askFiles.slice();
  if (!text && !files.length) return;
  if (!aiAvailable()) { aiHelp(); return; }
  const images = [];
  for (const f of files) { const img = await loadImage(f); images.push(drawScaled(img, 1280).toDataURL("image/jpeg", 0.85)); }
  const image = images[0] || null;
  bubble("me", `${images.length ? `<div class="shots">${images.map((im) => `<img src="${im}" alt="">`).join("")}</div>` : ""}${esc(text || "(photos)")}`);
  askTurns.push({ role: "me", text: (text || "") + (images.length ? ` (${images.length} photo${images.length === 1 ? "" : "s"})` : "") });
  $("#ask-text").value = ""; askFiles = []; showAskPreview();
  const history = askTurns.slice(-8, -1).map((t) => `${t.role === "me" ? "They" : "You"}: ${t.text}`).join("\n");
  const prompt = `You are the assistant inside a cheat-day food diary app. ${dayContext()}
${history ? `Recent conversation:\n${history}\n` : ""}They now say: "${text || "(photos, no words)"}"${images.length === 1 ? " (a photo is attached; use it for what the food is and the portion size, but trust their words over the photo for the name)" : images.length > 1 ? ` (${images.length} photos are attached, in order. They may show the dish, a menu or label for it, and what was left over at the end. Use the menu or label for names and stated nutrition, the dish photo for the portion, and subtract anything shown left over so the estimate is what was actually eaten.)` : ""}.

Decide what they want and fill exactly one of estimate / plan / edit / recipe / lighter (leave the others null), or kind=answer for a plain question:
- estimate: a food or plate to log, as one portion with honest kcal and macros.
- plan: 3 to 5 things for the rest of today that fit the calories left, close the macro gaps as far as sensible, and leave room for one treat.
- edit: they're correcting today's list ("I only had 2 eggs", "remove the toast", "add a banana") or logging exercise (action "workout": activity from Walk, Run, Cycle, Swim, Gym weights, HIIT, Yoga / stretch, Football, Tennis / padel, Hike, Rowing, Elliptical, Dance, Boxing, Climbing, Other; minutes; effort; for gym sessions the lifts as sets × reps at kg); match targets to the exact names given above.
- recipe: a dish to cook, with realistic ingredient amounts, kcal and macros per ingredient, and short method steps; respect any calorie or protein target they give and the calories they have left if they mention it.
- lighter: a lighter way to have something, with tips and the lighter serving's numbers.
Estimates use standard reference values. Keep reply short and friendly.`;
  const content = [];
  for (const im of images) content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: im.split(",")[1] } });
  content.push({ type: "text", text: prompt });
  const thinking = bubble("bot", `<span class="muted">Thinking…</span>`);
  try {
    const r = await askAI(ASSIST_SCHEMA, content);
    thinking.remove();
    askTurns.push({ role: "bot", text: r.reply, kind: r.kind, result: r });
    renderAssistant(r, image);
    saveChat();
  } catch (err) { thinking.innerHTML = `<span class="over">${esc(err.message || "Something went wrong")}</span>`; }
}
function statRow(kcal, p, c, f) { return `<div><span class="stat"><b>${fmt(kcal)}</b> kcal</span><span class="stat">P <b>${Math.round(p)}</b></span><span class="stat">C <b>${Math.round(c)}</b></span><span class="stat">F <b>${Math.round(f)}</b></span></div>`; }
function renderAssistant(r, image) {
  let html = esc(r.reply || "");
  const el = bubble("bot", html);
  if (r.kind === "estimate" && r.estimate) {
    const g = r.estimate, portion = num(g.portion_g) || 100;
    el.insertAdjacentHTML("beforeend", `<div class="card"><b>${esc(g.name)}</b> · ${fmt(portion)} ${g.unit || "g"}${statRow(g.kcal_total, g.protein_g, g.carbs_g, g.fat_g)}<p class="muted tiny">${esc(g.notes || "")} (${g.confidence} confidence)</p><button class="btn primary" data-act="add">Add to today</button><button class="btn mint" data-act="details">See the details first</button></div>`);
    const item = estimateToItem(g, image);
    el.querySelector("[data-act=add]").onclick = () => { draft = { ...item }; openShare(); };
    el.querySelector("[data-act=details]").onclick = () => { draft = { ...item }; openDetails("Estimate"); };
  }
  if (r.kind === "plan" && r.plan) {
    const ul = document.createElement("ul"); ul.className = "list";
    for (const sg of r.plan.suggestions || []) {
      const li = document.createElement("li");
      li.innerHTML = `<div class="body"><div class="name">${esc(sg.name)}</div><div class="detail">${esc(sg.amount)} · ${fmt(sg.kcal)} kcal · P ${Math.round(sg.protein_g)} · C ${Math.round(sg.carbs_g)} · F ${Math.round(sg.fat_g)} · ${esc(sg.why)}</div></div><button class="add" aria-label="Add"><svg><use href="#i-plus"/></svg></button>`;
      li.querySelector(".add").onclick = () => { const it = suggestionToItem(sg); draft = it.basis; openShare(it.kcal); };
      ul.appendChild(li);
    }
    el.appendChild(ul);
    el.insertAdjacentHTML("beforeend", `<p class="muted tiny">Tap ＋ to add one. Say "swap the treat" or "no dairy" to change it.</p>`);
  }
  if (r.kind === "edit" && r.edit) {
    const acts = (r.edit.actions || []).map(planTalkAction).filter(Boolean);
    if (acts.length) {
      el.insertAdjacentHTML("beforeend", `<ul class="method">${acts.map((a) => `<li>${esc(a.label)}</li>`).join("")}</ul><button class="btn primary" data-act="apply">Apply these changes</button>`);
      el.querySelector("[data-act=apply]").onclick = (e) => { for (const a of acts) a.run(); save(); e.target.textContent = "Done"; e.target.disabled = true; toast("Today updated"); };
    }
  }
  if (r.kind === "recipe" && r.recipe) {
    const rc = r.recipe, portions = num(rc.portions) || 1;
    const items = (rc.ingredients || []).map(recipeIngredientToItem);
    const total = items.reduce((a, it) => a + it.kcal, 0), mac = sumMacros(items);
    el.insertAdjacentHTML("beforeend", `<div class="card"><b>${esc(rc.name)}</b> · ${portions} portion${portions === 1 ? "" : "s"}${statRow(total / portions, mac.p / portions, mac.c / portions, mac.f / portions)}<p class="muted tiny">per portion</p>
      <ul class="list">${items.map((it) => `<li><div class="body"><div class="name">${esc(it.name)}</div><div class="detail">${fmt(it.grams)} ${it.unit || "g"} · ${fmt(it.kcal)} kcal</div></div></li>`).join("")}</ul>
      <ol class="method">${(rc.steps || []).map((st) => `<li>${esc(st)}</li>`).join("")}</ol>
      <p class="muted tiny">${esc(rc.notes || "")}</p><button class="btn primary" data-act="save">Save as a meal</button></div>`);
    const existing = state.meals.find((m) => m.name.trim().toLowerCase() === String(rc.name || "").trim().toLowerCase());
    if (existing) {
      el.querySelector("[data-act=save]").textContent = "Save as a new meal";
      el.querySelector("[data-act=save]").insertAdjacentHTML("beforebegin", `<button class="btn primary" data-act="update">Update "${esc(existing.name)}"</button>`);
      el.querySelector("[data-act=update]").onclick = async (e) => {
        if (!await ask(`Replace the ingredients of "${existing.name}" with this version?`)) return;
        existing.items = items; existing.portions = portions; existing.steps = rc.steps || existing.steps || []; existing.updatedAt = new Date().toISOString();
        save(); e.target.textContent = "Updated"; e.target.disabled = true; toast(`${existing.name} updated`);
      };
      el.querySelector("[data-act=save]").classList.remove("primary"); el.querySelector("[data-act=save]").classList.add("mint");
    }
    el.querySelector("[data-act=save]").onclick = (e) => {
      state.meals.unshift({ id: uid(), name: existing ? `${rc.name} (new)` : rc.name, portions, items, steps: rc.steps || [], saved: true, updatedAt: new Date().toISOString() });
      save(); e.target.textContent = "Saved to Meals"; e.target.disabled = true; toast(`${rc.name} is in your meals`);
    };
  }
  if (r.kind === "lighter" && r.lighter) {
    const l = r.lighter;
    el.insertAdjacentHTML("beforeend", `<div class="card"><b>${esc(l.name)}</b>${statRow(l.kcal_per_serving, l.protein_g, l.carbs_g, l.fat_g)}<ul class="tips">${(l.tips || []).map((t) => `<li>${esc(t)}</li>`).join("")}</ul><button class="btn primary" data-act="use">Add the lighter version</button></div>`);
    el.querySelector("[data-act=use]").onclick = () => {
      const serving = num(l.serving_size) || 100, kcal = Math.round(num(l.kcal_per_serving) || 0);
      const item = blankItem("claude"); item.name = l.name; item.unit = "g"; item.servingSize = Math.round(serving); item.unitLabel = "serving"; item.kcalPerServing = kcal; item.kcalPer100 = Math.round(kcal / serving * 100);
      item.p100 = Math.round((nz(l.protein_g) || 0) / serving * 1000) / 10; item.c100 = Math.round((nz(l.carbs_g) || 0) / serving * 1000) / 10; item.f100 = Math.round((nz(l.fat_g) || 0) / serving * 1000) / 10;
      draft = item; openShare();
    };
  }
  scrollThread();
}
function estimateToItem(g, image) {
  const item = blankItem("claude"), portion = num(g.portion_g) || 100;
  item.name = g.name || "Something"; item.unit = g.unit === "ml" ? "ml" : "g";
  item.kcalPer100 = Math.round((num(g.kcal_total) || 0) / portion * 100);
  item.servingSize = Math.round(portion); item.unitLabel = "portion"; item.kcalPerServing = Math.round(num(g.kcal_total) || 0);
  item.p100 = Math.round((nz(g.protein_g) || 0) / portion * 1000) / 10; item.c100 = Math.round((nz(g.carbs_g) || 0) / portion * 1000) / 10; item.f100 = Math.round((nz(g.fat_g) || 0) / portion * 1000) / 10;
  item.image = image || null;
  item.note = `AI estimate (${g.confidence || "medium"} confidence), not a label. ${g.notes || ""}`;
  return item;
}
function suggestionToItem(sg) {
  const hit = searchLocal(sg.name)[0];
  if (hit) return { basis: { ...foodItem(hit) }, kcal: Math.round(sg.kcal) };
  const item = blankItem("claude");
  item.name = `${sg.name} (${sg.amount})`; item.kcalPerServing = Math.round(sg.kcal); item.unitLabel = "portion";
  item.pServ = nz(sg.protein_g) || 0; item.cServ = nz(sg.carbs_g) || 0; item.fServ = nz(sg.fat_g) || 0;
  return { basis: item, kcal: Math.round(sg.kcal) };
}
/** A recipe ingredient becomes a meal item: our numbers where the food list knows it, the model's otherwise. */
function recipeIngredientToItem(x) {
  const grams = num(x.grams) || 100;
  const hit = searchLocal(x.name)[0];
  if (hit) {
    const f = foodItem(hit);
    return { id: uid(), ...basisOf(f), kcal: Math.round(grams * f.kcalPer100 / 100), grams: Math.round(grams * 10) / 10 };
  }
  const base = { name: x.name, source: "claude", unit: "g", kcalPer100: Math.round((nz(x.kcal) || 0) / grams * 100),
    p100: Math.round((nz(x.protein_g) || 0) / grams * 1000) / 10, c100: Math.round((nz(x.carbs_g) || 0) / grams * 1000) / 10, f100: Math.round((nz(x.fat_g) || 0) / grams * 1000) / 10 };
  return { id: uid(), ...base, kcal: Math.round(nz(x.kcal) || 0), grams: Math.round(grams * 10) / 10 };
}

// what's left, and what's short (no key needed)
function dayGaps() {
  const mac = sumMacros(state.day.items), g = state.goals || {};
  return { left: budgetToday() - usedKcal(), p: g.p ? Math.max(0, g.p - mac.p) : null, c: g.c ? Math.max(0, g.c - mac.c) : null, f: g.f ? Math.max(0, g.f - mac.f) : null, mac };
}
function showFits() {
  const d = dayGaps();
  const gaps = [];
  if (d.p != null) gaps.push(`protein ${d.p ? `${Math.round(d.p)} g to go` : "done"}`);
  if (d.c != null) gaps.push(`carbs ${d.c ? `${Math.round(d.c)} g to go` : "done"}`);
  if (d.f != null) gaps.push(`fat ${d.f ? `${Math.round(d.f)} g to go` : "done"}`);
  const el = bubble("bot", `<b>${d.left >= 0 ? fmt(d.left) + " kcal left" : fmt(-d.left) + " kcal over"}</b>${gaps.length ? ` · ${gaps.join(" · ")}` : ""}<br><span class="muted tiny">From the everyday food list, favouring what you're short on. Tap ＋ to add one.</span>`);
  if (d.left <= 50) { el.insertAdjacentHTML("beforeend", `<p class="muted">You're at your budget for today.</p>`); return; }
  const scored = [];
  for (const row of (typeof FOODS !== "undefined" ? FOODS : [])) {
    const it = foodItem(row);
    if (!it.servingSize || it.p100 == null) continue;
    const serves = it.servingSize, kcal = it.kcalPer100 * serves / 100;
    if (kcal < 40 || kcal > d.left * 0.45) continue;
    const gp = serves * it.p100 / 100, gc = serves * it.c100 / 100, gf = serves * it.f100 / 100;
    let score = 0;
    if (d.p != null && d.p > 0) score += Math.min(gp, d.p) / d.p * 3;
    if (d.c != null && d.c > 0) score += Math.min(gc, d.c) / d.c;
    if (d.f != null && d.f > 0) score += Math.min(gf, d.f) / d.f;
    if (d.p == null && d.c == null && d.f == null) score = gp / kcal * 10;
    score -= 1.5 * (kcal / d.left);
    scored.push({ it, kcal, score, key: row[0].split(",")[0].toLowerCase() });
  }
  scored.sort((a, b) => b.score - a.score);
  const seen = new Set(), picks = [];
  for (const x of scored) { if (seen.has(x.key)) continue; seen.add(x.key); picks.push(x); if (picks.length >= 8) break; }
  const ul = document.createElement("ul"); ul.className = "list";
  for (const x of picks) {
    const li = document.createElement("li");
    li.innerHTML = `<div class="body"><div class="name">${esc(x.it.name)}</div><div class="detail">${fmt1(x.it.servingSize)} ${x.it.unit} ${esc(x.it.unitLabel || "serving")} · ${fmt(x.kcal)} kcal · ${macroText(macrosFor(x.it, x.kcal))}</div></div><button class="add" aria-label="Add"><svg><use href="#i-plus"/></svg></button>`;
    li.querySelector(".add").onclick = () => { draft = { ...x.it }; openShare(Math.round(x.kcal)); };
    ul.appendChild(li);
  }
  if (!picks.length) ul.innerHTML = `<li class="muted">Nothing in the list fits in ${fmt(d.left)} kcal.</li>`;
  el.appendChild(ul); scrollThread();
}





// ---------------------------------------------------------------- body: scale readings, typed in or posted by an iPhone Shortcut

const BODY_METRICS = [
  { key: "weight", name: "Weight", unit: "kg", dp: 1 }, { key: "fat", name: "Body fat", unit: "%", dp: 1 }, { key: "muscle", name: "Muscle", unit: "kg", dp: 1 },
  { key: "lean", name: "Lean mass", unit: "kg", dp: 1 }, { key: "water", name: "Water", unit: "%", dp: 1 }, { key: "bone", name: "Bone", unit: "kg", dp: 1 },
  { key: "visceral", name: "Visceral fat", unit: "", dp: 1 }, { key: "bmr", name: "BMR", unit: "kcal", dp: 0 }, { key: "age", name: "Metabolic age", unit: "", dp: 0 }, { key: "bmi", name: "BMI", unit: "", dp: 1 }
];
let bodyMetric = "weight", bodyAt = 0;
const bodySorted = () => state.body.slice().sort((a, b) => String(a.day).localeCompare(String(b.day)));
const latestBody = () => { const rows = bodySorted(); return rows[rows.length - 1] || null; };
/** Keep one row per day; newer updatedAt wins. Weight flows into the workout burn estimate. */
function upsertBody(row) {
  const i = state.body.findIndex((r) => r.day === row.day);
  const merged = { ...(i >= 0 ? state.body[i] : {}), ...row };
  if (i >= 0) state.body[i] = merged; else state.body.push(merged);
  state.body = bodySorted().slice(-400);
  const lb = latestBody(); if (lb && lb.weight) state.weightKg = Math.round(lb.weight * 10) / 10;
}
async function pullBody(force) {
  const c = window.cloud; if (!(c && c.user)) return false;
  if (!force && Date.now() - bodyAt < 60000) return false;
  bodyAt = Date.now();
  let rows; try { rows = await c.bodyRows(dateMinus(400)); } catch (e) { return false; }
  let changed = false;
  for (const r of rows) {
    const mine = state.body.find((x) => x.day === r.day);
    if (mine && String(mine.updatedAt || "") >= String(r.updated_at || "")) continue;
    const row = { day: r.day, updatedAt: r.updated_at };
    for (const m of BODY_METRICS) if (r[m.key] != null) row[m.key] = +r[m.key];
    upsertBody(row); changed = true;
  }
  if (changed) save();
  return changed;
}
function lineChart(pts, dp) {
  if (pts.length < 2) return `<div class="none">${pts.length ? "One reading so far: the line starts with the next one." : "Nothing to chart yet."}</div>`;
  const W = 320, H = 150, px = 20, py = 22, vals = pts.map((p) => p.v);
  const lo = Math.min(...vals), hi = Math.max(...vals), pad = (hi - lo || Math.abs(hi) * 0.05 || 1) * 0.25;
  const x = (i) => px + i * (W - 2 * px) / (pts.length - 1), y = (v) => H - py - (v - (lo - pad)) / ((hi + pad) - (lo - pad)) * (H - 2 * py);
  const lab = (i) => (pts.length <= 8 || i === 0 || i === pts.length - 1 || i % Math.ceil(pts.length / 5) === 0) ? `<text x="${x(i)}" y="${H - 5}" text-anchor="middle" font-size="10" fill="#6b7770">${new Date(pts[i].day + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short" })}</text>` : "";
  const val = (i) => (pts.length <= 8 || i === 0 || i === pts.length - 1 || pts[i].v === hi || pts[i].v === lo) ? `<text x="${x(i)}" y="${y(pts[i].v) - 9}" text-anchor="middle" font-size="11" fill="#2f5d4b" font-weight="700">${fmt(pts[i].v, dp)}</text>` : "";
  return `<svg viewBox="0 0 ${W} ${H}"><polyline points="${pts.map((p, i) => `${x(i)},${y(p.v)}`).join(" ")}" fill="none" stroke="#2f5d4b" stroke-width="2.5" stroke-linejoin="round"/>${pts.map((p, i) => `<circle cx="${x(i)}" cy="${y(p.v)}" r="${pts.length > 20 ? 2.5 : 4}" fill="#2f5d4b"/>${val(i)}${lab(i)}`).join("")}</svg>`;
}
async function renderBody() {
  $("#bd-date").value = localDate();
  drawBody();
  vesyncStatus().then((linked) => { if (linked && Date.now() - vsSyncAt > 6 * 3600 * 1000) vesyncSync(true); });
  if (await pullBody(false)) drawBody();
}
// ---- the VeSync link
let vsSyncAt = 0, vsLinked = null, bdFormOpen = false;
$("#bd-form-toggle").onclick = () => { bdFormOpen = !bdFormOpen; $("#bd-form").classList.toggle("hidden", !bdFormOpen); if (bdFormOpen) $("#bd-weight").focus(); };
function showVesync(st) {
  const signed = !!(window.cloud && window.cloud.user);
  $("#vs-card").classList.toggle("hidden", !signed);
  if (!signed) return;
  vsLinked = !!(st && st.linked);
  $("#vs-form").classList.toggle("hidden", vsLinked);
  $("#vs-linked").classList.toggle("hidden", !vsLinked);
  // With a scale linked the typed-in form folds away behind a button
  $("#bd-form-toggle").classList.toggle("hidden", !vsLinked);
  if (vsLinked && !bdFormOpen) $("#bd-form").classList.add("hidden"); else $("#bd-form").classList.remove("hidden");
  if (!vsLinked) return;
  $("#vs-device").textContent = (st.device_name ? `to ${st.device_name}` : "(no scale found on the account yet)") + (st.region ? ` · ${st.region} server` : "");
  $("#vs-last").textContent = st.last_sync ? `Last sync ${ago(st.last_sync)} · ${st.last_count || 0} reading${st.last_count === 1 ? "" : "s"} on VeSync` : "Not synced yet";
  if (st.last_keys && st.last_keys.length) $("#vs-keys").textContent = st.last_keys.join(", ");
}
async function vesyncStatus() {
  if (!(window.cloud && window.cloud.user)) { showVesync(null); return false; }
  try { const st = await window.cloud.vesync("status"); showVesync(st); return !!st.linked; }
  catch (e) { showVesync(null); if (!e.missing) toast(e.message); return false; }
}
$("#vs-connect").onclick = async () => {
  const c = window.cloud, email = $("#vs-email").value.trim(), password = $("#vs-pass").value;
  if (!email || !password) { toast("Email and password, please"); return; }
  busy("Signing in to VeSync…");
  try {
    const r = await c.vesync("connect", { email, password, country: $("#vs-country").value || "GB" });
    $("#vs-pass").value = "";
    busy(false);
    if (r.device) toast(`Linked to ${r.device.name || "your scale"}`, 4000);
    else toast(`Linked, but no scale on that account yet (${(r.devices || []).length} device${(r.devices || []).length === 1 ? "" : "s"}). Weigh in with the VeSync app, then Sync.`, 7000);
    await vesyncStatus();
    if (r.device) vesyncSync(false);
  } catch (e) { busy(false); toast(e.missing ? "The VeSync link isn't deployed yet" : "Couldn't link: " + e.message, 6000); }
};
async function vesyncSync(quiet) {
  const c = window.cloud; if (!(c && c.user)) return;
  if (!quiet) busy("Pulling readings from VeSync…");
  try {
    const r = await c.vesync("sync");
    vsSyncAt = Date.now();
    if (!quiet) busy(false);
    if (r.keys && r.keys.length) $("#vs-keys").textContent = `Fields: ${r.keys.join(", ")}
From: ${r.from}
First row: ${JSON.stringify(r.sample)}`;
    else $("#vs-keys").textContent = `No rows. VeSync answered: ${JSON.stringify(r.raw || r)}`;
    if (!r.readings) { if (!quiet) toast(`VeSync returned no readings (tried ${r.from}). Open "What the scale sends" below for its exact reply.`, 7000); const d = $("#vs-linked details"); if (d) d.open = true; return; }
    const changed = await pullBody(true); drawBody(); await vesyncStatus();
    if (!quiet || changed) toast(`${r.readings} reading${r.readings === 1 ? "" : "s"} on VeSync · ${r.days} day${r.days === 1 ? "" : "s"}${r.latest && r.latest.weight ? ` · latest ${r.latest.weight} kg` : ""}`, 4500);
  } catch (e) { if (!quiet) { busy(false); toast("Sync failed: " + e.message, 6000); } if (/connect again|Not linked/.test(e.message)) vesyncStatus(); }
}
$("#vs-sync").onclick = () => vesyncSync(false);
$("#vs-unlink").onclick = async () => { if (!await ask("Unlink your VeSync account? Readings already pulled in stay.")) return; try { await window.cloud.vesync("disconnect"); toast("Unlinked"); vesyncStatus(); } catch (e) { toast(e.message); } };
function drawBody() {
  const rows = bodySorted(), lb = rows[rows.length - 1] || null;
  const have = BODY_METRICS.filter((m) => rows.some((r) => r[m.key] != null));
  const cutoff = dateMinus(30);
  const st = $("#body-stats");
  if (!lb) st.innerHTML = `<div style="grid-column:1/-1"><small>Nothing yet</small><b>Add your first reading below</b></div>`;
  else st.innerHTML = have.slice(0, 6).map((m) => {
    const cur = rows.filter((r) => r[m.key] != null), now = cur[cur.length - 1], before = cur.slice().reverse().find((r) => r.day <= cutoff) || cur[0];
    const d = before !== now ? now[m.key] - before[m.key] : 0, good = m.key === "muscle" || m.key === "lean" || m.key === "water" || m.key === "bone" || m.key === "bmr" ? d > 0 : d < 0;
    return `<div><small>${m.name}</small><b>${fmt(now[m.key], m.dp)}${m.unit ? ` <span class="muted tiny">${m.unit}</span>` : ""}${d ? `<span class="delta ${good ? "down" : "up"}">${d > 0 ? "+" : ""}${fmt(d, m.dp)}</span>` : ""}</b></div>`;
  }).join("");
  const chips = $("#body-metrics"); chips.innerHTML = "";
  if (!have.some((m) => m.key === bodyMetric) && have.length) bodyMetric = have[0].key;
  for (const m of have) { const b = document.createElement("button"); b.textContent = m.name; b.classList.toggle("on", m.key === bodyMetric); b.onclick = () => { bodyMetric = m.key; drawBody(); }; chips.appendChild(b); }
  const m = BODY_METRICS.find((x) => x.key === bodyMetric);
  $("#body-chart-title").textContent = `${m.name}${m.unit ? ` (${m.unit})` : ""}, last 30 readings`;
  $("#body-chart").innerHTML = lineChart(rows.filter((r) => r[m.key] != null).slice(-30).map((r) => ({ day: r.day, v: r[m.key] })), m.dp);
  const list = $("#body-list"); list.innerHTML = "";
  for (const r of rows.slice().reverse().slice(0, 30)) {
    const li = document.createElement("li");
    const bits = BODY_METRICS.filter((x) => r[x.key] != null).map((x) => `${x.name} ${fmt(r[x.key], x.dp)}${x.unit === "%" ? "%" : x.unit ? ` ${x.unit}` : ""}`);
    li.innerHTML = `<span class="thumb-sm"><svg><use href="#i-scale"/></svg></span><div class="body"><div class="name">${r.day === localDate() ? "Today" : new Date(r.day + "T12:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" })}</div><div class="detail">${esc(bits.join(" · "))}</div></div><button class="del" aria-label="Remove">✕</button>`;
    li.querySelector(".del").onclick = async () => { if (!await ask(`Remove the reading for ${r.day}?`)) return; state.body = state.body.filter((x) => x.day !== r.day); save(); drawBody(); };
    li.querySelector(".body").onclick = () => { $("#bd-date").value = r.day; for (const x of BODY_METRICS) { const el = $(`#bd-${x.key}`); if (el) el.value = r[x.key] ?? ""; } window.scrollTo({ top: $("#bd-date").getBoundingClientRect().top + window.scrollY - 90, behavior: "smooth" }); };
    list.appendChild(li);
  }
  $("#body-empty").classList.toggle("hidden", rows.length > 0);
}
$("#bd-save").onclick = async () => {
  const day = $("#bd-date").value || localDate(), row = { day, updatedAt: new Date().toISOString() };
  let any = false;
  for (const m of BODY_METRICS) { const el = $(`#bd-${m.key}`); if (!el) continue; const v = num(el.value); if (v != null) { row[m.key] = Math.round(v * 10) / 10; any = true; } }
  if (!any) { toast("Type at least one number"); return; }
  upsertBody(row); save(); drawBody();
  for (const m of BODY_METRICS) { const el = $(`#bd-${m.key}`); if (el) el.value = ""; }
  toast(`Saved${row.weight ? `: ${row.weight} kg` : ""}`);
  const c = window.cloud; if (c && c.user) { try { const { day: d, updatedAt, ...rest } = row; await c.saveBodyRow({ day: d, ...rest }); } catch (e) {} }
};
$("#body-refresh").onclick = async () => { if (vsLinked) { await vesyncSync(false); return; } busy("Checking for new readings…"); const ch = await pullBody(true); busy(false); drawBody(); toast(ch ? "New readings pulled in" : "Nothing new"); };
const randomToken = () => { const a = new Uint8Array(24); crypto.getRandomValues(a); return btoa(String.fromCharCode(...a)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); };
async function showToken(make) {
  const c = window.cloud; if (!(c && c.user)) { toast("Connecting a scale needs an account: sign in from Settings"); return; }
  busy("One moment…");
  let token = null;
  try { token = make ? null : await c.importToken(); if (!token) { token = randomToken(); await c.setImportToken(token); } }
  catch (err) { busy(false); toast("Not set up yet: " + c.explain(err), 6000); return; }
  busy(false);
  $("#bd-url").value = `${window.SUPABASE_CONFIG.url}/functions/v1/body-import?token=${token}`;
  $("#bd-token-box").classList.remove("hidden"); $("#bd-token").classList.add("hidden");
}
$("#bd-token").onclick = () => showToken(false);
$("#bd-token-new").onclick = async () => { if (!await ask("Make a new link? The Shortcut will need the new one pasted in.")) return; showToken(true); };
$("#bd-copy").onclick = async () => { try { await navigator.clipboard.writeText($("#bd-url").value); toast("Link copied"); } catch (e) { toast("Couldn't copy; long-press the field instead"); } };

// ---------------------------------------------------------------- goals, XP, levels and badges: the game layer

const XP = { log: 10, under: 25, protein: 15, workout: 20, pb: 30, post: 5, goal: 50 };
const LEVEL_NAMES = ["Newbie", "Regular", "Steady", "Committed", "Disciplined", "Machine", "Legend"];
const GOAL_DEFS = [
  { key: "under", name: "Days under budget", icon: "budget", tone: "green", max: 7, sub: (n) => `${n} day${n === 1 ? "" : "s"} this week` },
  { key: "protein", name: "Days hitting protein", icon: "search", tone: "coral", max: 7, sub: (n) => `${n} day${n === 1 ? "" : "s"} this week`, needs: () => !!(state.goals && state.goals.p) },
  { key: "workouts", name: "Workouts", icon: "dumbbell", tone: "coral", max: 14, sub: (n) => `${n} this week` },
  { key: "log", name: "Days logged", icon: "pen", tone: "sand", max: 7, sub: (n) => `${n} day${n === 1 ? "" : "s"} this week` }
];
/** A day's facts, from history or today. */
function dayFacts(date) {
  const today = localDate();
  if (date === today) { const m = sumMacros(state.day.items); return { date, logged: state.day.items.length > 0, kcal: usedKcal(), budget: budgetToday(), p: Math.round(m.p), workouts: (state.day.workouts || []).length, live: true }; }
  const h = state.history.find((x) => x.date === date);
  if (!h) return { date, logged: false, kcal: 0, budget: 0, p: 0, workouts: 0 };
  return { date, logged: Array.isArray(h.items) ? h.items.length > 0 : (h.kcal || 0) > 0, kcal: h.kcal || 0, budget: h.budget || 0, p: h.p || 0, workouts: (h.workouts || []).length };
}
const underBudget = (d) => d.logged && d.budget > 0 && d.kcal <= d.budget;
const hitProtein = (d) => d.logged && !!(state.goals && state.goals.p) && d.p >= state.goals.p;
function weekDates() {   // Monday to today
  const out = [], now = new Date(), dow = (now.getDay() + 6) % 7;
  for (let i = dow; i >= 0; i--) out.push(dateMinus(i));
  return out;
}
function weekProgress() {
  const days = weekDates().map(dayFacts);
  return { under: days.filter(underBudget).length, protein: days.filter(hitProtein).length, workouts: days.reduce((a, d) => a + d.workouts, 0), log: days.filter((d) => d.logged).length };
}
function logStreak() {
  let n = 0, i = dayFacts(localDate()).logged ? 0 : 1;
  for (; i < 400; i++) { if (dayFacts(dateMinus(i)).logged) n++; else break; }
  return n;
}
function underStreak() {
  let n = 0;
  for (let i = 1; i < 400; i++) { const d = dayFacts(dateMinus(i)); if (underBudget(d)) n++; else break; }
  return n;
}
/** XP is worked out from what's recorded, so it can't be double counted or lost. Today counts only for logging and workouts until it's over. */
function totalXp() {
  let xp = 0;
  for (const h of state.history) { const d = dayFacts(h.date); if (d.logged) xp += XP.log; if (underBudget(d)) xp += XP.under; if (hitProtein(d)) xp += XP.protein; xp += d.workouts * XP.workout; }
  const t = dayFacts(localDate()); if (t.logged) xp += XP.log; xp += t.workouts * XP.workout;
  xp += (state.pbCount || 0) * XP.pb + (state.postCount || 0) * XP.post + (state.goalWins || []).length * XP.goal;
  return xp;
}
function levelFor(xp) {
  const lvl = Math.floor(Math.sqrt(xp / 100)) + 1, base = (lvl - 1) ** 2 * 100, next = lvl ** 2 * 100;
  return { lvl, name: LEVEL_NAMES[Math.min(LEVEL_NAMES.length - 1, lvl - 1)], into: xp - base, span: next - base, next };
}
/** Weekly goals that have been reached are banked once per week so they keep paying XP. */
function bankGoals() {
  const wk = weekDates()[0], prog = weekProgress(), g = state.weekGoals; let banked = false;
  for (const def of GOAL_DEFS) {
    if (def.needs && !def.needs()) continue;
    const key = `${wk}:${def.key}`;
    if ((g[def.key] || 0) > 0 && prog[def.key] >= g[def.key] && !state.goalWins.includes(key)) { state.goalWins.push(key); banked = true; toast(`Goal reached: ${def.name.toLowerCase()} · +${XP.goal} XP`, 4000); }
  }
  if (banked) save();
}
const BADGES = [
  { id: "first", icon: "🌱", name: "First bite", how: "Log your first day", test: () => state.history.some((h) => dayFacts(h.date).logged) || dayFacts(localDate()).logged },
  { id: "streak7", icon: "🔥", name: "One week", how: "Log 7 days in a row", test: () => logStreak() >= 7 },
  { id: "streak30", icon: "🏆", name: "One month", how: "Log 30 days in a row", test: () => logStreak() >= 30 },
  { id: "under3", icon: "🎯", name: "On target", how: "3 days under budget in a row", test: () => underStreak() >= 3 },
  { id: "under14", icon: "💎", name: "Iron will", how: "14 days under budget in a row", test: () => underStreak() >= 14 },
  { id: "protein5", icon: "🥩", name: "Protein pro", how: "Hit your protein goal 5 times", test: () => state.history.filter((h) => hitProtein(dayFacts(h.date))).length >= 5 },
  { id: "wo1", icon: "👟", name: "Moved", how: "Log a workout", test: () => state.history.some((h) => (h.workouts || []).length) || (state.day.workouts || []).length > 0 },
  { id: "wo10", icon: "💪", name: "Ten strong", how: "Log 10 workouts", test: () => state.history.reduce((a, h) => a + (h.workouts || []).length, 0) + (state.day.workouts || []).length >= 10 },
  { id: "pb", icon: "🥇", name: "New best", how: "Beat a lifting PB", test: () => (state.pbCount || 0) >= 1 },
  { id: "post1", icon: "📸", name: "Shared", how: "Post to the feed", test: () => (state.postCount || 0) >= 1 },
  { id: "post10", icon: "🌟", name: "Influencer", how: "Post 10 times", test: () => (state.postCount || 0) >= 10 },
  { id: "goal", icon: "✅", name: "Goal getter", how: "Finish a weekly goal", test: () => (state.goalWins || []).length >= 1 },
  { id: "lvl5", icon: "👑", name: "Level 5", how: "Reach level 5", test: () => levelFor(totalXp()).lvl >= 5 }
];
function checkBadges() {
  bankGoals();
  const fresh = BADGES.filter((b) => !state.seenBadges.includes(b.id) && b.test());
  if (!fresh.length) return;
  for (const b of fresh) state.seenBadges.push(b.id);
  save();
  toast(`${fresh[0].icon} Badge earned: ${fresh[0].name}${fresh.length > 1 ? ` and ${fresh.length - 1} more` : ""}`, 4500);
}
function renderLevelCard() {
  const xp = totalXp(), L = levelFor(xp), prog = weekProgress(), g = state.weekGoals;
  const active = GOAL_DEFS.filter((d) => (g[d.key] || 0) > 0 && !(d.needs && !d.needs()));
  const done = active.filter((d) => prog[d.key] >= g[d.key]).length;
  $("#lv-title").textContent = `Level ${L.lvl} · ${L.name}`;
  $("#lv-sub").textContent = `${fmt(xp)} XP · ${L.next - xp} to next${active.length ? ` · ${done}/${active.length} goals this week` : ""}`;
  $("#lv-bar").style.width = `${Math.round(L.into / L.span * 100)}%`;
  checkBadges();
}
function renderGoals() {
  const xp = totalXp(), L = levelFor(xp), prog = weekProgress(), g = state.weekGoals, ls = logStreak(), us = underStreak();
  $("#g-level").innerHTML = `<div class="lv-num">${L.lvl}</div><div class="lv-name">${L.name}</div><div class="muted tiny">${fmt(xp)} XP · ${L.next - xp} more for level ${L.lvl + 1}</div><span class="bar"><span style="width:${Math.round(L.into / L.span * 100)}%"></span></span>
    <div class="streaks">${ls ? `<span>🔥 ${ls} day${ls === 1 ? "" : "s"} logged</span>` : ""}${us ? `<span>🎯 ${us} day${us === 1 ? "" : "s"} under budget</span>` : ""}${!ls && !us ? `<span>Log today to start a streak</span>` : ""}</div>`;
  const wk = weekDates(); $("#g-week-note").textContent = `Monday to Sunday · ${wk.length} day${wk.length === 1 ? "" : "s"} in so far. Tap a goal to change its target.`;
  const box = $("#g-goals"); box.innerHTML = "";
  for (const def of GOAL_DEFS) {
    const target = g[def.key] || 0, have = prog[def.key], off = target === 0, na = def.needs && !def.needs();
    const row = document.createElement("div"); row.className = `card goal-row ${!off && !na && have >= target ? "done" : ""}`;
    row.innerHTML = `<span class="circle ${def.tone}"><svg><use href="#i-${def.icon}"/></svg></span><div class="body"><div class="name">${def.name}</div><div class="prog">${na ? "Set a protein goal on the Daily budget screen first" : off ? "Off" : `${have} of ${target} · ${def.sub(target)}${have >= target ? " · done ✓" : ""}`}</div>${!off && !na ? `<span class="bar"><span style="width:${Math.min(100, have / target * 100)}%"></span></span>` : ""}</div>
      ${!na ? `<div class="count">${off ? "Off" : `${have}<small>/${target}</small>`}</div>` : ""}<svg class="chev"><use href="#i-chev"/></svg>`;
    if (!na) row.onclick = async () => {
      const n = await askNumber(`${def.name}: how many ${def.key === "workouts" ? "workouts" : "days"} a week?`, target, 0, def.max, "Off");
      if (n == null) return;
      g[def.key] = n; save(); renderGoals();
    };
    box.appendChild(row);
  }
  const bl = $("#g-badges"); bl.innerHTML = "";
  for (const b of BADGES) {
    const has = state.seenBadges.includes(b.id) || b.test();
    const d = document.createElement("div"); d.className = `badge ${has ? "" : "locked"}`;
    d.innerHTML = `<span class="ic">${b.icon}</span><b>${b.name}</b><small>${has ? "Earned" : b.how}</small>`;
    bl.appendChild(d);
  }
  $("#g-xp").innerHTML = [["Log a day", XP.log], ["Finish a day under budget", XP.under], ["Hit your protein goal", XP.protein], ["Log a workout", XP.workout], ["Beat a lifting PB", XP.pb], ["Post to the feed", XP.post], ["Finish a weekly goal", XP.goal]].map(([k, v]) => `<div><span>${k}</span><b>+${v} XP</b></div>`).join("");
  checkBadges();
}

// ---------------------------------------------------------------- send an item to a friend; they add it with one tap

async function friendList() {
  const c = window.cloud;
  if (!fr.friendships.length) { fr.friendships = await c.friendships(); }
  const ids = new Set();
  for (const f of fr.friendships) if (f.status === "accepted") { ids.add(f.requester); ids.add(f.addressee); }
  ids.delete(c.uid);
  const missing = [...ids].filter((id) => !fr.people[id]);
  if (missing.length) { const people = await c.profiles(missing); for (const p of people) fr.people[p.user_id] = p; }
  return [...ids].map((id) => ({ id, name: personName(id) })).sort((a, b) => a.name.localeCompare(b.name));
}
$("#share-send").onclick = async () => {
  const c = window.cloud; if (!(c && c.user)) { toast("Sending needs an account: sign in from Settings"); return; }
  const sheet = $("#send-sheet"); if (!sheet.classList.contains("hidden")) { sheet.classList.add("hidden"); return; }
  busy("Finding your friends…");
  let friends = [];
  try { friends = await friendList(); } catch (err) { busy(false); toast(c.explain(err)); return; }
  busy(false);
  const box = $("#send-friends"); box.innerHTML = "";
  if (!friends.length) { box.innerHTML = `<span class="muted tiny">No friends yet. Add someone from the Friends tab first.</span>`; }
  for (const f of friends) {
    const b = document.createElement("button"); b.className = "avatar-chip"; b.innerHTML = `${avatar(f.id, f.name)}<span>${esc(f.name)}</span>`;
    b.onclick = async () => {
      const kcal = Math.round(amountKcal), a = amountsFor(draft, kcal);
      b.disabled = true;
      try {
        await c.sendItem(f.id, { name: draft.name, kcal, grams: a.grams != null ? Math.round(a.grams) : null, unit: draft.unit || "g", photo: draft.photo || null, payload: basisOf(draft) });
        toast(`Sent ${draft.name} to ${f.name}`); sheet.classList.add("hidden");
      } catch (err) { b.disabled = false; toast("Couldn't send: " + c.explain(err), 5000); }
    };
    box.appendChild(b);
  }
  sheet.classList.remove("hidden");
  sheet.scrollIntoView({ block: "nearest", behavior: "smooth" });
};

let inbox = [], inboxAt = 0;
async function refreshInbox(force) {
  const c = window.cloud, box = $("#home-inbox");
  if (!(c && c.user)) { box.innerHTML = ""; return; }
  if (!force && Date.now() - inboxAt < 60000) { drawInbox(); return; }
  inboxAt = Date.now();
  try { inbox = await c.inbox(); } catch (err) { return; }   // the table may not exist yet; stay quiet
  const ids = new Set(inbox.map((x) => x.from_user)), missing = [...ids].filter((id) => !fr.people[id]);
  if (missing.length) { try { const people = await c.profiles(missing); for (const p of people) fr.people[p.user_id] = p; } catch (e) {} }
  drawInbox();
}
function drawInbox() {
  const box = $("#home-inbox"); box.innerHTML = "";
  for (const x of inbox) {
    const card = document.createElement("div"); card.className = "card inbox-card";
    card.innerHTML = `${x.photo ? `<img class="thumb-sm" src="${esc(x.photo)}" alt="">` : `<span class="thumb-sm"><svg><use href="#i-send"/></svg></span>`}<div class="body"><div class="from">${esc(personName(x.from_user))} sent you</div><div class="name">${esc(x.name)}</div><div class="detail">${x.grams != null ? `${x.grams} ${x.unit || "g"} · ` : ""}${fmt(x.kcal)} kcal</div></div><button class="add" aria-label="Add to today"><svg><use href="#i-plus"/></svg></button><button class="dismiss" aria-label="Dismiss">✕</button>`;
    const settle = async (status) => { inbox = inbox.filter((y) => y.id !== x.id); drawInbox(); try { await window.cloud.settleSend(x.id, status); } catch (e) {} };
    card.querySelector(".add").onclick = () => { draft = { ...(x.payload || { name: x.name, kcalPerServing: x.kcal, unitLabel: "portion" }), photo: x.photo || null, note: "" }; if (!draft.name) draft.name = x.name; settle("added"); openShare(x.kcal); };
    card.querySelector(".dismiss").onclick = async () => { if (!await ask(`Dismiss ${x.name} from ${personName(x.from_user)}?`)) return; settle("dismissed"); };
    box.appendChild(card);
  }
}

// ---------------------------------------------------------------- the feed: post what you're having, friends react, comment and repost

let composeWhat = null, composePhoto = null;
let feed = { posts: [], reactions: [], comments: [], people: {} };
const REACTS = ["👍", "❤️", "🔥", "😋"];
function openCompose(what, photo) { composeWhat = what; composePhoto = photo; $("#compose-caption").value = ""; go("compose"); }
function dishCard(w) {
  const meal = w.kind === "meal", n = w.portions || 1;
  const amt = meal ? `${n} portion${n === 1 ? "" : "s"} · ${fmt(w.kcal)} kcal each` : (w.grams != null ? `${w.grams} ${w.unit || "g"}` : "1 serving");
  return `<div class="dish"><span class="thumb-sm ${meal ? "tone-peach" : ""}"><svg><use href="#i-${meal ? "meal" : "search"}"/></svg></span><div class="dish-main"><span class="dish-name">${esc(w.name)}</span><span class="dish-amt">${amt}</span></div><div class="dish-kcal">${fmt(w.kcal)}<small>kcal</small></div></div>`;
}
function renderCompose() {
  const w = composeWhat; if (!w) { back(); return; }
  $("#compose-what").innerHTML = dishCard(w);
  showComposePhoto();
  if (!composePhoto) setTimeout(() => $("#compose-caption").focus(), 120);
}
function showComposePhoto() {
  const img = $("#compose-photo"), has = !!composePhoto;
  img.classList.toggle("hidden", !has); if (has) img.src = composePhoto;
  $("#compose-hint").classList.toggle("hidden", has);
  $("#compose-remove").classList.toggle("hidden", !has);
  $("#compose-cam").querySelector("span").textContent = has ? "Retake" : "Snap a pic";
}
$("#compose-media").onclick = () => $("#file-compose-cam").click();
async function composeAttach(file) { try { composePhoto = await thumbFromBig(file); showComposePhoto(); } catch (e) { toast("Couldn't read that photo"); } }
/** Feed photos can be a bit bigger than thumbnails: 640px square, roughly 40 KB. */
async function thumbFromBig(src) {
  const img = await loadImage(src instanceof Blob ? src : await (await fetch(src)).blob());
  const size = 640, c = document.createElement("canvas"); c.width = size; c.height = size;
  const iw = img.naturalWidth, ih = img.naturalHeight, m = Math.min(iw, ih);
  c.getContext("2d").drawImage(img, (iw - m) / 2, (ih - m) / 2, m, m, 0, 0, size, size);
  return c.toDataURL("image/jpeg", 0.72);
}
$("#compose-cam").onclick = () => $("#file-compose-cam").click();
$("#compose-lib").onclick = () => $("#file-compose-lib").click();
$("#file-compose-cam").addEventListener("change", (e) => { const f = e.target.files[0]; e.target.value = ""; if (f) composeAttach(f); });
$("#file-compose-lib").addEventListener("change", (e) => { const f = e.target.files[0]; e.target.value = ""; if (f) composeAttach(f); });
$("#compose-remove").onclick = () => { composePhoto = null; showComposePhoto(); };
$("#compose-go").onclick = async () => {
  const c = window.cloud; if (!c || !c.user) { toast("Sign in first"); return; }
  const w = composeWhat; if (!w) return;
  busy("Posting…");
  try {
    await c.createPost({ kind: w.kind, caption: $("#compose-caption").value.trim(), photo: composePhoto, name: w.name, kcal: w.kcal, macros: { p: w.p, c: w.c, f: w.f }, payload: w.kind === "meal" ? w.meal : w.basis, extra: w.kind === "meal" ? { portions: w.portions } : { grams: w.grams, unit: w.unit } });
    busy(false); toast("Posted"); composeWhat = null; composePhoto = null;
    state.postCount = (state.postCount || 0) + 1; save(); checkBadges();
    stack = ["home", "feed"]; show("feed");
  } catch (err) { busy(false); toast("Couldn't post: " + c.explain(err), 5000); }
};
function renderPicker() {
  const tl = $("#feed-pick-today"); tl.innerHTML = "";
  for (const it of state.day.items) {
    const li = document.createElement("li"); const m = macrosFor(it, it.kcal);
    li.innerHTML = `${it.photo || it.image ? `<img class="thumb-sm" src="${esc(it.photo || it.image)}" alt="">` : `<span class="thumb-sm"><svg><use href="#i-${iconFor(it.source)}"/></svg></span>`}<div class="body"><div class="name">${esc(it.name)}</div><div class="detail">${it.grams != null ? `${Math.round(it.grams)} ${it.unit || "g"} · ` : ""}${fmt(it.kcal)} kcal</div></div><svg class="chev"><use href="#i-chev"/></svg>`;
    li.onclick = () => openCompose({ kind: "food", name: it.name, kcal: Math.round(it.kcal), grams: it.grams != null ? Math.round(it.grams) : null, unit: it.unit || "g", p: m.p != null ? Math.round(m.p) : null, c: m.c != null ? Math.round(m.c) : null, f: m.f != null ? Math.round(m.f) : null, basis: basisOf(it) }, it.photo || null);
    tl.appendChild(li);
  }
  $("#feed-pick-today-empty").classList.toggle("hidden", state.day.items.length > 0);
  const ml = $("#feed-pick-meals"); ml.innerHTML = "";
  const meals = state.meals.filter((m) => m.saved).slice(0, 8);
  for (const m of meals) {
    const li = document.createElement("li"); const t = mealTotals(m), n = num(m.portions) || 1, hasMac = (t.p || 0) + (t.c || 0) + (t.f || 0) > 0;
    li.innerHTML = `${m.photo ? `<img class="thumb-sm" src="${esc(m.photo)}" alt="">` : `<span class="thumb-sm tone-peach"><svg><use href="#i-meal"/></svg></span>`}<div class="body"><div class="name">${esc(m.name)}</div><div class="detail">${n} portion${n === 1 ? "" : "s"} · ${fmt(t.kcal / n)} kcal each</div></div><svg class="chev"><use href="#i-chev"/></svg>`;
    li.onclick = () => openCompose({ kind: "meal", name: m.name, kcal: Math.round(t.kcal / n), portions: n, p: hasMac ? Math.round(t.p / n) : null, c: hasMac ? Math.round(t.c / n) : null, f: hasMac ? Math.round(t.f / n) : null, meal: { name: m.name, portions: n, items: m.items.map((it) => ({ ...basisOf(it), kcal: it.kcal, grams: it.grams })), steps: m.steps || [] } }, m.photo || null);
    ml.appendChild(li);
  }
  $("#feed-pick-meals-empty").classList.toggle("hidden", meals.length > 0);
}
$("#feed-prompt").onclick = () => { const pk = $("#feed-picker"); pk.classList.toggle("hidden"); if (!pk.classList.contains("hidden")) renderPicker(); };
async function renderFeed() {
  const c = window.cloud, signed = !!(c && c.user);
  $("#feed-signin").classList.toggle("hidden", signed);
  $("#feed-body").classList.toggle("hidden", !signed);
  if (!signed) return;
  $("#feed-picker").classList.add("hidden");
  $("#feed-me-avatar").innerHTML = avatar(c.uid, (c.profile && c.profile.display_name) || c.user.email || "Me");
  busy("Loading the feed…");
  try {
    feed.posts = await c.posts();
    const ids = feed.posts.map((p) => p.id);
    const [rx, cm] = await Promise.all([c.reactions(ids), c.comments(ids)]);
    feed.reactions = (rx || []).slice(); feed.comments = (cm || []).slice();
    const who = new Set(feed.posts.map((p) => p.owner).concat(feed.comments.map((x) => x.user_id), feed.reactions.map((x) => x.user_id)));
    const people = await c.profiles([...who]);
    feed.people = {}; for (const p of people) feed.people[p.user_id] = p;
    if (feed.people[c.uid]) $("#feed-me-avatar").innerHTML = avatar(c.uid, feed.people[c.uid].display_name);
  } catch (err) { busy(false); toast("Feed isn't set up yet: " + c.explain(err), 6000); return; }
  busy(false);
  drawFeed();
}
const feedName = (id) => (feed.people[id] && feed.people[id].display_name) || "Someone";
function ago(iso) { const s = (Date.now() - new Date(iso)) / 1000; if (s < 60) return "just now"; if (s < 3600) return `${Math.floor(s / 60)} min ago`; if (s < 86400) return `${Math.floor(s / 3600)} h ago`; const d = Math.floor(s / 86400); return d === 1 ? "yesterday" : `${d} days ago`; }
const openComments = new Set();
function drawFeed() {
  const c = window.cloud, me = c.uid, list = $("#feed-list"); list.innerHTML = "";
  $("#feed-empty").classList.toggle("hidden", feed.posts.length > 0);
  for (const p of feed.posts) {
    const card = document.createElement("article"); card.className = "card post";
    const meal = p.kind === "meal", ex = p.extra || {}, n = ex.portions || 1;
    const amt = meal ? `${n} portion${n === 1 ? "" : "s"} · ${fmt(p.kcal)} kcal each` : (ex.grams != null ? `${ex.grams} ${ex.unit || "g"}` : "1 serving");
    const mine = p.owner === me, who = mine ? "You" : feedName(p.owner);
    const rx = feed.reactions.filter((r) => r.post_id === p.id);
    const cm = feed.comments.filter((x) => x.post_id === p.id);
    const showAll = openComments.has(p.id) || cm.length <= 2, shown = showAll ? cm : cm.slice(-2);
    const mac = p.macros && p.macros.p != null ? `<div class="pills"><span>P ${p.macros.p} g</span><span>C ${p.macros.c} g</span><span>F ${p.macros.f} g</span></div>` : "";
    card.innerHTML = `<div class="who">${avatar(p.owner, feedName(p.owner))}<div><div class="name">${esc(who)}</div><div class="when">${ago(p.created_at)}${meal ? " · shared a meal" : ""}</div></div>${mine ? `<button class="more" aria-label="Delete post"><svg><use href="#i-more"/></svg></button>` : ""}</div>
      ${p.photo ? `<div class="media"><img src="${esc(p.photo)}" alt=""></div>` : `<div class="media none ${meal ? "meal" : ""}"><svg><use href="#i-${meal ? "meal" : "search"}"/></svg>${esc(p.name)}</div>`}
      <div class="body">
        ${p.caption ? `<div class="caption"><b>${esc(who)}</b>${esc(p.caption)}</div>` : ""}
        <div class="dish"><span class="thumb-sm ${meal ? "tone-peach" : ""}"><svg><use href="#i-${meal ? "meal" : "search"}"/></svg></span><div class="dish-main"><span class="dish-name">${esc(p.name)}</span><span class="dish-amt">${amt}</span></div><div class="dish-kcal">${fmt(p.kcal)}<small>kcal</small></div><button class="add" data-act="repost" aria-label="${meal ? "Save meal" : "Add to my day"}" title="${meal ? "Save to my meals" : "Add to my day"}"><svg><use href="#i-plus"/></svg></button></div>
        ${mac}
        <div class="actions"><div class="reacts">${REACTS.map((e) => { const k = rx.filter((r) => r.emoji === e).length, on = rx.some((r) => r.emoji === e && r.user_id === me); return `<button data-emoji="${e}" class="${on ? "on" : ""}" aria-label="React ${e}">${e}${k ? `<small>${k}</small>` : ""}</button>`; }).join("")}</div></div>
        <div class="comments">${!showAll ? `<button class="view-all">View all ${cm.length} comments</button>` : ""}${shown.map((x) => `<div class="comment">${avatar(x.user_id, feedName(x.user_id))}<span><b>${esc(x.user_id === me ? "You" : feedName(x.user_id))}</b>${esc(x.text)}</span>${x.user_id === me ? `<button class="del" data-comment="${x.id}" aria-label="Delete">✕</button>` : ""}</div>`).join("")}
          <div class="chat">${avatar(me, feedName(me))}<input type="text" placeholder="Add a comment…" maxlength="300" autocapitalize="sentences"><button class="btn primary slim" data-act="comment">Post</button></div></div>
      </div>`;
    const delBtn = card.querySelector(".who .more");
    if (delBtn) delBtn.onclick = async () => { if (!await ask("Delete this post?")) return; try { await c.deletePost(p.id); renderFeed(); } catch (e) { toast(c.explain(e)); } };
    const va = card.querySelector(".view-all"); if (va) va.onclick = () => { openComments.add(p.id); drawFeed(); };
    card.querySelector("[data-act=repost]").onclick = async () => {
      if (meal) {
        const m = p.payload || {};
        state.meals.unshift({ id: uid(), name: m.name || p.name, portions: +m.portions || 1, items: (m.items || []).map((it) => ({ ...it, id: uid() })), steps: m.steps || [], saved: true, copiedFrom: "post:" + p.id, updatedAt: new Date().toISOString() });
        save(); toast(`${p.name} saved to your meals`);
        if (await ask("Share it on to your friends with your own caption?")) openCompose({ kind: "meal", name: p.name, kcal: p.kcal, portions: n, p: p.macros && p.macros.p, c: p.macros && p.macros.c, f: p.macros && p.macros.f, meal: m }, p.photo || null);
      } else {
        draft = { ...(p.payload || { name: p.name, kcalPerServing: p.kcal, unitLabel: "portion" }), note: "" };
        openShare(p.kcal);
      }
    };
    card.querySelectorAll("[data-emoji]").forEach((b) => b.onclick = async () => {
      const e = b.dataset.emoji, on = b.classList.contains("on");
      try { if (on) await c.unreact(p.id, e); else await c.react(p.id, e); } catch (err) { toast(c.explain(err)); return; }
      if (on) feed.reactions = feed.reactions.filter((r) => !(r.post_id === p.id && r.user_id === me && r.emoji === e)); else feed.reactions.push({ post_id: p.id, user_id: me, emoji: e });
      drawFeed();
    });
    const input = card.querySelector(".chat input"), send = card.querySelector("[data-act=comment]");
    const doComment = async () => { const t = input.value.trim(); if (!t) return; try { const rows = await c.comment(p.id, t); feed.comments.push((rows && rows[0]) || { id: uid(), post_id: p.id, user_id: me, text: t, created_at: new Date().toISOString() }); openComments.add(p.id); drawFeed(); } catch (err) { toast(c.explain(err)); } };
    send.onclick = doComment; input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.target.blur(); doComment(); } });
    card.querySelectorAll("[data-comment]").forEach((b) => b.onclick = async () => { if (!await ask("Delete your comment?")) return; try { await c.deleteComment(b.dataset.comment); feed.comments = feed.comments.filter((x) => String(x.id) !== String(b.dataset.comment)); drawFeed(); } catch (err) { toast(c.explain(err)); } });
    list.appendChild(card);
  }
}
$("#feed-refresh").onclick = () => renderFeed();

// ---------------------------------------------------------------- workouts: activities with a burn estimate, and a lifting log

// Typical intensity (MET) per activity; kcal = MET x weight (kg) x hours. Rough by nature, and labelled so.
const ACTIVITIES = [
  ["Walk", 3.5], ["Run", 9.8], ["Cycle", 7.5], ["Swim", 7], ["Gym weights", 5, true], ["HIIT", 8], ["Yoga / stretch", 2.8],
  ["Football", 8], ["Tennis / padel", 7.3], ["Hike", 6], ["Rowing", 7], ["Elliptical", 5], ["Dance", 5.5], ["Boxing", 9], ["Climbing", 7], ["Other", 5]
];
const EFFORT = { easy: 0.8, moderate: 1, hard: 1.25 };
let wType = "Gym weights", wLifts = [];
function burnFor(type, minutes, effort) {
  const a = ACTIVITIES.find((x) => x[0] === type) || ["Other", 5];
  return Math.round(a[1] * EFFORT[effort || "moderate"] * (state.weightKg || 75) * (minutes / 60));
}
// ---- the week, streaks and history helpers
/** Workouts on each of the last n days (today included), newest first. */
function trainingDays(n) {
  const out = [], today = localDate();
  for (let i = 0; i < n; i++) {
    const date = dateMinus(i);
    const ws = date === today ? (state.day.workouts || []) : ((state.history.find((h) => h.date === date) || {}).workouts || []);
    out.push({ date, names: ws.map((w) => w.name), burned: ws.reduce((a, w) => a + (w.kcal || 0), 0), count: ws.length });
  }
  return out;
}
function streakDays() {
  const days = trainingDays(400); let n = 0, i = days[0].count ? 0 : 1;
  for (; i < days.length && days[i].count; i++) n++;
  return n;
}
/** Every session of an exercise: date, best set, estimated 1RM. Newest first. */
function exerciseSessions(name) {
  const key = name.toLowerCase(), out = [], today = localDate();
  const scan = (date, ws) => { for (const w of ws || []) for (const l of w.lifts || []) if ((l.exercise || "").toLowerCase() === key) { const kg = l.kg || 0, reps = l.reps || 1; out.push({ date, workout: w.name, sets: l.sets || 1, reps, kg, est1rm: kg ? Math.round(kg * (1 + reps / 30)) : 0 }); } };
  scan(today, state.day.workouts);
  for (const h of state.history) scan(h.date, h.workouts);
  return out;
}
function liftingSummary() {
  const ex = Object.values(state.exercises).sort((a, b) => String(b.lastUsed).localeCompare(String(a.lastUsed))).slice(0, 12);
  return ex.map((e) => `${e.name}: last ${e.sets}×${e.reps} @ ${e.kg} kg${e.best1rm ? `, best est. 1RM ${e.best1rm} kg` : ""}`).join("; ") || "no lifts logged yet";
}
const DAY_LETTERS = ["S", "M", "T", "W", "T", "F", "S"];
function renderWeek() {
  const days = trainingDays(7).reverse(), max = Math.max(1, ...days.map((d) => d.burned));
  const total = days.reduce((a, d) => a + d.burned, 0), count = days.reduce((a, d) => a + d.count, 0);
  $("#w-week").innerHTML = `<div class="bars">${days.map((d, i) => `<div class="bar ${d.count ? "on" : ""} ${i === 6 ? "today" : ""}" style="height:${Math.max(6, Math.round(d.burned / max * 100))}%" title="${d.date}: ${fmt(d.burned)} kcal"></div>`).join("")}</div>
    <div class="days">${days.map((d, i) => `<span><span class="tick">${d.count ? "✓" : ""}</span>${i === 6 ? "<b>Today</b>" : DAY_LETTERS[new Date(d.date + "T12:00").getDay()]}</span>`).join("")}</div>
    <div class="totals">This week: ${count} workout${count === 1 ? "" : "s"}, ${fmt(total)} kcal burned</div>`;
}

function renderWorkouts() {
  const ws = state.day.workouts || [], burned = burnedKcal(), streak = streakDays();
  $("#w-summary").innerHTML = `<div class="muted">Burned today</div><div class="result-big"><span>${fmt(burned)}</span><small> kcal</small></div>
    <div class="sub-line">${state.eatBack ? (burned ? `Budget now ${fmt(budgetToday())} kcal` : "Workouts stretch your budget") : "Recorded; budget unchanged (switch in Settings)"}${state.weightKg ? "" : " · assuming 75 kg; set your weight on the Daily budget screen"}</div>
    ${streak ? `<span class="streak">🔥 ${streak} day${streak === 1 ? "" : "s"} in a row</span>` : ""}`;
  renderWeek();
  const lb = latestBody();
  $("#wb-sub").textContent = lb ? `${lb.weight ? `${lb.weight} kg` : ""}${lb.fat ? ` · ${lb.fat}% fat` : ""}${lb.muscle ? ` · ${lb.muscle} kg muscle` : lb.lean ? ` · ${lb.lean} kg lean` : ""} · ${lb.day === localDate() ? "today" : new Date(lb.day + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short" })}` : "Weight, body fat, muscle: from your scale or typed in";
  const list = $("#w-list"); list.innerHTML = "";
  for (const w of ws) {
    const li = document.createElement("li");
    const lifts = (w.lifts || []).map((l) => `${l.exercise} ${l.sets}×${l.reps}${l.kg ? ` @ ${l.kg} kg` : ""}`).join(" · ");
    li.innerHTML = `<span class="thumb-sm tone-coral"><svg><use href="#i-dumbbell"/></svg></span><div class="body"><div class="name">${esc(w.name)}</div><div class="detail">${w.minutes} min · ${w.effort}${lifts ? `<div class="w-lifts">${esc(lifts)}</div>` : ""}</div></div><div class="kcal">${fmt(w.kcal)}</div><button class="del" aria-label="Remove">✕</button>`;
    li.querySelector(".del").onclick = async () => { if (!await ask(`Remove "${w.name}"?`)) return; state.day.workouts = ws.filter((x) => x.id !== w.id); save(); renderWorkouts(); };
    list.appendChild(li);
  }
  $("#w-empty").classList.toggle("hidden", ws.length > 0);
  // routines
  const rl = $("#w-routines"); rl.innerHTML = "";
  for (const r of state.routines) {
    const b = document.createElement("button"); b.textContent = `▶ ${r.name}`; b.title = "Tap to start, hold to remove";
    let t; b.onpointerdown = () => { t = setTimeout(async () => { t = null; if (await ask(`Remove the routine "${r.name}"?`)) { state.routines = state.routines.filter((x) => x.id !== r.id); save(); renderWorkouts(); } }, 600); };
    const clear = () => { if (t) { clearTimeout(t); t = null; } };
    b.onpointerup = () => { if (t) { clear(); startSession(r); } }; b.onpointerleave = clear; b.onpointercancel = clear; b.oncontextmenu = (e) => e.preventDefault();
    rl.appendChild(b);
  }
  if (!state.routines.length) { const b = document.createElement("button"); b.className = "new"; b.textContent = "No routines yet: finish a session and save it as one"; b.disabled = true; rl.appendChild(b); }
  // session and the plain form
  const live = !!state.session;
  $("#w-session").classList.toggle("hidden", !live);
  $("#w-start-gym").textContent = live ? "Session running" : "Start gym session";
  $("#w-start-gym").disabled = live;
  if (live) renderSession();
  const types = $("#w-types"); types.innerHTML = "";
  for (const [name, , lifting] of ACTIVITIES) { const b = document.createElement("button"); b.textContent = name; b.dataset.type = name; b.classList.toggle("on", name === wType); types.appendChild(b); }
  $("#w-lifting").classList.toggle("hidden", !(ACTIVITIES.find((x) => x[0] === wType) || [])[2]);
  renderSets(); updateEstimate();
  // personal bests
  const pl = $("#w-pbs"); pl.innerHTML = "";
  const exs = Object.values(state.exercises).sort((a, b) => String(b.lastUsed).localeCompare(String(a.lastUsed))).slice(0, 12);
  for (const e of exs) {
    const li = document.createElement("li");
    const best = e.bestSet ? `${e.bestSet.kg} kg × ${e.bestSet.reps}` : (e.kg ? `${e.kg} kg × ${e.reps}` : "bodyweight");
    li.innerHTML = `<span class="thumb-sm tone-coral"><svg><use href="#i-lift"/></svg></span><div class="body"><div class="name">${esc(e.name)}</div><div class="detail">Best ${best}${e.best1rm ? ` · est. 1RM ${e.best1rm} kg` : ""} · last ${e.sets}×${e.reps}${e.kg ? ` @ ${e.kg} kg` : ""}</div></div><svg class="chev"><use href="#i-chev"/></svg>`;
    li.onclick = () => openExercise(e.name);
    pl.appendChild(li);
  }
  $("#w-pbs-hint").classList.toggle("hidden", exs.length > 0);
  // quick add
  const ql = $("#w-recent"); ql.innerHTML = "";
  for (const r of state.recentWorkouts) {
    const li = document.createElement("li");
    li.innerHTML = `<span class="thumb-sm tone-coral"><svg><use href="#i-dumbbell"/></svg></span><div class="body"><div class="name">${esc(r.name)}</div><div class="detail">${r.minutes} min · ${r.effort}${(r.lifts || []).length ? ` · ${r.lifts.length} exercise${r.lifts.length === 1 ? "" : "s"}` : ""}</div></div><div class="kcal">${fmt(burnFor(r.type, r.minutes, r.effort))}</div><button class="add" aria-label="Log again"><svg><use href="#i-plus"/></svg></button>`;
    li.querySelector(".add").onclick = (e) => { e.stopPropagation(); logWorkout({ ...r, lifts: (r.lifts || []).map((l) => ({ ...l })) }); toast(`Logged ${r.name}`); };
    li.querySelector(".body").onclick = () => { wType = r.type; $("#w-min").value = r.minutes; $("#w-effort").value = r.effort; $("#w-name").value = r.name; wLifts = (r.lifts || []).map((l) => ({ ...l })); $("#w-form").classList.remove("hidden"); renderWorkouts(); window.scrollTo({ top: $("#w-types").getBoundingClientRect().top + window.scrollY - 80, behavior: "smooth" }); };
    ql.appendChild(li);
  }
  $("#w-recent-hint").classList.toggle("hidden", state.recentWorkouts.length > 0);
}
$("#w-log-toggle").onclick = () => { const f = $("#w-form"); f.classList.toggle("hidden"); if (!f.classList.contains("hidden")) window.scrollTo({ top: f.getBoundingClientRect().top + window.scrollY - 80, behavior: "smooth" }); };
$("#w-ask").addEventListener("click", (e) => { const b = e.target.closest("button"); if (!b) return; if (!aiAvailable()) { aiHelp(); return; } go("ask"); $("#ask-text").value = b.dataset.ask; sendAsk(); });
$("#w-types").addEventListener("click", (e) => { const b = e.target.closest("button"); if (!b) return; wType = b.dataset.type; renderWorkouts(); });
$("#w-min").addEventListener("input", updateEstimate);
$("#w-effort").addEventListener("change", updateEstimate);
function updateEstimate() {
  const min = num($("#w-min").value);
  $("#w-estimate").textContent = min ? `About ${fmt(burnFor(wType, min, $("#w-effort").value))} kcal for ${min} min of ${wType.toLowerCase()} (${$("#w-effort").value}). An estimate, like every tracker's.` : "";
}
function renderSets() {
  const box = $("#w-sets"); box.innerHTML = "";
  $("#w-save-routine").classList.toggle("hidden", !wLifts.some((l) => (l.exercise || "").trim()));
  if (!wLifts.length) { $("#w-volume").textContent = ""; return; }
  box.innerHTML = `<div class="set-head"><span>Exercise</span><span>Sets</span><span>Reps</span><span>kg</span><span></span></div>`;
  wLifts.forEach((l, i) => {
    const row = document.createElement("div"); row.className = "set-row";
    const known = state.exercises[(l.exercise || "").toLowerCase()];
    row.innerHTML = `<input type="text" placeholder="e.g. Squat" value="${esc(l.exercise || "")}" list="w-ex-list"><input type="number" inputmode="numeric" placeholder="3" value="${l.sets || ""}"><input type="number" inputmode="numeric" placeholder="8" value="${l.reps || ""}"><input type="number" inputmode="decimal" placeholder="${known ? known.kg : "kg"}" value="${l.kg || ""}"><button class="del" aria-label="Remove">✕</button>`;
    const [ex, sets, reps, kg] = row.querySelectorAll("input");
    ex.oninput = () => { l.exercise = ex.value; const k = state.exercises[ex.value.trim().toLowerCase()]; if (k && !sets.value) { sets.value = k.sets; reps.value = k.reps; kg.placeholder = k.kg; l.sets = k.sets; l.reps = k.reps; volume(); } $("#w-save-routine").classList.toggle("hidden", !wLifts.some((x) => (x.exercise || "").trim())); };
    sets.oninput = () => { l.sets = num(sets.value); volume(); }; reps.oninput = () => { l.reps = num(reps.value); volume(); }; kg.oninput = () => { l.kg = num(kg.value); volume(); };
    row.querySelector(".del").onclick = () => { wLifts.splice(i, 1); renderSets(); };
    box.appendChild(row);
  });
  ensureExerciseList();
  volume();
}
function ensureExerciseList() {
  if (!$("#w-ex-list")) { const dl = document.createElement("datalist"); dl.id = "w-ex-list"; document.body.appendChild(dl); }
  $("#w-ex-list").innerHTML = Object.values(state.exercises).map((e) => `<option value="${esc(e.name)}">`).join("");
}
function volume() {
  const v = wLifts.reduce((a, l) => a + (l.sets || 0) * (l.reps || 0) * (l.kg || 0), 0);
  $("#w-volume").textContent = v ? `Total volume ${fmt(v)} kg` : "";
}
$("#w-add-set").onclick = () => { wLifts.push({ exercise: "", sets: null, reps: null, kg: null }); renderSets(); setTimeout(() => { const rows = $$("#w-sets .set-row"); rows[rows.length - 1].querySelector("input").focus(); }, 50); };
$("#w-save-routine").onclick = () => {
  const lifts = wLifts.filter((l) => (l.exercise || "").trim()).map((l) => ({ exercise: l.exercise.trim(), sets: l.sets || 3, reps: l.reps || 8, kg: l.kg || 0 }));
  saveRoutine($("#w-name").value.trim(), lifts);
};
async function saveRoutine(suggested, exercises) {
  if (!exercises.length) { toast("Add some exercises first"); return; }
  const name = await askText("Name this routine", suggested || "Gym day"); if (!name) return;
  const id = uid();
  state.routines = [{ id, name: name.trim(), exercises }].concat(state.routines.filter((r) => r.name.toLowerCase() !== name.trim().toLowerCase())).slice(0, 12);
  save(); toast(`Saved "${name.trim()}"`); if (stack[stack.length - 1] === "workouts") renderWorkouts();
}
$("#w-save").onclick = () => {
  const minutes = num($("#w-min").value);
  if (!minutes) { toast("How many minutes?"); $("#w-min").focus(); return; }
  const lifts = wLifts.filter((l) => (l.exercise || "").trim()).map((l) => ({ exercise: l.exercise.trim(), sets: l.sets || 1, reps: l.reps || 1, kg: l.kg || 0 }));
  logWorkout({ type: wType, name: $("#w-name").value.trim() || wType, minutes, effort: $("#w-effort").value, lifts });
  $("#w-min").value = ""; $("#w-name").value = ""; wLifts = []; $("#w-form").classList.add("hidden");
  toast("Workout logged");
};

// ---- a live gym session: exercises pre-filled from last time, tick sets off, rest timer between them
const REST_SECONDS = 90;
let sessionTimer = null;
function lastFor(name) { return state.exercises[(name || "").trim().toLowerCase()] || null; }
function sessionExercise(name, tmpl) {
  const k = lastFor(name) || tmpl || { sets: 3, reps: 8, kg: 0 };
  const n = Math.max(1, Math.min(8, k.sets || 3));
  return { exercise: name, sets: Array.from({ length: n }, () => ({ reps: k.reps || 8, kg: k.kg || 0, done: false })) };
}
function startSession(routine) {
  if (state.session) { toast("A session is already running"); return; }
  state.session = { startedAt: Date.now(), name: routine ? routine.name : "", routineId: routine ? routine.id : null, restUntil: null,
    exercises: routine ? routine.exercises.map((e) => sessionExercise(e.exercise, e)) : [] };
  save(); $("#w-form").classList.add("hidden"); renderWorkouts();
  window.scrollTo({ top: $("#w-session").getBoundingClientRect().top + window.scrollY - 70, behavior: "smooth" });
}
$("#w-start-gym").onclick = () => startSession(null);
function tickSession() {
  const ss = state.session; if (!ss || document.body.dataset.view !== "workouts") { clearInterval(sessionTimer); sessionTimer = null; return; }
  const el = Math.floor((Date.now() - ss.startedAt) / 1000);
  $("#ws-clock").textContent = `${Math.floor(el / 60)}:${String(el % 60).padStart(2, "0")}`;
  const rest = $("#ws-rest"), left = ss.restUntil ? Math.ceil((ss.restUntil - Date.now()) / 1000) : 0;
  if (left > 0) { rest.classList.remove("hidden"); $("#ws-rest-time").textContent = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`; }
  else { if (!rest.classList.contains("hidden")) { rest.classList.add("hidden"); if (ss.restUntil) { ss.restUntil = null; save(false); if (navigator.vibrate) navigator.vibrate([120, 60, 120]); toast("Rest's over: next set"); } } }
}
function renderSession() {
  const ss = state.session; if (!ss) return;
  $("#ws-name").value = ss.name || "";
  const box = $("#ws-exercises"); box.innerHTML = "";
  ss.exercises.forEach((ex, i) => {
    const div = document.createElement("div"); div.className = "ws-ex";
    const last = lastFor(ex.exercise);
    div.innerHTML = `<div class="ex-head"><input type="text" placeholder="Exercise, e.g. Bench press" value="${esc(ex.exercise || "")}" list="w-ex-list"><button class="del" aria-label="Remove">✕</button></div>
      <div class="last">${last ? `Last time ${last.sets}×${last.reps}${last.kg ? ` @ ${last.kg} kg` : ""}${last.best1rm ? ` · best est. 1RM ${last.best1rm} kg` : ""}` : "New exercise"}</div>
      ${ex.sets.map((st, j) => `<div class="ws-set ${st.done ? "done" : ""}" data-j="${j}"><span>Set ${j + 1}</span><input type="number" inputmode="numeric" value="${st.reps || ""}" placeholder="reps"><input type="number" inputmode="decimal" value="${st.kg || ""}" placeholder="kg"><button class="tick" aria-label="Done">${st.done ? "✓" : "○"}</button></div>`).join("")}
      <button class="add-set">＋ set</button>`;
    const nameIn = div.querySelector(".ex-head input");
    nameIn.onchange = () => { ex.exercise = nameIn.value.trim(); const k = lastFor(ex.exercise); if (k) ex.sets.forEach((st) => { if (!st.done) { st.reps = k.reps; st.kg = k.kg; } }); save(false); renderSession(); };
    div.querySelector(".ex-head .del").onclick = async () => { if (ex.sets.some((st) => st.done) && !await ask(`Remove ${ex.exercise || "this exercise"} from the session?`)) return; ss.exercises.splice(i, 1); save(false); renderSession(); };
    div.querySelectorAll(".ws-set").forEach((row) => {
      const st = ex.sets[+row.dataset.j], [reps, kg] = row.querySelectorAll("input");
      reps.oninput = () => { st.reps = num(reps.value) || 0; save(false); sessionVolume(); }; kg.oninput = () => { st.kg = nz(kg.value) || 0; save(false); sessionVolume(); };
      row.querySelector(".tick").onclick = () => { st.done = !st.done; if (st.done) { st.reps = num(reps.value) || st.reps || 1; st.kg = nz(kg.value) || 0; ss.restUntil = Date.now() + REST_SECONDS * 1000; } save(false); renderSession(); tickSession(); };
    });
    div.querySelector(".add-set").onclick = () => { const prev = ex.sets[ex.sets.length - 1] || { reps: 8, kg: 0 }; ex.sets.push({ reps: prev.reps, kg: prev.kg, done: false }); save(false); renderSession(); };
    box.appendChild(div);
  });
  ensureExerciseList(); sessionVolume();
  if (!sessionTimer) sessionTimer = setInterval(tickSession, 1000);
  tickSession();
}
function sessionVolume() {
  const ss = state.session; if (!ss) return;
  const done = ss.exercises.reduce((a, ex) => a + ex.sets.filter((s) => s.done).length, 0);
  const v = ss.exercises.reduce((a, ex) => a + ex.sets.filter((s) => s.done).reduce((b, s) => b + (s.reps || 0) * (s.kg || 0), 0), 0);
  $("#ws-volume").textContent = done ? `${done} set${done === 1 ? "" : "s"} done${v ? ` · ${fmt(v)} kg lifted` : ""}` : "Tick each set as you finish it; the rest timer starts on its own.";
}
$("#ws-name").addEventListener("input", (e) => { if (state.session) { state.session.name = e.target.value; save(false); } });
$("#ws-add").onclick = () => { const ss = state.session; if (!ss) return; ss.exercises.push(sessionExercise("", null)); save(false); renderSession(); setTimeout(() => { const ins = $$("#ws-exercises .ex-head input"); ins[ins.length - 1].focus(); }, 50); };
$("#ws-rest-skip").onclick = () => { if (state.session) { state.session.restUntil = null; save(false); $("#ws-rest").classList.add("hidden"); } };
$("#ws-discard").onclick = async () => { if (!await ask("Discard this session? Nothing will be logged.")) return; state.session = null; save(); renderWorkouts(); };
$("#ws-finish").onclick = async () => {
  const ss = state.session; if (!ss) return;
  const lifts = [];
  for (const ex of ss.exercises) {
    if (!(ex.exercise || "").trim()) continue;
    let sets = ex.sets.filter((s) => s.done); if (!sets.length) sets = ex.sets;
    if (!sets.length) continue;
    const kg = Math.max(...sets.map((s) => s.kg || 0)), reps = Math.round(sets.reduce((a, s) => a + (s.reps || 0), 0) / sets.length) || 1;
    lifts.push({ exercise: ex.exercise.trim(), sets: sets.length, reps, kg, detail: sets.map((s) => ({ reps: s.reps || 0, kg: s.kg || 0 })) });
  }
  const minutes = Math.max(1, Math.round((Date.now() - ss.startedAt) / 60000));
  if (!lifts.length && !await ask(`Finish an empty ${minutes} min session?`)) return;
  const name = (ss.name || "").trim() || (ss.routineId && (state.routines.find((r) => r.id === ss.routineId) || {}).name) || "Gym session";
  const routineId = ss.routineId;
  state.session = null;
  logWorkout({ type: "Gym weights", name, minutes, effort: "moderate", lifts });
  toast(`Logged ${name}: ${minutes} min`);
  if (lifts.length && !routineId) setTimeout(async () => { if (await ask("Save this session as a routine, to start again next time?")) saveRoutine(name, lifts.map((l) => ({ exercise: l.exercise, sets: l.sets, reps: l.reps, kg: l.kg }))); }, 500);
};

// ---- one exercise: best set, estimated 1RM, a chart of the last sessions
let exerciseName = null;
function openExercise(name) { exerciseName = name; go("exercise"); }
function renderExercise() {
  const name = exerciseName; if (!name) { back(); return; }
  $("#ex-title").textContent = name;
  const ses = exerciseSessions(name), e = lastFor(name) || {};
  const best = ses.reduce((b, s) => (!b || s.kg > b.kg || (s.kg === b.kg && s.reps > b.reps)) ? s : b, null);
  const top = ses.reduce((b, s) => Math.max(b, s.est1rm), e.best1rm || 0);
  $("#ex-stats").innerHTML = `<div><small>Best set</small><b>${best && best.kg ? `${best.kg} kg × ${best.reps}` : "–"}</b></div><div><small>Est. one-rep max</small><b>${top ? `${top} kg` : "–"}</b></div><div><small>Sessions</small><b>${ses.length}</b></div><div><small>Last done</small><b>${ses[0] ? (ses[0].date === localDate() ? "Today" : new Date(ses[0].date + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short" })) : "–"}</b></div>`;
  const pts = ses.slice(0, 8).reverse().filter((s) => s.est1rm > 0);
  const ch = $("#ex-chart");
  if (pts.length < 2) ch.innerHTML = `<div class="none">${pts.length ? "One session so far: the line starts with the next one." : "No weighted sets yet."}</div>`;
  else {
    const W = 320, H = 150, px = 18, py = 22, lo = Math.min(...pts.map((p) => p.est1rm)) * 0.9, hi = Math.max(...pts.map((p) => p.est1rm)) * 1.05;
    const x = (i) => px + i * (W - 2 * px) / (pts.length - 1), y = (v) => H - py - (v - lo) / (hi - lo || 1) * (H - 2 * py);
    ch.innerHTML = `<svg viewBox="0 0 ${W} ${H}"><polyline points="${pts.map((p, i) => `${x(i)},${y(p.est1rm)}`).join(" ")}" fill="none" stroke="#2f5d4b" stroke-width="2.5" stroke-linejoin="round"/>${pts.map((p, i) => `<circle cx="${x(i)}" cy="${y(p.est1rm)}" r="4" fill="#2f5d4b"/><text x="${x(i)}" y="${y(p.est1rm) - 9}" text-anchor="middle" font-size="11" fill="#2f5d4b" font-weight="700">${p.est1rm}</text><text x="${x(i)}" y="${H - 5}" text-anchor="middle" font-size="10" fill="#6b7770">${new Date(p.date + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short" })}</text>`).join("")}</svg>`;
  }
  const list = $("#ex-sessions"); list.innerHTML = "";
  for (const s of ses.slice(0, 20)) {
    const li = document.createElement("li");
    li.innerHTML = `<span class="thumb-sm tone-coral"><svg><use href="#i-lift"/></svg></span><div class="body"><div class="name">${s.date === localDate() ? "Today" : new Date(s.date + "T12:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" })}</div><div class="detail">${s.sets}×${s.reps}${s.kg ? ` @ ${s.kg} kg` : ""} · ${esc(s.workout)}</div></div>${s.est1rm ? `<div class="kcal">${s.est1rm}<small> 1RM</small></div>` : ""}`;
    list.appendChild(li);
  }
  $("#ex-empty").classList.toggle("hidden", ses.length > 0);
}

/** Add a workout to today, remember it for quick add, and update exercise bests. */
function logWorkout(w) {
  const kcal = burnFor(w.type, w.minutes, w.effort);
  const pbs = [];
  for (const l of w.lifts || []) {
    const key = l.exercise.toLowerCase(), prev = state.exercises[key];
    const est1rm = l.kg ? Math.round(l.kg * (1 + l.reps / 30)) : 0;   // Epley estimate, for spotting a best
    if (prev && est1rm > (prev.best1rm || 0) && l.kg) pbs.push(`${l.exercise} (${l.kg} kg × ${l.reps})`);
    const prevBest = (prev && prev.bestSet) || null, better = l.kg && (!prevBest || l.kg > prevBest.kg || (l.kg === prevBest.kg && l.reps > prevBest.reps));
    state.exercises[key] = { name: l.exercise, sets: l.sets, reps: l.reps, kg: l.kg, best1rm: Math.max(est1rm, (prev && prev.best1rm) || 0), bestSet: better ? { kg: l.kg, reps: l.reps } : prevBest, lastUsed: new Date().toISOString() };
  }
  state.day.workouts = state.day.workouts || [];
  state.day.workouts.push({ id: uid(), type: w.type, name: w.name, minutes: w.minutes, effort: w.effort, kcal, lifts: w.lifts || [], at: new Date().toISOString() });
  const key = `${w.type}|${w.name}`.toLowerCase();
  state.recentWorkouts = [{ key, type: w.type, name: w.name, minutes: w.minutes, effort: w.effort, lifts: w.lifts || [] }].concat(state.recentWorkouts.filter((r) => r.key !== key)).slice(0, 10);
  save();
  if (pbs.length) { state.pbCount = (state.pbCount || 0) + pbs.length; save(false); setTimeout(() => toast(`New best: ${pbs.join(", ")}`, 5000), 400); }
  setTimeout(checkBadges, pbs.length ? 5600 : 600);
  if (stack[stack.length - 1] === "workouts") renderWorkouts();
}

// ---------------------------------------------------------------- item details

let draft = null;
function blankItem(source) {
  return { source, name: "", brand: "", unit: "g", kcalPer100: null, servingSize: null, kcalPerServing: null, packSize: null, piecesPerPack: null, image: null, note: "" };
}
function openManual() { draft = blankItem("manual"); openDetails("Enter the details"); }
function openDetails(title) {
  const d = draft;
  $("#details-title").textContent = title;
  $("#f-name").value = d.name || ""; $("#f-brand").value = d.brand || "";
  $("#f-unit").value = d.unit || "g";
  $("#f-kcal100").value = d.kcalPer100 ?? ""; $("#f-serving").value = d.servingSize ?? "";
  $("#f-kcalserving").value = d.kcalPerServing ?? ""; $("#f-pack").value = d.packSize ?? ""; $("#f-pieces").value = d.piecesPerPack ?? "";
  $("#f-piece").value = d.unitLabel || "";
  $("#f-p100").value = d.p100 ?? ""; $("#f-c100").value = d.c100 ?? ""; $("#f-f100").value = d.f100 ?? "";
  $("#d-thumb").innerHTML = d.image ? `<img src="${esc(d.image)}" alt="">` : `<svg><use href="#i-image"/></svg>`;
  $("#d-badge").classList.toggle("hidden", d.source !== "barcode");
  const note = $("#d-note"); note.textContent = d.note || ""; note.classList.toggle("hidden", !d.note);
  $("#details-lighter-out").innerHTML = "";
  syncUnitEcho();
  go("details");
}
function readDetails() {
  const d = draft;
  d.name = $("#f-name").value.trim(); d.brand = $("#f-brand").value.trim(); d.unit = $("#f-unit").value;
  d.kcalPer100 = num($("#f-kcal100").value); d.servingSize = num($("#f-serving").value);
  d.kcalPerServing = num($("#f-kcalserving").value); d.packSize = num($("#f-pack").value); d.piecesPerPack = num($("#f-pieces").value);
  d.unitLabel = $("#f-piece").value.trim().toLowerCase().replace(/s$/, "") || null;
  d.p100 = nz($("#f-p100").value); d.c100 = nz($("#f-c100").value); d.f100 = nz($("#f-f100").value);
  if (d.p100 == null && d.c100 == null && d.f100 == null) { d.p100 = null; d.c100 = null; d.f100 = null; }
  else { d.p100 = d.p100 || 0; d.c100 = d.c100 || 0; d.f100 = d.f100 || 0; }
  return d;
}
function syncUnitEcho() { $$(".unit-echo").forEach((el) => el.textContent = $("#f-unit").value); }
$("#f-unit").onchange = syncUnitEcho;
$("#details-next").onclick = () => {
  const d = readDetails();
  if (!d.kcalPer100 && !d.kcalPerServing) { toast("I need kcal per 100 or kcal per serving"); return; }
  if (!d.name) d.name = d.brand || "Something tasty";
  openShare();
};


// A single product made lighter: how to prepare or eat it with fewer calories (half the sachet, drain the oil, add veg...)
const PRODUCT_LIGHTER_SCHEMA = {
  type: "object",
  properties: {
    summary: { type: "string", description: "One or two sentences on the approach" },
    tips: { type: "array", items: { type: "string" }, description: "3 to 5 concrete, short tips in order of impact" },
    lighter_name: { type: "string", description: "e.g. 'Shin Ramyun, lighter (half seasoning, extra veg)'" },
    serving_size: { type: "number", description: "the lighter serving in g or ml as eaten" },
    kcal_per_serving: { type: "number" }, protein_g: { type: "number" }, carbs_g: { type: "number" }, fat_g: { type: "number" },
    notes: { type: "string", description: "assumptions in one short sentence" }
  },
  required: ["summary", "tips", "lighter_name", "serving_size", "kcal_per_serving", "protein_g", "carbs_g", "fat_g", "notes"],
  additionalProperties: false
};
function renderProductLighter(d, r) {
  const before = d.kcalPerServing || (d.kcalPer100 && d.servingSize ? Math.round(d.kcalPer100 * d.servingSize / 100) : null);
  const out = $("#details-lighter-out");
  out.innerHTML = `<div class="plan-card"><p><b>${before ? `${fmt(before)} → ` : ""}${fmt(r.kcal_per_serving)} kcal a serving</b></p><p>${esc(r.summary)}</p>
    <ul class="tips">${(r.tips || []).map((t) => `<li>${esc(t)}</li>`).join("")}</ul>
    <p class="muted tiny">${esc(r.notes || "")}</p>
    ${chatBox("plight", "Change something? e.g. no egg, or cut it further")}
    <button class="btn primary" id="details-lighter-use">Use this version</button></div>`;
  wireChat(out, "plight", (answer) => renderProductLighter(d, answer));
  out.querySelector("#details-lighter-use").onclick = () => {
    const serving = num(r.serving_size) || d.servingSize || 100, kcal = Math.round(num(r.kcal_per_serving) || 0);
    const item = blankItem("claude");
    item.name = r.lighter_name || `${d.name} (lighter)`; item.brand = d.brand; item.unit = d.unit; item.image = d.image;
    item.servingSize = Math.round(serving); item.unitLabel = "serving"; item.kcalPerServing = kcal;
    item.kcalPer100 = Math.round(kcal / serving * 100);
    item.p100 = Math.round((nz(r.protein_g) || 0) / serving * 1000) / 10; item.c100 = Math.round((nz(r.carbs_g) || 0) / serving * 1000) / 10; item.f100 = Math.round((nz(r.fat_g) || 0) / serving * 1000) / 10;
    item.note = "AI's lighter version, an estimate. " + (r.tips || []).slice(0, 2).join(" ");
    draft = item; openShare();
  };
}
$("#details-lighter").onclick = () => productAsk("Make it lighter: suggest realistic ways to prepare or eat it with fewer calories while keeping it enjoyable (part of a seasoning or oil sachet, draining, smaller portion, bulking with vegetables or protein, lighter accompaniments).");
$("#details-ask-go").onclick = () => { const t = $("#details-ask").value.trim(); if (t) { $("#details-ask").value = ""; productAsk(t); } };
$("#details-ask").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.target.blur(); $("#details-ask-go").click(); } });
async function productAsk(instruction) {
  if (!aiAvailable()) { aiHelp(); return; }
  const d = readDetails();
  const facts = [`kcal per 100 ${d.unit}: ${d.kcalPer100 ?? "unknown"}`, d.servingSize ? `serving ${d.servingSize} ${d.unit}` : null, d.kcalPerServing ? `${d.kcalPerServing} kcal per serving` : null,
    d.p100 != null ? `per 100: protein ${d.p100} g, carbs ${d.c100} g, fat ${d.f100} g` : null, d.packSize ? `pack ${d.packSize} ${d.unit}` : null].filter(Boolean).join("; ");
  const prompt = `${(state.notes || "").trim() ? `About this person: ${state.notes.trim()}\n` : ""}Product: "${d.name}"${d.brand ? ` by ${d.brand}` : ""}. Label facts: ${facts || "none"}.
The person asks: "${instruction}"
Answer that with concrete tips (3 to 5, most useful first), then estimate the resulting version as one serving: its weight as eaten, kcal and macros; name it to reflect the change (lighter_name). If their request doesn't change the food, keep the numbers and say so in the summary. Estimates, honestly labelled.`;
  busy("Thinking…");
  try {
    const r = await askAI(PRODUCT_LIGHTER_SCHEMA, [{ type: "text", text: prompt }]);
    busy(false);
    chats.plight = { schema: PRODUCT_LIGHTER_SCHEMA, basePrompt: prompt, turns: [{ ask: "(first version)", answer: r }] };
    renderProductLighter(d, r);
  } catch (err) { busy(false); toast(err.message || "Claude couldn't lighten that", 5000); }
};

// ---------------------------------------------------------------- one scanner: barcodes live, labels on demand

let scanStream = null, scanning = false, zxReader = null, nativeDetector = null;
let photoMode = "auto";   // what a fallback photo is for: "auto" (barcode, then label) or "label"
const cameraPossible = () => !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.isSecureContext);
const NATIVE_FORMATS = ["ean_13", "ean_8", "upc_a", "upc_e", "code_128", "code_39", "itf", "qr_code"];
function zxingHints() {
  const F = ZXing.BarcodeFormat, h = new Map();
  h.set(ZXing.DecodeHintType.POSSIBLE_FORMATS, [F.EAN_13, F.EAN_8, F.UPC_A, F.UPC_E, F.CODE_128, F.CODE_39, F.ITF, F.QR_CODE]);
  h.set(ZXing.DecodeHintType.TRY_HARDER, true);
  return h;
}
function zxingReader() {
  if (!zxReader) { zxReader = new ZXing.MultiFormatReader(); zxReader.setHints(zxingHints()); }
  return zxReader;
}
/** Decode one canvas with ZXing; null when nothing is there. */
function zxingDecodeCanvas(canvas) {
  try {
    const source = new ZXing.HTMLCanvasElementLuminanceSource(canvas);
    const bitmap = new ZXing.BinaryBitmap(new ZXing.HybridBinarizer(source));
    const res = zxingReader().decodeWithState(bitmap);
    return res ? res.getText() : null;
  } catch (e) { return null; }
}
let camToken = 0;
const onScanView = () => stack[stack.length - 1] === "scan";
const busyShown = () => !$("#busy").classList.contains("hidden");
async function startCamera() {
  const token = ++camToken;
  stopCamera();
  $("#scan-fallback").classList.add("hidden");
  $("#barcode-manual").classList.add("hidden");
  $("#scan-hint").textContent = "Point at a barcode. For a nutrition table, tap Read the label.";
  if (!cameraPossible()) { $("#scan-fallback").classList.remove("hidden"); return; }
  const video = $("#video");
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment", width: { ideal: 1920 }, height: { ideal: 1080 } }, audio: false });
  } catch (err) {
    console.warn("camera", err);
    if (token === camToken) $("#scan-fallback").classList.remove("hidden");
    return;
  }
  // The user may have gone back while the camera was opening: don't leave a hidden stream running.
  if (token !== camToken || !onScanView()) { stream.getTracks().forEach((t) => t.stop()); return; }
  scanStream = stream;
  video.srcObject = stream;
  await video.play().catch(() => {});
  // iOS ends the stream when the app is backgrounded or another app takes the camera: bring it back.
  const track = stream.getVideoTracks()[0];
  if (track) track.addEventListener("ended", () => { if (token === camToken && onScanView() && !busyShown()) startCamera(); });
  if (!nativeDetector && "BarcodeDetector" in window) { try { nativeDetector = new BarcodeDetector({ formats: NATIVE_FORMATS }); } catch (e) {} }
  scanning = true;
  fitVideo();
  scanLoop(video, token);
}
async function scanLoop(video, token) {
  let frame = 0, autoReads = 0, quietSince = Date.now();
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  while (scanning && token === camToken) {
    if (video.readyState >= 2 && video.videoWidth && !busyShown()) {
      let code = null;
      if (nativeDetector) {
        try { const found = await nativeDetector.detect(video); if (found.length) code = found[0].rawValue; } catch (e) {}
      }
      if (!code) {
        // Upright and sideways every frame; every third pass also zooms on the middle for small barcodes.
        const zoom = frame % 3 === 2;
        code = zxingDecodeCanvas(frameCanvas(video, 1280, 0, zoom)) || zxingDecodeCanvas(frameCanvas(video, 1280, 90, zoom));
      }
      if (code && token === camToken) {
        $("#scan-hint").textContent = `Found ${code}, looking it up…`;
        stopCamera();
        lookupBarcode(code);
        return;
      }
      frame++;
      // No barcode for a while: maybe it's a nutrition table. Let Claude look, at most twice.
      const quiet = Date.now() - quietSince;
      if (quiet > 4500 && autoReads < 2 && aiAvailable()) {
        autoReads++; quietSince = Date.now();
        $("#scan-hint").textContent = "No barcode yet, checking for a nutrition table…";
        const found = await autoReadLabel(video, token);
        if (found || token !== camToken) return;
        $("#scan-hint").textContent = autoReads < 2 ? "Not a nutrition table yet. Get closer, or keep looking for the barcode." : "Point at the barcode, or tap Read the label when the table is in view.";
      } else if (quiet > 4500 && !aiAvailable() && autoReads === 0) {
        autoReads = 1;
        $("#scan-hint").textContent = "No barcode? A nutrition table can be read too, with a free AI key in Settings.";
      }
    }
    await sleep(120);
  }
}
/** Sends the current frame to Claude; true if it was a nutrition table and the product page opened. */
async function autoReadLabel(video, token) {
  const blob = await new Promise((res) => drawScaled(video, 1600).toBlob(res, "image/jpeg", 0.9));
  busy("Checking for a nutrition table…");
  try {
    const item = await readLabelWithClaude(blob, true);
    busy(false);
    if (!item) return false;
    if (token !== camToken) return true;
    stopCamera();
    draft = item;
    openDetails("Nutrition (from photo)");
    return true;
  } catch (err) { busy(false); console.warn("auto label", err); return false; }
}
function frameCanvas(video, maxW, rot, zoom) {
  const vw = video.videoWidth, vh = video.videoHeight;
  const sx = zoom ? vw * 0.2 : 0, sy = zoom ? vh * 0.2 : 0, sw = zoom ? vw * 0.6 : vw, sh = zoom ? vh * 0.6 : vh;
  const scale = Math.min(1, maxW / Math.max(sw, sh));
  const w = Math.round(sw * scale), h = Math.round(sh * scale);
  const c = document.createElement("canvas");
  if (rot === 90) { c.width = h; c.height = w; } else { c.width = w; c.height = h; }
  const ctx = c.getContext("2d", { willReadFrequently: true });
  ctx.translate(c.width / 2, c.height / 2); ctx.rotate(rot * Math.PI / 180);
  ctx.drawImage(video, sx, sy, sw, sh, -w / 2, -h / 2, w, h);
  return c;
}
function stopCamera() {
  scanning = false;
  if (scanStream) { try { scanStream.getTracks().forEach((t) => t.stop()); } catch (e) {} scanStream = null; }
  const v = $("#video"); if (v.srcObject) v.srcObject = null;
}
// Coming back to the app on the scan screen: the camera needs reopening.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  if (rollDay() && stack[stack.length - 1] === "home") renderHome();
  if (onScanView() && !busyShown()) startCamera();
});

$("#scan-photo").onclick = () => { photoMode = "auto"; $("#file-scan").click(); };
$("#scan-library").onclick = () => { photoMode = "auto"; $("#file-scan-lib").click(); };
$("#file-scan-lib").addEventListener("change", (e) => { const f = e.target.files[0]; e.target.value = ""; if (f) handleScanPhoto(f); });
$("#scan-label").onclick = () => {
  if (!aiAvailable()) { aiHelp(); return; }
  const video = $("#video");
  if (scanStream && video.videoWidth) {
    drawScaled(video, 1600).toBlob((blob) => readLabel(blob), "image/jpeg", 0.9);
  } else {
    photoMode = "label"; $("#file-scan").click();
  }
};
$("#barcode-manual-toggle").onclick = () => { $("#barcode-manual").classList.toggle("hidden"); $("#code-input").focus(); };
$("#code-go").onclick = () => { const c = $("#code-input").value.replace(/\D/g, ""); if (c) lookupBarcode(c); };
$("#code-input").addEventListener("keydown", (e) => { if (e.key === "Enter") $("#code-go").click(); });

$("#file-scan").addEventListener("change", (e) => { const file = e.target.files[0]; e.target.value = ""; if (file) handleScanPhoto(file); });
async function handleScanPhoto(file) {
  if (photoMode === "label") { readLabel(file); return; }
  busy("Looking for a barcode…");
  let code = null;
  try { code = await decodeBarcodeFromFile(file); } catch (err) { console.error(err); }
  busy(false);
  if (code) { lookupBarcode(code); return; }
  if (aiAvailable()) { toast("No barcode found, reading it as a label instead"); readLabel(file); return; }
  toast("No barcode found. Try closer and flatter, or type the number.", 4000);
  $("#barcode-manual").classList.remove("hidden");
}

async function decodeBarcodeFromFile(file) {
  const img = await loadImage(file);
  if ("BarcodeDetector" in window) {
    try {
      const det = new BarcodeDetector({ formats: ["ean_13", "ean_8", "upc_a", "upc_e", "code_128", "code_39", "itf", "qr_code"] });
      const found = await det.detect(img);
      if (found.length) return found[0].rawValue;
    } catch (e) {}
  }
  for (const width of [1400, 1000, 700]) {
    for (const rot of [0, 90]) {
      const code = zxingDecodeCanvas(drawScaled(img, width, rot));
      if (code) return code;
    }
  }
  return null;
}
/** A small square thumbnail (data URL) from a File or data URL: about 10 KB, fine to keep and sync. */
async function thumbFrom(src) {
  const img = await loadImage(src instanceof Blob ? src : await (await fetch(src)).blob());
  const size = 256, c = document.createElement("canvas"); c.width = size; c.height = size;
  const iw = img.naturalWidth, ih = img.naturalHeight, m = Math.min(iw, ih);
  c.getContext("2d").drawImage(img, (iw - m) / 2, (ih - m) / 2, m, m, 0, 0, size, size);
  return c.toDataURL("image/jpeg", 0.7);
}
function loadImage(file) {
  return new Promise((resolve, reject) => {
    const img = new Image(); img.onload = () => resolve(img); img.onerror = reject; img.src = URL.createObjectURL(file);
  });
}
function drawScaled(img, maxW, rot = 0) {
  const iw = img.naturalWidth || img.videoWidth, ih = img.naturalHeight || img.videoHeight;
  const scale = Math.min(1, maxW / Math.max(iw, ih));
  const w = Math.round(iw * scale), h = Math.round(ih * scale);
  const c = document.createElement("canvas");
  if (rot === 90) { c.width = h; c.height = w; } else { c.width = w; c.height = h; }
  const ctx = c.getContext("2d", { willReadFrequently: true });
  ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, c.width, c.height);   // transparent PNGs would otherwise read as black
  ctx.translate(c.width / 2, c.height / 2); ctx.rotate(rot * Math.PI / 180); ctx.drawImage(img, -w / 2, -h / 2, w, h);
  return c;
}
// ---------------------------------------------------------------- Open Food Facts

/** "1 slice (44 g)", "2 biscuits (33g)", "per bar" -> what one piece is and weighs. */
function pieceFromServing(text) {
  const t = String(text || "").toLowerCase();
  const m = t.match(/(\d+(?:[.,]\d+)?)?\s*(slices?|biscuits?|cookies?|bars?|pieces?|eggs?|sausages?|nuggets?|wraps?|rolls?|crackers?|squares?|sweets?|cans?|bottles?|pots?|scoops?|buns?|pancakes?|waffles?|muffins?|crumpets?|bagels?|fingers?|sticks?|cubes?|balls?|tablets?)\b/);
  if (!m) return null;
  const count = m[1] ? parseFloat(m[1].replace(",", ".")) : 1;
  const g = t.match(/(\d+(?:[.,]\d+)?)\s*(g|ml)\b/);
  return { count: count || 1, word: m[2].replace(/s$/, ""), grams: g ? parseFloat(g[1].replace(",", ".")) : null };
}
const CATEGORY_PIECES = [
  [/sliced-bread|\bbreads?\b|loaf|loaves|toast/, "slice", 40], [/bread-rolls|\bbuns\b|baps|burger-buns|brioche/, "roll", 60],
  [/crumpets/, "crumpet", 45], [/bagels/, "bagel", 85], [/tortillas|wraps/, "wrap", 60], [/pancakes/, "pancake", 40],
  [/biscuits|cookies|shortbread|digestives/, "biscuit", 12], [/crackers|crispbreads|rice-cakes/, "cracker", 8], [/wafers/, "wafer", 10],
  [/cereal-bars|protein-bars|chocolate-bars|candy-bars|snack-bars|granola-bars/, "bar", null], [/sausages|frankfurters|hot-dogs/, "sausage", 60],
  [/\beggs\b/, "egg", 55], [/fish-fingers/, "finger", 28], [/chicken-nuggets/, "nugget", 18], [/cheese-slices|sliced-cheeses/, "slice", 20],
  [/sliced-hams|\bhams\b|cooked-meats|charcuterie/, "slice", 25], [/muffins/, "muffin", 100], [/croissants/, "croissant", 60], [/doughnuts|donuts/, "doughnut", 60],
  [/ice-cream-bars|ice-lollies|ice-pops/, "lolly", 70], [/yogurts|desserts/, "pot", null], [/beverages|drinks|sodas|beers|ciders|wines/, "can", null]
];
function pieceFromCategories(tags) {
  const t = (Array.isArray(tags) ? tags : []).join(" ").toLowerCase();
  for (const [re, word, g] of CATEGORY_PIECES) if (re.test(t)) return { word, defaultG: g };
  return null;
}

/** Turn an Open Food Facts product into one of our items. */
function itemFromProduct(p) {
  const n = p.nutriments || {};
  const item = blankItem("barcode");
  const energy = energyFrom(n);
  item.name = p.product_name_en || p.product_name || "";
  item.brand = Array.isArray(p.brands) ? p.brands.join(", ") : (p.brands || "");
  item.image = p.image_front_small_url || null;
  const q = ((p.product_quantity_unit || "") + " " + (p.quantity || "")).toLowerCase();
  item.unit = /\bml\b|\bl\b|litre|liter/.test(q) ? "ml" : "g";
  item.kcalPer100 = energy.per100 ? Math.round(energy.per100) : null;
  item.servingSize = num(p.serving_quantity) || num((p.serving_size || "").match(/(\d+(?:[.,]\d+)?)\s*(g|ml)/i)?.[1]?.replace(",", "."));
  item.kcalPerServing = energy.perServing ? Math.round(energy.perServing) : null;
  // A per-serving figure that doesn't match per-100 x serving size is usually kJ typed into the kcal box.
  if (item.kcalPerServing && item.kcalPer100 && item.servingSize) {
    const expected = item.kcalPer100 * item.servingSize / 100;
    if (item.kcalPerServing > expected * 2 && Math.abs(item.kcalPerServing / 4.184 - expected) / expected < 0.25) { item.kcalPerServing = Math.round(item.kcalPerServing / 4.184); energy.fixed = true; }
  }
  item.packSize = num(p.product_quantity);
  item.p100 = nz(n.proteins_100g); item.c100 = nz(n.carbohydrates_100g); item.f100 = nz(n.fat_100g);
  if (item.p100 == null && item.servingSize && nz(n.proteins_serving) != null) {
    const k = 100 / item.servingSize;
    item.p100 = nz(n.proteins_serving) * k; item.c100 = (nz(n.carbohydrates_serving) || 0) * k; item.f100 = (nz(n.fat_serving) || 0) * k;
  }
  const notes = [];
  if (!item.kcalPer100 && !item.kcalPerServing) notes.push("Open Food Facts has this product but no calorie data. Fill it in from the pack.");
  else if (energy.fixed) notes.push("Open Food Facts had kJ in the kcal box for this one; I've converted it. Worth a glance at the pack.");
  // Things eaten by the piece: bread by the slice, biscuits, bars, sausages...
  const fromText = pieceFromServing(p.serving_size), fromCat = pieceFromCategories(p.categories_tags);
  if (fromText || fromCat) {
    item.unitLabel = (fromText && fromText.word) || fromCat.word;
    if (fromText && fromText.grams) item.servingSize = fromText.grams / fromText.count;
    if (fromText && fromText.count > 1 && item.kcalPerServing) item.kcalPerServing = Math.round(item.kcalPerServing / fromText.count);
    if (!item.servingSize && !(item.packSize && item.piecesPerPack) && fromCat && fromCat.defaultG) {
      item.servingSize = fromCat.defaultG; item.kcalPerServing = null;
      notes.push(`I've assumed ${fromCat.defaultG} g per ${item.unitLabel}; the pack will say.`);
    }
    if (item.packSize && item.servingSize && !item.piecesPerPack) item.piecesPerPack = Math.round(item.packSize / item.servingSize);
  }
  item.note = notes.join(" ");
  return item;
}

/** kcal per 100 and per serving, trusting kJ when the kcal field looks like kJ (a common data-entry slip,
 *  especially on Australian labels which print kJ first). Nothing edible exceeds ~900 kcal per 100 g. */
function energyFrom(n) {
  const pick = (suffix, cap) => {
    const kcal = num(n["energy-kcal" + suffix]);
    const kj = num(n["energy-kj" + suffix]) || num(n["energy" + suffix]);   // energy_* is always kJ on OFF
    let fixed = false, out = null;
    if (kcal && kj) {
      if (Math.abs(kcal * 4.184 - kj) / kj < 0.2) out = kcal;              // the two agree
      else { out = kj / 4.184; fixed = Math.abs(kcal - kj) / kj < 0.2; }    // kcal box holds the kJ number
    } else if (kcal) { if (cap && kcal > cap) { out = kcal / 4.184; fixed = true; } else out = kcal; }
    else if (kj) out = kj / 4.184;
    return { value: out, fixed };
  };
  const a = pick("_100g", 950), b = pick("_serving", null);
  return { per100: a.value, perServing: b.value, fixed: a.fixed || b.fixed };
}

async function lookupBarcode(code) {
  busy(`Looking up ${code}…`);
  const fields = "product_name,product_name_en,brands,quantity,product_quantity,product_quantity_unit,serving_size,serving_quantity,nutriments,image_front_small_url,categories_tags";
  const url = `https://world.openfoodfacts.org/api/v2/product/${encodeURIComponent(code)}.json?fields=${fields}`;
  let data = null, failure = null;
  for (let attempt = 0; attempt < 2 && !data; attempt++) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 10000);
    try {
      const r = await fetch(url, { signal: ctrl.signal });
      if (r.status === 503 || r.status === 429) { failure = "busy"; await new Promise((res) => setTimeout(res, 1500)); continue; }
      data = await r.json();
    } catch (e) {
      failure = ctrl.signal.aborted ? "slow" : "offline";
    } finally { clearTimeout(timer); }
  }
  busy(false);
  if (!data) {
    toast(failure === "offline" ? "No connection to Open Food Facts. Type the numbers in instead." : "Open Food Facts is slow right now. Try the scan again in a moment, or type the numbers in.", 5000);
    draft = blankItem("manual"); draft.note = `Barcode ${code}. Open Food Facts didn't answer; fill in from the pack or go back and try again.`; openDetails("Enter the details"); return;
  }
  if (data.status !== 1 || !data.product) {
    toast(`Barcode ${code} isn't on Open Food Facts yet.`, 4000);
    draft = blankItem("manual"); draft.note = `Barcode ${code} not found. Fill in from the pack, or go back and read the label.`; openDetails("Enter the details"); return;
  }
  draft = itemFromProduct(data.product);
  openDetails("Product details");
}


// ---------------------------------------------------------------- search: everyday foods (bundled), Open Food Facts, Claude

let searchTimer = null, searchAbort = null, lastQuery = "";
function openSearch() {
  const q = $("#q");
  setTimeout(() => q.focus(), 50);
  if (pick && pick.prefill) { q.value = pick.prefill; pick.prefill = null; q.dispatchEvent(new Event("input")); return; }
  if (!q.value) { $("#search-local").innerHTML = ""; $("#search-off").innerHTML = ""; $("#search-status").classList.add("hidden"); $("#search-claude").classList.add("hidden"); }
}
function foodItem(row) {
  const [name, kcal, serving, label, unit, tags, p, c, f] = row;
  const item = blankItem("search");
  item.name = name; item.unit = unit || "g"; item.kcalPer100 = kcal;
  if (p != null) { item.p100 = p; item.c100 = c || 0; item.f100 = f || 0; }
  item.servingSize = serving || null; item.unitLabel = label || null;
  item.kcalPerServing = serving ? Math.round(kcal * serving / 10) / 10 : null;   // one decimal, so 2 eggs is exactly 2
  return item;
}
function searchLocal(query) {
  const STOP = new Set(["a", "an", "of", "the", "and", "with", "some", "my", "one"]);
  const words = query.toLowerCase().split(/[\s,]+/).filter((w) => w && !STOP.has(w));
  if (!words.length) return [];
  const scored = [];
  for (const row of (typeof FOODS !== "undefined" ? FOODS : [])) {
    const name = row[0].toLowerCase(), hay = name + " " + (row[3] || "") + " " + (row[5] || "").toLowerCase();
    let score = 0, ok = true;
    for (const raw of words) {
      let best = 0;
      for (const w of new Set([raw, raw.replace(/(ies|es|s)$/, ""), raw.replace(/ies$/, "y")])) {   // carrots -> carrot, tomatoes -> tomato
        if (w.length < 2) continue;
        const safe = w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const sc = name.startsWith(w) ? 3 : new RegExp("\\b" + safe).test(hay) ? 2 : hay.includes(w) ? 1 : 0;
        if (sc > best) best = sc;
      }
      if (!best) { ok = false; break; }
      score += best;
    }
    if (ok) scored.push([score - name.length / 100, row]);
  }
  return scored.sort((a, b) => b[0] - a[0]).slice(0, 12).map((x) => x[1]);
}
function resultRow(item, tone) {
  const li = document.createElement("li");
  const perServing = item.kcalPerServing && item.servingSize;
  const detail = [`${fmt(item.kcalPer100)} kcal / 100 ${item.unit}`];
  if (perServing) detail.push(`${fmt1(item.servingSize)} ${item.unit} ${item.unitLabel || "serving"} = ${fmt(item.kcalPerServing)}`);
  else if (item.kcalPerServing) detail.push(`${fmt(item.kcalPerServing)} per serving`);
  if (item.brand) detail.unshift(item.brand);
  const thumb = item.image ? `<img class="thumb-sm" src="${esc(item.image)}" alt="">` : `<span class="thumb-sm ${tone || ""}"><svg><use href="#i-${iconFor(item.source)}"/></svg></span>`;
  li.innerHTML = `${thumb}<div class="body"><div class="name">${esc(item.name)}</div><div class="detail">${esc(detail.join(" · "))}</div></div>
    <div class="kcal">${fmt(perServing ? item.kcalPerServing : item.kcalPer100)}</div>`;
  li.onclick = () => { draft = { ...item }; if (item.source === "meal") openShare(); else openDetails(item.source === "barcode" ? "Product details" : "Food details"); };
  return li;
}
$("#q").addEventListener("input", (e) => {
  const query = e.target.value.trim();
  clearTimeout(searchTimer);
  const local = $("#search-local"); local.innerHTML = "";
  const ql = query.toLowerCase();
  if (ql.length >= 2 && !pick) for (const m of state.meals.filter((x) => x.name.toLowerCase().includes(ql))) local.appendChild(resultRow({ ...mealBasis(m), image: null }, "tone-peach"));
  for (const row of searchLocal(query)) local.appendChild(resultRow(foodItem(row), "tone-coral"));
  $("#search-off").innerHTML = "";
  $("#search-status").classList.add("hidden");
  $("#search-claude").classList.toggle("hidden", !(query.length >= 2 && aiAvailable()));
  $("#search-claude").textContent = `Ask Claude about "${query}"`;
  if (searchAbort) { searchAbort.abort(); searchAbort = null; }
  if (query.length < 3) return;
  searchTimer = setTimeout(() => searchOpenFoodFacts(query), 450);
});
$("#q").addEventListener("keydown", (e) => { if (e.key === "Enter") e.target.blur(); });
async function searchOpenFoodFacts(query) {
  lastQuery = query;
  const status = $("#search-status"), list = $("#search-off");
  status.textContent = "Looking on Open Food Facts…"; status.classList.remove("hidden");
  const ctrl = new AbortController(); searchAbort = ctrl;
  const timeout = setTimeout(() => ctrl.abort(), 8000);
  const fields = "code,product_name,product_name_en,brands,quantity,product_quantity,product_quantity_unit,serving_size,serving_quantity,nutriments,image_front_small_url,categories_tags";
  try {
    const url = `https://world.openfoodfacts.org/cgi/search.pl?search_terms=${encodeURIComponent(query)}&search_simple=1&action=process&json=1&page_size=10&fields=${fields}`;
    let r = await fetch(url, { signal: ctrl.signal });
    if (r.status === 503) { await new Promise((res) => setTimeout(res, 1500)); r = await fetch(url, { signal: ctrl.signal }); }   // it's often busy; one retry
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const data = await r.json();
    if (lastQuery !== query) return;
    const items = (data.products || []).map(itemFromProduct).filter((it) => it.name && (it.kcalPer100 || it.kcalPerServing));
    list.innerHTML = "";
    for (const it of items) list.appendChild(resultRow(it));
    status.textContent = items.length ? "From Open Food Facts:" : "Nothing on Open Food Facts for that.";
  } catch (err) {
    if (ctrl.signal.aborted && lastQuery !== query) return;
    status.textContent = "Open Food Facts is busy right now. Try again in a moment, or ask Claude.";
  } finally { clearTimeout(timeout); if (searchAbort === ctrl) searchAbort = null; }
}

// Claude estimates a food that neither list knows
const FOOD_SCHEMA = {
  type: "object",
  properties: {
    name: { type: "string", description: "The food, tidied up, e.g. 'Chicken thigh, roasted, skin on'" },
    unit: { type: "string", enum: ["g", "ml"] },
    kcal_per_100: { type: "number", description: "Typical kcal per 100 g or 100 ml as eaten" },
    serving_size: { type: ["number", "null"], description: "A typical single serving in g or ml" },
    serving_label: { type: ["string", "null"], description: "What one serving is called: egg, slice, glass, portion…" },
    protein_per_100: { type: ["number", "null"] }, carbs_per_100: { type: ["number", "null"] }, fat_per_100: { type: ["number", "null"] },
    notes: { type: "string", description: "Assumptions made, e.g. 'assumed cooked without oil', in one short sentence" }
  },
  required: ["name", "unit", "kcal_per_100", "serving_size", "serving_label", "protein_per_100", "carbs_per_100", "fat_per_100", "notes"],
  additionalProperties: false
};
$("#search-claude").onclick = async () => {
  const query = $("#q").value.trim();
  if (!query) return;
  if (!aiAvailable()) { aiHelp(); return; }
  busy(`Asking about ${query}…`);
  try {
    const parsed = await askAI(FOOD_SCHEMA, [{ type: "text", text: `Give typical nutrition for this food as commonly eaten: "${query}". If it's ambiguous, pick the most common preparation and say so in notes. Use standard reference values (USDA / McCance & Widdowson), not guesses.` }]);
    busy(false);
    const item = blankItem("claude");
    item.name = parsed.name || query; item.unit = parsed.unit === "ml" ? "ml" : "g";
    item.kcalPer100 = num(parsed.kcal_per_100) ? Math.round(parsed.kcal_per_100) : null;
    item.servingSize = num(parsed.serving_size); item.unitLabel = parsed.serving_label || null;
    item.kcalPerServing = item.kcalPer100 && item.servingSize ? Math.round(item.kcalPer100 * item.servingSize / 100) : null;
    if (nz(parsed.protein_per_100) != null) { item.p100 = nz(parsed.protein_per_100); item.c100 = nz(parsed.carbs_per_100) || 0; item.f100 = nz(parsed.fat_per_100) || 0; }
    item.note = "Claude's estimate, not a label. " + (parsed.notes || "");
    draft = item;
    openDetails("Food details");
  } catch (err) { busy(false); toast(err.message || "Claude couldn't help with that", 5000); }
};

// ---------------------------------------------------------------- Claude reads a label

async function readLabel(file) {
  if (!aiAvailable()) { aiHelp(); return; }
  busy("Reading the label with Claude…");
  try {
    draft = await readLabelWithClaude(file);
    busy(false);
    openDetails("Nutrition (from photo)");
  } catch (err) { busy(false); console.error(err); toast(err.message || "Label reading failed", 5000); }
}

const LABEL_SCHEMA = {
  type: "object",
  properties: {
    name: { type: "string", description: "Product name as printed, or a short description if no name is visible" },
    brand: { type: ["string", "null"] },
    unit: { type: "string", enum: ["g", "ml"], description: "Whether the per-100 values are per 100 g or per 100 ml" },
    kcal_per_100: { type: ["number", "null"], description: "kcal per 100 g/ml. If only kJ is printed, convert: kcal = kJ / 4.184" },
    serving_size: { type: ["number", "null"], description: "One serving/portion in g or ml, if stated" },
    kcal_per_serving: { type: ["number", "null"], description: "kcal per serving/portion, if stated" },
    pack_size: { type: ["number", "null"], description: "Total pack net weight/volume in g or ml, if visible" },
    pieces_per_pack: { type: ["number", "null"], description: "Number of pieces/bars/biscuits per pack, if stated" },
    protein_per_100: { type: ["number", "null"], description: "Protein g per 100 g/ml, if shown" },
    carbs_per_100: { type: ["number", "null"], description: "Carbohydrate g per 100 g/ml, if shown" },
    fat_per_100: { type: ["number", "null"], description: "Fat g per 100 g/ml, if shown" },
    piece_name: { type: ["string", "null"], description: "If it's eaten by the piece, what one is called: slice, biscuit, bar, sausage… else null" },
    is_nutrition_label: { type: "boolean", description: "true only if a nutrition table or energy figures are actually visible" },
    confidence: { type: "string", enum: ["high", "medium", "low"] },
    notes: { type: "string", description: "Anything unclear, e.g. 'values are per 30g portion; per-100 not shown'" }
  },
  required: ["name", "brand", "unit", "kcal_per_100", "serving_size", "kcal_per_serving", "pack_size", "pieces_per_pack", "protein_per_100", "carbs_per_100", "fat_per_100", "piece_name", "is_nutrition_label", "confidence", "notes"],
  additionalProperties: false
};
const LABEL_PROMPT = `This is a photo of a food or drink product, its nutrition table, or both. Read the energy information off it.
Report only numbers you can actually read on the label; use null for anything not visible rather than guessing.
If energy is given in kJ only, convert to kcal (kcal = kJ / 4.184). If values are per portion only, fill kcal_per_serving and serving_size and leave kcal_per_100 null.
If no nutrition table or energy figure is visible at all, set is_nutrition_label to false and leave the numbers null.`;

// ---- Which AI can we use? Shared key on the server (signed in), a free Gemini key on this phone, or a Claude key.
const GEMINI_MODELS = ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite", "gemini-flash-lite-latest"];
let aiProxyState = "unknown";   // "unknown" | "yes" | "no": whether the Supabase "ai" function is deployed
const aiAvailable = () => !!(state.geminiKey || state.apiKey || (window.cloud && window.cloud.user && aiProxyState !== "no"));
function aiHelp() { toast("AI features need a key: a free Google Gemini key or an Anthropic key, in Settings. Or ask whoever set the app up to switch on the shared one.", 6000); go("settings"); }
async function askAI(schema, content, effort = "medium") {
  // 1) shared key via the Supabase function
  if (window.cloud && window.cloud.user && aiProxyState !== "no") {
    try { return await askGemini(schema, content, null); }
    catch (err) { if (err.proxyMissing) aiProxyState = "no"; else throw err; }
  }
  // 2) a Gemini key on this phone
  if (state.geminiKey) return askGemini(schema, content, state.geminiKey);
  // 3) a Claude key on this phone
  if (state.apiKey) return askClaude(schema, content, effort);
  throw new Error("No AI key set. Add a free Google Gemini key in Settings.");
}
/** Gemini's schema dialect: no type unions, no additionalProperties; nulls become nullable. */
function geminiSchema(node) {
  if (Array.isArray(node)) return node.map(geminiSchema);
  if (!node || typeof node !== "object") return node;
  const out = {};
  for (const [k, v] of Object.entries(node)) {
    if (k === "additionalProperties") continue;
    if (k === "type" && Array.isArray(v)) { const t = v.filter((x) => x !== "null"); out.type = t[0] || "string"; if (v.includes("null")) out.nullable = true; continue; }
    out[k] = (k === "properties") ? Object.fromEntries(Object.entries(v).map(([pk, pv]) => [pk, geminiSchema(pv)])) : geminiSchema(v);
  }
  return out;
}
async function askGemini(schema, content, key) {
  const parts = content.map((b) => b.type === "image" ? { inline_data: { mime_type: b.source.media_type, data: b.source.data } } : { text: b.text });
  const bodyFor = (model) => {
    const generationConfig = { responseMimeType: "application/json", responseSchema: geminiSchema(schema), temperature: 0.2 };
    if (/^gemini-3/.test(model)) generationConfig.thinkingConfig = { thinkingLevel: "low" };   // quick answers; these are lookups, not puzzles
    return JSON.stringify({ contents: [{ parts }], generationConfig });
  };
  const send = async (model) => {
    if (key) return fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, { method: "POST", headers: { "Content-Type": "application/json", "X-goog-api-key": key }, body: bodyFor(model) });
    const cfg = window.SUPABASE_CONFIG;
    return window.cloud.rawFetch(`${cfg.url}/functions/v1/ai?model=${model}`, { method: "POST", headers: { "Content-Type": "application/json", apikey: cfg.anonKey }, body: bodyFor(model) });
  };
  let resp, lastNet = null;
  for (const model of GEMINI_MODELS) {             // newest first; fall through on "no longer available", "high demand", or a dropped connection
    resp = null;
    for (let attempt = 0; attempt < 2 && !resp; attempt++) {
      try { resp = await send(model); } catch (e) { lastNet = e; await new Promise((r) => setTimeout(r, 600)); }
    }
    if (!resp) continue;
    if (!key && resp.status === 404) { const e = new Error("shared AI not set up"); e.proxyMissing = true; throw e; }
    if (!key && resp.ok) aiProxyState = "yes";
    if (resp.status !== 503 && resp.status !== 429 && !(resp.status === 404 && key)) break;
    await new Promise((r) => setTimeout(r, 400));
  }
  if (!resp) throw new Error(`Couldn't reach the AI service (${(lastNet && lastNet.message) || "no connection"}). Check the signal and try again.`);
  if (resp.status === 503 || resp.status === 429) throw new Error("Every free AI model is busy right now. Try again in a minute.");
  const json = await resp.json().catch(() => ({}));
  if (resp.status === 401 && !key) { aiProxyState = "no"; const e = new Error("shared AI not available"); e.proxyMissing = true; throw e; }
  if (resp.status === 500 && !key && /GEMINI_API_KEY/.test(JSON.stringify(json))) { aiProxyState = "no"; const e = new Error("shared AI has no key yet"); e.proxyMissing = true; throw e; }
  if (resp.status === 429) throw new Error("The free AI limit is busy right now. Try again in a minute.");
  if (!resp.ok) throw new Error((json.error && json.error.message) || `AI error ${resp.status}`);
  const text = (((json.candidates || [])[0] || {}).content || {}).parts?.map((p) => p.text || "").join("") || "";
  try { return JSON.parse(text); } catch (e) { throw new Error("Couldn't understand the AI's answer. Try again."); }
}

/** One structured-output request to Claude; returns the parsed JSON. */
async function askClaude(schema, content, effort = "medium") {
  const body = {
    model: CLAUDE_MODEL,
    max_tokens: 2048,
    fallbacks: "default",
    output_config: { effort, format: { type: "json_schema", schema } },
    messages: [{ role: "user", content }]
  };
  let resp;
  try {
    resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": state.apiKey,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "server-side-fallback-2026-07-01",
        "anthropic-dangerous-direct-browser-access": "true"
      },
      body: JSON.stringify(body)
    });
  } catch (e) { throw new Error("Couldn't reach the Anthropic API (offline?)"); }
  const json = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    if (resp.status === 401) throw new Error("API key rejected. Check it in Settings.");
    throw new Error(`Claude error: ${json?.error?.message || `HTTP ${resp.status}`}`);
  }
  if (json.stop_reason === "refusal") throw new Error("Claude declined that request");
  if (json.stop_reason === "max_tokens") throw new Error("Claude's answer was cut off. Try again.");
  const text = (json.content || []).filter((b) => b.type === "text").map((b) => b.text).join("");
  try { return JSON.parse(text); } catch (e) { throw new Error("Couldn't understand Claude's answer. Try again."); }
}

async function readLabelWithClaude(file, quiet = false) {
  const img = await loadImage(file);
  const dataUrl = drawScaled(img, 1280).toDataURL("image/jpeg", 0.85);
  const b64 = dataUrl.split(",")[1];
  const parsed = await askAI(LABEL_SCHEMA, [
    { type: "image", source: { type: "base64", media_type: "image/jpeg", data: b64 } },
    { type: "text", text: LABEL_PROMPT }
  ]);
  if (parsed.is_nutrition_label === false || (!num(parsed.kcal_per_100) && !num(parsed.kcal_per_serving))) {
    if (quiet) return null;
    throw new Error("Can't see a nutrition table in that photo. Get closer and try again.");
  }
  const item = blankItem("label");
  item.name = parsed.name || ""; item.brand = parsed.brand || "";
  item.unitLabel = parsed.piece_name ? String(parsed.piece_name).toLowerCase().replace(/s$/, "") : null;
  if (nz(parsed.protein_per_100) != null || nz(parsed.carbs_per_100) != null || nz(parsed.fat_per_100) != null) { item.p100 = nz(parsed.protein_per_100) || 0; item.c100 = nz(parsed.carbs_per_100) || 0; item.f100 = nz(parsed.fat_per_100) || 0; }
  item.unit = parsed.unit === "ml" ? "ml" : "g";
  item.kcalPer100 = num(parsed.kcal_per_100) ? Math.round(parsed.kcal_per_100) : null;
  item.servingSize = num(parsed.serving_size);
  item.kcalPerServing = num(parsed.kcal_per_serving) ? Math.round(parsed.kcal_per_serving) : null;
  item.packSize = num(parsed.pack_size); item.piecesPerPack = num(parsed.pieces_per_pack);
  item.image = dataUrl;
  const bits = [];
  if (parsed.confidence && parsed.confidence !== "high") bits.push(`Claude's confidence: ${parsed.confidence}.`);
  if (parsed.notes) bits.push(parsed.notes);
  item.note = bits.join(" ");
  return item;
}

// ---------------------------------------------------------------- how much? (kcal <-> grams <-> pieces)

let amountKcal = null;   // the amount currently on the How much? screen
/** What we can convert for this item: kcal per 100, and kcal per "count" (piece / serving / drink). */
function conv(item) {
  const kcalPer100 = item.kcalPer100 || (item.kcalPerServing && item.servingSize ? item.kcalPerServing / item.servingSize * 100 : null);
  let countKcal = null, countLabel = null;
  if (item.piecesPerPack && item.packSize && kcalPer100) { countKcal = item.packSize / item.piecesPerPack * kcalPer100 / 100; countLabel = item.unitLabel || "piece"; }
  else if (item.kcalPerServing) { countKcal = item.kcalPerServing; countLabel = item.unitLabel || "serving"; }
  else if (item.servingSize && kcalPer100) { countKcal = item.servingSize * kcalPer100 / 100; countLabel = "serving"; }
  return { kcalPer100, countKcal, countLabel };
}
function showSharePhoto() {
  const img = $("#share-photo"), has = !!(draft && draft.photo);
  img.classList.toggle("hidden", !has); if (has) img.src = draft.photo;
  $("#share-photo-remove").classList.toggle("hidden", !has);
  $("#share-photo-cam").textContent = has ? "📷 Retake" : "📷 Add a photo";
}
async function attachPhoto(file) { try { draft.photo = await thumbFrom(file); showSharePhoto(); } catch (e) { toast("Couldn't read that photo"); } }
$("#share-photo-cam").onclick = () => $("#file-share-cam").click();
$("#share-photo-lib").onclick = () => $("#file-share-lib").click();
$("#file-share-cam").addEventListener("change", (e) => { const f = e.target.files[0]; e.target.value = ""; if (f) attachPhoto(f); });
$("#file-share-lib").addEventListener("change", (e) => { const f = e.target.files[0]; e.target.value = ""; if (f) attachPhoto(f); });
$("#share-photo-remove").onclick = () => { delete draft.photo; showSharePhoto(); };
function openShare(prefillKcal) {
  const c = conv(draft);
  // A label read or an estimate came with a photo: keep a small copy of it with the entry
  if (!draft.photo && draft.image && String(draft.image).startsWith("data:")) thumbFrom(draft.image).then((t) => { if (draft) { draft.photo = t; showSharePhoto(); } }).catch(() => {});
  showSharePhoto();
  $("#share-name").textContent = draft.name;
  $("#share-add").textContent = pick ? "Add to the meal" : editId ? "Save changes" : "Add to today";
  $("#item-talk").value = ""; $("#item-talk-note").classList.add("hidden");
  $("#send-sheet").classList.add("hidden");
  $("#a-unit").textContent = draft.unit || "g";
  $("#a-grams-wrap").classList.toggle("hidden", !c.kcalPer100);
  $("#a-count-wrap").classList.toggle("hidden", !c.countKcal);
  if (c.countLabel) $("#a-count-label").textContent = c.countLabel.charAt(0).toUpperCase() + c.countLabel.slice(1) + "s";
  amountKcal = null;
  fillAmounts(null);
  if (prefillKcal) { setAmount(prefillKcal, "kcal"); $("#a-kcal").value = Math.round(prefillKcal); }
  else if (c.countKcal) { $("#a-count").value = "1"; setAmount(1, "count"); }   // "an egg", "a slice": start at one and let them tap 2 or 3
  go("share");
}
const tidy = (n) => n == null ? "" : (Math.abs(n) >= 10 ? Math.round(n) : Math.round(n * 10) / 10);
function fillAmounts(except) {
  const c = conv(draft), k = amountKcal;
  if (except !== "kcal") $("#a-kcal").value = k == null ? "" : Math.round(k);
  if (except !== "grams") $("#a-grams").value = (k == null || !c.kcalPer100) ? "" : tidy(k / c.kcalPer100 * 100);
  if (except !== "count") $("#a-count").value = (k == null || !c.countKcal) ? "" : tidy(k / c.countKcal);
  const count = (k != null && c.countKcal) ? k / c.countKcal : null;
  $$("#count-chips button").forEach((b) => b.classList.toggle("on", count != null && Math.abs(count - +b.dataset.n) < 0.05));
  updateResult();
}
$("#count-chips").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  $("#a-count").value = b.dataset.n;
  setAmount(+b.dataset.n, "count");
});
function setAmount(value, field) {
  const c = conv(draft), v = num(value);
  if (v == null) { amountKcal = null; fillAmounts(field); return; }
  if (field === "kcal") amountKcal = v;
  else if (field === "grams") amountKcal = v * c.kcalPer100 / 100;
  else if (field === "count") amountKcal = v * c.countKcal;
  fillAmounts(field);
}
$("#a-kcal").addEventListener("input", (e) => setAmount(e.target.value, "kcal"));
$("#a-grams").addEventListener("input", (e) => setAmount(e.target.value, "grams"));
$("#a-count").addEventListener("input", (e) => setAmount(e.target.value, "count"));
$("#share-rest").onclick = async () => {
  const left = Math.max(0, budgetToday() - usedKcal());
  if (!left) { toast("Nothing left in today's budget"); return; }
  if (!await ask(`Set this to ${fmt(left)} kcal, all that's left of today's budget?`)) return;
  setAmount(left, "kcal");
};
$("#share-reset").onclick = () => { amountKcal = null; fillAmounts(null); };

function updateResult() {
  const btn = $("#share-add"), bar = $("#r-bar");
  $("#share-post").disabled = !amountKcal || !!pick;
  $("#share-send").disabled = !amountKcal || !!pick;
  if (!amountKcal) { $("#r-kcal").textContent = "0"; $("#r-sub").textContent = "of your day"; bar.style.width = "0"; $("#r-lines").innerHTML = ""; $("#r-macros").innerHTML = ""; btn.disabled = true; return; }
  const kcal = Math.round(amountKcal);
  const frac = state.budget > 0 ? kcal / state.budget : 0;
  $("#r-kcal").textContent = fmt(kcal);
  $("#r-sub").textContent = `≈ ${fmt(frac * 100, 1)}% of your day`;
  bar.style.width = `${Math.min(100, frac * 100)}%`;
  const a = amountsFor(draft, kcal), lines = [];
  if (a.packFraction != null) lines.push(`<b>${fmt(a.packFraction * 100)}%</b> of the pack`);
  const leftAfter = budgetToday() - usedKcal() - kcal;
  lines.push(leftAfter >= 0 ? `leaves <b>${fmt(leftAfter)}</b> kcal for the rest of the day` : `<b style="color:var(--bad)">${fmt(-leftAfter)} kcal over</b> your day`);
  $("#r-lines").innerHTML = lines.map((l) => `<div>${l}</div>`).join("");
  $("#r-macros").innerHTML = macroText(macrosFor(draft, kcal), true);
  btn.disabled = false;
}
$("#share-post").onclick = () => {
  if (!amountKcal || !draft || pick) return;
  if (!(window.cloud && window.cloud.user)) { toast("Sharing needs an account: sign in from Settings"); return; }
  const kcal = Math.round(amountKcal);
  if (editId) { const it = state.day.items.find((x) => x.id === editId); if (it) { Object.assign(it, basisOf(draft)); it.kcal = kcal; it.shareLabel = `${fmt(kcal / state.budget * 100, 1)}% of the day`; save(); } editId = null; }
  else addToDay(draft, kcal, `${fmt(kcal / state.budget * 100, 1)}% of the day`);
  const m = macrosFor(draft, kcal), a = amountsFor(draft, kcal);
  openCompose({ kind: "food", name: draft.name, kcal, grams: a.grams != null ? Math.round(a.grams) : null, unit: draft.unit || "g", p: m.p != null ? Math.round(m.p) : null, c: m.c != null ? Math.round(m.c) : null, f: m.f != null ? Math.round(m.f) : null, basis: basisOf(draft) }, draft.photo || null);
};
$("#share-add").onclick = () => {
  if (!amountKcal || !draft) return;
  const kcal = Math.round(amountKcal);
  if (pick) { mealTakeIngredient(draft, kcal); toast(`${draft.name} is in the meal`); return; }
  if (editId) {
    const it = state.day.items.find((x) => x.id === editId);
    if (it) { Object.assign(it, basisOf(draft)); it.kcal = kcal; it.shareLabel = `${fmt(kcal / state.budget * 100, 1)}% of the day`; save(); }
    editId = null; toast(`Updated ${draft.name} · ${fmt(kcal)} kcal`); home(); return;
  }
  addToDay(draft, kcal, `${fmt(kcal / state.budget * 100, 1)}% of the day`);
  toast(`Added ${draft.name} · ${fmt(kcal)} kcal`);
  home();
};

// ---------------------------------------------------------------- account + sync (optional, see cloud.js)

const SYNC_KEYS = ["budget", "day", "history", "recent", "meals", "presetUses", "shareDay", "sharedMealIds", "goals", "chats", "notes", "weightKg", "eatBack", "recentWorkouts", "exercises", "routines", "session", "weekGoals", "seenBadges", "goalWins", "postCount", "pbCount", "body", "updatedAt"];   // the API key stays on the device
let pushTimer = null;
function schedulePush() {
  if (!window.cloud || !window.cloud.user) return;
  clearTimeout(pushTimer);
  pushTimer = setTimeout(() => {
    const data = {}; for (const k of SYNC_KEYS) data[k] = state[k];
    window.cloud.push(data).catch((err) => syncProblem(err));
    publishDay();
  }, 600);
}
function publishDay() {
  const c = window.cloud; if (!c || !c.user || !state.shareDay) return;
  const items = state.day.items.map((it) => ({ name: it.name, kcal: it.kcal })).concat((state.day.workouts || []).map((w) => ({ name: `Workout: ${w.name}, ${w.minutes} min`, kcal: -Math.round(w.kcal || 0) })));
  c.publishDay({ date: state.day.date, budget: budgetToday(), kcal: usedKcal(), items }).catch((err) => { if (!publishDay.warned) { publishDay.warned = true; toast("Couldn't share your day: " + c.explain(err), 5000); } });
}
let syncWarned = false;
function syncProblem(err) {
  const m = String((err && err.message) || "").toLowerCase();
  if (m.includes("schema cache") || (m.includes("relation") && m.includes("exist"))) {
    if (syncWarned) return;
    syncWarned = true;
    toast("Signed in, but the cheatday table hasn't been created in Supabase yet. Run the SQL from the README once and sync will start. Everything is safe on this phone meanwhile.", 8000);
    return;
  }
  toast("Couldn't sync: " + window.cloud.explain(err), 4000);
}
/** Newest copy wins, whole. One person, one device at a time, so this keeps deletions deleted. */
async function pull() {
  const c = window.cloud; if (!c || !c.user) return;
  let remote;
  try { remote = await c.pull(); } catch (err) { syncProblem(err); return; }
  if (remote === null) { schedulePush(); return; }                       // fresh account: upload what we have
  if ((remote.updatedAt || 0) > (state.updatedAt || 0)) {
    for (const k of SYNC_KEYS) if (remote[k] != null) state[k] = remote[k];
    save(false);
    const current = stack[stack.length - 1];
    if (current === "home") renderHome();
    if (current === "settings") renderSettings();
  } else if ((state.updatedAt || 0) > (remote.updatedAt || 0)) {
    schedulePush();
  }
}
function renderAccount() {
  const c = window.cloud;
  $("#account-card").classList.toggle("hidden", !c);
  if (!c) return;
  $("#acct-out").classList.toggle("hidden", !!c.user);
  $("#acct-in").classList.toggle("hidden", !c.user);
  if (c.user) $("#acct-who").textContent = c.user.email || "";
}
function cloudInit() {
  const c = window.cloud;
  renderAccount();
  if (!c) return;
  c.onAuth((u) => { renderAccount(); if (u) { pull(); publishDay(); } });
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") { pull(); publishDay(); if (stack[stack.length - 1] === "friends") renderFriends(); } });
  if (c.user) { pull(); publishDay(); }
}
async function acct(action) {
  const c = window.cloud; if (!c) return;
  const email = $("#acct-email").value.trim(), pass = $("#acct-pass").value;
  try {
    if (action === "forgot") {
      if (!email) { toast("Type your email first"); return; }
      await c.resetPassword(email); toast("Password reset email sent"); return;
    }
    if (!email || !pass) { toast("Email and password, please"); return; }
    busy(action === "signup" ? "Creating your account…" : "Signing in…");
    const done = await (action === "signup" ? c.signUp(email, pass) : c.signIn(email, pass));
    busy(false); $("#acct-pass").value = "";
    if (action === "signup" && done === false) { toast("Check your email for a confirmation link, then sign in.", 6000); return; }
    toast(action === "signup" ? "Account created. You're signed in." : "Signed in");
  } catch (err) { busy(false); toast(c.explain(err), 4500); }
}
$("#acct-signin").onclick = () => acct("signin");
$("#acct-signup").onclick = () => acct("signup");
$("#acct-forgot").onclick = () => acct("forgot");
$("#acct-signout").onclick = async () => { try { await window.cloud.signOut(); toast("Signed out. This device keeps its own copy."); } catch (e) {} };
$("#acct-pass").addEventListener("keydown", (e) => { if (e.key === "Enter") acct("signin"); });

// ---------------------------------------------------------------- boot

show("home");
cloudInit();
// Keep everyone current: if the server has a newer version, fetch it and reload. Checked on open and on return, at most every 5 minutes.
let lastUpdateCheck = 0;
async function checkForUpdate() {
  if (!navigator.onLine || Date.now() - lastUpdateCheck < 5 * 60 * 1000 || busyShown()) return;
  lastUpdateCheck = Date.now();
  try {
    const r = await fetch("version.json?t=" + Date.now(), { cache: "no-store" });
    if (!r.ok) return;
    const { v } = await r.json();
    if (!v || v === APP_VERSION) return;
    let tried = ""; try { tried = localStorage.getItem("cheatday.autoUpdated") || ""; } catch (e) {}
    if (tried === v) return;                       // already tried this one; don't loop
    try { localStorage.setItem("cheatday.autoUpdated", v); } catch (e) {}
    toast(`Updating to version ${v}…`, 3000);
    if ("serviceWorker" in navigator) { const regs = await navigator.serviceWorker.getRegistrations(); await Promise.all(regs.map((x) => x.unregister())); }
    if (window.caches) { const keys = await caches.keys(); await Promise.all(keys.map((k) => caches.delete(k))); }
    setTimeout(() => location.replace(location.pathname + "?fresh=" + Date.now()), 600);
  } catch (e) { /* offline or blocked: try again later */ }
}
checkForUpdate();
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") checkForUpdate(); });
importMealFromLink();
// Portrait only. Android installed apps can be locked for real; everywhere else the CSS counter-rotates
// the whole app when the phone is turned, so it always looks upright. The scanner reads barcodes any way up.
try { if (screen.orientation && screen.orientation.lock) screen.orientation.lock("portrait").catch(() => {}); } catch (e) {}
function orientApp() {
  let o = typeof window.orientation === "number" ? window.orientation : ((screen.orientation && screen.orientation.angle) || 0);
  if (o === 270) o = -90;
  document.documentElement.dataset.orient = String(o);
  fitVideo();
}
function fitVideo() {
  const v = $("#video"), box = v.parentElement;
  const o = +document.documentElement.dataset.orient || 0;
  if (o === 90 || o === -90) {
    v.style.width = box.clientHeight + "px"; v.style.height = box.clientWidth + "px";
    v.style.left = "50%"; v.style.top = "50%";
    v.style.transform = `translate(-50%, -50%) rotate(${o === 90 ? 90 : -90}deg)`;
  } else { v.style.width = ""; v.style.height = ""; v.style.left = ""; v.style.top = ""; v.style.transform = ""; }
}
window.addEventListener("orientationchange", () => setTimeout(orientApp, 150));
window.addEventListener("resize", () => setTimeout(orientApp, 50));
orientApp();
// No pinch-zoom on iOS Safari, which ignores user-scalable=no.
document.addEventListener("gesturestart", (e) => e.preventDefault());
document.addEventListener("touchmove", (e) => { if (e.scale && e.scale !== 1) e.preventDefault(); }, { passive: false });
if ("serviceWorker" in navigator && window.isSecureContext) navigator.serviceWorker.register("sw.js").catch(() => {});
