/* Cheat Days — spend your cheat-day calories on purpose.
 * Everything lives in localStorage on this device. The only network calls are
 * barcode lookups (Open Food Facts) and label photos (Anthropic, only if you've
 * entered an API key in Settings). */
"use strict";

const APP_VERSION = "38";   // keep in step with ?v= in index.html and CACHE in sw.js
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
  const base = { budget: 1600, apiKey: "", geminiKey: "", day: { date: localDate(), items: [] }, history: [], recent: [], meals: [], presetUses: {}, mealDraft: null, shareDay: true, sharedMealIds: [], goals: { p: null, c: null, f: null } };
  try { const raw = localStorage.getItem(STORE_KEY); if (raw) Object.assign(base, JSON.parse(raw)); } catch (e) {}
  if (!Array.isArray(base.recent)) base.recent = [];
  if (!Array.isArray(base.meals)) base.meals = [];
  if (!base.presetUses || typeof base.presetUses !== "object") base.presetUses = {};
  if (!Array.isArray(base.sharedMealIds)) base.sharedMealIds = [];
  if (base.shareDay == null) base.shareDay = true;
  if (!base.goals || typeof base.goals !== "object") base.goals = { p: null, c: null, f: null };
  return base;
}
function save(sync = true) {
  if (sync) state.updatedAt = Date.now();
  try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch (e) { toast("Couldn't save (storage blocked?)"); }
  if (sync) schedulePush();
}
const state = load();
const usedKcal = () => state.day.items.reduce((s, it) => s + it.kcal, 0);

// ---------------------------------------------------------------- helpers

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
const BASIS_KEYS = ["name", "brand", "source", "unit", "unitLabel", "kcalPer100", "servingSize", "kcalPerServing", "packSize", "piecesPerPack", "image", "mealId", "p100", "c100", "f100", "pServ", "cServ", "fServ"];
function basisOf(obj) {
  const b = {};
  for (const k of BASIS_KEYS) if (obj[k] != null && obj[k] !== "") b[k] = obj[k];
  if (b.image && String(b.image).startsWith("data:")) delete b.image;   // never store photos
  return b;
}

// ---------------------------------------------------------------- router

const VIEWS = ["home", "budget", "settings", "history", "friends", "ask", "scan", "search", "meals", "meal", "details", "share"];
let stack = ["home"];
function show(view) {
  for (const v of VIEWS) $(`#view-${v}`).classList.toggle("hidden", v !== view);
  document.body.dataset.view = view;
  window.scrollTo(0, 0);
  if (view !== "scan") stopCamera();
  if (view === "home") renderHome();
  if (view === "settings") renderSettings();
  if (view === "budget") { $("#b-budget").value = state.budget; $$("#budget-chips button").forEach((b) => b.classList.toggle("on", +b.dataset.b === state.budget)); const g = state.goals || {}; $("#b-p").value = g.p ?? ""; $("#b-c").value = g.c ?? ""; $("#b-f").value = g.f ?? ""; }
  if (view === "scan") startCamera();
  if (view === "search") openSearch();
  if (view === "meals") renderMeals();
  if (view === "friends") renderFriends();
  if (view === "history") renderHistory();
  if (view === "ask") renderAsk();
  if (view === "meal") renderMeal();
}
function go(view) { stack.push(view); show(view); }
function back() { if (stack[stack.length - 1] === "share") editId = null; stack.pop(); if (!stack.length) stack = ["home"]; show(stack[stack.length - 1]); }
function home() { pick = null; editId = null; stack = ["home"]; show("home"); }

document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-go]"); if (b) { const v = b.dataset.go; v === "manual" ? openManual() : go(v); return; }
  if (e.target.closest("[data-back]")) back();
});

// ---------------------------------------------------------------- home

/** A new calendar day: file today under History and start clean. Runs on open, on return, and on every home render. */
function archiveDay() {
  if (!state.day.items.length) return;
  const m = sumMacros(state.day.items);
  state.history.unshift({ date: state.day.date, budget: state.budget, kcal: usedKcal(), items: state.day.items.map((it) => ({ ...basisOf(it), kcal: it.kcal, shareLabel: it.shareLabel })),
    p: Math.round(m.p), c: Math.round(m.c), f: Math.round(m.f) });
  state.history = state.history.slice(0, 120);
}
function rollDay() {
  if (state.day.date === localDate()) return false;
  archiveDay();
  state.day = { date: localDate(), items: [] };
  save();
  return true;
}
function renderHome() {
  rollDay();
  const used = usedKcal(), left = state.budget - used;
  $("#home-used").textContent = fmt(used);
  $("#home-budget").textContent = fmt(state.budget);
  const bar = $("#home-bar");
  bar.style.width = `${Math.min(100, state.budget > 0 ? used / state.budget * 100 : 0)}%`;
  bar.classList.toggle("over", left < 0);
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
}
function iconFor(source) {
  return { barcode: "barcode", label: "camera", quick: "plus", search: "search", claude: "search", meal: "meal" }[source] || "pen";
}
function itemRow(it) {
  const li = document.createElement("li");
  const thumb = it.image ? `<img class="thumb-sm" src="${esc(it.image)}" alt="">` : `<span class="thumb-sm"><svg><use href="#i-${iconFor(it.source)}"/></svg></span>`;
  li.innerHTML = `${thumb}
    <div class="body"><div class="name">${esc(it.name || "Unnamed")}</div><div class="detail">${esc(shortAmounts(it))}</div></div>
    <div class="kcal">${fmt(it.kcal)}</div>
    <button class="del" aria-label="Remove">✕</button>`;
  li.querySelector(".del").onclick = (e) => { e.stopPropagation(); if (!confirm(`Remove "${it.name}" from today?`)) return; state.day.items = state.day.items.filter((x) => x.id !== it.id); save(); renderHome(); };
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
    const thumb = b.image ? `<img class="thumb-sm" src="${esc(b.image)}" alt="">` : `<span class="thumb-sm ${q.meal ? "tone-peach" : ""}"><svg><use href="#i-${iconFor(b.source)}"/></svg></span>`;
    li.innerHTML = `${thumb}
      <div class="body"><div class="name">${esc(b.name)}</div><div class="detail">${esc(detail)}</div></div>
      <div class="kcal">${fmt(q.lastKcal)}</div><button class="add" aria-label="Add"><svg><use href="#i-plus"/></svg></button>`;
    li.querySelector(".add").onclick = (e) => { e.stopPropagation(); addToDay(b, q.lastKcal, q.lastShareLabel); toast(`Added ${b.name} · ${fmt(q.lastKcal)} kcal`); };
    li.querySelector(".body").onclick = () => { draft = { ...b, note: "" }; openShare(q.lastKcal); };
    if (!q.preset && !q.meal) longPress(li, () => {
      if (confirm(`Remove "${b.name}" from Quick add?`)) { state.recent = state.recent.filter((r) => r.key !== q.key); save(); renderQuick(); }
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
    name: meal.name || "Meal", source: "meal", mealId: meal.id, unit: "g",
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
    li.querySelector(".del").onclick = (e) => { e.stopPropagation(); if (confirm(`Discard the unsaved "${state.mealDraft.name || "meal"}"?`)) { state.mealDraft = null; mealDraft = null; save(false); renderMeals(); } };
    list.appendChild(li);
  }
  for (const m of state.meals) {
    const t = mealTotals(m), portions = num(m.portions) || 1;
    const li = document.createElement("li");
    li.innerHTML = `<span class="thumb-sm tone-peach"><svg><use href="#i-meal"/></svg></span>
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

function renderMeal() {
  if (!mealDraft) mealDraft = state.mealDraft || newMeal();
  const m = mealDraft;
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
    li.onclick = (e) => {
      const act = e.target.closest("[data-act]");
      if (act) {
        e.stopPropagation();
        if (act.dataset.act === "remove") { if (!confirm(`Remove "${it.name}" from this meal?`)) return; m.items = m.items.filter((x) => x.id !== it.id); openRow = null; mealChanged(); }
        if (act.dataset.act === "amount") { pick = { replaceId: it.id }; draft = { ...basisOf(it), note: "" }; openShare(it.kcal); }
        if (act.dataset.act === "swap") { pick = { replaceId: it.id, prefill: it.fromText || it.name }; go("search"); }
        return;
      }
      openRow = openRow === it.id ? null : it.id; renderMeal();
    };
    list.appendChild(li);
  }
  $("#m-empty").classList.toggle("hidden", m.items.length > 0);
  const t = mealTotals(m), portions = num(m.portions) || 1;
  $("#m-total-kcal").textContent = fmt(t.kcal);
  $("#m-total-sub").textContent = t.grams ? `about ${fmt(t.grams)} g` : "";
  $("#m-per-portion").innerHTML = m.items.length ? `<div>each of <b>${portions}</b> portion${portions === 1 ? "" : "s"}: <b>${fmt(t.kcal / portions)}</b> kcal${t.grams ? ` (${fmt(t.grams / portions)} g)` : ""}</div>` : "";
  $("#m-macros").innerHTML = m.items.length ? `Per portion: ${macroText({ p: t.p / portions, c: t.c / portions, f: t.f / portions }, true)}${t.macroMissing ? ` <span class="tiny">(${t.macroMissing} ingredient${t.macroMissing === 1 ? "" : "s"} without macros)</span>` : ""}` : "";
  $("#m-use").classList.toggle("hidden", !m.saved);
  $("#m-share").classList.toggle("hidden", !m.saved);
  $("#m-lighter").classList.toggle("hidden", !m.items.length);
  const canFriends = m.saved && window.cloud && window.cloud.user;
  $("#m-share-friends").classList.toggle("hidden", !canFriends);
  $("#m-share-friends").textContent = state.sharedMealIds.includes(m.id) ? "Stop sharing with friends" : "Share with friends";
  $("#m-save").textContent = m.saved ? "Save changes" : "Save meal";
}
$("#m-name").addEventListener("input", (e) => { mealDraft.name = e.target.value; state.mealDraft = mealDraft; save(false); });
$("#m-portions").addEventListener("input", (e) => { mealDraft.portions = num(e.target.value) || mealDraft.portions; state.mealDraft = mealDraft; save(false); renderMeal(); });
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
  const bytes = new TextEncoder().encode(JSON.stringify({ v: 1, name: m.name, portions: m.portions, items }));
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
  if (!confirm(`Add "${m.name}" to your meals?\n\n${m.items.length} ingredients, ${portions} portion${portions === 1 ? "" : "s"}, ${fmt(t.kcal / portions)} kcal each.`)) return;
  state.meals.unshift({ id: uid(), name: m.name, portions, items: m.items.map((it) => ({ ...it, id: uid() })), saved: true, shared: true, updatedAt: new Date().toISOString() });
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
      await c.shareMeal({ id: m.id, name: m.name, portions, kcalPerPortion: Math.round(t.kcal / portions), items: m.items.map((it) => ({ ...basisOf(it), kcal: it.kcal, grams: it.grams })) });
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
  const items = (r.ingredients || []).filter((x) => /removed/i.test(x.change) === false).map((x) => {
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
  out.innerHTML = `<div class="plan-card"><p><b>${fmt(t.kcal / portions)} → ${fmt(after / portions)} kcal a portion</b> (${fmt((1 - after / t.kcal) * 100)}% less)</p><p>${esc(r.summary)}</p>
    <ul class="list">${(r.ingredients || []).map((x) => `<li><div class="body"><div class="name">${esc(x.name)}</div><div class="detail">${fmt(x.grams)} g · ${fmt(x.kcal)} kcal · ${esc(x.change)}</div></div></li>`).join("")}</ul>
    ${chatBox("mlight", "Change something? e.g. keep the butter, drop the walnuts")}
    <button class="btn primary" id="m-lighter-save">Save as "${esc(r.new_name || (m.name + " (lighter)"))}"</button></div>`;
  wireChat(out, "mlight", (answer) => renderMealLighter(m, t, portions, answer));
  out.querySelector("#m-lighter-save").onclick = () => {
    state.meals.unshift({ id: uid(), name: r.new_name || `${m.name} (lighter)`, portions, items, saved: true, updatedAt: new Date().toISOString(), lighterOf: m.id });
    save(); toast("Saved as a new meal"); stack = ["home", "meals"]; show("meals");
  };
}
$("#m-lighter").onclick = async () => {
  if (!aiAvailable()) { aiHelp(); return; }
  const m = mealDraft, t = mealTotals(m), portions = num(m.portions) || 1;
  const lines = m.items.map((it) => { const g = it.grams != null ? it.grams : amountsFor(it, it.kcal || 0).grams; return `${it.name}: ${g != null ? Math.round(g) + " g" : "?"}, ${it.kcal} kcal`; }).join("\n");
  const prompt = `Here is a recipe called "${m.name || "meal"}" making ${portions} portions, ${fmt(t.kcal)} kcal in total (${fmt(t.kcal / portions)} per portion):
${lines}

Make it noticeably lower in calories while keeping it recognisably the same dish and still enjoyable. Prefer swaps people actually have (lighter dairy, less oil or butter, leaner cuts, less sugar, more veg, smaller amounts of the richest items) over exotic ingredients. Return the full new ingredient list with realistic amounts and honest kcal and macro figures per ingredient, marking each as kept, less, swapped or removed. Aim for at least 20% fewer calories if that's achievable without ruining it; say so in the summary if it isn't.`;
  busy("Lightening it…");
  try {
    const r = await askAI(LIGHTER_SCHEMA, [{ type: "text", text: prompt }]);
    busy(false);
    chats.mlight = { schema: LIGHTER_SCHEMA, basePrompt: prompt, turns: [{ ask: "(first version)", answer: r }] };
    renderMealLighter(m, t, portions, r);
  } catch (err) { busy(false); toast(err.message || "Claude couldn't lighten that", 5000); }
};

$("#m-use").onclick = () => { const m = state.meals.find((x) => x.id === mealDraft.id) || mealDraft; draft = { ...mealBasis(m), note: "" }; openShare(); };
function deleteMeal(m) {
  if (!confirm(`Delete "${m.name}"?

Days it was already added to keep their numbers.`)) return false;
  state.meals = state.meals.filter((x) => x.id !== m.id);
  if (mealDraft && mealDraft.id === m.id) { mealDraft = null; state.mealDraft = null; }
  save(); toast(`Deleted ${m.name}`); return true;
}
$("#meal-delete").onclick = () => { if (deleteMeal(mealDraft)) { stack = ["home", "meals"]; show("meals"); } };
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
        ? `<ul class="ate">${items.map((it) => `<li><span>${esc(it.name)}</span><b>${fmt(it.kcal)}</b></li>`).join("")}</ul><button class="btn mint ate-btn" data-act="toggle">Hide</button>`
        : `<div class="items muted tiny">${esc(items.map((it) => it.name).slice(0, 3).join(", "))}${items.length > 3 ? ` and ${items.length - 3} more` : ""}</div><button class="btn mint ate-btn" data-act="toggle">What I had (${items.length}) ▾</button>`;
    } else if (count) body = `<div class="muted tiny">${count} item${count === 1 ? "" : "s"} (logged before history kept the details)</div>`;
    card.innerHTML = `<div class="top"><b>${esc(label)}</b><span class="kcal ${over ? "over" : "ok"}">${fmt(d.kcal)} / ${fmt(d.budget)} kcal</span></div>
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
  save(); toast(`Budget set to ${fmt(state.budget)} kcal`); home();
};

// ---------------------------------------------------------------- settings

function renderSettings() {
  $("#s-budget").value = state.budget;
  $("#s-apikey").value = state.apiKey;
  $("#s-geminikey").value = state.geminiKey || "";
  $("#s-ai-status").textContent = (window.cloud && window.cloud.user && aiProxyState === "yes") ? "Using the shared key from the app's server: nothing to add here." : state.geminiKey ? "Using your Gemini key (free)." : state.apiKey ? "Using your Anthropic key." : "No key yet. A free Google Gemini key from aistudio.google.com is enough.";
  $("#s-version").textContent = APP_VERSION;
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
$("#btn-new-day").onclick = () => {
  if (state.day.items.length && !confirm("Start a fresh day now? Today's list goes into History.")) return;
  archiveDay();
  state.day = { date: localDate(), items: [] };
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
    li.querySelector(".del").onclick = async () => { if (!confirm(`Decline ${personName(f.requester)}'s request?`)) return; try { await c.removeFriend(f.id); renderFriends(); } catch (e) { toast(c.explain(e)); } };
    pl.appendChild(li);
  }
  for (const f of sent) {
    const li = document.createElement("li");
    li.innerHTML = `${avatar(f.addressee, personName(f.addressee))}<div class="body"><div class="name">${esc(personName(f.addressee))}</div><div class="detail">request sent · waiting for them</div></div><button class="del" aria-label="Cancel">✕</button>`;
    li.querySelector(".del").onclick = async () => { if (!confirm(`Cancel the request to ${personName(f.addressee)}?`)) return; try { await c.removeFriend(f.id); renderFriends(); } catch (e) { toast(c.explain(e)); } };
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
    card.querySelector(".del").onclick = async () => { if (!confirm(`Remove ${personName(f.uid)} as a friend?`)) return; try { await c.removeFriend(f.id); renderFriends(); } catch (e) { toast(c.explain(e)); } };
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
    card.innerHTML = `<span class="thumb-sm tone-peach"><svg><use href="#i-meal"/></svg></span><div class="body"><div class="name">${esc(m.name)}</div><div class="detail">${m.portions} portion${m.portions == 1 ? "" : "s"} · ${fmt(m.kcal_per_portion)} kcal each · ${(m.items || []).length} ingredients</div><div class="by">${avatar(m.owner, personName(m.owner))} ${esc(personName(m.owner))}</div></div><button class="add" aria-label="Copy to my meals"><svg><use href="#i-plus"/></svg></button>`;
    card.querySelector(".add").onclick = () => {
      if (state.meals.some((x) => x.copiedFrom === m.id) && !confirm(`You already have "${m.name}". Add another copy?`)) return;
      state.meals.unshift({ id: uid(), name: m.name, portions: +m.portions || 1, items: (m.items || []).map((it) => ({ ...it, id: uid() })), saved: true, copiedFrom: m.id, updatedAt: new Date().toISOString() });
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
      action: { type: "string", enum: ["add", "remove", "update", "set_budget"] },
      target: { type: ["string", "null"], description: "For remove/update: the exact name of the existing item from the list" },
      name: { type: ["string", "null"], description: "For add: what the food is" },
      grams: { type: ["number", "null"], description: "amount in g or ml if known" },
      count: { type: ["number", "null"], description: "how many pieces/servings if that's how they said it" },
      kcal: { type: ["number", "null"], description: "your best estimate of kcal for the amount (add) or the corrected total (update)" },
      protein_g: { type: ["number", "null"] }, carbs_g: { type: ["number", "null"] }, fat_g: { type: ["number", "null"] },
      budget: { type: ["number", "null"], description: "for set_budget" }
    }, required: ["action", "target", "name", "grams", "count", "kcal", "protein_g", "carbs_g", "fat_g", "budget"], additionalProperties: false } }
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
  const prompt = `You maintain someone's food diary for today. Budget ${state.budget} kcal, eaten ${usedKcal()} kcal so far. Today's list:\n${list}\n\nThey say: "${text}"\n\nTurn that into actions on the list. Use "update" with the corrected total kcal (and amount) when they say they had more or less of an existing item; "remove" to take one off; "add" for new things with a realistic kcal estimate for the amount; "set_budget" if they change the day's budget. Match targets to the exact names in the list. If they're only asking a question, return no actions and answer in reply.`;
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

// ---------------------------------------------------------------- Ask Claude: guess a food, plan the rest of the day

const GUESS_SCHEMA = {
  type: "object",
  properties: {
    name: { type: "string", description: "What the food is, short, e.g. 'Chicken katsu curry with rice'" },
    portion_g: { type: "number", description: "Estimated weight of the portion shown or described, in grams (ml for drinks)" },
    unit: { type: "string", enum: ["g", "ml"] },
    kcal_total: { type: "number", description: "Estimated kcal for that whole portion" },
    protein_g: { type: "number" }, carbs_g: { type: "number" }, fat_g: { type: "number" },
    confidence: { type: "string", enum: ["high", "medium", "low"] },
    notes: { type: "string", description: "One short sentence on the assumptions, e.g. 'assumed a restaurant-sized portion with sauce'" }
  },
  required: ["name", "portion_g", "unit", "kcal_total", "protein_g", "carbs_g", "fat_g", "confidence", "notes"],
  additionalProperties: false
};
const GUESS_PROMPT = `Estimate the nutrition of this food as a whole portion, the way it would be eaten. Use typical reference values and realistic portion sizes. If a description is given, trust it over the photo for what the food is; use the photo for portion size. Be honest about confidence.`;
function renderAsk() {
  showAskPreview();
  $("#ask-nokey").classList.toggle("hidden", aiAvailable());
  $("#plan-go").disabled = !aiAvailable();
  $("#plan-out").innerHTML = "";
  renderPlanLeft();
  renderFits();
}
async function guessFood(file) {
  const text = $("#ask-text").value.trim();
  if (!file && !text) { toast("Describe it or take a photo"); return; }
  if (!aiAvailable()) { aiHelp(); return; }
  busy("Thinking…");
  try {
    const content = [];
    let image = null;
    if (file) {
      const img = await loadImage(file);
      image = drawScaled(img, 1280).toDataURL("image/jpeg", 0.85);
      content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: image.split(",")[1] } });
    }
    content.push({ type: "text", text: GUESS_PROMPT + (text ? `\nDescription: "${text}"` : "") });
    const g = await askAI(GUESS_SCHEMA, content);
    busy(false);
    const item = blankItem("claude");
    const portion = num(g.portion_g) || 100;
    item.name = g.name || text || "Something"; item.unit = g.unit === "ml" ? "ml" : "g";
    item.kcalPer100 = Math.round((num(g.kcal_total) || 0) / portion * 100);
    item.servingSize = Math.round(portion); item.unitLabel = "portion";
    item.kcalPerServing = Math.round(num(g.kcal_total) || 0);
    item.p100 = Math.round((nz(g.protein_g) || 0) / portion * 1000) / 10; item.c100 = Math.round((nz(g.carbs_g) || 0) / portion * 1000) / 10; item.f100 = Math.round((nz(g.fat_g) || 0) / portion * 1000) / 10;
    item.image = image;
    item.note = `Claude's estimate (${g.confidence || "medium"} confidence), not a label. ${g.notes || ""}`;
    draft = item; $("#ask-text").value = ""; askFile = null; showAskPreview();
    openDetails("Claude's estimate");
  } catch (err) { busy(false); toast(err.message || "Claude couldn't help with that", 5000); }
}
// Photo first, then a chance to say what it is (A5 wagyu nigiri looks like a lot of things), then Estimate.
let askFile = null;
function showAskPreview() {
  const wrap = $("#ask-preview");
  if (askFile) { $("#ask-img").src = URL.createObjectURL(askFile); wrap.classList.remove("hidden"); $("#ask-text-label").textContent = "What is it?"; $("#ask-words").textContent = "Estimate from photo"; }
  else { wrap.classList.add("hidden"); $("#ask-img").removeAttribute("src"); $("#ask-text-label").textContent = "Describe it"; $("#ask-words").textContent = "Estimate"; }
}
$("#ask-photo").onclick = () => { if (!aiAvailable()) { aiHelp(); return; } $("#file-ask").click(); };
$("#file-ask").addEventListener("change", (e) => { const f = e.target.files[0]; e.target.value = ""; if (f) { askFile = f; showAskPreview(); setTimeout(() => $("#ask-text").focus(), 100); } });
$("#ask-retake").onclick = () => { askFile = null; showAskPreview(); $("#file-ask").click(); };
$("#ask-words").onclick = () => { const f = askFile; guessFood(f); };
$("#ask-text").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.target.blur(); guessFood(askFile); } });

// what's left, and what's short
function dayGaps() {
  const mac = sumMacros(state.day.items), g = state.goals || {};
  return { left: state.budget - usedKcal(), p: g.p ? Math.max(0, g.p - mac.p) : null, c: g.c ? Math.max(0, g.c - mac.c) : null, f: g.f ? Math.max(0, g.f - mac.f) : null, mac };
}
function renderPlanLeft() {
  const d = dayGaps();
  const gaps = [];
  if (d.p != null) gaps.push(`protein ${d.p ? `<b>${Math.round(d.p)} g</b> to go` : "done"}`);
  if (d.c != null) gaps.push(`carbs ${d.c ? `<b>${Math.round(d.c)} g</b> to go` : "done"}`);
  if (d.f != null) gaps.push(`fat ${d.f ? `<b>${Math.round(d.f)} g</b> to go` : "done"}`);
  $("#plan-left").innerHTML = `<div class="left-box"><div class="big">${d.left >= 0 ? fmt(d.left) + " kcal left" : fmt(-d.left) + " kcal over"}</div><div class="gaps">${gaps.length ? gaps.join(" · ") : "Set macro goals on the Daily budget screen to see what you're short on."}</div></div>`;
}
/** Foods from the list that fit the remaining calories, favouring whatever you're short on. */
function renderFits() {
  const d = dayGaps(), list = $("#plan-fits"); list.innerHTML = "";
  if (d.left <= 50) { list.innerHTML = `<li class="muted">Nothing fits: you're at your budget for today.</li>`; return; }
  const scored = [];
  for (const row of (typeof FOODS !== "undefined" ? FOODS : [])) {
    const it = foodItem(row);
    if (!it.servingSize || it.p100 == null) continue;
    const serves = it.servingSize, kcal = it.kcalPer100 * serves / 100;
    if (kcal < 40 || kcal > d.left * 0.45) continue;                          // single foods, not a whole day in one go
    const gp = serves * it.p100 / 100, gc = serves * it.c100 / 100, gf = serves * it.f100 / 100;
    let score = 0;
    if (d.p != null && d.p > 0) score += Math.min(gp, d.p) / d.p * 3;
    if (d.c != null && d.c > 0) score += Math.min(gc, d.c) / d.c;
    if (d.f != null && d.f > 0) score += Math.min(gf, d.f) / d.f;
    if (d.p == null && d.c == null && d.f == null) score = gp / kcal * 10;     // no goals: lean towards protein-dense
    score -= 1.5 * (kcal / d.left);                                              // cheaper in calories wins, all else equal
    scored.push({ it, kcal, score, key: row[0].split(",")[0].toLowerCase() });
  }
  scored.sort((a, b) => b.score - a.score);
  const seen = new Set(), picks = [];
  for (const x of scored) { if (seen.has(x.key)) continue; seen.add(x.key); picks.push(x); if (picks.length >= 8) break; }
  for (const x of picks) {
    const li = resultRow(x.it, "tone-coral");
    li.querySelector(".detail").textContent = `${fmt1(x.it.servingSize)} ${x.it.unit} ${x.it.unitLabel || "serving"} · ${fmt(x.kcal)} kcal · ${macroText(macrosFor(x.it, x.kcal))}`;
    li.onclick = () => { draft = { ...x.it }; openShare(Math.round(x.kcal)); };
    list.appendChild(li);
  }
  if (!picks.length) list.innerHTML = `<li class="muted">Nothing in the list fits in ${fmt(d.left)} kcal.</li>`;
}
const PLAN_SCHEMA = {
  type: "object",
  properties: {
    summary: { type: "string", description: "Two or three friendly sentences: how the day is going and the idea behind the plan" },
    suggestions: { type: "array", items: { type: "object", properties: {
      name: { type: "string" }, amount: { type: "string", description: "e.g. '150 g', '2 eggs', '1 small bar'" },
      kcal: { type: "number" }, protein_g: { type: "number" }, carbs_g: { type: "number" }, fat_g: { type: "number" },
      why: { type: "string", description: "A few words, e.g. 'covers most of the protein gap'" }
    }, required: ["name", "amount", "kcal", "protein_g", "carbs_g", "fat_g", "why"], additionalProperties: false } }
  },
  required: ["summary", "suggestions"],
  additionalProperties: false
};
function renderPlan(plan) {
  const out = $("#plan-out");
  out.innerHTML = `<div class="plan-card"><p>${esc(plan.summary)}</p><ul class="list" id="plan-list"></ul><p class="muted tiny">Tap one to add it with these numbers.</p>${chatBox("plan", "Change something? e.g. no dairy, more protein, swap the treat")}</div>`;
  const ul = out.querySelector("#plan-list");
  for (const sg of plan.suggestions || []) {
    const li = document.createElement("li");
    li.innerHTML = `<span class="thumb-sm"><svg><use href="#i-spark"/></svg></span><div class="body"><div class="name">${esc(sg.name)}</div><div class="detail">${esc(sg.amount)} · ${fmt(sg.kcal)} kcal · P ${Math.round(sg.protein_g)} · C ${Math.round(sg.carbs_g)} · F ${Math.round(sg.fat_g)} · ${esc(sg.why)}</div></div><div class="kcal">${fmt(sg.kcal)}</div>`;
    li.style.cursor = "pointer";
    li.onclick = () => {
      const hit = searchLocal(sg.name)[0];
      if (hit) { draft = { ...foodItem(hit) }; openShare(Math.round(sg.kcal)); return; }
      const item = blankItem("claude");
      item.name = `${sg.name} (${sg.amount})`; item.kcalPerServing = Math.round(sg.kcal); item.unitLabel = "portion";
      item.pServ = nz(sg.protein_g) || 0; item.cServ = nz(sg.carbs_g) || 0; item.fServ = nz(sg.fat_g) || 0;
      draft = item; openShare(Math.round(sg.kcal));
    };
    ul.appendChild(li);
  }
  wireChat(out, "plan", (answer) => renderPlan(answer));
}
$("#plan-go").onclick = async () => {
  if (!aiAvailable()) { aiHelp(); return; }
  const d = dayGaps(), g = state.goals || {};
  const eaten = state.day.items.map((it) => `${it.name} (${it.kcal} kcal)`).join(", ") || "nothing yet";
  const quick = quickEntries().slice(0, 8).map((q) => q.basis.name).join(", ");
  const prompt = `You're helping someone enjoy a cheat day while still landing near their targets.
Budget ${state.budget} kcal, eaten so far ${usedKcal()} kcal: ${eaten}. Left: ${d.left} kcal.
Macro goals: protein ${g.p || "none"} g, carbs ${g.c || "none"} g, fat ${g.f || "none"} g. So far: protein ${Math.round(d.mac.p)} g, carbs ${Math.round(d.mac.c)} g, fat ${Math.round(d.mac.f)} g.
Things they often have: ${quick || "unknown"}.
Suggest 3 to 5 things for the rest of the day that together fit in the calories left, close the macro gaps as far as sensible, and deliberately leave room for one treat or a drink. Give realistic amounts and honest kcal/macro estimates. Keep it warm and short.`;
  busy("Planning…");
  try {
    const plan = await askAI(PLAN_SCHEMA, [{ type: "text", text: prompt }]);
    busy(false);
    chats.plan = { schema: PLAN_SCHEMA, basePrompt: prompt, turns: [{ ask: "(first version)", answer: plan }] };
    renderPlan(plan);
  } catch (err) { busy(false); toast(err.message || "Claude couldn't plan that", 5000); }
};

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
    <button class="btn primary" id="details-lighter-use">Use the lighter version</button></div>`;
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
$("#details-lighter").onclick = async () => {
  if (!aiAvailable()) { aiHelp(); return; }
  const d = readDetails();
  const facts = [`kcal per 100 ${d.unit}: ${d.kcalPer100 ?? "unknown"}`, d.servingSize ? `serving ${d.servingSize} ${d.unit}` : null, d.kcalPerServing ? `${d.kcalPerServing} kcal per serving` : null,
    d.p100 != null ? `per 100: protein ${d.p100} g, carbs ${d.c100} g, fat ${d.f100} g` : null, d.packSize ? `pack ${d.packSize} ${d.unit}` : null].filter(Boolean).join("; ");
  const prompt = `Product: "${d.name}"${d.brand ? ` by ${d.brand}` : ""}. Label facts: ${facts || "none"}.
Someone wants to eat this but lighter. Suggest realistic ways to prepare or eat it with fewer calories while keeping it enjoyable: for example using part of a seasoning or oil sachet, draining, smaller portion, bulking with vegetables or protein, lighter accompaniments. Then estimate the lighter version as one serving: its weight as eaten, kcal and macros. Be honest that these are estimates.`;
  busy("Lightening it…");
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

$("#file-scan").addEventListener("change", async (e) => {
  const file = e.target.files[0]; e.target.value = "";
  if (!file) return;
  if (photoMode === "label") { readLabel(file); return; }
  busy("Looking for a barcode…");
  let code = null;
  try { code = await decodeBarcodeFromFile(file); } catch (err) { console.error(err); }
  busy(false);
  if (code) { lookupBarcode(code); return; }
  if (aiAvailable()) { toast("No barcode found, reading it as a label instead"); readLabel(file); return; }
  toast("No barcode found. Try closer and flatter, or type the number.", 4000);
  $("#barcode-manual").classList.remove("hidden");
});

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
function openShare(prefillKcal) {
  const c = conv(draft);
  $("#share-name").textContent = draft.name;
  $("#share-add").textContent = pick ? "Add to the meal" : editId ? "Save changes" : "Add to today";
  $("#item-talk").value = ""; $("#item-talk-note").classList.add("hidden");
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
$("#share-rest").onclick = () => setAmount(Math.max(0, state.budget - usedKcal()), "kcal");
$("#share-reset").onclick = () => { amountKcal = null; fillAmounts(null); };

function updateResult() {
  const btn = $("#share-add"), bar = $("#r-bar");
  if (!amountKcal) { $("#r-kcal").textContent = "0"; $("#r-sub").textContent = "of your day"; bar.style.width = "0"; $("#r-lines").innerHTML = ""; $("#r-macros").innerHTML = ""; btn.disabled = true; return; }
  const kcal = Math.round(amountKcal);
  const frac = state.budget > 0 ? kcal / state.budget : 0;
  $("#r-kcal").textContent = fmt(kcal);
  $("#r-sub").textContent = `≈ ${fmt(frac * 100, 1)}% of your day`;
  bar.style.width = `${Math.min(100, frac * 100)}%`;
  const a = amountsFor(draft, kcal), lines = [];
  if (a.packFraction != null) lines.push(`<b>${fmt(a.packFraction * 100)}%</b> of the pack`);
  const leftAfter = state.budget - usedKcal() - kcal;
  lines.push(leftAfter >= 0 ? `leaves <b>${fmt(leftAfter)}</b> kcal for the rest of the day` : `<b style="color:var(--bad)">${fmt(-leftAfter)} kcal over</b> your day`);
  $("#r-lines").innerHTML = lines.map((l) => `<div>${l}</div>`).join("");
  $("#r-macros").innerHTML = macroText(macrosFor(draft, kcal), true);
  btn.disabled = false;
}
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

const SYNC_KEYS = ["budget", "day", "history", "recent", "meals", "presetUses", "shareDay", "sharedMealIds", "goals", "updatedAt"];   // the API key stays on the device
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
  const items = state.day.items.map((it) => ({ name: it.name, kcal: it.kcal }));
  c.publishDay({ date: state.day.date, budget: state.budget, kcal: usedKcal(), items }).catch((err) => { if (!publishDay.warned) { publishDay.warned = true; toast("Couldn't share your day: " + c.explain(err), 5000); } });
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
