/* Cheat Days — spend your cheat-day calories on purpose.
 * Everything lives in localStorage on this device. The only network calls are
 * barcode lookups (Open Food Facts) and label photos (Anthropic, only if you've
 * entered an API key in Settings). */
"use strict";

const APP_VERSION = "17";   // keep in step with ?v= in index.html and CACHE in sw.js
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
  const base = { budget: 1600, apiKey: "", day: { date: localDate(), items: [] }, history: [], recent: [], meals: [], presetUses: {}, mealDraft: null };
  try { const raw = localStorage.getItem(STORE_KEY); if (raw) Object.assign(base, JSON.parse(raw)); } catch (e) {}
  if (!Array.isArray(base.recent)) base.recent = [];
  if (!Array.isArray(base.meals)) base.meals = [];
  if (!base.presetUses || typeof base.presetUses !== "object") base.presetUses = {};
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
function shortAmounts(item) {
  const a = amountsFor(item, item.kcal), parts = [];
  if (item.unitLabel && a.servings != null) parts.push(`${fmt1(a.servings)} ${plural(a.servings, item.unitLabel)}`);
  else {
    if (a.grams != null) parts.push(`${fmt1(a.grams)} ${a.unit}`);
    if (a.pieces != null) parts.push(`${fmt1(a.pieces)} pcs`);
    else if (a.servings != null) parts.push(`${fmt1(a.servings)} serv`);
  }
  parts.push(item.shareLabel);
  return parts.join(" · ");
}
const BASIS_KEYS = ["name", "brand", "source", "unit", "unitLabel", "kcalPer100", "servingSize", "kcalPerServing", "packSize", "piecesPerPack", "image", "mealId"];
function basisOf(obj) {
  const b = {};
  for (const k of BASIS_KEYS) if (obj[k] != null && obj[k] !== "") b[k] = obj[k];
  if (b.image && String(b.image).startsWith("data:")) delete b.image;   // never store photos
  return b;
}

// ---------------------------------------------------------------- router

const VIEWS = ["home", "settings", "scan", "search", "meals", "meal", "details", "share"];
let stack = ["home"];
function show(view) {
  for (const v of VIEWS) $(`#view-${v}`).classList.toggle("hidden", v !== view);
  document.body.dataset.view = view;
  window.scrollTo(0, 0);
  if (view !== "scan") stopCamera();
  if (view === "home") renderHome();
  if (view === "settings") renderSettings();
  if (view === "scan") startCamera();
  if (view === "search") openSearch();
  if (view === "meals") renderMeals();
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

function renderHome() {
  const used = usedKcal(), left = state.budget - used;
  $("#home-used").textContent = fmt(used);
  $("#home-budget").textContent = fmt(state.budget);
  const bar = $("#home-bar");
  bar.style.width = `${Math.min(100, state.budget > 0 ? used / state.budget * 100 : 0)}%`;
  bar.classList.toggle("over", left < 0);

  const list = $("#home-list"); list.innerHTML = "";
  for (const it of state.day.items) list.appendChild(itemRow(it));
  $("#home-empty").classList.toggle("hidden", state.day.items.length > 0);
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
  li.querySelector(".del").onclick = (e) => { e.stopPropagation(); state.day.items = state.day.items.filter((x) => x.id !== it.id); save(); renderHome(); };
  li.querySelector(".body").onclick = () => { editId = it.id; draft = { ...basisOf(it), note: "" }; openShare(it.kcal); };
  li.style.cursor = "pointer";
  return li;
}

// --- quick add: presets from presets.js, saved meals, and everything you've added before; most-used first
const LS_QUICK_OPEN = "cheatday.quickOpen";
function quickEntries() {
  const presets = (typeof PRESETS !== "undefined" ? PRESETS : []).map((p) => ({
    key: "preset:" + p.name, preset: true, uses: state.presetUses[p.name] || 0, lastUsed: "",
    basis: { name: p.name, source: "quick", unit: "ml", unitLabel: p.unit || "serving", kcalPerServing: Math.round(p.kcal) },
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
  return { kcal, grams, allWeighed };
}
function mealBasis(meal) {
  const t = mealTotals(meal), portions = num(meal.portions) || 1;
  return {
    name: meal.name || "Meal", source: "meal", mealId: meal.id, unit: "g",
    kcalPer100: t.grams ? t.kcal / t.grams * 100 : null,
    servingSize: t.grams ? t.grams / portions : null,
    kcalPerServing: t.kcal / portions, unitLabel: "portion"
  };
}
function newMeal() { return { id: uid(), name: "", portions: 4, items: [], saved: false }; }
function mealChanged() { state.mealDraft = mealDraft; save(false); renderMeal(); }

function renderMeals() {
  const list = $("#meals-list"); list.innerHTML = "";
  if (state.mealDraft && !state.mealDraft.saved && (state.mealDraft.items.length || state.mealDraft.name)) {
    const li = document.createElement("li");
    li.className = "warn";
    li.innerHTML = `<span class="thumb-sm tone-peach"><svg><use href="#i-meal"/></svg></span><div class="body"><div class="name">${esc(state.mealDraft.name || "Unsaved meal")}</div><div class="detail">Not saved yet · tap to carry on</div></div>`;
    li.onclick = () => { mealDraft = state.mealDraft; go("meal"); };
    list.appendChild(li);
  }
  for (const m of state.meals) {
    const t = mealTotals(m), portions = num(m.portions) || 1;
    const li = document.createElement("li");
    li.innerHTML = `<span class="thumb-sm tone-peach"><svg><use href="#i-meal"/></svg></span>
      <div class="body"><div class="name">${esc(m.name)}</div><div class="detail">${portions} portion${portions === 1 ? "" : "s"} · ${fmt(t.kcal / portions)} kcal each · ${m.items.length} ingredient${m.items.length === 1 ? "" : "s"}</div></div>
      <button class="add" aria-label="Add a portion to today"><svg><use href="#i-plus"/></svg></button>`;
    li.querySelector(".add").onclick = (e) => { e.stopPropagation(); draft = { ...mealBasis(m), note: "" }; openShare(); };
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
        if (act.dataset.act === "remove") { m.items = m.items.filter((x) => x.id !== it.id); openRow = null; mealChanged(); }
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
  $("#m-use").classList.toggle("hidden", !m.saved);
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
$("#m-use").onclick = () => { const m = state.meals.find((x) => x.id === mealDraft.id) || mealDraft; draft = { ...mealBasis(m), note: "" }; openShare(); };
$("#meal-delete").onclick = () => {
  if (!confirm(`Delete "${mealDraft.name}"? Days it was added to keep their numbers.`)) return;
  state.meals = state.meals.filter((x) => x.id !== mealDraft.id);
  state.mealDraft = null; mealDraft = null; save(); back();
};
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

// ---------------------------------------------------------------- settings

function renderSettings() {
  $("#s-budget").value = state.budget;
  $("#s-apikey").value = state.apiKey;
  $("#s-version").textContent = APP_VERSION;
  renderAccount();
  const d = state.day.date;
  $("#s-day").textContent = d === localDate() ? "Today" : new Date(d + "T12:00").toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "short" });
  const h = $("#pastdays-list"); h.innerHTML = "";
  if (!state.history.length) h.innerHTML = `<li class="muted">No past days yet.</li>`;
  for (const p of state.history) {
    const li = document.createElement("li");
    li.innerHTML = `<div class="body"><div class="name">${esc(p.date)}</div><div class="detail">${p.items} item${p.items === 1 ? "" : "s"} · budget ${fmt(p.budget)}</div></div><div class="kcal">${fmt(p.kcal)}</div>`;
    h.appendChild(li);
  }
}
$("#settings-save").onclick = () => {
  const b = num($("#s-budget").value);
  if (!b) { toast("Budget needs to be a number of kcal"); return; }
  state.budget = Math.round(b);
  state.apiKey = $("#s-apikey").value.trim();
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
  if (state.day.items.length && !confirm("Start a fresh day? Today's list moves to past days.")) return;
  if (state.day.items.length) {
    state.history.unshift({ date: state.day.date, budget: state.budget, kcal: usedKcal(), items: state.day.items.length });
    state.history = state.history.slice(0, 60);
  }
  state.day = { date: localDate(), items: [] };
  save(); toast("New day started"); home();
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
  $("#d-thumb").innerHTML = d.image ? `<img src="${esc(d.image)}" alt="">` : `<svg><use href="#i-image"/></svg>`;
  $("#d-badge").classList.toggle("hidden", d.source !== "barcode");
  const note = $("#d-note"); note.textContent = d.note || ""; note.classList.toggle("hidden", !d.note);
  syncUnitEcho();
  go("details");
}
function readDetails() {
  const d = draft;
  d.name = $("#f-name").value.trim(); d.brand = $("#f-brand").value.trim(); d.unit = $("#f-unit").value;
  d.kcalPer100 = num($("#f-kcal100").value); d.servingSize = num($("#f-serving").value);
  d.kcalPerServing = num($("#f-kcalserving").value); d.packSize = num($("#f-pack").value); d.piecesPerPack = num($("#f-pieces").value);
  d.unitLabel = $("#f-piece").value.trim().toLowerCase().replace(/s$/, "") || null;
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
      if (quiet > 4500 && autoReads < 2 && state.apiKey) {
        autoReads++; quietSince = Date.now();
        $("#scan-hint").textContent = "No barcode yet, checking for a nutrition table…";
        const found = await autoReadLabel(video, token);
        if (found || token !== camToken) return;
        $("#scan-hint").textContent = autoReads < 2 ? "Not a nutrition table yet. Get closer, or keep looking for the barcode." : "Point at the barcode, or tap Read the label when the table is in view.";
      } else if (quiet > 4500 && !state.apiKey && autoReads === 0) {
        autoReads = 1;
        $("#scan-hint").textContent = "No barcode? Tap Read the label for a nutrition table (needs the API key in Settings).";
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
  if (document.visibilityState === "visible" && onScanView() && !busyShown()) startCamera();
});

$("#scan-photo").onclick = () => { photoMode = "auto"; $("#file-scan").click(); };
$("#scan-label").onclick = () => {
  if (!state.apiKey) { toast("Add your Anthropic API key in Settings first"); go("settings"); return; }
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
  if (state.apiKey) { toast("No barcode found, reading it as a label instead"); readLabel(file); return; }
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
  const [name, kcal, serving, label, unit, tags] = row;
  const item = blankItem("search");
  item.name = name; item.unit = unit || "g"; item.kcalPer100 = kcal;
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
  $("#search-claude").classList.toggle("hidden", !(query.length >= 2 && state.apiKey));
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
    notes: { type: "string", description: "Assumptions made, e.g. 'assumed cooked without oil', in one short sentence" }
  },
  required: ["name", "unit", "kcal_per_100", "serving_size", "serving_label", "notes"],
  additionalProperties: false
};
$("#search-claude").onclick = async () => {
  const query = $("#q").value.trim();
  if (!query) return;
  if (!state.apiKey) { toast("Add your Anthropic API key in Settings first"); go("settings"); return; }
  busy(`Asking Claude about ${query}…`);
  try {
    const parsed = await askClaude(FOOD_SCHEMA, [{ type: "text", text: `Give typical nutrition for this food as commonly eaten: "${query}". If it's ambiguous, pick the most common preparation and say so in notes. Use standard reference values (USDA / McCance & Widdowson), not guesses.` }]);
    busy(false);
    const item = blankItem("claude");
    item.name = parsed.name || query; item.unit = parsed.unit === "ml" ? "ml" : "g";
    item.kcalPer100 = num(parsed.kcal_per_100) ? Math.round(parsed.kcal_per_100) : null;
    item.servingSize = num(parsed.serving_size); item.unitLabel = parsed.serving_label || null;
    item.kcalPerServing = item.kcalPer100 && item.servingSize ? Math.round(item.kcalPer100 * item.servingSize / 100) : null;
    item.note = "Claude's estimate, not a label. " + (parsed.notes || "");
    draft = item;
    openDetails("Food details");
  } catch (err) { busy(false); toast(err.message || "Claude couldn't help with that", 5000); }
};

// ---------------------------------------------------------------- Claude reads a label

async function readLabel(file) {
  if (!state.apiKey) { toast("Add your Anthropic API key in Settings first"); go("settings"); return; }
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
    piece_name: { type: ["string", "null"], description: "If it's eaten by the piece, what one is called: slice, biscuit, bar, sausage… else null" },
    is_nutrition_label: { type: "boolean", description: "true only if a nutrition table or energy figures are actually visible" },
    confidence: { type: "string", enum: ["high", "medium", "low"] },
    notes: { type: "string", description: "Anything unclear, e.g. 'values are per 30g portion; per-100 not shown'" }
  },
  required: ["name", "brand", "unit", "kcal_per_100", "serving_size", "kcal_per_serving", "pack_size", "pieces_per_pack", "piece_name", "is_nutrition_label", "confidence", "notes"],
  additionalProperties: false
};
const LABEL_PROMPT = `This is a photo of a food or drink product, its nutrition table, or both. Read the energy information off it.
Report only numbers you can actually read on the label; use null for anything not visible rather than guessing.
If energy is given in kJ only, convert to kcal (kcal = kJ / 4.184). If values are per portion only, fill kcal_per_serving and serving_size and leave kcal_per_100 null.
If no nutrition table or energy figure is visible at all, set is_nutrition_label to false and leave the numbers null.`;

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
  const parsed = await askClaude(LABEL_SCHEMA, [
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
  if (!amountKcal) { $("#r-kcal").textContent = "0"; $("#r-sub").textContent = "of your day"; bar.style.width = "0"; $("#r-lines").innerHTML = ""; btn.disabled = true; return; }
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
  btn.disabled = false;
}
$("#share-add").onclick = () => {
  if (!amountKcal || !draft) return;
  const kcal = Math.round(amountKcal);
  if (pick) { mealTakeIngredient(draft, kcal); toast(`${draft.name} is in the meal`); return; }
  if (editId) {
    const it = state.day.items.find((x) => x.id === editId);
    if (it) { it.kcal = kcal; it.shareLabel = `${fmt(kcal / state.budget * 100, 1)}% of the day`; save(); }
    editId = null; toast(`Updated ${draft.name} · ${fmt(kcal)} kcal`); home(); return;
  }
  addToDay(draft, kcal, `${fmt(kcal / state.budget * 100, 1)}% of the day`);
  toast(`Added ${draft.name} · ${fmt(kcal)} kcal`);
  home();
};

// ---------------------------------------------------------------- account + sync (optional, see cloud.js)

const SYNC_KEYS = ["budget", "day", "history", "recent", "meals", "presetUses", "updatedAt"];   // the API key stays on the device
let pushTimer = null;
function schedulePush() {
  if (!window.cloud || !window.cloud.user) return;
  clearTimeout(pushTimer);
  pushTimer = setTimeout(() => {
    const data = {}; for (const k of SYNC_KEYS) data[k] = state[k];
    window.cloud.push(data).catch((err) => toast("Couldn't sync: " + window.cloud.explain(err), 4000));
  }, 600);
}
/** Newest copy wins, whole. One person, one device at a time, so this keeps deletions deleted. */
async function pull() {
  const c = window.cloud; if (!c || !c.user) return;
  let remote;
  try { remote = await c.pull(); } catch (err) { toast("Couldn't sync: " + c.explain(err), 4000); return; }
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
  c.onAuth((u) => { renderAccount(); if (u) pull(); });
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") pull(); });
  if (c.user) pull();
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
