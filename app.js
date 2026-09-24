/* Cheat Days — spend your cheat-day calories on purpose.
 * Everything lives in localStorage on this device. The only network calls are
 * barcode lookups (Open Food Facts) and label photos (Anthropic, only if you've
 * entered an API key in Settings). */
"use strict";

const APP_VERSION = "129";   // keep in step with ?v= in index.html and CACHE in sw.js
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
  load.fresh = false; load.unreadable = false;   // start-up facts for recoverLocal(), never stored
  try { const raw = localStorage.getItem(STORE_KEY); if (raw) { try { Object.assign(base, JSON.parse(raw)); } catch (e) { try { localStorage.setItem(STORE_KEY + ".unreadable", raw); } catch (e2) {} load.unreadable = true; } } else load.fresh = true; } catch (e) { load.fresh = true; }
  delete base.__fresh; delete base.__unreadable;
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
  if (base.goalWeight != null && !(+base.goalWeight > 0)) base.goalWeight = null;
  if (!base.weekGoals || typeof base.weekGoals !== "object") base.weekGoals = { under: 5, protein: 4, workouts: 3, log: 7 };
  if (!Array.isArray(base.seenBadges)) base.seenBadges = [];
  if (!Array.isArray(base.goalWins)) base.goalWins = [];
  if (typeof base.postCount !== "number") base.postCount = 0;
  if (base.session && typeof base.session !== "object") base.session = null;
  return base;
}
let spaceWarned = false;
/** Photo fields that hold the picture itself (data: URLs) rather than a link, anywhere in the stored data. */
function eachPhotoField(fn) {
  const visit = (o) => { if (!o || typeof o !== "object") return; for (const k of ["photo", "image"]) if (typeof o[k] === "string" && o[k].startsWith("data:")) fn(o, k); };
  const lists = { history: state.history.flatMap((h) => Array.isArray(h.items) ? h.items : []), recent: state.recent.map((r) => r.basis), meals: state.meals.concat(state.meals.flatMap((m) => m.items || [])), today: state.day.items.concat(state.mealDraft ? [state.mealDraft] : []) };
  for (const list of Object.values(lists)) for (const o of list) visit(o);
  return lists;
}
/** Storage full: drop pictures stored on the phone, oldest kinds first, until the save fits. */
function freeSpace() {
  const lists = eachPhotoField(() => {});
  for (const where of ["history", "recent", "meals", "today"]) {
    let dropped = 0;
    for (const o of lists[where]) { if (!o) continue; for (const k of ["image", "photo"]) if (typeof o[k] === "string" && o[k].startsWith("data:")) { delete o[k]; dropped++; } }
    if (dropped) { try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); return true; } catch (e) {} }
  }
  return false;
}
function save(sync = true) {
  if (sync) state.updatedAt = Date.now();
  try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); }
  catch (e) {
    if (freeSpace()) { if (!spaceWarned) { spaceWarned = true; toast(window.cloud && window.cloud.user ? "This phone's storage was full, so older photos kept on the phone were removed. New photos go to the cloud." : "This phone's storage was full, so older photos were removed to keep saving. Sign in to keep photos in the cloud.", 7000); } }
    else toast("Couldn't save (storage blocked or full)");
  }
  if (sync) schedulePush();
  if (typeof localBackup === "function") localBackup();
}
const state = load();
/** A deletion to remember for a while, so merging with another device's copy doesn't resurrect it. */
function tomb(kind, id) {
  state.tombs = state.tombs && typeof state.tombs === "object" ? state.tombs : {};
  state.tombs[`${kind}:${id}`] = Date.now();
  const cutoff = Date.now() - 60 * 864e5;
  for (const [k, t] of Object.entries(state.tombs)) if (t < cutoff) delete state.tombs[k];
}
const usedKcal = () => state.day.items.reduce((s, it) => s + it.kcal, 0);
const burnedKcal = () => (state.day.workouts || []).reduce((s, w) => s + (w.kcal || 0), 0);
const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
/** The budget for a date: that weekday's own budget if one is set, else the everyday one. */
const baseBudget = (date = state.day.date) => { const v = state.dayBudgets && state.dayBudgets[new Date(date + "T12:00").getDay()]; return v > 0 ? v : state.budget; };
const budgetToday = () => baseBudget() + (state.eatBack ? burnedKcal() : 0);   // the day's allowance, stretched by workouts only if asked

// ---------------------------------------------------------------- helpers

/** An in-app dialog in place of the browser's confirm() and prompt(). Resolves true/false, or the text (null on cancel). */
function ask(text, opts = {}) {
  return new Promise((resolve) => {
    const wrap = $("#ask-dialog"), input = $("#dlg-input");
    const title = opts.title || (String(text).split("\n")[0].length <= 60 && String(text).includes("\n") ? "" : "");
    $("#dlg-text").textContent = String(text);
    $("#dlg-ok").textContent = opts.ok || "OK";
    $("#dlg-cancel").textContent = opts.cancel || "Cancel";
    $("#dlg-cancel").classList.toggle("hidden", opts.cancel === false);
    $("#dlg-ok").classList.toggle("danger", /^(delete|remove|discard|decline|dismiss)/i.test(String(text)));
    const chips = $("#dlg-choices"); chips.innerHTML = ""; chips.classList.toggle("hidden", !opts.choices);
    $("#dlg-ok").classList.toggle("hidden", !!opts.choices);
    input.classList.toggle("hidden", !opts.input);
    if (opts.input) { input.value = opts.value == null ? "" : String(opts.value); input.type = "text"; input.inputMode = opts.number ? "numeric" : "text"; input.pattern = opts.number ? "[0-9]*" : ""; }
    wrap.classList.remove("hidden");
    const done = (v) => { wrap.classList.add("hidden"); $("#dlg-ok").onclick = $("#dlg-cancel").onclick = null; input.onkeydown = null; resolve(v); };
    if (opts.choices) for (const ch of opts.choices) { const b = document.createElement("button"); b.textContent = ch.label; b.classList.toggle("on", ch.value === opts.value); b.onclick = () => done(ch.value); chips.appendChild(b); }
    $("#dlg-ok").onclick = () => { if (opts.onOk) { try { opts.onOk(); } catch (e) {} } done(opts.input ? input.value : true); };
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
  if (text === false) { b.classList.add("hidden"); $("#busy-sub").textContent = ""; $("#busy-cancel").classList.add("hidden"); return; }
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

const VIEWS = ["home", "budget", "settings", "history", "friends", "compose", "recipe", "workouts", "exercise", "goals", "body", "welcome", "plan", "ask", "chats", "scan", "search", "meals", "meal", "details", "share"];
let stack = ["home"];
function show(view) {
  if (view === "feed") { frSeg = "feed"; view = "friends"; }   // the feed lives in the Friends tab now
  for (const v of VIEWS) $(`#view-${v}`).classList.toggle("hidden", v !== view);
  document.body.dataset.view = view;
  window.scrollTo(0, 0);
  if (view !== "scan") stopCamera();
  if (view === "home") renderHome();
  if (view === "settings") renderSettings();
  if (view === "budget") { renderPlanCards(); renderBudgetBody(); renderDayBudgets(true); $("#b-budget").value = state.budget; $$("#budget-chips button").forEach((b) => b.classList.toggle("on", +b.dataset.b === state.budget)); const g = state.goals || {}; $("#b-p").value = g.p ?? ""; $("#b-c").value = g.c ?? ""; $("#b-f").value = g.f ?? ""; renderManualHead(); $("#b-manual").open = false; $("#bm-warn").classList.toggle("hidden", !state.plan); }
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
  if (view === "plan") renderPlanStep();
  if (view === "friends") showFrSeg(false);
  if (view === "compose") renderCompose();
  $$("#tabbar button").forEach((b) => b.classList.toggle("on", b.dataset.tab === view));
  if (view === "chats") renderChats();
  if (view === "meal") renderMeal();
}
// ---- coming back to a screen puts you where you were on it (Quick add, a long list...)
const scrollMem = {};
function rememberScroll() { const cur = document.body.dataset.view; if (cur) scrollMem[cur] = window.scrollY; }
function restoreScroll(view) { const y = scrollMem[view]; if (y) { window.scrollTo(0, y); requestAnimationFrame(() => window.scrollTo(0, y)); } }
function go(view) { rememberScroll(); stack.push(view); show(view); }
$$("#tabbar button").forEach((b) => b.onclick = () => { const v = b.dataset.tab; if (stack[stack.length - 1] === "share") editId = null; pastAdd = pastEdit = null; stack = v === "home" ? ["home"] : ["home", v]; show(v); });
function back() { if (stack[stack.length - 1] === "share") editId = null; stack.pop(); if (!stack.length) stack = ["home"]; const to = stack[stack.length - 1]; if (to === "history" || to === "home") pastAdd = pastEdit = null; show(to); restoreScroll(to); }
function home() { const from = document.body.dataset.view; pick = null; editId = null; pastAdd = pastEdit = null; stack = ["home"]; show("home"); if (from === "share" || from === "details") restoreScroll("home"); }   // after adding something, back where you were

document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-go]"); if (b) { const v = b.dataset.go; v === "manual" ? openManual() : go(v); return; }
  if (e.target.closest("[data-back]")) back();
});

// ---------------------------------------------------------------- home

/** A new calendar day: file today under History and start clean. Runs on open, on return, and on every home render. */
function archiveDay() {
  if (!state.day.items.length && !(state.day.workouts || []).length) return;
  const m = sumMacros(state.day.items);
  state.history.unshift({ date: state.day.date, budget: budgetToday(), kcal: usedKcal(), items: state.day.items.map((it) => ({ ...basisOf(it), kcal: it.kcal, shareLabel: it.shareLabel, addedAt: it.addedAt || null, meal: it.meal || null })),
    p: Math.round(m.p), c: Math.round(m.c), f: Math.round(m.f), burned: burnedKcal(), workouts: (state.day.workouts || []).map((w) => ({ name: w.name, minutes: w.minutes, kcal: w.kcal, lifts: w.lifts || [] })) });
  state.history = state.history.slice(0, 400);
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
  applySimple();
  renderHomeWeigh();
  const used = usedKcal(), budget = budgetToday(), left = budget - used, burned = burnedKcal();
  $("#home-used").textContent = fmt(used);
  $("#home-budget").textContent = state.eatBack && burned ? `${fmt(baseBudget())} + ${fmt(burned)}` : fmt(baseBudget());
  $("#home-budget-label").textContent = baseBudget() !== state.budget ? `${WEEKDAYS[new Date(state.day.date + "T12:00").getDay()]} budget` : "Daily budget";
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

  $("#home-left").textContent = left >= 0 ? ` · ${fmt(left)} left` : ` · ${fmt(-left)} over`;
  $("#home-left").classList.toggle("over", left < 0);
  renderTodayList();
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
  renderHomePlan();
  setTimeout(maybeAskReminders, 2500);
  renderLevelCard();
}
// ---- today's food, grouped by meal (by the time it was logged, unless moved)
const MEALS = ["Breakfast", "Lunch", "Dinner", "Snacks"];
// What kind of food it is says a lot about the meal: oats are breakfast, a sandwich is lunch, curry is dinner.
const MEAL_WORDS = {
  Breakfast: /\b(oats?|porridge|granola|muesli|cereal|cornflakes|weetabix|shreddies|bran flakes|toast|bagel|croissant|pain au|pancakes?|waffles?|crumpets?|eggs?|omelette|scrambled|bacon|full english|yogh?urt|smoothie|overnight oats)\b/i,
  Lunch: /\b(sandwich|sarnie|wrap|panini|baguette|sub|salad|soup|toastie|meal deal|sushi|poke|burrito bowl)\b/i,
  Dinner: /\b(curry|pasta|spaghetti|lasagne|bolognese|chilli|steak|roast|stir.?fry|risotto|pizza|burger|fajitas?|tacos?|casserole|stew|pie|salmon|noodles|kebab|shepherd'?s|cottage pie|fish and chips|dinner)\b/i,
  Snacks: /\b(crisps|chocolate|biscuits?|cookies?|cake|brownie|sweets|nuts|popcorn|protein bar|flapjack|ice cream|donut|doughnut|muffin|beer|wine|cider|gin|vodka|whisky|rum|cocktail|jack daniel)\b/i
};
const timeMeal = (h) => h == null ? "Snacks" : h >= 4 && h < 11 ? "Breakfast" : h >= 11 && h < 15 ? "Lunch" : h >= 17 && h < 22 ? "Dinner" : "Snacks";
function guessMeal(name, h) {
  // the clock decides at meal times; the food only settles the in-between times (3-5pm, late night)
  const byTime = timeMeal(h), n = String(name || "");
  if (h == null) return byTime;
  const hits = MEALS.filter((m) => MEAL_WORDS[m].test(n));
  if (!hits.length) return byTime;
  if (hits.includes("Breakfast") && h >= 11 && h < 12) return "Breakfast";   // brunch: porridge at 11:30 is still breakfast
  if (byTime !== "Snacks") return byTime;
  if (hits.includes("Lunch") && h >= 15 && h < 17) return "Lunch";            // a late lunch
  if (hits.includes("Dinner") && (h >= 15 || h < 2)) return "Dinner";         // an early or a late dinner
  return "Snacks";
}
function mealOf(it) {
  if (MEALS.includes(it.meal)) return it.meal;
  return guessMeal(it.name, it.addedAt ? new Date(it.addedAt).getHours() : null);
}
let todayAll = false;
function renderTodayList() {
  const list = $("#home-list"), items = state.day.items; list.innerHTML = "";
  const groups = MEALS.map((g) => ({ g, its: items.filter((it) => mealOf(it) === g) })).filter((x) => x.its.length);
  const compact = items.length > 5 && !todayAll;   // a busy day: one line per meal until "Show all"
  for (const { g, its } of groups) {
    const total = its.reduce((a, it) => a + (it.kcal || 0), 0);
    if (compact) {
      const li = document.createElement("li"); li.className = "sum";
      li.innerHTML = `<div class="body"><div class="name">${g}</div><div class="detail">${esc(its.map((it) => it.name).join(", "))}</div></div><div class="kcal">${fmt(total)}</div>`;
      li.onclick = () => { todayAll = true; renderTodayList(); };
      list.appendChild(li); continue;
    }
    const head = document.createElement("li"); head.className = "grp"; head.innerHTML = `<span>${g}</span><span>${fmt(total)}</span>`;
    list.appendChild(head);
    for (const it of its) list.appendChild(itemRow(it));
  }
  const more = $("#home-more");
  more.classList.toggle("hidden", items.length <= 5);
  more.textContent = todayAll ? "Show less" : `Show all ${items.length} items`;
  more.onclick = () => { todayAll = !todayAll; renderTodayList(); };
  $("#home-empty").classList.toggle("hidden", items.length > 0);
  $("#today-total").textContent = items.length ? `${fmt(items.reduce((x, it) => x + (it.kcal || 0), 0))} kcal` : "";
}
function iconFor(source) {
  return { barcode: "barcode", label: "camera", quick: "plus", search: "search", claude: "search", meal: "meal" }[source] || "pen";
}
function itemRow(it) {
  const li = document.createElement("li");
  const pic = it.photo || it.image;
  const thumb = pic ? `<img class="thumb-sm" src="${esc(pic)}" alt="">` : `<span class="thumb-sm"><svg><use href="#i-${iconFor(it.source)}"/></svg></span>`;
  li.innerHTML = `${thumb}
    <div class="body"><div class="name">${esc(it.name || "Unnamed")}</div><div class="detail">${esc(String(shortAmounts(it)).replace(/[\s·]+$/, ""))}</div></div>
    <div class="kcal">${fmt(it.kcal)}</div>
    <button class="del" aria-label="Remove">✕</button>`;
  li.querySelector(".del").onclick = async (e) => { e.stopPropagation(); if (!await ask(`Remove "${it.name}" from today?`)) return; tomb("item", it.id); state.day.items = state.day.items.filter((x) => x.id !== it.id); save(); renderHome(); };
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
    detail: p.detail || "", lastKcal: Math.round(p.kcal), lastShareLabel: `${fmt(Math.round(p.kcal) / baseBudget() * 100, 1)}% of the day`
  }));
  const meals = state.meals.map((m) => {
    const b = mealBasis(m), kcal = Math.round(b.kcalPerServing || 0);
    return { key: "meal:" + m.id, meal: true, uses: m.uses || 0, lastUsed: m.lastUsed || "", basis: b,
      detail: `1 portion of ${m.portions || 1} · ${fmt(kcal)} kcal`, lastKcal: kcal, lastShareLabel: `${fmt(kcal / baseBudget() * 100, 1)}% of the day` };
  });
  return presets.concat(meals, state.recent.map((r) => ({ ...r, uses: r.uses || 0 })))
    .sort((a, b) => (b.uses - a.uses) || String(b.lastUsed || "").localeCompare(String(a.lastUsed || "")));
}
/** How often each food was had at breakfast, lunch, dinner or as a snack, from the days with times kept. */
function mealHabits() {
  const c = {}, add = (it) => { if (!it || !(it.addedAt || it.meal)) return; const k = String(it.name || "").toLowerCase(), g = mealOf(it); (c[k] = c[k] || {})[g] = (c[k][g] || 0) + 1; };
  state.day.items.forEach(add);
  for (const h of state.history.slice(0, 60)) if (Array.isArray(h.items)) h.items.forEach(add);
  return c;
}
/** Quick add, ordered for now: what you usually have at this time of day, then your saved meals, then the rest. */
function quickSections(entries) {
  const now = timeMeal(new Date().getHours()), habits = mealHabits();
  const fit = (q) => {   // times had at this meal, counted only if this is one of its main meals
    const h = habits[String(q.basis.name || "").toLowerCase()] || {}, n = h[now] || 0, top = Math.max(0, ...Object.values(h));
    return n && n * 2 >= top ? n : 0;
  };
  const scored = entries.map((q) => ({ q, f: fit(q) }));
  const usual = scored.filter((x) => x.f > 0).sort((a, b) => (b.f - a.f) || (b.q.uses - a.q.uses)).slice(0, 6).map((x) => x.q);
  const rest = entries.filter((q) => !usual.includes(q)), meals = rest.filter((q) => q.meal), other = rest.filter((q) => !q.meal);
  return [
    { title: `Your usual ${now === "Snacks" ? "snacks" : now.toLowerCase()}`, items: usual },
    { title: "Your meals", items: meals },
    { title: usual.length || meals.length ? "Other favourites" : "", items: other }
  ].filter((s) => s.items.length);
}
function renderQuick() {
  const list = $("#quick-list"); list.innerHTML = "";
  const entries = quickEntries();
  let open = false; try { open = localStorage.getItem(LS_QUICK_OPEN) === "1"; } catch (e) {}
  $("#quick-toggle").classList.toggle("open", open);
  list.classList.toggle("hidden", !open);
  $("#quick-hint").classList.toggle("hidden", !open || entries.length === 0);
  $("#quick-sub").textContent = entries.length ? `${entries.length} thing${entries.length === 1 ? "" : "s"} you have often` : "Things you add come back here";
  for (const sec of quickSections(entries)) {
  if (sec.title) { const h = document.createElement("li"); h.className = "qgrp"; h.textContent = sec.title; list.appendChild(h); }
  for (const q of sec.items) {
    const li = document.createElement("li");
    const b = q.basis;
    const detail = String(q.detail || shortAmounts({ ...b, kcal: q.lastKcal, shareLabel: q.lastShareLabel })).replace(/[\s·]+$/, "");
    const qp = b.photo || b.image;
    const thumb = qp ? `<img class="thumb-sm" src="${esc(qp)}" alt="">` : `<span class="thumb-sm ${q.meal ? "tone-peach" : ""}"><svg><use href="#i-${iconFor(b.source)}"/></svg></span>`;
    li.innerHTML = `${thumb}
      <div class="body"><div class="name">${esc(b.name)}</div><div class="detail">${esc(detail)}</div></div>
      <div class="kcal">${fmt(q.lastKcal)}</div><button class="add" aria-label="Add"><svg><use href="#i-plus"/></svg></button>`;
    li.querySelector(".add").onclick = (e) => { e.stopPropagation(); addToDay(b, q.lastKcal, q.lastShareLabel); toast(`Added ${b.name} · ${fmt(q.lastKcal)} kcal`); };
    li.querySelector(".body").onclick = () => { draft = { ...b, note: "" }; openShare(q.lastKcal); };
    if (!q.preset && !q.meal) longPress(li, async () => {
      if (await ask(`Remove "${b.name}" from Quick add?`)) { tomb("recent", q.key); state.recent = state.recent.filter((r) => r.key !== q.key); save(); renderQuick(); }
    });
    list.appendChild(li);
  }
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
let mealEditing = false;
$("#m-edit").onclick = () => { mealEditing = true; renderMeal(); setTimeout(() => $("#m-name").focus(), 60); };
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
  if (!renderMeal.lastId || renderMeal.lastId !== m.id) { $("#m-lighter-out").innerHTML = ""; mealEditing = false; }
  renderMeal.lastId = m.id;
  // a saved meal reads like a recipe card; Edit turns the boxes back on
  const viewing = !!m.saved && !mealEditing;
  $("#view-meal").classList.toggle("viewing", viewing);
  $("#m-view").classList.toggle("hidden", !viewing);
  if (viewing) { $("#mv-name").textContent = m.name || "Meal"; const n = num(m.portions) || 1; $("#mv-portions").textContent = `Makes ${n} portion${n === 1 ? "" : "s"}`; }
  const steps = Array.isArray(m.steps) ? m.steps.filter((x) => String(x).trim()) : [];
  $("#mv-steps").classList.toggle("hidden", !(viewing && steps.length));
  if (viewing) $("#mv-steps-list").innerHTML = steps.map((st) => `<li>${esc(String(st).replace(/^\d+[.)]\s*/, ""))}</li>`).join("");
  $("#m-edit").classList.toggle("hidden", !viewing);
  $("#meal-title").textContent = viewing ? "Meal" : m.saved ? "Edit meal" : "New meal";
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
    if (openRow === it.id && !viewing) {
      const actions = document.createElement("div");
      actions.className = "row-actions";
      actions.innerHTML = `<button data-act="amount" ${it.unresolved ? "disabled" : ""}>Amount</button><button data-act="swap">${it.unresolved ? "Pick it" : "Swap product"}</button><button data-act="remove" class="danger">Remove</button>`;
      li.appendChild(actions);
    }
    if (viewing) li.classList.add("plain");
    li.onclick = async (e) => {
      if (viewing) return;
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
  const sharing = state.sharedMealIds.includes(m.id);
  $("#m-share-friends").innerHTML = sharing ? "<b>Stop sharing with friends</b><small>Take it out of your friends' Meals</small>" : "<b>Share with friends</b><small>It stays in your friends' Meals so they can use it</small>";
  // the three ways to share sit behind one button
  $("#m-share-open").classList.toggle("hidden", !m.saved);
  $("#m-share-sheet").classList.add("hidden");
  $("#m-share-open").classList.remove("open");
  $$("#m-share-sheet .share-opt:not(.hidden)").forEach((b, i) => b.classList.toggle("first", i === 0));
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
  mealEditing = false; renderMeal();
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
$("#m-share-open").onclick = () => { const sh = $("#m-share-sheet"), open = sh.classList.toggle("hidden") === false; $("#m-share-open").classList.toggle("open", open); if (open) sh.scrollIntoView({ block: "nearest" }); };
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
/** If they asked for a number (kcal or protein per portion), check the AI's sums and send it back once to fix them. */
function mealTargets(instruction) {
  const t = String(instruction || "").toLowerCase(), out = {};
  const k = /(\d{2,4})\s*(?:k?cal|calories)/.exec(t); if (k) out.kcal = +k[1];
  const p = /(\d{1,3})\s*g?\s*(?:of\s+)?protein/.exec(t) || /protein\D{0,12}(\d{1,3})\s*g?/.exec(t); if (p) out.protein = +p[1];
  return out;
}
async function checkMealTarget(r, instruction, portions, prompt) {
  const want = mealTargets(instruction); if (!want.kcal && !want.protein) return r;
  const totals = (x) => { const its = (x.ingredients || []).filter((i) => !/removed/i.test(i.change)); return { kcal: its.reduce((s, i) => s + (nz(i.kcal) || 0), 0) / portions, protein: its.reduce((s, i) => s + (nz(i.protein_g) || 0), 0) / portions }; };
  const got = totals(r), off = (want.kcal && Math.abs(got.kcal - want.kcal) > want.kcal * 0.07) || (want.protein && Math.abs(got.protein - want.protein) > Math.max(4, want.protein * 0.1));
  if (!off) return r;
  busy("Checking the sums…");
  const fix = `${prompt}

Your first answer was:
${JSON.stringify(r.ingredients)}
Adding it up gives ${fmt(got.kcal)} kcal and ${fmt(got.protein)} g protein per portion, but they asked for ${want.kcal ? `${want.kcal} kcal` : ""}${want.kcal && want.protein ? " and " : ""}${want.protein ? `${want.protein} g protein` : ""} per portion. Change the ingredient amounts (kcal must stay consistent with the grams) until the per-portion totals land within 3% of that, then answer again in full.`;
  try { const r2 = await askAI(LIGHTER_SCHEMA, [{ type: "text", text: fix }]); const g2 = totals(r2); const better = (!want.kcal || Math.abs(g2.kcal - want.kcal) <= Math.abs(got.kcal - want.kcal)) && (!want.protein || Math.abs(g2.protein - want.protein) <= Math.abs(got.protein - want.protein)); return better ? r2 : r; } catch (e) { return r; }
}
async function mealAsk(instruction) {
  if (!aiAvailable()) { aiHelp(); return; }
  const m = mealDraft, t = mealTotals(m), portions = num(m.portions) || 1;
  const lines = m.items.map((it) => { const g = it.grams != null ? it.grams : amountsFor(it, it.kcal || 0).grams; return `${it.name}: ${g != null ? Math.round(g) + " g" : "?"}, ${it.kcal} kcal`; }).join("\n");
  const prompt = `${(state.notes || "").trim() ? `About this person: ${state.notes.trim()}\n` : ""}Here is a recipe called "${m.name || "meal"}" making ${portions} portions, ${fmt(t.kcal)} kcal in total (${fmt(t.kcal / portions)} per portion):
${lines}

The person asks: "${instruction}"
Return the full new ingredient list with realistic amounts and honest kcal and macro figures per ingredient (standard reference values; kcal must match the grams: kcal = grams × kcal-per-100 ÷ 100), marking each as kept, less, more, swapped or removed, and a name for the new version (new_name).
Rules: change amounts, not just labels. If they give a target (kcal or protein per portion, or "double it"), work it out: per portion = total ÷ ${portions} portions, and adjust the main ingredients until the per-portion figure lands within 3% of the target, keeping the dish recognisable. Before answering, add up every ingredient's kcal and protein and state the per-portion totals in the summary. Say what changed and what it does to the taste.`;
  busy("Thinking…");
  try {
    let r = await askAI(LIGHTER_SCHEMA, [{ type: "text", text: prompt }]);
    r = await checkMealTarget(r, instruction, portions, prompt);
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
  tomb("meal", m.id); state.meals = state.meals.filter((x) => x.id !== m.id);
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
// ---- a month calendar coloured by budget, and weekly averages under it
let calMonth = null;   // "YYYY-MM"
function dayRecord(date) {
  if (date === localDate()) return state.day.items.length ? { date, kcal: usedKcal(), budget: budgetToday() } : null;
  const h = state.history.find((x) => x.date === date);
  return h && (h.kcal || (Array.isArray(h.items) && h.items.length)) ? h : null;
}
const budgetClass = (r) => !r || !r.budget ? "" : r.kcal <= r.budget ? "ok" : r.kcal <= r.budget * 1.1 ? "near" : "over";
function renderCalendar() {
  const today = localDate();
  if (!calMonth) calMonth = today.slice(0, 7);
  const [y, mo] = calMonth.split("-").map(Number);
  const first = new Date(y, mo - 1, 1), daysIn = new Date(y, mo, 0).getDate(), lead = (first.getDay() + 6) % 7;
  $("#cal-title").textContent = first.toLocaleDateString(undefined, { month: "long", year: "numeric" });
  $("#cal-next").disabled = calMonth >= today.slice(0, 7);
  const grid = $("#cal-days"); grid.innerHTML = "";
  for (let i = 0; i < lead; i++) grid.insertAdjacentHTML("beforeend", `<span class="cal-day blank"></span>`);
  for (let d = 1; d <= daysIn; d++) {
    const date = `${calMonth}-${String(d).padStart(2, "0")}`, rec = dayRecord(date), cls = budgetClass(rec);
    const b = document.createElement("button");
    b.className = `cal-day ${cls}${date === today ? " today" : ""}${date > today ? " future" : ""}`;
    b.innerHTML = `${d}${rec ? `<small>${fmt(Math.round(rec.kcal / 100) / 10, 1)}k</small>` : ""}`;
    if (rec) b.onclick = () => {
      if (date === today) { home(); return; }
      histOpen.add(date); renderHistory();
      const card = document.querySelector(`#history-list [data-date="${date}"]`);
      if (card) { window.scrollTo(0, card.getBoundingClientRect().top + window.scrollY - innerHeight / 2 + card.offsetHeight / 2); card.classList.add("flash"); setTimeout(() => card.classList.remove("flash"), 1400); }
    };
    else b.disabled = true;
    grid.appendChild(b);
  }
  $("#cal-weeks").innerHTML = "";
}
$("#cal-prev").onclick = () => { const [y, m] = calMonth.split("-").map(Number); const d = new Date(y, m - 2, 1); calMonth = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`; renderCalendar(); };
$("#cal-next").onclick = () => { const [y, m] = calMonth.split("-").map(Number); const d = new Date(y, m, 1); calMonth = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`; renderCalendar(); };
function ateList(items, editable) {
  const row = (it) => `<li${editable ? ` data-i="${items.indexOf(it)}"` : ""}><span>${it.photo ? `<img class="pic" src="${esc(it.photo)}" alt="">` : ""}${esc(it.name)}</span><b>${fmt(it.kcal)}</b>${editable ? `<button class="x" aria-label="Remove">✕</button>` : ""}</li>`;
  if (!items.some((it) => it.addedAt || it.meal)) return items.map(row).join("");   // older days: no times kept
  return MEALS.map((g) => { const its = items.filter((it) => mealOf(it) === g); return its.length ? `<li class="ate-grp"><span>${g}</span><b>${fmt(its.reduce((a, it) => a + (it.kcal || 0), 0))}</b></li>${its.map(row).join("")}` : ""; }).join("");
}
// ---- fixing a past day: change or remove what's there, or add something you missed
let pastAdd = null, pastEdit = null;   // a date to add to; { date, i } of an item being changed
const pastLabel = (date) => new Date(date + "T12:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
function recalcPastDay(h) {
  h.kcal = Math.round((h.items || []).reduce((x, it) => x + (it.kcal || 0), 0));
  const m = sumMacros(h.items || []); h.p = Math.round(m.p); h.c = Math.round(m.c); h.f = Math.round(m.f);
}
function addToPastDay(date) { pastAdd = date; pastEdit = null; editId = null; pick = null; go("search"); }
function editPastItem(date, i) {
  const h = state.history.find((x) => x.date === date), it = h && h.items[i]; if (!it) return;
  pastEdit = { date, i }; pastAdd = null; editId = null; pick = null;
  draft = { ...basisOf(it), note: "" }; openShare(it.kcal);
}
function savePastItem(kcal) {
  const date = pastAdd || pastEdit.date, h = state.history.find((x) => x.date === date); if (!h) return;
  const hour = { Breakfast: 8, Lunch: 13, Dinner: 19, Snacks: 16 }[shareMeal] || 12, at = new Date(date + "T00:00"); at.setHours(hour);
  if (pastEdit) { const it = h.items[pastEdit.i]; if (it) { Object.assign(it, basisOf(draft)); it.kcal = kcal; it.meal = shareMeal; } }
  else h.items.push({ ...basisOf(draft), kcal, shareLabel: "", addedAt: at.toISOString(), meal: shareMeal });
  recalcPastDay(h); save();
  toast(`${pastEdit ? "Updated" : "Added"} ${draft.name} · ${pastLabel(date)}`);
  pastAdd = pastEdit = null;
  histOpen.add(date); stack = ["home", "history"]; show("history");
  const card = document.querySelector(`#history-list [data-date="${date}"]`); if (card) card.scrollIntoView({ block: "center" });
}
function renderHistory() {
  renderCalendar();
  const list = $("#history-list"); list.innerHTML = "";
  const wk = state.history.filter((h) => h.date >= dateMinus(6)), tr = trainingDays(7);
  const eaten = wk.reduce((a, h) => a + (h.kcal || 0), 0) + usedKcal(), burned = tr.reduce((a, d) => a + d.burned, 0), n = tr.reduce((a, d) => a + d.count, 0);
  const daysCounted = wk.length + (state.day.items.length ? 1 : 0);
  $("#history-week").classList.add("hidden");
  $("#history-week").innerHTML = `<b>Last 7 days</b><span>${daysCounted ? `${fmt(eaten / Math.max(1, daysCounted))} kcal a day on average` : "nothing eaten logged"}${n ? ` · ${n} workout${n === 1 ? "" : "s"}, ${fmt(burned)} kcal burned` : " · no workouts"}</span>`;
  const days = state.history.slice().sort((a, b) => String(b.date).localeCompare(String(a.date)));
  $("#history-empty").classList.toggle("hidden", days.length > 0);
  const today = localDate();
  const mondayOf = (date) => { const x = new Date(date + "T12:00"); x.setDate(x.getDate() - ((x.getDay() + 6) % 7)); return localDate(x); };
  const thisMon = mondayOf(today), lastMon = (() => { const x = new Date(thisMon + "T12:00"); x.setDate(x.getDate() - 7); return localDate(x); })();
  const wAll = bodyPast().filter((r) => r.weight), oddW = wAll.length >= 4 ? trendOf(wAll.map((r) => ({ day: r.day, v: r.weight }))).odd : [];
  const weights = wAll.filter((r, i) => !oddW[i]);   // unusual readings don't make a week look like a big gain
  let week = null;
  for (const d of days) {
    const mon = mondayOf(d.date);
    if (mon !== week) {
      week = mon;
      const dates = Array.from({ length: 7 }, (_, i) => { const x = new Date(mon + "T12:00"); x.setDate(x.getDate() + i); return localDate(x); });
      const recs = dates.map(dayRecord).filter(Boolean), on = recs.filter((r) => r.budget && r.kcal <= r.budget).length;
      const avg = recs.length ? recs.reduce((a, r) => a + r.kcal, 0) / recs.length : 0;
      const w = weights.filter((r) => r.day >= dates[0] && r.day <= dates[6]), change = w.length > 1 ? w[w.length - 1].weight - w[0].weight : null;
      const wo = dates.reduce((a, dt) => a + ((dt === today ? state.day.workouts : (state.history.find((h) => h.date === dt) || {}).workouts) || []).length, 0);
      const label = (x) => new Date(x + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short" });
      const title = mon === thisMon ? "This week" : mon === lastMon ? "Last week" : `${label(dates[0])} – ${label(dates[6])}`;
      list.insertAdjacentHTML("beforeend", `<div class="week-head"><div><b>${title}</b><small>${on} of ${recs.length} day${recs.length === 1 ? "" : "s"} on budget${change != null ? ` · ${change > 0 ? "+" : "−"}${fmt(Math.abs(change), 1)} kg` : ""}${wo ? ` · ${wo} workout${wo === 1 ? "" : "s"}` : ""}</small></div><div class="avg"><b>${fmt(avg)}</b><small> kcal a day</small></div></div>`);
    }
    const card = document.createElement("div");
    card.className = "card day-card"; card.dataset.date = d.date;
    const label = d.date === dateMinus(1) ? "Yesterday" : new Date(d.date + "T12:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
    const over = d.kcal > d.budget, pct = d.budget ? Math.min(100, d.kcal / d.budget * 100) : 0;
    const items = Array.isArray(d.items) ? d.items : [];
    const count = typeof d.items === "number" ? d.items : items.length;
    let body = "";
    if (items.length) {
      body = histOpen.has(d.date)
        ? `<ul class="ate ate-edit">${ateList(items, true)}</ul><p class="muted tiny hist-tip">Tap a food to change it or move its meal.</p><div class="hist-acts"><button class="btn mint slim" data-act="add">＋ Add something</button><button class="btn ghost slim" data-act="toggle">Hide</button></div>`
        : `<div class="items muted tiny">${esc(items.map((it) => it.name).slice(0, 3).join(", "))}${items.length > 3 ? ` and ${items.length - 3} more` : ""}</div><button class="btn mint ate-btn" data-act="toggle">What I had (${items.length}) ▾</button>`;
    } else if (count) body = `<div class="muted tiny">${count} item${count === 1 ? "" : "s"} (logged before history kept the details)</div>`;
    card.innerHTML = `<div class="top"><b>${esc(label)}</b><span class="kcal ${over ? "over" : "ok"}">${fmt(d.kcal)} / ${fmt(d.budget)} kcal</span></div>${(d.workouts || []).length ? `<div class="hist-wo">${d.workouts.map((w, k) => `<button class="hist-w" data-w="${k}"><svg><use href="#i-dumbbell"/></svg>${esc(w.name)} · ${w.minutes} min · ${fmt(w.kcal)} kcal${(w.lifts || []).length ? `<small>${esc(w.lifts.map(liftText).join(" · "))}</small>` : ""}</button>`).join("")}</div>` : ""}
      <span class="bar"><span style="width:${pct}%" class="${over ? "over" : ""}"></span></span>
      ${d.p != null ? `<div class="macros">${macroText({ p: d.p, c: d.c, f: d.f }, true)}</div>` : ""}${body}`;
    const tog = card.querySelector("[data-act=toggle]");
    if (tog) tog.onclick = () => { if (histOpen.has(d.date)) histOpen.delete(d.date); else histOpen.add(d.date); renderHistory(); };
    card.querySelectorAll(".hist-w").forEach((b) => b.onclick = () => editWorkoutMinutes(d.workouts[+b.dataset.w], () => { d.burned = d.workouts.reduce((x, w) => x + (w.kcal || 0), 0); save(); renderHistory(); }));
    const addBtn = card.querySelector("[data-act=add]");
    if (addBtn) addBtn.onclick = () => addToPastDay(d.date);
    card.querySelectorAll(".ate-edit li[data-i]").forEach((li) => {
      const i = +li.dataset.i;
      li.onclick = (e) => { if (e.target.closest(".x")) return; editPastItem(d.date, i); };
      li.querySelector(".x").onclick = async (e) => {
        e.stopPropagation(); const it = d.items[i]; if (!it || !await ask(`Remove ${it.name} from ${label}?`)) return;
        d.items.splice(i, 1); recalcPastDay(d); save(); renderHistory(); toast(`Removed ${it.name}`);
      };
    });
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
function renderManualHead() {
  const days = Object.keys(state.dayBudgets || {}).length, g = state.goals || {};
  $("#bm-n").innerHTML = `${fmt(state.budget)}<small>kcal · ${days ? "varies by day" : "same every day"}</small>`;
  const mac = [g.p ? `protein ${g.p} g` : "", g.c ? `carbs ${g.c} g` : "", g.f ? `fat ${g.f} g` : ""].filter(Boolean).join(" · ");
  $("#bm-s").textContent = mac ? mac.charAt(0).toUpperCase() + mac.slice(1) : "No macro goals set";
}
$("#budget-save").onclick = () => {
  const b = num($("#b-budget").value);
  if (!b) { toast("Budget needs to be a number of kcal"); return; }
  state.budget = Math.round(b);
  const days = {};
  if (!$("#b-same").checked) for (const [w, v] of Object.entries(dayDraft)) if (v && v !== state.budget) days[w] = v;
  state.dayBudgets = days;
  state.goals = { p: num($("#b-p").value) ? Math.round(num($("#b-p").value)) : null, c: num($("#b-c").value) ? Math.round(num($("#b-c").value)) : null, f: num($("#b-f").value) ? Math.round(num($("#b-f").value)) : null };
  const extra = [1, 2, 3, 4, 5, 6, 0].filter((w) => state.dayBudgets[w]).map((w) => `${WEEKDAYS[w].slice(0, 3)} ${fmt(state.dayBudgets[w])}`);
  save(); toast(`Budget set to ${fmt(state.budget)} kcal${extra.length ? `; ${extra.join(", ")}` : ""}`); home();
};

// ---------------------------------------------------------------- settings

// ---- budgets per weekday: edited as a draft, kept on Save
let dayDraft = {}, daySel = null;
const kShort = (n) => n >= 1000 ? `${fmt(Math.round(n / 100) / 10, 1)}k` : fmt(n);
function renderDayBudgets(fresh) {
  if (fresh) { dayDraft = Object.assign({}, state.dayBudgets || {}); daySel = new Date(state.day.date + "T12:00").getDay(); $("#b-same").checked = !Object.keys(dayDraft).length; }
  const same = $("#b-same").checked, base = fresh ? state.budget : (num($("#b-budget").value) || state.budget), today = new Date(state.day.date + "T12:00").getDay();
  $("#b-days-wrap").classList.toggle("hidden", same);
  if (same) return;
  $("#b-days").innerHTML = [1, 2, 3, 4, 5, 6, 0].map((w) => { const v = dayDraft[w]; return `<button data-w="${w}" class="${v ? "custom" : ""}${w === daySel ? " sel" : ""}${w === today ? " today" : ""}"><b>${WEEKDAYS[w].slice(0, 2)}</b><small>${kShort(v || base)}</small></button>`; }).join("");
  $("#b-day-label").textContent = WEEKDAYS[daySel];
  const input = $("#b-day-val");
  if (document.activeElement !== input) input.value = dayDraft[daySel] || "";
  input.placeholder = `${fmt(base)} (everyday)`;
  $("#b-day-reset").classList.toggle("hidden", !dayDraft[daySel]);
}
$("#b-days").addEventListener("click", (e) => { const b = e.target.closest("button"); if (!b) return; daySel = +b.dataset.w; $("#b-day-val").value = dayDraft[daySel] || ""; renderDayBudgets(); });
$("#b-day-val").addEventListener("input", (e) => { const v = num(e.target.value); if (v && v >= 500 && v <= 10000) dayDraft[daySel] = Math.round(v); else delete dayDraft[daySel]; renderDayBudgets(); });
$("#b-day-reset").onclick = () => { delete dayDraft[daySel]; $("#b-day-val").value = ""; renderDayBudgets(); };
$("#b-same").addEventListener("change", () => renderDayBudgets());
$("#b-budget").addEventListener("input", () => renderDayBudgets());
function renderSettings() {
  $("#s-apikey").value = state.apiKey;
  $("#s-geminikey").value = state.geminiKey || "";
  $("#s-ai-status").textContent = (window.cloud && window.cloud.user && aiProxyState === "yes") ? "Using the shared key from the app's server: nothing to add here." : state.geminiKey ? "Using your Gemini key (free)." : state.apiKey ? "Using your Anthropic key." : "No key yet. A free Google Gemini key from aistudio.google.com is enough.";
  $("#s-version").textContent = APP_VERSION;
  let bytes = 0; try { bytes = (localStorage.getItem(STORE_KEY) || "").length * 2; } catch (e) {}
  let onPhone = 0; eachPhotoField(() => onPhone++);
  $("#s-storage").textContent = `Stored on this phone: ${(bytes / 1048576).toFixed(1)} MB of about 5 MB.${window.cloud && window.cloud.user ? (photoBucketMissing ? " Photos can't go to the cloud yet: the photos bucket isn't set up." : onPhone ? ` ${onPhone} photo${onPhone === 1 ? "" : "s"} still to move to the cloud.` : " Photos are kept in the cloud.") : " Sign in to keep photos in the cloud."}`;
  $("#s-eatback").checked = !!state.eatBack;
  $("#s-simple").checked = !!state.simple;
  applyTheme();
  renderReminders();
  renderAccount();
}
$("#settings-save").onclick = () => {
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
// ---- friends: a card each, as before, with a little more on them: streak and level, the week as dots,
//      and a tap opens their day by meal with Cheer and Send
const frCheered = new Set();
function drawFriendRows(friends, dayLabel) {
  const c = window.cloud, today = localDate(), fl = $("#fr-list"); fl.innerHTML = "";
  fr.lastFriends = friends; fr.lastDayLabel = dayLabel;
  $("#seg-friends").classList.toggle("nofriends", !friends.length);
  if (!friends.length) return;
  const stats = (uid) => ((lbCache && lbCache.rows) || []).find((r) => r.user_id === uid) || null;
  const isWorkout = (it) => /^Workout: /.test(String(it.name || ""));
  const mon = new Date(today + "T12:00"); mon.setDate(mon.getDate() - ((mon.getDay() + 6) % 7));
  const week = Array.from({ length: 7 }, (_, k) => { const x = new Date(mon); x.setDate(x.getDate() + k); return localDate(x); });
  // their date can differ from ours (family abroad), so a day they've touched in the last 18 hours is still their today
  const current = (d) => !!d && (String(d.day) === today || Date.parse(d.updated_at || 0) > Date.now() - 18 * 3600e3);
  friends.map((f) => {
    const days = fr.days.filter((x) => x.user_id === f.uid);
    const d = days.slice().sort((p, q) => String(q.day).localeCompare(String(p.day)))[0];
    const all = d && Array.isArray(d.items) ? d.items : [], food = all.filter((it) => !isWorkout(it));
    return { f, d, days, all, food, active: !!(food.length && current(d)) };
  }).sort((p, q) => q.active - p.active).forEach((cd) => fl.appendChild(friendCard(cd)));

  function friendCard({ f, d, days, all, food, active }) {
    const name = personName(f.uid), st = stats(f.uid), open = frOpen.has(f.uid);
    const card = document.createElement("div"); card.className = `card friend-card fc${active ? "" : " quiet"}${open ? " open" : ""}`;
    const dot = (day) => {
      const x = days.find((y) => String(y.day) === day);
      if (day > today) return `<i class="future"></i>`;
      if (!x || !x.budget) return `<i class="none${day === today ? " today" : ""}"></i>`;
      return `<i class="${x.kcal <= x.budget ? "ok" : x.kcal <= x.budget * 1.1 ? "near" : "over"}${day === today ? " today" : ""}"></i>`;
    };
    let right = `<span class="fc-when">nothing shared yet</span>`, bar = "", line = "";
    if (d) {
      const over = d.kcal > d.budget * 1.1, near = !over && d.kcal > d.budget, pct = d.budget ? Math.min(100, d.kcal / d.budget * 100) : 0;
      right = active ? `<span class="fc-k${over ? " over" : near ? " near" : ""}">${fmt(d.kcal)}<small> / ${fmt(d.budget)}</small></span>` : `<span class="fc-when">${esc(dayLabel(String(d.day)))} ${fmt(d.kcal)}</span>`;
      if (active && String(d.day) !== today) right += `<span class="fc-tz">their ${new Date(d.day + "T12:00").toLocaleDateString(undefined, { weekday: "long" })}</span>`;
      if (active) bar = `<span class="bar"><span style="width:${pct}%" class="${over ? "over" : near ? "near" : ""}"></span></span>`;
      line = active ? esc(food.map((it) => it.name).slice(0, 3).join(", ") + (food.length > 3 ? ` and ${food.length - 3} more` : "")) : "Nothing logged today yet";
    }
    const wo = all.filter(isWorkout);
    card.innerHTML = `${avatar(f.uid, name, true)}<div class="body">
        <div class="fc-top"><b>${esc(name)}</b>${right}</div>
        ${st ? `<div class="fc-tag">🔥 ${st.streak || 0} day${st.streak === 1 ? "" : "s"} · Level ${st.level || 1}</div>` : ""}
        ${bar}
        <div class="fc-week">${week.map((day) => dot(day)).join("")}</div>
        ${line ? `<div class="fc-line">${line}${active ? `<svg class="fc-chev${open ? " up" : ""}"><use href="#i-chev"/></svg>` : ""}</div>` : ""}
        ${open ? `<div class="fc-open">
          ${active ? `<ul class="ate">${ateList(food)}</ul>` : ""}
          ${active && wo.length ? `<ul class="ate"><li class="ate-grp"><span>Workouts</span><b></b></li>${wo.map((w) => `<li><span>${esc(String(w.name).replace(/^Workout: /, ""))}</span><b>−${fmt(-w.kcal)}</b></li>`).join("")}</ul>` : ""}
          <div class="fr-acts"><button class="btn mint slim" data-act="cheer"${frCheered.has(f.uid) ? " disabled" : ""}>${frCheered.has(f.uid) ? "Cheered 👏" : "👏 Cheer"}</button><button class="btn ghost slim" data-act="send">Send food</button><button class="fc-menu" data-act="menu" aria-label="More options"><svg><use href="#i-more"/></svg></button></div>
          <div class="fr-send hidden"></div>
          <div class="fc-menu-box hidden"><button class="fc-remove fr-remove">Remove ${esc(name)} as a friend</button></div>
        </div>` : ""}
      </div>`;
    card.onclick = (e) => { if (e.target.closest("button, .fr-send")) return; if (frOpen.has(f.uid)) frOpen.delete(f.uid); else frOpen.add(f.uid); drawFriendRows(fr.lastFriends, fr.lastDayLabel); };
    if (!open) return card;
    card.querySelector("[data-act=cheer]").onclick = (e) => {
      notifyFriend(f.uid, "react", "your day", { emoji: "👏" }); frCheered.add(f.uid);
      e.target.textContent = "Cheered 👏"; e.target.disabled = true; toast(`You cheered ${name} on 👏`);
    };
    card.querySelector("[data-act=send]").onclick = () => {
      const box = card.querySelector(".fr-send"); box.classList.toggle("hidden");
      if (box.classList.contains("hidden")) return;
      const mine = state.day.items;
      box.innerHTML = mine.length ? `<p class="muted tiny">Send one of today's:</p><div class="chips left">${mine.map((it, k) => `<button data-k="${k}">${esc(it.name)}</button>`).join("")}</div>` : `<p class="muted tiny">Log something first, then send it from here.</p>`;
      box.querySelectorAll("[data-k]").forEach((b) => b.onclick = async () => {
        const it = mine[+b.dataset.k]; b.disabled = true;
        try {
          notifyFriend(f.uid, "send", it.name); state.sendCount = (state.sendCount || 0) + 1; save(false);
          await c.sendItem(f.uid, { name: it.name, kcal: Math.round(it.kcal), grams: it.grams != null ? Math.round(it.grams) : null, unit: it.unit || "g", photo: await sharablePhoto(it.photo), payload: basisOf(it) });
          toast(`Sent ${it.name} to ${name}`); box.classList.add("hidden");
        } catch (err) { b.disabled = false; toast("Couldn't send: " + c.explain(err), 5000); }
      });
    };
    card.querySelector("[data-act=menu]").onclick = () => card.querySelector(".fc-menu-box").classList.toggle("hidden");
    card.querySelector(".fr-remove").onclick = async () => { if (!await ask(`Remove ${name} as a friend? You'll stop seeing each other's days.`)) return; try { await c.removeFriend(f.id); renderFriends(); } catch (err) { toast(c.explain(err)); } };
    return card;
  }
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
  $("#fr-list-title").classList.toggle("hidden", !(pending.length || sent.length) || !fr.friendships.some((f) => f.status === "accepted"));
  $("#fr-dot").textContent = pending.length; $("#fr-dot").classList.toggle("hidden", !pending.length);
  $("#fr-code-sub").textContent = `Your code ${fr.profile.friend_code || "…"} · your name and privacy`;
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
  if (state.friendCount !== friends.length) { state.friendCount = friends.length; save(); checkBadges(); }
  const today = localDate();
  const fl = $("#fr-list"); fl.innerHTML = "";
  
  const dayLabel = (day) => day === today ? "today" : day === dateMinus(1) ? "yesterday" : new Date(day + "T12:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
  drawFriendRows(friends, dayLabel);
  $("#fr-empty").classList.toggle("hidden", friends.length > 0);
  publishStats(); renderLeaderboards(true);
  // the week
  const byUser = {};
  for (const d of fr.days) { (byUser[d.user_id] = byUser[d.user_id] || []).push(d); }
  if (!byUser[me] && state.shareDay) byUser[me] = [{ user_id: me, day: today, budget: budgetToday(), kcal: usedKcal() }];
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
// ---- the Friends tab: Feed, Friends and Leaderboard behind one switch
let frSeg = (() => { try { return localStorage.getItem("cheatday.frSeg") || "feed"; } catch (e) { return "feed"; } })();
function showFrSeg(remember = true) {
  if (!["feed", "friends", "board"].includes(frSeg)) frSeg = "feed";
  if (remember) { try { localStorage.setItem("cheatday.frSeg", frSeg); } catch (e) {} }
  $$("#fr-seg button").forEach((b) => b.classList.toggle("on", b.dataset.s === frSeg));
  for (const k of ["feed", "friends", "board"]) $(`#seg-${k}`).classList.toggle("hidden", k !== frSeg);
  if (frSeg === "feed") renderFeed();
}
$("#fr-seg").addEventListener("click", (e) => { const b = e.target.closest("button"); if (!b) return; frSeg = b.dataset.s; showFrSeg(); window.scrollTo(0, 0); });
$("#fr-refresh").onclick = () => { renderFriends(); if (frSeg === "feed") renderFeed(); };
$("#fr-add-toggle").onclick = () => { const w = $("#fr-connect"), open = w.classList.toggle("hidden") === false; if (open) setTimeout(() => $("#fr-add").focus(), 50); };
// one leaderboard: days on budget, or the goals / level / streak rankings
let frBoard = "budget";
document.addEventListener("click", (e) => {
  const b = e.target.closest(".fr-board-modes button"); if (!b) return;
  frBoard = b.dataset.m;
  $$(".fr-board-modes button").forEach((x) => x.classList.toggle("on", x === b));
  $("#fr-week").classList.toggle("hidden", frBoard !== "budget");
  $("#fr-lb").classList.toggle("hidden", frBoard === "budget");
  $("#fr-board-note").textContent = { budget: "Days on budget this week, from the days friends share.", week: "Weekly goals done this week.", level: "Everyone's level and XP.", streak: "Days in a row logging food." }[frBoard];
  if (frBoard !== "budget") { lbMode = frBoard; drawLeaderboard($("#fr-lb")); }
});
$("#g-lb-link").onclick = () => { frSeg = "board"; go("friends"); };
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
if ($("#talk-go")) { $("#talk-go").onclick = () => talk(); $("#talk").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.target.blur(); talk(); } }); }
async function talk() {
  const text = $("#talk").value.trim(); if (!text) return;
  if (!aiAvailable()) { aiHelp(); return; }
  const list = state.day.items.map((it) => `- "${it.name}": ${it.kcal} kcal${(() => { const a = amountsFor(it, it.kcal); return a.grams != null ? `, ${Math.round(a.grams)} ${it.unit || "g"}` : ""; })()}`).join("\n") || "(nothing yet)";
  const prompt = `You maintain someone's food diary for today. Budget ${budgetToday()} kcal, eaten ${usedKcal()} kcal so far. Today's list:\n${list}\n\nThey say: "${text}"\n\nTurn that into actions on the list. Use "update" with the corrected total kcal (and amount) when they say they had more or less of an existing item; "remove" to take one off; "add" for new things with a realistic kcal estimate for the amount; "set_budget" if they change the day's budget; "workout" when they did exercise (activity from the list, minutes, effort, and for gym sessions the lifts as sets × reps at kg). Match targets to the exact names in the list. If they're only asking a question, return no actions and answer in reply.`;
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
    return { label: `Remove ${it.name} (${fmt(it.kcal)} kcal)`, run: () => { tomb("item", it.id); state.day.items = state.day.items.filter((x) => x.id !== it.id); } };
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
    return { label: `${it.name}: ${fmt(it.kcal)} → ${fmt(kcal)} kcal`, run: () => { it.kcal = kcal; it.shareLabel = `${fmt(kcal / baseBudget() * 100, 1)}% of the day`; } };
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
    return { label: `Add ${basis.name}${amt ? `, ${amt}` : ""} (${fmt(kcal)} kcal)`, run: () => addToDay(basis, kcal, `${fmt(kcal / baseBudget() * 100, 1)}% of the day`) };
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
      confidence: { type: "string", enum: ["high", "medium", "low"] }, notes: { type: "string" },
      parts: { type: "array", description: "each component on the plate, including cooking oil, butter and sauces as their own parts", items: { type: "object", properties: {
        name: { type: "string", description: "plain name, e.g. roast chicken breast" },
        usda_name: { type: "string", description: "the closest USDA FoodData Central SR Legacy description, e.g. 'Chicken, broilers or fryers, breast, meat only, cooked, roasted'" },
        grams: { type: "number", description: "as eaten (cooked weight)" }, kcal: { type: "number" }, protein_g: { type: "number" }, carbs_g: { type: "number" }, fat_g: { type: "number" }
      }, required: ["name", "usda_name", "grams", "kcal", "protein_g", "carbs_g", "fat_g"], additionalProperties: false } }
    }, required: ["name", "portion_g", "unit", "kcal_total", "protein_g", "carbs_g", "fat_g", "confidence", "notes", "parts"], additionalProperties: false },
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
      target_kcal: { type: ["number", "null"], description: "the calorie limit per portion they asked for (or what's left today if they asked it to fit), else null" },
      ingredients: { type: "array", items: { type: "object", properties: {
        name: { type: "string" }, grams: { type: "number", description: "g, or ml for liquids" }, kcal: { type: "number" }, protein_g: { type: "number" }, carbs_g: { type: "number" }, fat_g: { type: "number" }
      }, required: ["name", "grams", "kcal", "protein_g", "carbs_g", "fat_g"], additionalProperties: false } },
      steps: { type: "array", items: { type: "string" }, description: "short numbered method steps" },
      notes: { type: "string" }
    }, required: ["name", "portions", "target_kcal", "ingredients", "steps", "notes"], additionalProperties: false },
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
    li.querySelector(".del").onclick = async (e) => { e.stopPropagation(); if (!await ask(`Delete this chat?`)) return; tomb("chat", c.id); state.chats = state.chats.filter((x) => x.id !== c.id); if (chatId === c.id) newChat(); save(); renderChats(); };
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
let askFridge = false;
const FRIDGE_ASK = "This is my fridge / cupboard. What can I cook from what you can see, that fits what I have left today?";
function addAskFiles(list) {
  for (const f of list) if (askFiles.length < 5) askFiles.push(f);
  showAskPreview();
  if (askFridge) { askFridge = false; if (!$("#ask-text").value.trim()) $("#ask-text").value = FRIDGE_ASK; }
  setTimeout(() => $("#ask-text").focus(), 100);
}
function bubble(role, html) {
  const el = document.createElement("div");
  el.className = `bubble ${role}`; el.innerHTML = html;
  $("#ask-thread").appendChild(el);
  scrollThread();
  return el;
}
$("#ask-clear").onclick = () => { newChat(); toast("New chat"); };
$("#ask-about-btn").onclick = () => { const p = $("#ask-about"), open = p.classList.toggle("hidden") === false; if (open) { $("#b-notes").value = state.notes || ""; setTimeout(() => $("#b-notes").focus(), 50); } };
$("#ask-about-save").onclick = () => { state.notes = $("#b-notes").value.trim(); save(); $("#ask-about").classList.add("hidden"); toast(state.notes ? "Saved: the assistant will use this" : "Cleared"); };
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
  if (q === "fridge") { if (!aiAvailable()) { aiHelp(); return; } askFridge = true; $("#ask-photo").click(); return; }
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
${state.plan ? `Their plan: ${PLAN_GOALS[state.plan.goal].name}, ${state.plan.kcal} kcal a day${state.plan.rate ? ` (${state.plan.rate > 0 ? "+" : ""}${state.plan.rate} kg a week)` : ""}, protein ${state.plan.macros.p} g, training ${state.plan.trainDays} days a week. ` : ""}Lifting: ${liftingSummary()}. Workout routines: ${(state.routines || []).map((r) => `"${r.name}" (${r.exercises.map((e) => e.exercise).join(", ")})`).join("; ") || "none"}. Recent training days: ${trainingDays(14).map((d) => `${d.date}: ${d.names.join(", ")}`).join("; ") || "none"}.`;
}
async function sendAsk() {
  const text = $("#ask-text").value.trim(), files = askFiles.slice();
  if (!text && !files.length) return;
  if (!aiAvailable()) { aiHelp(); return; }
  const images = [];
  for (const f of files) { const img = await loadImage(f); images.push(drawScaled(img, 1024).toDataURL("image/jpeg", 0.85)); }
  const image = images[0] || null;
  bubble("me", `${images.length ? `<div class="shots">${images.map((im) => `<img src="${im}" alt="">`).join("")}</div>` : ""}${esc(text || "(photos)")}`);
  askTurns.push({ role: "me", text: (text || "") + (images.length ? ` (${images.length} photo${images.length === 1 ? "" : "s"})` : "") });
  $("#ask-text").value = ""; askFiles = []; showAskPreview();
  const past = askTurns.slice(-8, -1);
  const lastRecipe = past.slice().reverse().find((t) => t.role === "bot" && t.result && t.result.kind === "recipe" && t.result.recipe);
  const history = past.map((t) => {
    if (t.role === "me") return `They: ${t.text}`;
    const r = t.result || {}; let line = `You: ${t.text}`;
    if (r.kind === "recipe" && r.recipe && t !== lastRecipe) line += ` [an earlier recipe: ${recipeSummary(r.recipe)}]`;
    if (r.kind === "plan" && r.plan) line += ` [suggested: ${(r.plan.suggestions || []).map((x) => `${x.name} ${fmt(x.kcal)} kcal`).join(", ")}]`;
    if (r.kind === "lighter" && r.lighter) line += ` [lighter ${r.lighter.name}: ${fmt(r.lighter.kcal_per_serving)} kcal]`;
    return line;
  }).join("\n");
  const current = lastRecipe ? `THE RECIPE YOU'RE WORKING ON, current version: ${recipeSummary(lastRecipe.result.recipe, true)}
If they want it changed, start from exactly this version: change only what they ask, keep every other ingredient and amount the same, never bring back something they asked to remove, and say in the reply exactly what changed and the new calories per portion.
` : "";
  const prompt = `You are the assistant inside a cheat-day food diary app. ${dayContext()}
${history ? `Recent conversation:\n${history}\n` : ""}${current}They now say: "${text || "(photos, no words)"}"${images.length === 1 ? " (a photo is attached. If it shows food to log, use it for what the food is and the portion size, trusting their words over the photo for the name. If it shows the inside of a fridge, a cupboard or loose ingredients, treat it as what they have to cook with)" : images.length > 1 ? ` (${images.length} photos are attached, in order. They may show the dish, a menu or label for it, and what was left over at the end. Use the menu or label for names and stated nutrition, the dish photo for the portion, and subtract anything shown left over so the estimate is what was actually eaten.)` : ""}.

Decide what they want and fill exactly one of estimate / plan / edit / recipe / lighter (leave the others null), or kind=answer for a plain question:
- estimate: a food or plate to log, as one portion with honest kcal and macros, broken into parts (each component with its cooked grams, and oil, butter or sauce as separate parts) so the app can check each against a food database.
- plan: 3 to 5 things for the rest of today that fit the calories left, close the macro gaps as far as sensible, and leave room for one treat.
- edit: they're correcting today's list ("I only had 2 eggs", "remove the toast", "add a banana") or logging exercise (action "workout": activity from Walk, Run, Cycle, Swim, Gym weights, HIIT, Yoga / stretch, Football, Tennis / padel, Hike, Rowing, Elliptical, Dance, Boxing, Climbing, Other; minutes; effort; for gym sessions the lifts as sets × reps at kg); match targets to the exact names given above.
- recipe: a dish to cook, with realistic ingredient amounts, kcal and macros per ingredient (standard reference values, so the numbers add up), and short method steps. If they give a calorie limit, or ask it to fit what's left today, put that in target_kcal and check the per-portion total is at or under it before you answer. To make it tastier within the limit, pay for anything you add by trimming something else (oil, cheese, the carb portion) in the same answer, rather than adding and removing things over several turns. If a photo shows a fridge, cupboard or ingredients, build the recipe mainly from what's visible (assume basics like oil, salt, pepper and spices), size one portion to fit the calories left today, and name two other dishes they could make instead in the reply.
- lighter: a lighter way to have something, with tips and the lighter serving's numbers.
Estimates use standard reference values. Keep reply short and friendly.`;
  const content = [];
  for (const im of images) content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: im.split(",")[1] } });
  content.push({ type: "text", text: prompt });
  const thinking = bubble("bot", `<span class="muted ai-live">Thinking… <span class="secs"></span><a href="#" class="cancel">Cancel</a></span>`);
  try {
    const r = await askAI(ASSIST_SCHEMA, content);
    if (r.kind === "estimate" && r.estimate) r.estimate = await groundEstimate(r.estimate);
    thinking.remove();
    askTurns.push({ role: "bot", text: r.reply, kind: r.kind, result: r });
    renderAssistant(r, image);
    saveChat();
  } catch (err) { thinking.innerHTML = err.message === "Cancelled" ? `<span class="muted">Stopped. Ask again whenever you like.</span>` : `<span class="over">${esc(err.message || "Something went wrong")}</span>`; }
}
function statRow(kcal, p, c, f) { return `<div><span class="stat"><b>${fmt(kcal)}</b> kcal</span><span class="stat">P <b>${Math.round(p)}</b></span><span class="stat">C <b>${Math.round(c)}</b></span><span class="stat">F <b>${Math.round(f)}</b></span></div>`; }
function renderAssistant(r, image) {
  let html = esc(r.reply || "");
  const el = bubble("bot", html);
  if (r.kind === "estimate" && r.estimate) {
    const g = r.estimate, portion = num(g.portion_g) || 100;
    const parts = (g.parts || []).filter((x) => num(x.grams) > 0), checked = parts.filter((x) => x.src && x.src !== "ai").length;
    const partsHtml = parts.length > 1 || checked ? `<ul class="est-parts">${parts.map((x) => `<li><span class="nm">${esc(x.name)} <span class="muted">${fmt(x.grams)} ${g.unit || "g"}</span></span><span class="kc">${fmt(x.kcal)} kcal</span><span class="src${x.src && x.src !== "ai" ? " ok" : ""}">${x.src === "usda" ? "USDA" : x.src === "list" ? "Food list" : "Estimate"}</span></li>`).join("")}</ul>
      ${checked ? `<p class="tiny fit-line ok est-check">${checked} of ${parts.length} checked against food databases${g.aiKcal && Math.abs(g.aiKcal - g.kcal_total) > g.kcal_total * 0.05 ? ` (the AI first guessed ${fmt(g.aiKcal)} kcal)` : ""}</p>` : ""}` : "";
    el.insertAdjacentHTML("beforeend", `<div class="card"><b>${esc(g.name)}</b> · ${fmt(portion)} ${g.unit || "g"}${statRow(g.kcal_total, g.protein_g, g.carbs_g, g.fat_g)}${partsHtml}<p class="muted tiny">${esc(g.notes || "")} (${g.confidence} confidence)</p><button class="btn primary" data-act="add">Add to today</button><button class="btn mint" data-act="details">See the details first</button></div>`);
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
    el.insertAdjacentHTML("beforeend", `<div class="card"><b>${esc(rc.name)}</b> · ${portions} portion${portions === 1 ? "" : "s"}${statRow(total / portions, mac.p / portions, mac.c / portions, mac.f / portions)}<p class="muted tiny">per portion</p>${rc.target_kcal ? (total / portions <= rc.target_kcal + 10 ? `<p class="tiny fit-line ok">Fits your ${fmt(rc.target_kcal)} kcal limit</p>` : `<p class="tiny fit-line over">${fmt(total / portions - rc.target_kcal)} kcal over your ${fmt(rc.target_kcal)} limit. Say "fit it" and I'll trim it.</p>`) : ""}
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
// ---- checking an AI estimate: each part's calories come from the app's own food list, then USDA, and only then the AI's guess
let foodProxyOk = true;
async function foodLookup(names) {
  const cfg = window.SUPABASE_CONFIG, c = window.cloud;
  if (!foodProxyOk || !cfg || !c || !c.user) return names.map(() => null);
  const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), 6000);
  try {
    const r = await c.rawFetch(`${cfg.url}/functions/v1/food`, { method: "POST", headers: { "Content-Type": "application/json", apikey: cfg.anonKey }, body: JSON.stringify({ foods: names }), signal: ctl.signal });
    if (r.status === 404 || r.status === 500) { foodProxyOk = false; return names.map(() => null); }   // not set up yet: keep the AI's numbers
    if (!r.ok) return names.map(() => null);
    return ((await r.json()).results || []).concat(names.map(() => null)).slice(0, names.length);
  } catch (e) { return names.map(() => null); }
  finally { clearTimeout(timer); }
}
async function groundEstimate(g) {
  const parts = (g.parts || []).filter((x) => num(x.grams) > 0).map((x) => ({ ...x, grams: num(x.grams), src: "ai" }));
  if (!parts.length) return g;
  const ai100 = (x) => (nz(x.kcal) || 0) / x.grams * 100;
  const plausible = (db, x) => { const a = ai100(x); return db != null && (!a || (db >= a * 0.55 && db <= a * 1.8)); };   // a wildly different number means a wrong match
  const use = (x, k, pp, cc, ff, src) => { x.kcal = Math.round(x.grams * k / 100); if (pp != null) { x.protein_g = x.grams * pp / 100; x.carbs_g = x.grams * (cc || 0) / 100; x.fat_g = x.grams * (ff || 0) / 100; } x.src = src; };
  const ask = [];
  parts.forEach((x, i) => { const row = searchLocal(x.name)[0]; if (row && plausible(row[1], x)) use(x, row[1], row[6], row[7], row[8], "list"); else ask.push(i); });
  if (ask.length) {
    const found = await foodLookup(ask.map((i) => parts[i].usda_name || parts[i].name));
    found.forEach((d, k) => { const x = parts[ask[k]]; if (d && plausible(d.kcal100, x)) use(x, d.kcal100, d.p100, d.c100, d.f100, "usda"); });
  }
  if (!parts.some((x) => x.src !== "ai")) return { ...g, parts };
  const sum = (f) => parts.reduce((a, x) => a + (nz(x[f]) || 0), 0);
  return { ...g, parts, aiKcal: g.kcal_total, kcal_total: Math.round(sum("kcal")), protein_g: sum("protein_g"), carbs_g: sum("carbs_g"), fat_g: sum("fat_g"), portion_g: Math.round(sum("grams")) };
}
function estimateToItem(g, image) {
  const item = blankItem("claude"), portion = num(g.portion_g) || 100;
  item.name = g.name || "Something"; item.unit = g.unit === "ml" ? "ml" : "g";
  item.kcalPer100 = Math.round((num(g.kcal_total) || 0) / portion * 100);
  item.servingSize = Math.round(portion); item.unitLabel = "portion"; item.kcalPerServing = Math.round(num(g.kcal_total) || 0);
  item.p100 = Math.round((nz(g.protein_g) || 0) / portion * 1000) / 10; item.c100 = Math.round((nz(g.carbs_g) || 0) / portion * 1000) / 10; item.f100 = Math.round((nz(g.fat_g) || 0) / portion * 1000) / 10;
  item.image = image || null;
  const chk = (g.parts || []).filter((x) => x.src && x.src !== "ai").length;
  item.note = `AI estimate (${g.confidence || "medium"} confidence)${chk ? `, ${chk} of ${g.parts.length} parts checked against food databases` : ""}, not a label. ${g.notes || ""}`;
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
/** A recipe as the app counts it: short for older turns, every ingredient for the one being worked on. */
function recipeSummary(rc, full) {
  const portions = num(rc.portions) || 1, items = (rc.ingredients || []).map(recipeIngredientToItem);
  const total = items.reduce((a, it) => a + it.kcal, 0), mac = sumMacros(items);
  const per = `${fmt(total / portions)} kcal, protein ${Math.round(mac.p / portions)} g, carbs ${Math.round(mac.c / portions)} g, fat ${Math.round(mac.f / portions)} g per portion`;
  if (!full) return `"${rc.name}", ${per}`;
  return `"${rc.name}", ${portions} portion${portions === 1 ? "" : "s"}${rc.target_kcal ? `, limit ${fmt(rc.target_kcal)} kcal a portion` : ""}. Ingredients (whole recipe): ${items.map((it) => `${it.name} ${fmt(it.grams)} ${it.unit || "g"} (${fmt(it.kcal)} kcal)`).join("; ")}. Totals as the app counts them: ${per}.`;
}
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
let bodyMetric = "weight", bodyAt = 0, bodyAll = false, bodyOpen = null;
$("#body-metric").addEventListener("change", (e) => { bodyMetric = e.target.value; drawBody(); });
$("#body-more").onclick = () => { bodyAll = !bodyAll; drawBody(); };
const showBodyForm = (open) => { $("#bd-form").classList.toggle("hidden", !open); $("#bd-form-toggle").classList.toggle("open", open); if (open) $("#bd-add-sheet").classList.add("hidden"); };
$("#bd-form-toggle").onclick = () => showBodyForm($("#bd-form").classList.contains("hidden"));
const bodySorted = () => state.body.slice().sort((a, b) => String(a.day).localeCompare(String(b.day)));
const bodyPast = () => { const today = localDate(); return bodySorted().filter((r) => r.day <= today); };   // a future date is a misread, not a reading
const latestBody = () => { const rows = bodyPast(); return rows[rows.length - 1] || null; };
/** Keep one row per day; newer updatedAt wins. Weight flows into the workout burn estimate. */
function upsertBody(row) {
  if (state.tombs && state.tombs[`body:${row.day}`]) delete state.tombs[`body:${row.day}`];
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
    const gone = state.tombs && state.tombs[`body:${r.day}`];
    if (gone && gone >= (Date.parse(r.updated_at) || 0)) continue;
    const row = { day: r.day, updatedAt: r.updated_at };
    for (const m of BODY_METRICS) if (r[m.key] != null) row[m.key] = +r[m.key];
    upsertBody(row); changed = true;
  }
  if (changed) save();
  return changed;
}
/** A body-measurement chart: faint dots for each reading, a smooth trend through them (a moving average
 *  that weighs the last week or so), soft fill, light gridlines, an optional goal line, and tap-for-value. */
/** A robust local fit (LOWESS): each point's trend comes from a weighted straight line through the readings
 *  within about 2 weeks (at least 5 readings, or 40% of them), and readings far from their neighbours count for less, then
 *  nothing. Returns the trend and which readings look unusual. */
function trendOf(pts, tol = 0.035) {
  const n = pts.length, xs = pts.map((p) => new Date(p.day + "T12:00") / 864e5), ys = pts.map((p) => p.v);
  if (n < 3) return { fit: ys.slice(), odd: ys.map(() => false) };
  const k = Math.min(n, Math.max(5, Math.ceil(n * 0.4))), med = (a) => { const b = a.slice().sort((p, q) => p - q), m = b.length >> 1; return b.length % 2 ? b[m] : (b[m - 1] + b[m]) / 2; };
  const floor = Math.abs(med(ys)) * 0.003 || 0.05;   // readings within ~0.3% are never "unusual" (0.25 kg at 83 kg)
  // unusual: far from the typical reading in the 3 weeks around it (3.5% for weight, ~3 kg at 83 kg, past normal water swings)
  const flag = (skip) => ys.map((v, a) => {
    const nb = ys.filter((_, b) => b !== a && !skip[b] && Math.abs(xs[b] - xs[a]) <= 21);
    if (nb.length < 3) return null;   // not enough to judge
    const m = med(nb), spread = med(nb.map((u) => Math.abs(u - m))) * 1.4826;
    return Math.abs(v - m) > Math.max(tol * Math.abs(m), Math.min(4 * spread, 2 * tol * Math.abs(m)));
  });
  const first = flag(ys.map(() => false)), second = flag(first.map(Boolean));   // second pass: judge against the readings that look normal
  const odd = second.map((v, a) => v == null ? !!first[a] : v);
  let rw = odd.map((o) => o ? 0 : 1), fit = ys.slice();
  for (let it = 0; it < 3; it++) {
    for (let a = 0; a < n; a++) {
      const dist = xs.map((x) => Math.abs(x - xs[a])), h = Math.max(dist.slice().sort((p, q) => p - q)[k - 1], 14) * 1.0001;
      let sw = 0, sx = 0, sy = 0, sxx = 0, sxy = 0, lo = Infinity, hi = -Infinity;
      for (let b = 0; b < n; b++) {
        const u = dist[b] / h; if (u >= 1) continue;
        const w = (1 - u ** 3) ** 3 * rw[b]; if (w <= 0) continue;
        const dx = xs[b] - xs[a]; sw += w; sx += w * dx; sy += w * ys[b]; sxx += w * dx * dx; sxy += w * dx * ys[b];
        if (w > 0.05) { lo = Math.min(lo, ys[b]); hi = Math.max(hi, ys[b]); }
      }
      const den = sw * sxx - sx * sx;
      let v = den > 1e-9 ? (sy * sxx - sx * sxy) / den : sw ? sy / sw : ys[a];
      if (isFinite(lo)) v = Math.min(hi, Math.max(lo, v));   // never overshoot the readings around it
      fit[a] = v;
    }
    const res = ys.map((y, a) => y - fit[a]), mad = Math.max(med(res.map(Math.abs)), floor);
    rw = res.map((r, a) => { if (odd[a]) return 0; const u = r / (6 * mad); return Math.abs(u) < 1 ? (1 - u * u) ** 2 : 0; });
  }
  return { fit, odd };
}
function niceStep(span) { for (const s of [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500]) if (span / s <= 4) return s; return 1000; }
function bodyChart(pts, { dp = 1, goal = null, unit = "" } = {}) {
  if (pts.length < 2) return { html: `<div class="none">${pts.length ? "One reading so far: the line starts with the next one." : "Nothing to chart yet."}</div>`, trend: pts.map((p) => p.v), odd: pts.map(() => false), goalShown: false };
  const W = 320, H = 180, L = 6, R = 34, T = 28, B = 22;
  const tr = trendOf(pts, unit === "kg" ? 0.035 : unit === "%" ? 0.1 : 0.05), trend = tr.fit, days = pts.map((p) => new Date(p.day + "T12:00") / 864e5);
  const vals = pts.filter((p, i) => !tr.odd[i]).map((p) => p.v).concat(trend);   // unusual readings don't stretch the scale
  let lo = Math.min(...vals), hi = Math.max(...vals);
  const spanNow = hi - lo || Math.max(Math.abs(hi) * 0.02, 0.5);
  const goalShown = goal != null && goal >= lo - spanNow * 2.5 && goal <= hi + spanNow * 2.5;   // a goal far off would flatten the line
  if (goalShown) { lo = Math.min(lo, goal); hi = Math.max(hi, goal); }
  const pad = (hi - lo || spanNow) * 0.12; lo -= pad; hi += pad;
  const d0 = days[0], d1 = days[days.length - 1] || d0 + 1;
  const x = (d) => L + (d - d0) / (d1 - d0 || 1) * (W - L - R), y = (v) => T + (hi - v) / (hi - lo) * (H - T - B);
  const step = niceStep(hi - lo), ticks = [];
  for (let v = Math.ceil(lo / step) * step; v <= hi; v += step) ticks.push(Math.round(v * 1000) / 1000);
  const tdp = step < 1 ? 1 : 0;
  const grid = ticks.map((v) => `<line x1="${L}" x2="${W - R + 4}" y1="${y(v)}" y2="${y(v)}" class="cg"/><text x="${W - R + 8}" y="${y(v) + 3.5}" class="ct">${fmt(v, tdp)}</text>`).join("");
  // a smooth path through the trend that never swings past the points it joins (monotone cubic)
  const P = trend.map((v, i) => [x(days[i]), y(v)]), nP = P.length;
  const dxs = P.slice(1).map((p, i) => p[0] - P[i][0] || 1e-6), sl = P.slice(1).map((p, i) => (p[1] - P[i][1]) / dxs[i]);
  const tg = P.map((_, i) => i === 0 ? sl[0] : i === nP - 1 ? sl[nP - 2] : sl[i - 1] * sl[i] <= 0 ? 0 : (sl[i - 1] + sl[i]) / 2);
  for (let i = 0; i < nP - 1; i++) { if (!sl[i]) { tg[i] = tg[i + 1] = 0; continue; } const a = tg[i] / sl[i], b = tg[i + 1] / sl[i], h2 = a * a + b * b; if (h2 > 9) { const t3 = 3 / Math.sqrt(h2); tg[i] = t3 * a * sl[i]; tg[i + 1] = t3 * b * sl[i]; } }
  let path = `M${P[0][0].toFixed(1)},${P[0][1].toFixed(1)}`;
  for (let i = 0; i < nP - 1; i++) {
    const d = dxs[i] / 3;
    path += ` C${(P[i][0] + d).toFixed(1)},${(P[i][1] + tg[i] * d).toFixed(1)} ${(P[i + 1][0] - d).toFixed(1)},${(P[i + 1][1] - tg[i + 1] * d).toFixed(1)} ${P[i + 1][0].toFixed(1)},${P[i + 1][1].toFixed(1)}`;
  }
  const area = `${path} L${P[P.length - 1][0].toFixed(1)},${H - B} L${P[0][0].toFixed(1)},${H - B} Z`;
  const r = pts.length > 60 ? 1.8 : 2.6;
  const clampY = (v) => Math.max(T - 4, Math.min(H - B, y(v)));
  const dots = pts.map((p, i) => `<circle cx="${x(days[i]).toFixed(1)}" cy="${clampY(p.v).toFixed(1)}" r="${tr.odd[i] ? r + 0.8 : r}" class="cd${tr.odd[i] ? " odd" : ""}"/>`).join("");
  const last = P[P.length - 1];
  const goalLine = goalShown ? `<line x1="${L}" x2="${W - R + 4}" y1="${y(goal)}" y2="${y(goal)}" class="cgoal"/><text x="${L + 2}" y="${y(goal) - 5}" class="ctg">Goal ${fmt(goal, dp)}${unit ? " " + unit : ""}</text>` : "";
  const nLab = 4, dateLab = Array.from({ length: nLab }, (_, k) => {
    const d = d0 + (d1 - d0) * k / (nLab - 1), anchor = k === 0 ? "start" : k === nLab - 1 ? "end" : "middle";
    return `<text x="${x(d)}" y="${H - 5}" text-anchor="${anchor}" class="ct">${new Date(d * 864e5).toLocaleDateString(undefined, { day: "numeric", month: "short" })}</text>`;
  }).join("");
  const html = `<svg viewBox="0 0 ${W} ${H}" class="bchart" data-l="${L}" data-r="${R}">
    <defs><linearGradient id="bfill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" style="stop-color:var(--green);stop-opacity:.28"/><stop offset="1" style="stop-color:var(--green);stop-opacity:0"/></linearGradient></defs>
    ${grid}${goalLine}<path d="${area}" fill="url(#bfill)"/>${dots}<path d="${path}" class="cl"/>
    <circle cx="${last[0]}" cy="${last[1]}" r="5" class="cend"/>${dateLab}
    <g class="tip hidden"><line class="tip-l" y1="${T - 6}" y2="${H - B}"/><circle class="tip-c" r="5"/><rect class="tip-b" rx="10" height="20" y="2"/><text class="tip-t" y="16" text-anchor="middle"></text></g></svg>`;
  return { html, trend, odd: tr.odd, goalShown, geo: { days, x, y: (v) => Math.max(T - 4, Math.min(H - B, y(v))), W } };
}
/** Tap or drag across the chart to read any weigh-in. */
function wireChartTip(el, pts, geo, dp, unit) {
  const svg = el.querySelector("svg.bchart"); if (!svg || !geo) return;
  const tip = svg.querySelector(".tip"), line = tip.querySelector(".tip-l"), dot = tip.querySelector(".tip-c"), box = tip.querySelector(".tip-b"), txt = tip.querySelector(".tip-t");
  const show = (ev) => {
    const rect = svg.getBoundingClientRect(), vx = (ev.clientX - rect.left) / rect.width * geo.W;
    let best = 0; geo.days.forEach((d, i) => { if (Math.abs(geo.x(d) - vx) < Math.abs(geo.x(geo.days[best]) - vx)) best = i; });
    const cx = geo.x(geo.days[best]), cy = geo.y(pts[best].v);
    txt.textContent = `${fmt(pts[best].v, dp)}${unit === "%" ? "%" : unit ? " " + unit : ""} · ${new Date(pts[best].day + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short" })}`;
    const w = txt.textContent.length * 5.6 + 16, bx = Math.max(2, Math.min(geo.W - w - 2, cx - w / 2));
    line.setAttribute("x1", cx); line.setAttribute("x2", cx); dot.setAttribute("cx", cx); dot.setAttribute("cy", cy);
    box.setAttribute("x", bx); box.setAttribute("width", w); txt.setAttribute("x", bx + w / 2);
    tip.classList.remove("hidden");
  };
  svg.addEventListener("pointerdown", show); svg.addEventListener("pointermove", (e) => { if (e.buttons || e.pointerType === "mouse") show(e); });
  svg.addEventListener("pointerleave", (e) => { if (e.pointerType === "mouse") tip.classList.add("hidden"); });
}
async function renderBody() {
  renderWeighDays();
  $("#bd-date").value = localDate();
  drawBody();
  if (await pullBody(false)) drawBody();
}
// ---- goal weight: where you're heading and when you'll get there
let goalEditing = false;
const KCAL_PER_KG = 7700;
/** Weight trend from the last 4 weeks of weigh-ins (least squares), in kg per day; null without enough readings. */
function weightTrend() {
  const since = dateMinus(28), wide = bodyPast().filter((r) => r.weight && r.day >= dateMinus(70));
  const odd = wide.length >= 4 ? trendOf(wide.map((r) => ({ day: r.day, v: r.weight }))).odd : [];
  const pts = wide.filter((r, i) => !odd[i] && r.day >= since);   // a misread or someone else on the scale shouldn't set the pace
  if (pts.length < 3) return null;
  const t0 = new Date(pts[0].day + "T12:00") / 864e5, xs = pts.map((r) => new Date(r.day + "T12:00") / 864e5 - t0), ys = pts.map((r) => r.weight);
  if (xs[xs.length - 1] < 7) return null;
  const mx = xs.reduce((a, b) => a + b) / xs.length, my = ys.reduce((a, b) => a + b) / ys.length;
  const num_ = xs.reduce((a, x, i) => a + (x - mx) * (ys[i] - my), 0), den = xs.reduce((a, x) => a + (x - mx) ** 2, 0);
  return den ? { perDay: num_ / den, n: pts.length } : null;
}
/** Energy balance from the last 2 weeks of finished days: what's eaten vs an estimate of what's burned. */
function energyBalance(cur) {
  const since = dateMinus(14), days = state.history.filter((h) => h.date >= since && (h.kcal || 0) > 300);
  if (days.length < 3) return null;
  const eat = days.reduce((a, h) => a + h.kcal, 0) / days.length, burn = days.reduce((a, h) => a + (h.burned || 0), 0) / days.length;
  const lb = bodySorted().slice().reverse(), bmrRow = lb.find((r) => r.bmr), leanRow = lb.find((r) => r.lean);
  const bmr = bmrRow ? bmrRow.bmr : leanRow ? 370 + 21.6 * leanRow.lean : 22 * cur;   // scale's own BMR, else Katch-McArdle, else a rough guess
  const tdee = bmr * 1.3 + burn;
  return { eat, tdee, perDay: (eat - tdee) / KCAL_PER_KG, days: days.length, guessed: !bmrRow && !leanRow };
}
let goalOpen = false;
function renderGoal() {
  const card = $("#goal-card"), rows = bodyPast().filter((r) => r.weight), cur = rows.length ? rows[rows.length - 1].weight : state.weightKg;
  const goal = state.goalWeight;
  let short = "";
  const setForm = (label) => `<div class="set"><input type="number" inputmode="decimal" step="0.1" id="goal-input" placeholder="Goal weight in kg" value="${goal || ""}"><button class="btn primary" id="goal-save">${label}</button></div>`;
  if (!goal || goalEditing) {
    card.innerHTML = `<div class="gh"><b>Goal weight</b>${goal ? `<button id="goal-cancel">Cancel</button>` : ""}</div>
      <div class="why">${goal ? "Change your target." : "Set a target and the app works out when you'll get there, from your weigh-ins and what you eat."}</div>${setForm(goal ? "Save" : "Set goal")}${goal ? `<button class="btn ghost slim" id="goal-clear">Remove goal</button>` : ""}`;
  } else if (!cur) {
    card.innerHTML = `<div class="gh"><b>Goal: ${fmt(goal, 1)} kg</b><button id="goal-edit">Change</button></div><div class="why">Add a weigh-in and the app will show how far there is to go.</div>`;
  } else {
    const start = (state.goalStart && state.goalStart.weight) || rows[0].weight, diff = goal - cur, losing = goal < start;
    const pct = start === goal ? 100 : Math.max(0, Math.min(100, (start - cur) / (start - goal) * 100));
    const trend = weightTrend(), energy = energyBalance(cur), rate = trend ? trend.perDay : energy ? energy.perDay : null;
    let big, warn = false; const why = [];
    if (Math.abs(diff) < 0.25) big = `You've reached your goal 🎉`, short = "reached 🎉";
    else if (rate == null) big = `${fmt(Math.abs(diff), 1)} kg to go`, short = `${fmt(Math.abs(diff), 1)} kg to go`, why.push("Log a few days and weigh in over a week or two, and a projected date shows up here.");
    else if (rate * Math.sign(diff) <= 0.0004) {
      warn = true; big = `Not heading there yet`; short = `<span class="warn">not heading there yet</span>`;
      why.push(losing ? "At the current pace your weight is steady or going up." : "At the current pace your weight is steady or going down.");
      if (energy) why.push(`A daily budget around ${fmt(Math.round((energy.tdee + (losing ? -550 : 300)) / 50) * 50)} kcal would move you about ${losing ? "0.5 kg a week down" : "0.3 kg a week up"}.`);
    } else {
      const days = diff / rate;
      if (days > 730) big = `${fmt(Math.abs(diff), 1)} kg to go`, short = `${fmt(Math.abs(diff), 1)} kg to go`, why.push("At this pace it's more than two years away.");
      else { const d = new Date(); d.setDate(d.getDate() + Math.round(days)); big = `On track for ${fmt(goal, 1)} kg around ${d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: d.getFullYear() !== new Date().getFullYear() ? "numeric" : undefined })}`; short = `around ${d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: d.getFullYear() !== new Date().getFullYear() ? "numeric" : undefined })}`; }
    }
    if (trend) why.push(`From your weigh-ins: ${trend.perDay > 0 ? "+" : "−"}${fmt(Math.abs(trend.perDay * 7), 1)} kg a week.`);
    if (energy) why.push(`From what you eat: about ${fmt(Math.round(energy.eat / 10) * 10)} kcal a day against roughly ${fmt(Math.round(energy.tdee / 10) * 10)} burned${energy.guessed ? " (estimated)" : ""}.`);
    card.innerHTML = `<div class="gh"><b>Goal: ${fmt(goal, 1)} kg</b><button id="goal-edit">Change</button></div>
      <div class="big ${warn ? "warn" : ""}">${big}</div>
      <span class="bar"><span style="width:${pct}%"></span></span>
      <div class="ends"><span>Start ${fmt(start, 1)} kg</span><span>Now ${fmt(cur, 1)} kg</span><span>Goal ${fmt(goal, 1)} kg</span></div>
      ${why.length ? `<div class="why">${why.join(" ")}</div>` : ""}`;
  }
  // the one-line version in the main card, and the full card only when opened
  $("#goal-line").innerHTML = goal ? `<b>Goal ${fmt(goal, 1)} kg</b>${short ? ` · ${short}` : ""} · <span class="go">${goalOpen || goalEditing ? "hide" : "details"}</span>` : `<span class="go">Set a goal weight</span>`;
  card.classList.toggle("hidden", !(goalOpen || goalEditing));
  const saveBtn = $("#goal-save");
  if (saveBtn) saveBtn.onclick = () => {
    const v = num($("#goal-input").value);
    if (!v || v < 25 || v > 350) { toast("Type a goal weight in kg"); return; }
    if (!state.goalWeight || !state.goalStart) state.goalStart = { weight: cur || v, day: localDate() };
    state.goalWeight = Math.round(v * 10) / 10; goalEditing = false; save(); renderGoal(); toast(`Goal set: ${state.goalWeight} kg`);
  };
  const edit = $("#goal-edit"); if (edit) edit.onclick = () => { goalEditing = true; renderGoal(); };
  const cancel = $("#goal-cancel"); if (cancel) cancel.onclick = () => { goalEditing = false; renderGoal(); };
  const clear = $("#goal-clear"); if (clear) clear.onclick = async () => { if (!await ask("Remove your goal weight?")) return; state.goalWeight = null; state.goalStart = null; goalEditing = false; save(); renderGoal(); };
}
let bodyRange = 90, bodyOdd = new Set();   // days shown: 30, 90 or 0 for everything
function drawBodyChart(rows, m) {
  $$("#body-range button").forEach((b) => b.classList.toggle("on", +b.dataset.r === bodyRange));
  const today = localDate(), future = rows.filter((r) => r.day > today);
  const alert = $("#body-alert"); alert.classList.toggle("hidden", !future.length);
  if (future.length) {
    const f = future[0], sw = swappedDay(f.day), fixable = sw && sw <= today && !rows.some((r) => r.day === sw);
    const nice = (d) => new Date(d + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short", year: d.slice(0, 4) !== today.slice(0, 4) ? "numeric" : undefined });
    alert.innerHTML = `<span>${future.length === 1 ? "A reading is" : `${future.length} readings are`} dated in the future (${nice(f.day)}), so ${future.length === 1 ? "it's" : "they're"} left out.${fixable ? ` Probably ${nice(sw)}?` : ""}</span><button class="btn ${fixable ? "primary" : "ghost"} slim" id="body-fix">${fixable ? "Fix date" : "Remove"}</button>`;
    $("#body-fix").onclick = async () => {
      tomb("body", f.day); state.body = state.body.filter((r) => r.day !== f.day);
      if (fixable) { upsertBody({ ...f, day: sw, updatedAt: new Date().toISOString() }); toast(`Moved to ${nice(sw)}`); } else toast("Reading removed");
      save(); drawBody();
    };
  }
  const all = rows.filter((r) => r[m.key] != null && r.day <= today).map((r) => ({ day: r.day, v: r[m.key] }));
  let pts = bodyRange ? all.filter((p) => p.day >= dateMinus(bodyRange)) : all;
  if (pts.length < 2 && all.length >= 2) pts = all.slice(-2);   // too few in range: show at least the last two
  const goal = m.key === "weight" && state.goalWeight ? state.goalWeight : null;
  const ch = bodyChart(pts, { dp: m.dp, goal, unit: m.unit });
  $("#body-chart").innerHTML = ch.html;
  wireChartTip($("#body-chart"), pts, ch.geo, m.dp, m.unit);
  // headline: where you are, the pace, and the change over what's shown (measured on the trend, not one noisy day)
  const hero = $("#body-hero");
  if (!pts.length) { hero.innerHTML = ""; $("#body-key").innerHTML = ""; return; }
  const now = pts[pts.length - 1].v, upGood = ["muscle", "lean", "water", "bone", "bmr"].includes(m.key);
  let pace = "";
  if (m.key === "weight") { const tr = weightTrend(); if (tr && Math.abs(tr.perDay * 7) >= 0.05) { const wk = tr.perDay * 7; pace = `<span class="pace ${(wk < 0) !== upGood ? "good" : "bad"}">${wk < 0 ? "↓" : "↑"} ${fmt(Math.abs(wk), 2)} kg a week</span>`; } }
  let since = "";
  if (pts.length >= 2) {
    const d = ch.trend[ch.trend.length - 1] - ch.trend[0];
    const when = new Date(pts[0].day + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short" });
    since = Math.abs(d) < Math.pow(10, -m.dp) ? `Steady since ${when}` : `${d < 0 ? "Down" : "Up"} ${fmt(Math.abs(d), m.dp)}${m.unit === "%" ? "%" : m.unit ? " " + m.unit : ""} since ${when}`;
  }
  hero.innerHTML = `<div><span class="now">${fmt(now, m.dp)}<small>${esc(m.unit || "")}</small></span>${pace}</div>${since ? `<div class="since">${since}</div>` : ""}`;
  const odd = (ch.odd || []).filter(Boolean).length;
  bodyOdd = new Set(pts.filter((p, i) => ch.odd && ch.odd[i]).map((p) => p.day));
  $("#body-key").innerHTML = pts.length >= 2 ? `<span><i class="k-dot"></i>Weigh-ins</span><span><i class="k-line"></i>Trend</span>${ch.goalShown ? `<span><i class="k-goal"></i>Goal</span>` : goal ? `<span>Goal ${fmt(goal, 1)} kg (off the chart)</span>` : ""}${odd ? `<span><i class="k-odd"></i>${odd} unusual: check ${odd === 1 ? "it" : "them"} in the readings below</span>` : ""}` : "";
}
$("#body-range").addEventListener("click", (e) => { const b = e.target.closest("button"); if (!b) return; bodyRange = +b.dataset.r; drawBody(); });
$("#goal-line").onclick = () => { if (!state.goalWeight) { goalEditing = true; goalOpen = true; } else { goalOpen = !(goalOpen || goalEditing); goalEditing = false; } renderGoal(); };
$("#bd-add").onclick = () => { const sh = $("#bd-add-sheet"); sh.classList.toggle("hidden"); if (!sh.classList.contains("hidden")) showBodyForm(false); };
$("#bd-days-row").onclick = () => $("#body-often").classList.toggle("hidden");
function drawBody() {
  renderGoal();
  const rows = bodySorted(), lb = rows[rows.length - 1] || null;
  const have = BODY_METRICS.filter((m) => rows.some((r) => r[m.key] != null));
  const cutoff = dateMinus(30);
  const st = $("#body-stats");
  if (!lb) st.innerHTML = `<div style="grid-column:1/-1"><small>Nothing yet</small><b>Read a screenshot or add a reading below</b></div>`;
  const headline = ["weight", "fat", "muscle", "lean", "water"].map((k) => have.find((m) => m.key === k)).filter(Boolean).slice(0, 3);
  if (lb) st.innerHTML = headline.map((m) => {
    const cur = rows.filter((r) => r[m.key] != null), now = cur[cur.length - 1], before = cur.slice().reverse().find((r) => r.day <= cutoff) || cur[0];
    const d = before !== now ? now[m.key] - before[m.key] : 0, good = m.key === "muscle" || m.key === "lean" || m.key === "water" || m.key === "bone" || m.key === "bmr" ? d > 0 : d < 0;
    return `<div><small>${m.name}</small><b>${fmt(now[m.key], m.dp)}${m.unit ? ` <span class="muted tiny">${m.unit}</span>` : ""}${d ? `<span class="delta ${good ? "down" : "up"}">${d > 0 ? "+" : ""}${fmt(d, m.dp)}</span>` : ""}</b></div>`;
  }).join("");
  if (!have.some((m) => m.key === bodyMetric) && have.length) bodyMetric = have[0].key;
  const pickEl = $("#body-metric");
  pickEl.innerHTML = (have.length ? have : BODY_METRICS.slice(0, 1)).map((x) => `<option value="${x.key}"${x.key === bodyMetric ? " selected" : ""}>${x.name}${x.unit ? ` (${x.unit})` : ""}</option>`).join("");
  const m = BODY_METRICS.find((x) => x.key === bodyMetric);
  drawBodyChart(rows, m);
  const past = bodyPast(), latestOf = (k) => { for (let i = past.length - 1; i >= 0; i--) if (past[i][k] != null) return past[i][k]; return null; };
  $("#body-chips").innerHTML = BODY_METRICS.filter((x) => x.key !== m.key && ["weight", "fat", "muscle", "water", "visceral"].includes(x.key)).map((x) => { const v = latestOf(x.key); return v == null ? "" : `<span><b>${fmt(v, x.dp)}${x.unit === "%" ? "%" : x.unit ? " " + x.unit : ""}</b> ${x.key === "visceral" ? "visceral fat" : x.name.toLowerCase()}</span>`; }).join("");
  const list = $("#body-list"); list.innerHTML = "";
  const newest = rows.slice().reverse(), shown = bodyAll ? newest.slice(0, 60) : newest.slice(0, 5);
  const val = (x, v) => `${fmt(v, x.dp)}${x.unit === "%" ? "%" : x.unit ? ` ${x.unit}` : ""}`;
  for (const r of shown) {
    const li = document.createElement("li");
    const all = BODY_METRICS.filter((x) => r[x.key] != null);
    const short = ["weight", "fat", "muscle"].map((k) => all.find((x) => x.key === k)).filter(Boolean).map((x) => x.key === "fat" ? `${val(x, r[x.key])} fat` : x.key === "muscle" ? `${val(x, r[x.key])} muscle` : val(x, r[x.key]));
    const extra = all.length - short.length;
    const open = bodyOpen === r.day;
    const flag = r.day > localDate() ? `<span class="odd-tag">Future date</span>` : bodyOdd.has(r.day) ? `<span class="odd-tag">Looks unusual</span>` : "";
    li.innerHTML = `<span class="thumb-sm"><svg><use href="#i-scale"/></svg></span><div class="body"><div class="name">${r.day === localDate() ? "Today" : new Date(r.day + "T12:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" })}${flag}</div><div class="detail">${esc(short.join(" · "))}</div></div>${extra > 0 ? `<svg class="chev more-chev${open ? " up" : ""}"><use href="#i-chev"/></svg>` : ""}<button class="del" aria-label="Remove">✕</button>
      ${open ? `<div class="all">${all.map((x) => `<span>${x.name} <b>${val(x, r[x.key])}</b></span>`).join("")}<button class="btn mint slim edit">Edit this reading</button></div>` : ""}`;
    li.querySelector(".del").onclick = async (e) => { e.stopPropagation(); if (!await ask(`Remove the reading for ${r.day}?`)) return; tomb("body", r.day); state.body = state.body.filter((x) => x.day !== r.day); save(); drawBody(); };
    li.onclick = (e) => { if (e.target.closest(".edit") || e.target.closest(".del")) return; bodyOpen = open ? null : r.day; drawBody(); };
    const ed = li.querySelector(".edit");
    if (ed) ed.onclick = () => { showBodyForm(true); $("#bd-date").value = r.day; for (const x of BODY_METRICS) { const el = $(`#bd-${x.key}`); if (el) el.value = r[x.key] ?? ""; } window.scrollTo({ top: $("#bd-date").getBoundingClientRect().top + window.scrollY - 90, behavior: "smooth" }); };
    list.appendChild(li);
  }
  const more = $("#body-more");
  more.classList.toggle("hidden", newest.length <= 5);
  more.textContent = bodyAll ? "Show fewer" : `Show all ${newest.length} readings`;
  $("#body-empty").classList.toggle("hidden", rows.length > 0);
}
// ---- read a scale app screenshot with the AI: one tap, check, save
const BODY_SCHEMA = {
  type: "object",
  properties: {
    weight_kg: { type: ["number", "null"], description: "Body weight in kg. Convert from lb (x0.4536) or st/lb if needed" },
    body_fat_pct: { type: ["number", "null"], description: "Body fat as a percentage, e.g. 17.0" },
    muscle_kg: { type: ["number", "null"], description: "Muscle mass in kg" },
    lean_kg: { type: ["number", "null"], description: "Fat-free body weight / lean mass in kg" },
    water_pct: { type: ["number", "null"], description: "Body water as a percentage" },
    bone_kg: { type: ["number", "null"], description: "Bone mass in kg" },
    visceral_fat: { type: ["number", "null"], description: "Visceral fat rating, a small number like 7" },
    bmr_kcal: { type: ["number", "null"], description: "Basal metabolic rate in kcal" },
    metabolic_age: { type: ["number", "null"], description: "Metabolic age in years" },
    bmi: { type: ["number", "null"] },
    is_body_reading: { type: "boolean", description: "true only if this really shows body weight / composition figures" }
  },
  required: ["weight_kg", "body_fat_pct", "muscle_kg", "lean_kg", "water_pct", "bone_kg", "visceral_fat", "bmr_kcal", "metabolic_age", "bmi", "is_body_reading"],
  additionalProperties: false
};
const BODY_PROMPT = `This is a screenshot of a smart-scale app (such as VeSync / Etekcity, Renpho, Withings) or a photo of a scale's display. Read the body measurements off it.
Report only numbers actually visible; null for anything not shown. Muscle mass is the kg figure labelled Muscle Mass (not Skeletal Muscle %). Lean mass is Fat-Free Body Weight. If it isn't a body reading at all, set is_body_reading to false.`;
$("#bd-shot").onclick = () => { if (!aiAvailable()) { aiHelp(); return; } $("#file-bd-shot").click(); };
$("#file-bd-shot").addEventListener("change", async (e) => {
  const f = e.target.files[0]; e.target.value = ""; if (!f) return;
  busy("Reading your scale…");
  let r;
  try {
    const img = await loadImage(f);
    const b64 = drawScaled(img, 1024).toDataURL("image/jpeg", 0.8).split(",")[1];
    r = await askAI(BODY_SCHEMA, [{ type: "image", source: { type: "base64", media_type: "image/jpeg", data: b64 } }, { type: "text", text: BODY_PROMPT }], "low");
  } catch (err) { busy(false); toast(err.message || "Couldn't read that picture", 5000); return; }
  busy(false);
  if (!r || r.is_body_reading === false || (num(r.weight_kg) == null && num(r.body_fat_pct) == null)) { toast("Couldn't see scale readings in that picture. Try a screenshot of the results screen.", 5000); return; }
  const map = { weight: r.weight_kg, fat: r.body_fat_pct, muscle: r.muscle_kg, lean: r.lean_kg, water: r.water_pct, bone: r.bone_kg, visceral: r.visceral_fat, bmr: r.bmr_kcal, age: r.metabolic_age, bmi: r.bmi };
  const row = { day: localDate(), updatedAt: new Date().toISOString() };
  for (const [k, v] of Object.entries(map)) if (num(v) != null) row[k] = Math.round(v * 10) / 10;
  const lines = BODY_METRICS.filter((m) => row[m.key] != null).map((m) => `${m.name}: ${fmt(row[m.key], m.dp)}${m.unit === "%" ? "%" : m.unit ? ` ${m.unit}` : ""}`);
  if (!await ask(`Save today's reading?\n\n${lines.join("\n")}`, { ok: "Save" })) return;
  upsertBody(row); save(); drawBody();
  toast(`Saved${row.weight ? `: ${row.weight} kg` : ""}`);
  if (document.body.dataset.view === "plan") { planPrefillBody(true); renderPlanStep(); }
  const c = window.cloud; if (c && c.user) { try { const { day, updatedAt, ...rest } = row; await c.saveBodyRow({ day, ...rest }); } catch (err) {} }
});
// ---- upload a scale app's export (CSV or Excel): find the columns, bring in every day
const IMPORT_COLS = {
  date: /^(date|time|date ?time|measure(d|ment)? ?(time|date)|record(ed)? ?(time|date)|timestamp|日期|时间)/i,
  weight: /^(weight|body ?weight|体重)(?!.*(fat|muscle|bone|lean|free))/i,
  fat: /(body ?fat|fat ?(rate|%|percent))(?!.*(mass|kg|weight|free|subcut|visceral))/i,
  lean: /(fat[- ]?free|lean)/i,
  muscle: /^(muscle ?mass|muscle)(?!.*(%|rate|skeletal))/i,
  water: /(body ?water|water)/i,
  bone: /(bone)/i,
  visceral: /(visceral)/i,
  bmr: /(bmr|basal)/i,
  age: /(metabolic|body) ?age/i,
  bmi: /^bmi/i
};
function parseCSV(text) {
  const sep = (text.split("\n")[0].match(/;/g) || []).length > (text.split("\n")[0].match(/,/g) || []).length ? ";" : (text.includes("\t") && !text.includes(",") ? "\t" : ",");
  const rows = []; let row = [], cell = "", q = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (q) { if (ch === '"' && text[i + 1] === '"') { cell += '"'; i++; } else if (ch === '"') q = false; else cell += ch; continue; }
    if (ch === '"') q = true; else if (ch === sep) { row.push(cell); cell = ""; } else if (ch === "\n" || ch === "\r") { if (ch === "\r" && text[i + 1] === "\n") i++; row.push(cell); cell = ""; if (row.some((x) => x.trim())) rows.push(row); row = []; } else cell += ch;
  }
  row.push(cell); if (row.some((x) => x.trim())) rows.push(row);
  return rows;
}
async function readSheet(file) {
  if (/\.xlsx?$/i.test(file.name) || /sheet|excel/.test(file.type)) {
    if (!window.XLSX) await new Promise((res, rej) => { const sc = document.createElement("script"); sc.src = "https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js"; sc.onload = res; sc.onerror = () => rej(new Error("Couldn't load the Excel reader (offline?)")); document.head.appendChild(sc); });
    const wb = XLSX.read(await file.arrayBuffer(), { type: "array", cellDates: true });
    return XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, raw: false, dateNF: "yyyy-mm-dd hh:mm" }).map((r) => r.map((x) => x == null ? "" : String(x)));
  }
  return parseCSV((await file.text()).replace(/^\uFEFF/, ""));
}
/** Which column is which: by header name first; if that misses the date or weight, ask the AI to map them. */
async function mapColumns(header, sample) {
  const map = {};
  header.forEach((h, i) => { const name = String(h).trim(); for (const [k, rx] of Object.entries(IMPORT_COLS)) if (map[k] == null && rx.test(name)) { map[k] = i; break; } });
  let lb = false;   // set by the AI when headers give no unit
  if ((map.date == null || map.weight == null) && aiAvailable()) {
    const keys = Object.keys(IMPORT_COLS);
    const schema = { type: "object", properties: Object.fromEntries(keys.map((k) => [k, { type: ["integer", "null"], description: `0-based column index holding ${k}, or null` }]).concat([["weight_in_lb", { type: "boolean" }]])), required: keys.concat(["weight_in_lb"]), additionalProperties: false };
    const r = await askAI(schema, [{ type: "text", text: `A body-scale app's export. Header row and two data rows (columns separated by " | "):\n${header.join(" | ")}\n${sample.map((x) => x.join(" | ")).join("\n")}\nSay which column index holds each measurement: date (the date or date-time of the weigh-in), weight, fat (body fat %), lean (fat-free mass kg), muscle (muscle mass kg), water (%), bone (kg), visceral (visceral fat rating), bmr (kcal), age (metabolic age), bmi.` }]);
    for (const k of keys) if (Number.isInteger(r[k]) && r[k] >= 0 && r[k] < header.length) map[k] = r[k];
    lb = !!r.weight_in_lb;
  }
  return { map, lb };
}
/** "12/09/2026" is ambiguous. Look at the whole file: a first number over 12 means day-first, a second over 12 means
 *  month-first; otherwise pick the order that keeps the rows in time order and out of the future. */
function dateOrder(values) {
  const pairs = values.map((v) => String(v || "").match(/(?:^|\D)(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})/)).filter(Boolean);
  if (!pairs.length) return "dmy";
  if (pairs.some((m) => +m[1] > 12)) return "dmy";
  if (pairs.some((m) => +m[2] > 12)) return "mdy";
  const score = (order) => {
    const days = values.map((v) => importDay(v, order)).filter(Boolean), today = localDate();
    let inversions = 0, up = 0;
    for (let i = 1; i < days.length; i++) { if (days[i] < days[i - 1]) inversions++; else if (days[i] > days[i - 1]) up++; }
    const disorder = Math.min(inversions, up);   // files run newest-first or oldest-first; either is fine
    return days.filter((d) => d > today).length * 1000 + disorder;
  };
  return score("mdy") < score("dmy") ? "mdy" : "dmy";
}
function importDay(v, order = "dmy") {
  const s = String(v || "").trim(); if (!s) return null;
  if (/^\d{9,13}$/.test(s)) { const n = +s; return localDate(new Date(n > 1e12 ? n : n * 1000)); }
  let m = s.match(/(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/); if (m) return `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}`;
  m = s.match(/(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})/);
  if (m) { let [, a, b, y] = m; if (y.length === 2) y = "20" + y; const [day, mon] = order === "mdy" ? [b, a] : [a, b]; if (+mon > 12 || +day > 31) return null; return `${y}-${String(mon).padStart(2, "0")}-${String(day).padStart(2, "0")}`; }
  const d = new Date(s); return isNaN(d) ? null : localDate(d);
}
/** The same date with day and month swapped, or null if it can't be one. */
function swappedDay(day) { const [y, m, d] = day.split("-"); return +d <= 12 && d !== m ? `${y}-${d}-${m}` : null; }
$("#bd-import").onclick = () => $("#file-bd-import").click();
$("#file-bd-import").addEventListener("change", async (e) => {
  const f = e.target.files[0]; e.target.value = ""; if (!f) return;
  busy("Reading the file…");
  try {
    const rows = await readSheet(f);
    const hi = rows.findIndex((r) => r.filter((x) => String(x).trim()).length >= 2);
    if (hi < 0 || rows.length < hi + 2) throw new Error("That file looks empty");
    const header = rows[hi], data = rows.slice(hi + 1);
    const { map, lb } = await mapColumns(header, data.slice(0, 2));
    // Mass columns in pounds: each column's own header says so ("Weight(lb)", "Muscle Mass(lb)"), else the AI's guess
    const MASS = ["weight", "lean", "muscle", "bone"];
    const inLb = (k) => MASS.includes(k) && (/\b(lb|lbs|pounds?)\b|\(lb/i.test(String(header[map[k]] || "")) || (lb && !/kg/i.test(String(header[map[k]] || ""))));
    if (map.date == null || map.weight == null) throw new Error("Couldn't find the date and weight columns in that file");
    const byDay = {}, order = dateOrder(data.map((r) => r[map.date]));
    for (const r of data) {
      const day = importDay(r[map.date], order); if (!day) continue;
      const row = {};
      for (const k of Object.keys(IMPORT_COLS)) { if (k === "date" || map[k] == null) continue; let v = parseFloat(String(r[map[k]] || "").replace(",", ".").replace(/[^0-9.\-]/g, "")); if (!isFinite(v) || v <= 0) continue; if (inLb(k)) v *= 0.45359237; row[k] = Math.round(v * 10) / 10; }
      if (row.weight || row.fat) byDay[day] = { ...(byDay[day] || {}), ...row };   // later rows in a day win: the last weigh-in
    }
    const days = Object.keys(byDay).sort();
    busy(false);
    if (!days.length) throw new Error("No readings found in that file");
    const found = BODY_METRICS.filter((m) => map[m.key] != null).map((m) => m.name.toLowerCase());
    const fmtDay = (d) => new Date(d + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
    if (!await ask(`Bring in ${days.length} day${days.length === 1 ? "" : "s"} of readings, ${fmtDay(days[0])} to ${fmtDay(days[days.length - 1])}?\n\nFound: ${found.join(", ")}.\nDays already here are updated.`, { ok: "Import" })) return;
    const stamp = new Date().toISOString();
    let fixed = 0;
    for (const day of days) {
      const sw = swappedDay(day); if (!sw || byDay[sw]) continue;
      const wrong = state.body.find((r) => r.day === sw && r.weight && byDay[day].weight && Math.abs(r.weight - byDay[day].weight) < 0.05);
      if (wrong) { tomb("body", wrong.day); state.body = state.body.filter((r) => r !== wrong); fixed++; }
    }
    for (const day of days) upsertBody({ day, updatedAt: stamp, ...byDay[day] });
    if (fixed) setTimeout(() => toast(`Moved ${fixed} reading${fixed === 1 ? "" : "s"} an earlier import had put on the wrong date`, 5000), 2900);
    save(); drawBody();
    toast(`Imported ${days.length} day${days.length === 1 ? "" : "s"}`);
    const c = window.cloud; if (c && c.user) { for (const day of days) { try { await c.saveBodyRow({ day, ...byDay[day] }); } catch (err) { break; } } }
  } catch (err) { busy(false); toast(err.message || "Couldn't read that file", 5000); }
});
$("#bd-save").onclick = async () => {
  const day = $("#bd-date").value || localDate(), row = { day, updatedAt: new Date().toISOString() };
  let any = false;
  for (const m of BODY_METRICS) { const el = $(`#bd-${m.key}`); if (!el) continue; const v = num(el.value); if (v != null) { row[m.key] = Math.round(v * 10) / 10; any = true; } }
  if (!any) { toast("Type at least one number"); return; }
  upsertBody(row); save(); drawBody();
  for (const m of BODY_METRICS) { const el = $(`#bd-${m.key}`); if (el) el.value = ""; }
  toast(`Saved${row.weight ? `: ${row.weight} kg` : ""}`); showBodyForm(false);
  const c = window.cloud; if (c && c.user) { try { const { day: d, updatedAt, ...rest } = row; await c.saveBodyRow({ day: d, ...rest }); } catch (e) {} }
};
$("#body-refresh").onclick = async () => { busy("Checking for new readings…"); const ch = await pullBody(true); busy(false); drawBody(); toast(ch ? "New readings pulled in" : "Nothing new"); };
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

// ---------------------------------------------------------------- the plan: questions -> calories and macros that fit

const PLAN_GOALS = {
  lose: { name: "Lose weight", e: "i-trenddown:coral", sub: "Steady fat loss, eat a little less" },
  cut: { name: "Cut", e: "i-flame:peach", sub: "Lose fat, keep the muscle: high protein" },
  maintain: { name: "Maintain", e: "i-balance:sand", sub: "Stay where you are" },
  recomp: { name: "Recomp", e: "i-repost:green", sub: "Slowly swap fat for muscle at the same weight" },
  leanbulk: { name: "Lean bulk", e: "i-sprout:green", sub: "Build muscle, keep fat gain small" },
  bulk: { name: "Bulk", e: "i-lift:coral", sub: "Build as much as possible, some fat comes with it" }
};
const ACTIVITY = [
  { k: 1.2, e: "i-chair:sand", name: "Mostly sitting", sub: "Desk job, not much walking" },
  { k: 1.375, e: "i-walk:green", name: "Some walking", sub: "A bit on your feet, errands, a short walk" },
  { k: 1.55, e: "i-stand:peach", name: "On my feet a lot", sub: "Retail, teaching, nursing, lots of walking" },
  { k: 1.725, e: "i-hammer:coral", name: "Physical job", sub: "Building, deliveries, farming" }
];
const TRAIN_MET = { weights: 5, cardio: 7, mix: 6, sport: 7.5 };
const PACES = {   // kg a week (negative = losing); cut is % of body weight
  lose: [["Gentle", -0.25], ["Steady", -0.5], ["Fast", -0.75]],
  cut: [["Gentle", -0.5, "%"], ["Steady", -0.75, "%"], ["Fast", -1, "%"]],
  leanbulk: [["Slow", 0.15], ["Steady", 0.25]],
  bulk: [["Steady", 0.35], ["Fast", 0.5]]
};
let plan = null, planStep = 0, planReturn = null;
const PLAN_STEPS = ["body", "activity", "training", "goal", "pace", "spread", "protein", "summary"];
const planHasPace = () => !!PACES[plan.goal];
function planPrefillBody(scaleOnly) {
  const lb = latestBody(), prof = state.profile || {};
  if (!scaleOnly) Object.assign(plan, { sex: prof.sex || null, age: prof.age || null, height: prof.height || null });
  if (lb) {
    if (lb.weight) plan.weight = lb.weight;
    if (lb.fat) plan.fat = lb.fat;
    if (lb.lean) plan.lean = lb.lean;
    plan.scaleDay = lb.day; plan.useScale = true;
  } else if (!plan.weight && state.weightKg) plan.weight = state.weightKg;
}
function openPlan(returnTo) {
  const old = state.plan || {};
  plan = { sex: null, age: null, height: null, weight: null, fat: null, lean: null, activity: old.activity || null, trainDays: old.trainDays ?? null, trainType: old.trainType || null, trainMins: old.trainMins || null, trainWeekdays: (old.trainWeekdays || []).slice(),
    goal: old.goal || null, pace: old.pace ?? null, paceCustom: old.paceCustom || null, knownKcal: null, knownKg: null, knownDir: "lose", knownRate: 0, goalWeight: state.goalWeight || null, spread: old.spread || "same", cheatDay: old.cheatDay ?? 0, protein: old.protein || null };
  planPrefillBody(false);
  planStep = 0; planReturn = returnTo || null;
  go("plan");
}
/** The maths, all in one place. */
function computePlan(q) {
  const w = +q.weight, h = +q.height, a = +q.age, male = q.sex === "m";
  const fat = q.useScale !== false && q.fat ? +q.fat : null;
  const lean = fat ? w * (1 - fat / 100) : null;
  const bmr = lean ? 370 + 21.6 * lean : 10 * w + 6.25 * h - 5 * a + (male ? 5 : -161);   // Katch-McArdle with body fat, else Mifflin-St Jeor
  const everyday = bmr * (q.activity || 1.2);
  // training on top of the resting burn (so MET minus 1, which is already counted), averaged over the week
  const trainKcal = (q.trainDays || 0) * ((TRAIN_MET[q.trainType] || 6) - 1) * w * ((q.trainMins || 45) / 60) / 7;
  const estimate = everyday + trainKcal;
  const known = q.knownKcal > 0 ? q.knownKcal + (q.knownRate || 0) * -KCAL_PER_KG / 7 : null;   // what they eat now, corrected by how their weight is moving
  const tdee = known && known > 1000 && known < 6000 ? known : estimate;
  let rate = 0;   // kg a week
  if (planHasPaceFor(q.goal)) {
    if (q.paceCustom > 0) rate = (q.goal.includes("bulk") ? 1 : -1) * q.paceCustom;   // their own kg a week
    else { const p = PACES[q.goal].find((x) => x[1] === q.pace) || PACES[q.goal][1]; rate = p[2] === "%" ? p[1] / 100 * w : p[1]; }
  }
  let delta = rate * KCAL_PER_KG / 7, notes = [];
  if (q.goal === "recomp") delta = -Math.min(300, tdee * 0.1);
  const floor = male ? 1500 : 1200;
  if (delta < 0 && -delta > tdee * 0.25) { delta = -tdee * 0.25; notes.push("That pace would need more than a quarter less than you burn, so it's been eased to a safer rate."); }
  let kcal = tdee + delta;
  if (kcal < floor) { kcal = floor; notes.push(`It won't go below ${fmt(floor)} kcal a day, the usual safe minimum.`); }
  kcal = Math.round(kcal / 10) * 10;
  rate = Math.round((kcal - tdee) * 7 / KCAL_PER_KG * 100) / 100;
  // macros
  const bmi = h ? w / ((h / 100) ** 2) : 0, heavy = fat ? fat > (male ? 25 : 32) : bmi >= 30;
  const baseKg = heavy ? (lean ? lean * 1.25 : (h ? 25 * (h / 100) ** 2 : w)) : w;   // very high body fat: protein from a healthier weight
  const perKg = { std: 1.6, high: 2.0, lift: q.goal === "cut" ? 2.4 : 2.2 }[q.protein || "std"];
  const p = Math.round(baseKg * perKg);
  let f = Math.round(Math.max(0.8 * w, kcal * 0.25 / 9));
  let c = Math.round((kcal - p * 4 - f * 9) / 4);
  if (c < 50) { f = Math.round(Math.max(0.6 * w, (kcal - p * 4 - 50 * 4) / 9)); c = Math.max(0, Math.round((kcal - p * 4 - f * 9) / 4)); }
  // spreading over the week, same weekly total
  const days = {}; let everydayKcal = kcal, trainDayKcal = null, cheatKcal = null;
  const weekly = kcal * 7, tw = (q.trainWeekdays || []).slice();
  if (q.spread === "train" && tw.length && tw.length < 7) {
    const n = tw.length, rest = 7 - n;
    let restKcal = (weekly - kcal * 1.1 * n) / rest;          // 10% more on training days...
    if (restKcal < kcal * 0.9) restKcal = kcal * 0.9;          // ...but a rest day stays within 10% of the average
    everydayKcal = Math.round(restKcal / 10) * 10;
    trainDayKcal = Math.round((weekly - everydayKcal * rest) / n / 10) * 10;
    for (const d of tw) days[d] = trainDayKcal;
  } else if (q.spread === "cheat") {
    cheatKcal = Math.round(kcal * 1.3 / 10) * 10;
    everydayKcal = Math.round((weekly - cheatKcal) / 6 / 10) * 10;
    days[q.cheatDay] = cheatKcal;
  }
  if (everydayKcal < floor) notes.push(`Your lower days come out at ${fmt(everydayKcal)} kcal, under the usual ${fmt(floor)} minimum. "Same every day" avoids that.`);
  if (a && a < 18) notes.push("Under 18, it's best to check targets with a doctor or dietitian.");
  if (bmi && bmi < 18.5 && rate < 0) notes.push("Your weight is already on the low side for your height, so losing more isn't recommended.");
  if (rate < 0 && -rate > w * 0.01) notes.push("That's faster than 1% of body weight a week, which risks losing muscle.");
  let date = null;
  if (q.goalWeight && rate && Math.sign(q.goalWeight - w) === Math.sign(rate)) { const d = new Date(); d.setDate(d.getDate() + Math.round((q.goalWeight - w) / rate * 7)); date = d; }
  return { bmr: Math.round(bmr), tdee: Math.round(tdee), kcal, rate, macros: { p, c, f }, days, everydayKcal, trainDayKcal, cheatKcal, notes, date, formula: tdee !== estimate ? "worked out from what you eat now and how your weight is moving" : lean ? "Katch-McArdle, using your body fat" : "Mifflin-St Jeor", fromKnown: tdee !== estimate, estimate: Math.round(estimate) };
}
const planHasPaceFor = (g) => !!PACES[g];
function knownRead() {
  const k = $("#pl-known-kcal"), g = $("#pl-known-kg");
  if (k) plan.knownKcal = num(k.value) && num(k.value) >= 800 && num(k.value) <= 6000 ? Math.round(num(k.value)) : null;
  if (g) plan.knownKg = num(g.value) && num(g.value) <= 2 ? num(g.value) : null;
  const dir = plan.knownDir || "lose";
  plan.knownRate = dir === "steady" ? 0 : (dir === "lose" ? -1 : 1) * (plan.knownKg || 0);
}
function knownNote() {
  if (!plan.knownKcal) return "Leave blank to use the estimate from the questions.";
  const burn = Math.round((plan.knownKcal - (plan.knownRate || 0) * KCAL_PER_KG / 7) / 10) * 10;
  return `That means you burn about ${fmt(burn)} kcal a day. The plan will start from that.`;
}
/** What a chosen weekly amount means, said plainly, with a nudge if it's a lot. */
function paceNote(kg) {
  if (!kg) return "Anything from 0.1 kg. The app keeps it within safe limits.";
  const w = +plan.weight || 80, perDay = Math.round(kg * KCAL_PER_KG / 7 / 10) * 10, pct = kg / w * 100, bulk = plan.goal.includes("bulk");
  let t = `About ${fmt(perDay)} kcal a day ${bulk ? "above" : "below"} what you burn (${fmt(pct, 1)}% of your weight a week).`;
  if (!bulk && pct > 1) t += " That's faster than 1% a week, which risks muscle: it may be eased on the next screen.";
  if (bulk && kg > 0.5) t += " Gaining faster than 0.5 kg a week is mostly fat.";
  return t;
}
function planDots() { const steps = PLAN_STEPS.filter((st) => st !== "pace" || planHasPace()); const cur = steps.indexOf(PLAN_STEPS[planStep]); $("#plan-dots").innerHTML = steps.map((_, i) => `<i class="${i === cur ? "on" : i < cur ? "done" : ""}"></i>`).join(""); }
function planOpt(active, icon, name, sub, attrs) { const [id, tone] = String(icon).split(":"); return `<button class="card plan-opt${active ? " on" : ""}" ${attrs}><span class="circle ${tone || "green"}"><svg><use href="#${id}"/></svg></span><span><b>${name}</b><small>${sub}</small></span></button>`; }
function renderPlanStep() {
  if (!plan) { back(); return; }
  const step = PLAN_STEPS[planStep], box = $("#plan-body"), next = $("#plan-next");
  planDots(); next.textContent = step === "summary" ? "Use this plan" : "Next";
  if (step === "body") {
    const lb = latestBody();
    box.innerHTML = `<p class="plan-q">About you</p><p class="plan-sub">Used to work out what your body burns. Only kept on your account.</p>
      <div class="plan-label">Sex</div><div class="chips plan-chips" id="pl-sex"><button data-v="f" class="${plan.sex === "f" ? "on" : ""}">Female</button><button data-v="m" class="${plan.sex === "m" ? "on" : ""}">Male</button></div>
      <div class="plan-row"><label>Age <input type="number" inputmode="numeric" id="pl-age" value="${plan.age || ""}" placeholder="e.g. 32"></label><label>Height (cm) <input type="text" inputmode="decimal" id="pl-height" value="${plan.height || ""}" placeholder="e.g. 178 or 5'10"></label></div>
      <div class="card scale-box">${lb && (lb.weight || lb.fat) ? `<b>Use your scale readings?</b><div class="plan-note">From ${lb.day === localDate() ? "today" : new Date(lb.day + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short" })}: ${lb.weight ? `${fmt(lb.weight, 1)} kg` : ""}${lb.fat ? ` · ${fmt(lb.fat, 1)}% body fat` : ""}${lb.lean ? ` · ${fmt(lb.lean, 1)} kg lean` : ""}</div>
        <div class="chips plan-chips" id="pl-usescale"><button data-v="1" class="${plan.useScale !== false ? "on" : ""}">Use these</button><button data-v="0" class="${plan.useScale === false ? "on" : ""}">Type my own</button></div>`
        : `<b>Got a smart scale?</b><div class="plan-note">Body fat makes the numbers more accurate. Read your scale app's result, or type it below.</div>`}
        <button class="btn mint slim" id="pl-shot">Read my scale screenshot</button></div>
      <div class="plan-row"><label>Weight (kg) <input type="number" inputmode="decimal" id="pl-weight" value="${plan.weight ? fmt(plan.weight, 1).replace(/,/g, "") : ""}" placeholder="e.g. 80"></label><label>Body fat %<input type="number" inputmode="decimal" id="pl-fat" value="${plan.useScale !== false && plan.fat ? plan.fat : plan.useScale === false && plan.fatOwn ? plan.fatOwn : ""}" placeholder="Optional"></label></div>`;
    box.querySelectorAll("#pl-sex button").forEach((b) => b.onclick = () => { plan.sex = b.dataset.v; renderPlanStep(); });
    box.querySelectorAll("#pl-usescale button").forEach((b) => b.onclick = () => { plan.useScale = b.dataset.v === "1"; if (plan.useScale) planPrefillBody(true); renderPlanStep(); });
    $("#pl-shot").onclick = () => { if (!aiAvailable()) { aiHelp(); return; } $("#file-bd-shot").click(); };
    return;
  }
  if (step === "activity") {
    const dir = plan.knownDir || "lose";
    box.innerHTML = `<p class="plan-q">Outside workouts, how active are your days?</p><p class="plan-sub">Workouts come next, so just think about a normal day.</p>` + ACTIVITY.map((a) => planOpt(plan.activity === a.k, a.e, a.name, a.sub, `data-k="${a.k}"`)).join("") +
      `<div class="card plan-own${plan.knownKcal ? " on" : ""}"><b>Already tracking? <small class="muted">optional, most accurate</small></b>
        <div class="plan-note">If you know what you eat and how your weight's moving, that beats any formula.</div>
        <div class="plan-row"><label>I eat about (kcal a day)<input type="number" inputmode="numeric" id="pl-known-kcal" value="${plan.knownKcal || ""}" placeholder="e.g. 2500"></label></div>
        <div class="chips plan-chips" id="pl-known-dir"><button data-v="lose" class="${dir === "lose" ? "on" : ""}">Losing</button><button data-v="steady" class="${dir === "steady" ? "on" : ""}">Steady</button><button data-v="gain" class="${dir === "gain" ? "on" : ""}">Gaining</button></div>
        ${dir !== "steady" ? `<div class="plan-row"><label>kg a week<input type="number" inputmode="decimal" step="0.05" id="pl-known-kg" value="${plan.knownKg || ""}" placeholder="e.g. 0.3"></label></div>` : ""}
        <div class="plan-note" id="pl-known-note">${knownNote()}</div></div>`;
    box.querySelectorAll(".plan-opt").forEach((b) => b.onclick = () => { plan.activity = +b.dataset.k; knownRead(); renderPlanStep(); });
    box.querySelectorAll("#pl-known-dir button").forEach((b) => b.onclick = () => { knownRead(); plan.knownDir = b.dataset.v; renderPlanStep(); });
    ["#pl-known-kcal", "#pl-known-kg"].forEach((q) => { const el = $(q); if (el) el.addEventListener("input", () => { knownRead(); $("#pl-known-note").textContent = knownNote(); $(".plan-own").classList.toggle("on", !!plan.knownKcal); }); });
    return;
  }
  if (step === "training") {
    const chip = (id, vals, cur) => `<div class="chips plan-chips" id="${id}">${vals.map(([v, l]) => `<button data-v="${v}" class="${String(cur) === String(v) ? "on" : ""}">${l}</button>`).join("")}</div>`;
    box.innerHTML = `<p class="plan-q">How do you train?</p><p class="plan-sub">A typical week. Guess if it varies.</p>
      <div class="plan-label">Days a week</div>${chip("pl-days", [0, 1, 2, 3, 4, 5, 6, 7].map((n) => [n, n === 0 ? "None" : n]), plan.trainDays)}
      ${plan.trainDays > 0 ? `<div class="plan-label">What kind</div>${chip("pl-type", [["weights", "Weights"], ["cardio", "Cardio"], ["mix", "Mix"], ["sport", "Sport"]], plan.trainType)}
      <div class="plan-label">How long, usually</div>${chip("pl-mins", [[30, "30 min"], [45, "45 min"], [60, "1 hour"], [90, "1½ hours"]], plan.trainMins)}
      <div class="plan-label">Which days? <small class="muted">optional, for more calories on those days</small></div>
      <div class="plan-days" id="pl-wd">${[1, 2, 3, 4, 5, 6, 0].map((d) => `<button data-d="${d}" class="${plan.trainWeekdays.includes(d) ? "on" : ""}">${WEEKDAYS[d].slice(0, 2)}</button>`).join("")}</div>` : ""}`;
    box.querySelectorAll("#pl-days button").forEach((b) => b.onclick = () => { plan.trainDays = +b.dataset.v; if (!plan.trainDays) plan.trainWeekdays = []; renderPlanStep(); });
    box.querySelectorAll("#pl-type button").forEach((b) => b.onclick = () => { plan.trainType = b.dataset.v; renderPlanStep(); });
    box.querySelectorAll("#pl-mins button").forEach((b) => b.onclick = () => { plan.trainMins = +b.dataset.v; renderPlanStep(); });
    box.querySelectorAll("#pl-wd button").forEach((b) => b.onclick = () => { const d = +b.dataset.d, i = plan.trainWeekdays.indexOf(d); if (i >= 0) plan.trainWeekdays.splice(i, 1); else plan.trainWeekdays.push(d); renderPlanStep(); });
    return;
  }
  if (step === "goal") {
    const young = plan.age && plan.age < 18;
    box.innerHTML = `<p class="plan-q">What's your goal?</p><p class="plan-sub">You can change it any time.</p>` + Object.entries(PLAN_GOALS).filter(([k]) => !(young && k === "bulk")).map(([k, g]) => planOpt(plan.goal === k, g.e, g.name, g.sub, `data-g="${k}"`)).join("");
    box.querySelectorAll(".plan-opt").forEach((b) => b.onclick = () => { if (plan.goal !== b.dataset.g) { plan.pace = null; plan.paceCustom = null; } plan.goal = b.dataset.g; renderPlanStep(); });
    return;
  }
  if (step === "pace") {
    const list = PACES[plan.goal].filter((x) => !(plan.age && plan.age < 18 && x[0] === "Fast"));
    if (plan.pace == null) plan.pace = list[Math.min(1, list.length - 1)][1];
    const w = +plan.weight || 80;
    box.innerHTML = `<p class="plan-q">How fast?</p><p class="plan-sub">Slower is easier to stick to and keeps more muscle.</p>` +
      list.map(([name, v, pct]) => { const kg = pct ? v / 100 * w : v; return planOpt(plan.pace === v, name === "Gentle" || name === "Slow" ? "i-slow:green" : name === "Steady" ? "i-steady:sand" : "i-fast:coral", name, `About ${kg > 0 ? "+" : "−"}${fmt(Math.abs(kg), 2)} kg a week${pct ? ` (${Math.abs(v)}% of body weight)` : ""}`, `data-p="${v}"`); }).join("") +
      `<div class="card plan-own${plan.paceCustom ? " on" : ""}"><label>Or choose your own: kg ${plan.goal.includes("bulk") ? "to gain" : "to lose"} a week<input type="number" inputmode="decimal" step="0.05" id="pl-pace-own" value="${plan.paceCustom || ""}" placeholder="e.g. ${plan.goal.includes("bulk") ? "0.2" : "0.4"}"></label><div class="plan-note" id="pl-pace-note">${paceNote(plan.paceCustom)}</div></div>` +
      `<label>Goal weight (kg) <small>optional, for a target date</small><input type="number" inputmode="decimal" id="pl-goalw" value="${plan.goalWeight || ""}" placeholder="e.g. ${Math.round(w + (plan.goal.includes("bulk") ? 5 : -5))}"></label>`;
    box.querySelectorAll(".plan-opt").forEach((b) => b.onclick = () => { plan.pace = +b.dataset.p; plan.paceCustom = null; renderPlanStep(); });
    $("#pl-pace-own").addEventListener("input", (e) => {
      const v = num(e.target.value);
      plan.paceCustom = v && v <= 2 ? Math.round(v * 100) / 100 : null;
      box.querySelectorAll(".plan-opt").forEach((b) => b.classList.toggle("on", !plan.paceCustom && +b.dataset.p === plan.pace));
      $(".plan-own").classList.toggle("on", !!plan.paceCustom);
      $("#pl-pace-note").textContent = paceNote(plan.paceCustom);
    });
    return;
  }
  if (step === "spread") {
    const hasDays = plan.trainWeekdays.length > 0 && plan.trainWeekdays.length < 7;
    box.innerHTML = `<p class="plan-q">How should your week look?</p><p class="plan-sub">The weekly total is the same either way.</p>` +
      planOpt(plan.spread === "same", "i-calendar:green", "Same every day", "Simplest: one number, every day", `data-s="same"`) +
      (plan.trainDays > 0 ? planOpt(plan.spread === "train", "i-lift:coral", "More on training days", hasDays ? `A bit more on ${plan.trainWeekdays.map((d) => WEEKDAYS[d].slice(0, 3)).join(", ")}, a bit less on the rest` : "Pick your training days on the previous step first", `data-s="train"${hasDays ? "" : " disabled"}`) : "") +
      planOpt(plan.spread === "cheat", "i-cake:peach", "A bigger cheat day", "One day with about 30% more, the others a little less", `data-s="cheat"`) +
      (plan.spread === "cheat" ? `<div class="plan-label">Which day?</div><div class="plan-days" id="pl-cheat">${[1, 2, 3, 4, 5, 6, 0].map((d) => `<button data-d="${d}" class="${plan.cheatDay === d ? "on" : ""}">${WEEKDAYS[d].slice(0, 2)}</button>`).join("")}</div>` : "");
    box.querySelectorAll(".plan-opt").forEach((b) => b.onclick = () => { if (b.disabled) return; plan.spread = b.dataset.s; renderPlanStep(); });
    box.querySelectorAll("#pl-cheat button").forEach((b) => b.onclick = () => { plan.cheatDay = +b.dataset.d; renderPlanStep(); });
    return;
  }
  if (step === "protein") {
    const w = +plan.weight || 80;
    box.innerHTML = `<p class="plan-q">How much protein?</p><p class="plan-sub">More protein keeps you fuller and protects muscle.</p>` +
      planOpt(plan.protein === "std", "i-egg:sand", "Standard", `About ${Math.round(w * 1.6)} g a day`, `data-p="std"`) +
      planOpt(plan.protein === "high", "i-drumstick:peach", "High", `About ${Math.round(w * 2.0)} g a day`, `data-p="high"`) +
      planOpt(plan.protein === "lift", "i-lift:coral", "High, for lifting", `About ${Math.round(w * (plan.goal === "cut" ? 2.4 : 2.2))} g a day`, `data-p="lift"`);
    box.querySelectorAll(".plan-opt").forEach((b) => b.onclick = () => { plan.protein = b.dataset.p; renderPlanStep(); });
    return;
  }
  if (step === "summary") {
    const r = computePlan(plan); plan.result = r;
    const split = r.trainDayKcal ? `Training days ${fmt(r.trainDayKcal)} · other days ${fmt(r.everydayKcal)}` : r.cheatKcal ? `${WEEKDAYS[plan.cheatDay]} ${fmt(r.cheatKcal)} · other days ${fmt(r.everydayKcal)}` : "Every day";
    box.innerHTML = `<p class="plan-q">Your plan</p>
      <div class="card plan-sum"><div class="big">${fmt(r.kcal)} <small>kcal a day</small></div><div class="split">${split}</div>
        <div class="plan-macros"><div><b>${r.macros.p} g</b><small>Protein</small></div><div><b>${r.macros.c} g</b><small>Carbs</small></div><div><b>${r.macros.f} g</b><small>Fat</small></div></div>
        <div class="plan-facts"><svg class="ic"><use href="#${PLAN_GOALS[plan.goal].e.split(":")[0]}"/></svg>${PLAN_GOALS[plan.goal].name}${r.rate ? ` · ${r.rate > 0 ? "gaining" : "losing"} about ${fmt(Math.abs(r.rate), 2)} kg a week` : " · holding steady"}${r.date ? `<br><svg class="ic"><use href="#i-flag"/></svg>${fmt(plan.goalWeight, 1)} kg around ${r.date.toLocaleDateString(undefined, { day: "numeric", month: "short", year: r.date.getFullYear() !== new Date().getFullYear() ? "numeric" : undefined })}` : ""}</div>
        ${r.notes.map((n) => `<div class="plan-warn">${esc(n)}</div>`).join("")}</div>
      <p class="plan-how">You burn about ${fmt(r.tdee)} kcal a day: ${r.fromKnown ? `${r.formula} (the formula guessed ${fmt(r.estimate)})` : `${fmt(r.bmr)} at rest (${r.formula}), plus daily activity and training`}. Workout calories are already counted, so "add burned calories to my budget" is switched off. Each week after the first two, it learns your real burn from what you log and weigh, and suggests an updated budget. A guide, not medical advice.</p>`;
    return;
  }
}
function planCollect() {
  const step = PLAN_STEPS[planStep];
  if (step === "body") {
    plan.age = num($("#pl-age").value); let hv = String($("#pl-height").value || "").trim();
    const ft = hv.match(/^(\d)\s*['′ft]+\s*(\d{1,2})?/i); plan.height = ft ? Math.round((+ft[1] * 12 + +(ft[2] || 0)) * 2.54) : num(hv);
    plan.weight = num($("#pl-weight").value); const f = num($("#pl-fat").value);
    if (plan.useScale === false) { plan.fatOwn = f; plan.fat = f; } else plan.fat = f;
    if (!plan.sex) return "Pick female or male: it changes the maths";
    if (!plan.age || plan.age < 13 || plan.age > 100) return "Add your age";
    if (!plan.height || plan.height < 120 || plan.height > 230) return "Add your height in cm (or like 5'10)";
    if (!plan.weight || plan.weight < 30 || plan.weight > 300) return "Add your weight in kg";
    if (plan.fat && (plan.fat < 3 || plan.fat > 65)) return "Body fat looks off: leave it blank if unsure";
  }
  if (step === "activity") { knownRead(); if (!plan.activity && !plan.knownKcal) return "Pick the one closest to a normal day, or fill in what you eat now"; if (!plan.activity) plan.activity = 1.375; if (plan.knownKcal && plan.knownDir !== "steady" && !plan.knownKg) return "Add how many kg a week, or pick Steady"; }
  if (step === "training") { if (plan.trainDays == null) return "Pick how many days a week"; if (plan.trainDays > 0 && !plan.trainType) return "Pick what kind of training"; if (plan.trainDays > 0 && !plan.trainMins) return "Pick how long a session usually is"; }
  if (step === "goal" && !plan.goal) return "Pick a goal";
  if (step === "pace") { const own = num(($("#pl-pace-own") || {}).value); if (own && (own < 0.05 || own > 2)) return "Choose between 0.05 and 2 kg a week"; const g = num(($("#pl-goalw") || {}).value); plan.goalWeight = g && g > 30 && g < 300 ? Math.round(g * 10) / 10 : null; }
  if (step === "spread" && plan.spread === "train" && !(plan.trainWeekdays.length > 0 && plan.trainWeekdays.length < 7)) plan.spread = "same";
  if (step === "protein" && !plan.protein) return "Pick how much protein";
  return null;
}
function applyPlan() {
  const r = plan.result || computePlan(plan);
  state.profile = { sex: plan.sex, age: plan.age, height: plan.height };
  state.budget = r.everydayKcal;
  state.dayBudgets = Object.assign({}, r.days);
  state.goals = { p: r.macros.p, c: r.macros.c, f: r.macros.f };
  state.eatBack = false;
  state.weightKg = plan.weight;
  if (plan.goalWeight) { state.goalWeight = plan.goalWeight; state.goalStart = { weight: plan.weight, day: localDate() }; }
  // the starting weight goes in as today's reading if there isn't one
  const today = state.body.find((x) => x.day === localDate());
  if (!today || (!today.weight && plan.weight)) upsertBody(Object.assign({ day: localDate(), updatedAt: new Date().toISOString(), weight: plan.weight }, plan.fat && plan.useScale === false ? { fat: plan.fat } : {}));
  state.plan = { createdAt: new Date().toISOString(), goal: plan.goal, pace: plan.pace, rate: r.rate, activity: plan.activity, trainDays: plan.trainDays, trainType: plan.trainType, trainMins: plan.trainMins, trainWeekdays: plan.trainWeekdays,
    spread: plan.spread, cheatDay: plan.cheatDay, protein: plan.protein, paceCustom: plan.paceCustom || null, startWeight: plan.weight, fat: plan.fat, tdee: r.tdee, bmr: r.bmr, kcal: r.kcal, macros: r.macros, lastCheckIn: Date.now() };
  save();
  toast(`Plan set: ${fmt(r.kcal)} kcal a day`, 4000);
  const ret = planReturn; plan = null;
  if (ret === "welcome") { stack = ["welcome"]; show("welcome"); wlStep(3); } else home();
}
$("#plan-next").onclick = () => {
  const err = planCollect(); if (err) { toast(err); return; }
  if (PLAN_STEPS[planStep] === "summary") { applyPlan(); return; }
  planStep++; if (PLAN_STEPS[planStep] === "pace" && !planHasPace()) planStep++;
  window.scrollTo(0, 0); renderPlanStep();
};
$("#plan-back").onclick = () => {
  if (planStep === 0) { const ret = planReturn; plan = null; if (ret === "welcome") { stack = ["welcome"]; show("welcome"); wlStep(2); } else back(); return; }
  planCollect(); planStep--; if (PLAN_STEPS[planStep] === "pace" && !planHasPace()) planStep--;
  window.scrollTo(0, 0); renderPlanStep();
};
$("#wl-plan").onclick = () => openPlan("welcome");
function planLine() { const pl = state.plan; return pl ? `${PLAN_GOALS[pl.goal].name} · ${fmt(pl.kcal)} kcal${pl.learnedBurn ? ` · your burn ${fmt(pl.learnedBurn)} (learned)` : ""} · since ${new Date(pl.createdAt).toLocaleDateString(undefined, { day: "numeric", month: "short" })}` : ""; }
/** The plan as a big card: the daily number first, then the pace and the goal date. */
function bigPlanCard() {
  const pl = state.plan;
  if (!pl) return `<span class="circle big-ic"><svg><use href="#i-spark"/></svg></span><span class="big-text"><small class="k">Your plan</small><b class="n" style="font-size:21px">Work out my budget for me</b><small class="s">A few questions about you and your goal: 1 minute</small></span><svg class="chev"><use href="#i-chev"/></svg>`;
  const lb = latestBody(), goal = state.goalWeight;
  let when = "";
  if (goal && lb && lb.weight && pl.rate && Math.sign(goal - lb.weight) === Math.sign(pl.rate)) {
    const d = new Date(); d.setDate(d.getDate() + Math.round((goal - lb.weight) / pl.rate * 7));
    when = ` · ${fmt(goal, 1)} kg around ${d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: d.getFullYear() !== new Date().getFullYear() ? "numeric" : undefined })}`;
  }
  const pace = pl.rate ? `${pl.rate > 0 ? "+" : "−"}${fmt(Math.abs(pl.rate), 2)} kg a week` : "holding steady";
  return `<span class="circle big-ic"><svg><use href="#i-trophy"/></svg></span><span class="big-text"><small class="k">Your plan · ${esc(PLAN_GOALS[pl.goal].name)}</small><b class="n">${fmt(pl.kcal)}<small>kcal a day</small></b><small class="s">${pace}${when}</small></span><svg class="chev"><use href="#i-chev"/></svg>`;
}
function renderPlanCards() {
  const pl = state.plan;
  const html = pl ? `<span class="circle"><svg><use href="#i-trophy"/></svg></span><span class="level-text"><b>Your plan</b><small>${esc(planLine())} · tap to redo</small></span><svg class="chev"><use href="#i-chev"/></svg>`
    : `<span class="circle"><svg><use href="#i-spark"/></svg></span><span class="level-text"><b>Work out my budget for me</b><small>A few questions about you and your goal: 1 minute</small></span><svg class="chev"><use href="#i-chev"/></svg>`;
  $("#b-plan").innerHTML = bigPlanCard(); $("#b-plan").onclick = () => openPlan();
  const g = $("#g-plan"); g.classList.toggle("hidden", !pl); if (pl) { g.innerHTML = html; g.onclick = () => openPlan(); }
}
/** Real burn = average eaten on well-logged days minus what the weight trend says was stored or lost.
 *  Needs 10+ well-logged days in the last 3 weeks and a weight trend (3+ weigh-ins over a week or more). */
function learnedBurn() {
  const trend = weightTrend(); if (!trend) return null;
  const since = dateMinus(21);
  const days = state.history.filter((h) => h.date >= since && h.budget && (h.kcal || 0) >= h.budget * 0.6);   // skip days that were clearly only half logged
  if (days.length < 10) return null;
  const eat = days.reduce((a, h) => a + h.kcal, 0) / days.length;
  let burn = eat - trend.perDay * KCAL_PER_KG;
  const est = state.plan && state.plan.tdee;
  if (est) burn = Math.max(est * 0.7, Math.min(est * 1.3, burn));   // a sanity band around the estimate
  return { burn: Math.round(burn / 10) * 10, eat: Math.round(eat), days: days.length, weighins: trend.n, perWeek: Math.round(trend.perDay * 7 * 100) / 100 };
}
// ---- weigh-in days: which weekdays (0 = Sunday) someone steps on the scale. Once a week on Sunday unless they choose.
const weighDays = () => (Array.isArray(state.weighDays) && state.weighDays.length ? state.weighDays : [0]);
const weighedToday = () => { const lb = latestBody(); return !!(lb && lb.day === localDate()); };
function weighDue() { return weighDays().includes(new Date().getDay()) && !weighedToday(); }
function nextWeighIn() {
  const days = weighDays(), today = new Date().getDay();
  for (let i = weighedToday() || !days.includes(today) ? 1 : 0; i < 8; i++) if (days.includes((today + i) % 7)) return i;
  return 7;
}
const whenWord = (i) => i === 0 ? "today" : i === 1 ? "tomorrow" : WEEKDAYS[(new Date().getDay() + i) % 7];
function bodyLine(lb) {
  if (!lb) return "Weight, body fat, muscle: from your scale or typed in";
  const bits = [lb.weight ? `${lb.weight} kg` : "", lb.fat ? `${lb.fat}% fat` : "", lb.muscle ? `${lb.muscle} kg muscle` : lb.lean ? `${lb.lean} kg lean` : ""].filter(Boolean);
  return `${bits.join(" · ")} · ${lb.day === localDate() ? "today" : new Date(lb.day + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short" })}`;
}
function renderHomeWeigh() {
  const el = $("#home-weigh"), lb = latestBody(), due = weighDue();
  el.classList.toggle("due", due);
  const text = !lb ? "Track your weight to tune your budget" : due ? `${lb.weight ? `${lb.weight} kg · ` : ""}weigh-in due today` : `${lb.weight ? `${lb.weight} kg · ` : ""}next weigh-in ${whenWord(nextWeighIn()).replace(/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\w*$/, "$1")}`;
  el.innerHTML = `<svg><use href="#i-scale"/></svg><span class="wl-text">${esc(text)}</span><span class="wl-btn">${lb ? "Weigh in" : "Start"}</span>`;
}
function renderBudgetBody() {
  const lb = latestBody();
  $("#b-tunes").classList.toggle("hidden", !state.plan);
  $("#bb-n").innerHTML = lb && lb.weight ? `${fmt(lb.weight, 1)}<small>kg${lb.fat ? ` · ${fmt(lb.fat, 1)}% fat` : ""}</small>` : `<span style="font-size:20px">Track your weight</span>`;
  const since = dateMinus(14), recent = state.body.filter((r) => r.weight && r.day >= since).length;
  $("#bb-line").textContent = `${recent ? `${recent} weigh-in${recent === 1 ? "" : "s"} in 2 weeks · ` : ""}next ${whenWord(nextWeighIn())}`;
}
/** Body page: which days to weigh in. */
function renderWeighDays() {
  const days = weighDays(), n = days.length;
  $("#bd-days-title").textContent = n === 7 ? "Weigh in every day" : n === 1 ? `Weigh in on ${WEEKDAYS[days[0]]}s` : `Weigh in ${n} days a week`;
  const rem = state.reminders && state.reminders.weigh;
  $("#bd-days-sub").textContent = `${weighDue() ? "Due today" : `Next: ${whenWord(nextWeighIn())}`}${rem ? ` · reminder at ${rem}` : ""}`;
  $("#bb-next").textContent = weighDue() ? "Weigh-in due today" : `Next weigh-in ${whenWord(nextWeighIn())}`;
  $$("#bb-freq button").forEach((b) => b.classList.toggle("on", +b.dataset.f === n));
  const pick = $("#bb-days"); pick.classList.toggle("hidden", n === 7);
  pick.innerHTML = [1, 2, 3, 4, 5, 6, 0].map((d) => `<button data-d="${d}" class="${days.includes(d) ? "on" : ""}">${WEEKDAYS[d].slice(0, 1)}</button>`).join("");
  $("#bb-hint").textContent = n === 1 ? `Every ${WEEKDAYS[days[0]]}. Weekly works: your plan adjusts after about 3 weeks, and carefully, as one weigh-in can swing a kilo with water.`
    : n === 7 ? "Every day, ideally first thing. The more often, the sooner and steadier your plan adjusts."
    : `${n} days a week, ideally first thing. Your plan starts adjusting after about a week.`;
}
$("#bb-freq").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  const f = +b.dataset.f, cur = weighDays();
  state.weighDays = f === 7 ? [0, 1, 2, 3, 4, 5, 6] : f === 3 ? [1, 3, 5] : [cur.length === 1 ? cur[0] : 0];
  save(); renderWeighDays(); syncReminderDays();
});
$("#bb-days").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  const d = +b.dataset.d, cur = weighDays();
  if (cur.length === 1) state.weighDays = [d];   // once a week: tap moves the day
  else { const next = cur.includes(d) ? cur.filter((x) => x !== d) : cur.concat(d); state.weighDays = next.length ? next.sort() : cur; }
  save(); renderWeighDays(); syncReminderDays();
});
/** Home: invite people without a plan once; with a plan, a weekly check-in against the real weight trend. */
const PLAN_ASK = "cheatday.planAsk";
function renderHomePlan() {
  const box = $("#home-plan"); box.innerHTML = "";
  const pl = state.plan;
  if (!pl) {
    let rec = {}; try { rec = JSON.parse(localStorage.getItem(PLAN_ASK) || "{}"); } catch (e) {}
    if (rec.dismissed || !state.onboarded) return;
    box.innerHTML = `<div class="card home-plan-card"><span class="circle green"><svg><use href="#i-spark"/></svg></span><div class="body"><b>Get a budget that fits your goal</b><small>Losing, cutting, bulking or maintaining: a few questions, 1 minute.</small><div class="acts"><button class="btn primary" data-a="go">Set it up</button></div></div><button class="x" aria-label="Dismiss">✕</button></div>`;
    box.querySelector("[data-a=go]").onclick = () => openPlan();
    box.querySelector(".x").onclick = () => { try { localStorage.setItem(PLAN_ASK, JSON.stringify({ dismissed: true })); } catch (e) {} box.innerHTML = ""; };
    return;
  }
  const age = Date.now() - new Date(pl.createdAt).getTime(), since = Date.now() - (pl.lastCheckIn || 0);
  if (age < 14 * 864e5 || since < 7 * 864e5) return;
  const trend = weightTrend(), want = pl.rate || 0, learned = learnedBurn();
  let title, body, acts = "";
  const floor = (state.profile && state.profile.sex === "m") ? 1500 : 1200;
  if (learned) {
    // the budget that hits the plan's pace, given the burn the logs show
    const target = Math.max(floor, Math.round((learned.burn + want * KCAL_PER_KG / 7) / 10) * 10);
    let delta = Math.max(-300, Math.min(300, target - pl.kcal));
    delta = Math.round(delta / 10) * 10;
    const word = (v) => v === 0 ? "holding steady" : `${v > 0 ? "gaining" : "losing"} ${fmt(Math.abs(v), 2)} kg a week`;
    const facts = `From ${learned.days} logged days and ${learned.weighins} weigh-ins, you burn about ${fmt(learned.burn)} kcal a day and you're ${word(learned.perWeek)}.`;
    if (Math.abs(delta) < 50) { title = "Check-in: on track"; body = `${facts} Your budget already fits your plan.`; acts = `<button class="btn mint" data-a="ok" data-burn="${learned.burn}">Nice</button>`; }
    else { title = "Weekly check-in"; body = `${facts} To ${want < 0 ? `lose ${fmt(-want, 2)} kg a week` : want > 0 ? `gain ${fmt(want, 2)} kg a week` : "hold steady"}, ${delta < 0 ? "drop" : "raise"} your average to ${fmt(pl.kcal + delta)} kcal?`; acts = `<button class="btn primary" data-a="adj" data-d="${delta}" data-burn="${learned.burn}">Update</button><button class="btn ghost" data-a="ok" data-burn="${learned.burn}">Keep</button>`; }
  } else if (!trend) { title = "Weekly check-in"; body = "Weigh in a few times this week so your plan can check it's on track."; acts = `<button class="btn primary" data-go="body">Weigh in</button><button class="btn mint" data-a="ok">Later</button>`; }
  else {
    const got = Math.round(trend.perDay * 7 * 100) / 100, gap = want - got;
    const word = (v) => v === 0 ? "holding steady" : `${v > 0 ? "gaining" : "losing"} ${fmt(Math.abs(v), 2)} kg a week`;
    if (Math.abs(gap) < 0.15) { title = "Check-in: on track"; body = `You're ${word(got)}, just as planned. Keep going.`; acts = `<button class="btn mint" data-a="ok">Nice</button>`; }
    else {
      let delta = Math.round(Math.max(-250, Math.min(250, gap * KCAL_PER_KG / 7)) / 10) * 10;
      if (state.budget + delta < floor) delta = floor - state.budget;
      if (!delta) { title = "Weekly check-in"; body = `You're ${word(got)}; your plan aims for ${want === 0 ? "steady" : `${fmt(Math.abs(want), 2)}`}. Your budget is already at the safe minimum, so more movement is the next lever.`; acts = `<button class="btn mint" data-a="ok">OK</button>`; }
      else { title = "Weekly check-in"; body = `You're ${word(got)}; your plan aims for ${want === 0 ? "steady" : `${fmt(Math.abs(want), 2)}`}. ${delta < 0 ? "Drop" : "Raise"} your budget to ${fmt(state.budget + delta)} kcal?`; acts = `<button class="btn primary" data-a="adj" data-d="${delta}">Update</button><button class="btn ghost" data-a="ok">Keep</button>`; }
    }
  }
  box.innerHTML = `<div class="card home-plan-card"><span class="circle green"><svg><use href="#i-scale"/></svg></span><div class="body"><b>${title}</b><small>${body}</small><div class="acts">${acts}</div></div></div>`;
  box.querySelectorAll("[data-a]").forEach((b) => b.onclick = () => {
    if (b.dataset.a === "adj") {
      const d = +b.dataset.d;
      state.budget += d; for (const k of Object.keys(state.dayBudgets || {})) state.dayBudgets[k] += d;
      pl.kcal += d; pl.macros.c = Math.max(0, pl.macros.c + Math.round(d / 4)); state.goals = Object.assign({}, state.goals, { c: pl.macros.c });
      toast(`Budget now ${fmt(state.budget)} kcal`);
    }
    if (b.dataset.burn) { pl.learnedBurn = +b.dataset.burn; pl.learnedAt = Date.now(); }
    pl.lastCheckIn = Date.now(); save(); renderHome();
  });
}

// ---------------------------------------------------------------- goals, XP, levels and badges: the game layer

const XP = { item: 2, itemCap: 10, log: 10, under: 25, protein: 15, workout: 20, pb: 30, post: 5, goal: 50 };
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
/** Monday of the week a date is in. */
function weekOf(date) { const d = new Date(date + "T12:00"); d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); return localDate(d); }
/** Days logged in a row. One missed day per week is a free rest day and doesn't break it (never two misses in a row). */
function streakInfo() {
  let n = 0, i = dayFacts(localDate()).logged ? 0 : 1, lastRest = false;
  const rests = [];
  for (; i < 400; i++) {
    const d = dateMinus(i);
    if (dayFacts(d).logged) { n++; lastRest = false; continue; }
    const wk = weekOf(d);
    if (!lastRest && n > 0 && !rests.some((r) => weekOf(r) === wk)) { rests.push(d); lastRest = true; continue; }
    if (!lastRest && n === 0 && i === 1 && !rests.length) { rests.push(d); lastRest = true; continue; }   // yesterday missed, today not logged yet
    break;
  }
  // A rest that isn't followed (further back) by a logged day isn't really bridging anything
  while (rests.length && rests[rests.length - 1] === dateMinus(i - 1)) rests.pop();
  return { days: n, rests, restThisWeek: rests.some((r) => weekOf(r) === weekOf(localDate())) };
}
function logStreak() { return streakInfo().days; }
function underStreak() {
  let n = 0;
  for (let i = 1; i < 400; i++) { const d = dayFacts(dateMinus(i)); if (underBudget(d)) n++; else break; }
  return n;
}
/** XP is worked out from what's recorded, so it can't be double counted or lost. Today counts only for logging and workouts until it's over. */
function totalXp() {
  let xp = 0;
  const foodXp = (items) => Math.min(Array.isArray(items) ? items.length : 0, XP.itemCap) * XP.item;   // every food logged counts, up to a daily cap
  for (const h of state.history) { const d = dayFacts(h.date); if (d.logged) xp += XP.log; if (underBudget(d)) xp += XP.under; if (hitProtein(d)) xp += XP.protein; xp += d.workouts * XP.workout; xp += foodXp(h.items); }
  const t = dayFacts(localDate()); if (t.logged) xp += XP.log; xp += t.workouts * XP.workout; xp += foodXp(state.day.items);
  xp += (state.pbCount || 0) * XP.pb + (state.postCount || 0) * XP.post + (state.goalWins || []).length * XP.goal;
  xp += badgeXp();
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
// Everything the achievements count, worked out once per render
let bsCache = null;
function badgeStats() {
  if (bsCache && Date.now() - bsCache.at < 1500) return bsCache.v;
  const today = dayFacts(localDate()), hist = state.history.map((h) => ({ h, f: dayFacts(h.date) }));
  const allItems = state.history.flatMap((h) => Array.isArray(h.items) ? h.items : []).concat(state.day.items);
  const allWorkouts = state.history.flatMap((h) => h.workouts || []).concat(state.day.workouts || []);
  const weights = bodySorted().filter((r) => r.weight);
  const wins = state.goalWins || [], winsByWeek = {};
  for (const w of wins) { const wk = String(w).split(":")[0]; winsByWeek[wk] = (winsByWeek[wk] || 0) + 1; }
  const activeGoals = GOAL_DEFS.filter((d) => (state.weekGoals[d.key] || 0) > 0 && !(d.needs && !d.needs())).length || 4;
  const loggedDates = hist.filter((x) => x.f.logged).map((x) => x.h.date).concat(today.logged ? [localDate()] : []).sort();
  let comeback = false;
  for (let i = 1; i < loggedDates.length; i++) if ((new Date(loggedDates[i]) - new Date(loggedDates[i - 1])) / 864e5 >= 7) comeback = true;
  const hours = allItems.map((it) => it.addedAt ? new Date(it.addedAt).getHours() : null).filter((h) => h != null);
  const weekendWorkout = (() => { const days = new Set(state.history.filter((h) => (h.workouts || []).length).map((h) => h.date).concat((state.day.workouts || []).length ? [localDate()] : []));
    for (const d of days) { const dt = new Date(d + "T12:00"); if (dt.getDay() === 6) { const sun = new Date(dt); sun.setDate(sun.getDate() + 1); if (days.has(localDate(sun))) return true; } } return false; })();
  const v = {
    daysLogged: loggedDates.length, streak: logStreak(), under: underStreak(),
    underDays: hist.filter((x) => underBudget(x.f)).length, overDays: hist.filter((x) => x.f.logged && x.f.budget && x.f.kcal > x.f.budget).length,
    proteinDays: hist.filter((x) => hitProtein(x.f)).length,
    workouts: allWorkouts.length, workoutMins: allWorkouts.reduce((a, w) => a + (w.minutes || 0), 0), liftSessions: allWorkouts.filter((w) => (w.lifts || []).length).length,
    burned: allWorkouts.reduce((a, w) => a + (w.kcal || 0), 0), pbs: state.pbCount || 0, routines: (state.routines || []).length, weekendWorkout,
    weighins: weights.length, lost: weights.length > 1 ? Math.max(0, weights[0].weight - weights[weights.length - 1].weight) : 0,
    goalSet: !!state.goalWeight, goalReached: !!(state.goalWeight && weights.length && Math.abs(weights[weights.length - 1].weight - state.goalWeight) < 0.25),
    posts: state.postCount || 0, reacts: state.reactCount || 0, comments: state.commentCount || 0, sends: state.sendCount || 0, friends: state.friendCount || 0,
    meals: state.meals.filter((m) => m.saved).length, recipes: state.meals.filter((m) => m.saved && (m.steps || []).length).length,
    foods: new Set(allItems.map((it) => String(it.name || "").toLowerCase().trim()).filter(Boolean)).size,
    scans: allItems.filter((it) => it.source === "barcode" || it.source === "label").length, photos: allItems.filter((it) => it.photo).length, askItems: allItems.filter((it) => it.source === "claude").length,
    earlyBird: hours.some((h) => h < 8), nightOwl: hours.some((h) => h >= 22), comeback,
    level: levelFor(totalXp()).lvl, weeklyWins: wins.length, perfectWeeks: Object.values(winsByWeek).filter((n) => n >= activeGoals).length,
    rests: streakInfo().rests.length
  };
  bsCache = { at: Date.now(), v };
  return v;
}
/** A run of badges on one number: [id, icon, name, target, how] each; progress shown towards the target. */
const TIER_XP = [25, 50, 100, 200, 400, 800];
const tierSet = (group, stat, list) => list.map(([id, icon, name, target, how], i) => ({ id, group, icon, name, how, target, stat, xp: TIER_XP[Math.min(i, TIER_XP.length - 1)], test: () => (badgeStats()[stat] || 0) >= target }));
const flag = (group, stat, id, icon, name, how) => ({ id, group, icon, name, how, xp: 50, test: () => !!badgeStats()[stat] });
/** XP from achievements already earned (stored ones, so levels never depend on themselves). */
const badgeXp = () => state.seenBadges.reduce((a, id) => { const b = BADGES.find((x) => x.id === id); return a + (b ? b.xp || 0 : 0); }, 0);
const BADGE_GROUPS = ["Logging", "Budget", "Nutrition", "Workouts", "Body", "Social", "Level up"];
const BADGES = [
  ...tierSet("Logging", "daysLogged", [["first", "🌱", "First bite", 1, "Log your first day"], ["days10", "📒", "Getting the hang", 10, "Log 10 days"], ["days50", "📚", "Habit formed", 50, "Log 50 days"], ["days100", "💯", "Centurion", 100, "Log 100 days"], ["days250", "🗂️", "Record keeper", 250, "Log 250 days"]]),
  ...tierSet("Logging", "streak", [["streak3", "✨", "Warming up", 3, "Log 3 days in a row"], ["streak7", "🔥", "One week", 7, "Log 7 days in a row"], ["streak14", "🔥", "Fortnight", 14, "Log 14 days in a row"], ["streak30", "🏆", "One month", 30, "Log 30 days in a row"], ["streak100", "🌋", "Unstoppable", 100, "Log 100 days in a row"], ["streak365", "👑", "A whole year", 365, "Log 365 days in a row"]]),
  flag("Logging", "earlyBird", "early", "🌅", "Early bird", "Log something before 8am"),
  flag("Logging", "nightOwl", "owl", "🦉", "Night owl", "Log something after 10pm"),
  flag("Logging", "comeback", "comeback", "🔁", "Comeback", "Start logging again after a week off"),
  ...tierSet("Logging", "rests", [["rest1", "🛋️", "Rest day", 1, "Use a rest day without breaking your streak"]]),
  ...tierSet("Budget", "under", [["under3", "🎯", "On target", 3, "3 days under budget in a row"], ["under7", "🎯", "Bullseye week", 7, "7 days under budget in a row"], ["under14", "💎", "Iron will", 14, "14 days under budget in a row"], ["under30", "🧊", "Ice cold", 30, "30 days under budget in a row"]]),
  ...tierSet("Budget", "underDays", [["ud10", "🟢", "Ten good days", 10, "10 days under budget"], ["ud50", "🌿", "Fifty good days", 50, "50 days under budget"], ["ud100", "🌳", "Hundred good days", 100, "100 days under budget"]]),
  ...tierSet("Budget", "overDays", [["cheat1", "🍰", "It's a cheat day", 1, "Go over budget once. It happens!"]]),
  ...tierSet("Nutrition", "proteinDays", [["protein5", "🥩", "Protein pro", 5, "Hit your protein goal 5 times"], ["protein20", "🍗", "Protein machine", 20, "Hit your protein goal 20 times"], ["protein50", "🦾", "Built different", 50, "Hit your protein goal 50 times"]]),
  ...tierSet("Nutrition", "foods", [["foods25", "🥗", "Explorer", 25, "Log 25 different foods"], ["foods100", "🌍", "Adventurous eater", 100, "Log 100 different foods"]]),
  ...tierSet("Nutrition", "scans", [["scan1", "🔍", "Scanner", 1, "Scan a barcode or label"], ["scan25", "📷", "Label reader", 25, "Scan 25 barcodes or labels"]]),
  ...tierSet("Nutrition", "photos", [["photo1", "🖼️", "Food photographer", 1, "Add a photo to something you log"], ["photo25", "🎞️", "Food diary", 25, "Log 25 things with photos"]]),
  ...tierSet("Nutrition", "meals", [["meal1", "🍲", "Home cook", 1, "Save a meal"], ["meal10", "👩‍🍳", "Recipe book", 10, "Save 10 meals"]]),
  ...tierSet("Nutrition", "recipes", [["recipe1", "📝", "Chef's notes", 1, "Save a meal with method steps"]]),
  ...tierSet("Nutrition", "askItems", [["ask1", "💬", "Just ask", 1, "Log something through the assistant"]]),
  ...tierSet("Workouts", "workouts", [["wo1", "👟", "Moved", 1, "Log a workout"], ["wo10", "💪", "Ten strong", 10, "Log 10 workouts"], ["wo25", "🏃", "Regular", 25, "Log 25 workouts"], ["wo50", "🏋️", "Gym rat", 50, "Log 50 workouts"], ["wo100", "🥇", "Hundred club", 100, "Log 100 workouts"]]),
  ...tierSet("Workouts", "workoutMins", [["min600", "⏱️", "Ten hours in", 600, "Train for 10 hours in total"], ["min3000", "⏳", "Fifty hours in", 3000, "Train for 50 hours in total"]]),
  ...tierSet("Workouts", "burned", [["burn10k", "🔥", "Furnace", 10000, "Burn 10,000 kcal in workouts"]]),
  ...tierSet("Workouts", "pbs", [["pb", "🥇", "New best", 1, "Beat a lifting PB"], ["pb10", "📈", "Getting stronger", 10, "Beat 10 lifting PBs"], ["pb25", "🦍", "Beast mode", 25, "Beat 25 lifting PBs"]]),
  ...tierSet("Workouts", "routines", [["routine1", "📋", "Creature of habit", 1, "Save a workout routine"]]),
  flag("Workouts", "weekendWorkout", "weekend", "🗓️", "Weekend warrior", "Work out on a Saturday and the Sunday after"),
  ...tierSet("Body", "weighins", [["weigh1", "⚖️", "Stepped on", 1, "Record a weigh-in"], ["weigh10", "📉", "Tracking it", 10, "Record 10 weigh-ins"], ["weigh50", "📊", "Data driven", 50, "Record 50 weigh-ins"]]),
  flag("Body", "goalSet", "goalset", "🏁", "Eyes on the prize", "Set a goal weight"),
  ...tierSet("Body", "lost", [["lost1", "🪶", "First kilo", 1, "Lose 1 kg"], ["lost5", "🎈", "Five down", 5, "Lose 5 kg"], ["lost10", "🚀", "Ten down", 10, "Lose 10 kg"]]),
  flag("Body", "goalReached", "goalhit", "🎉", "Made it", "Reach your goal weight"),
  ...tierSet("Social", "friends", [["friend1", "🤝", "Buddy up", 1, "Add a friend"], ["friend5", "👥", "The crew", 5, "Have 5 friends"]]),
  ...tierSet("Social", "posts", [["post1", "📸", "Shared", 1, "Post to the feed"], ["post10", "🌟", "Influencer", 10, "Post 10 times"], ["post50", "📣", "Celebrity chef", 50, "Post 50 times"]]),
  ...tierSet("Social", "reacts", [["react10", "❤️", "Hype squad", 10, "React to 10 posts"]]),
  ...tierSet("Social", "comments", [["comment10", "💭", "Chatterbox", 10, "Leave 10 comments"]]),
  ...tierSet("Social", "sends", [["send1", "🎁", "Sharing is caring", 1, "Send food to a friend"]]),
  ...tierSet("Level up", "level", [["lvl5", "👑", "Level 5", 5, "Reach level 5"], ["lvl10", "🏅", "Level 10", 10, "Reach level 10"], ["lvl20", "🌠", "Level 20", 20, "Reach level 20"]]),
  ...tierSet("Level up", "weeklyWins", [["goal", "✅", "Goal getter", 1, "Finish a weekly goal"], ["goal10", "📆", "Consistent", 10, "Finish 10 weekly goals"], ["goal50", "🗓️", "Relentless", 50, "Finish 50 weekly goals"]]),
  ...tierSet("Level up", "perfectWeeks", [["perfect1", "💫", "Perfect week", 1, "Finish every weekly goal in one week"], ["perfect5", "🌈", "Perfect month", 5, "Have 5 perfect weeks"]])
];
function checkBadges() {
  bankGoals();
  const fresh = BADGES.filter((b) => !state.seenBadges.includes(b.id) && b.test());
  if (!fresh.length) return;
  for (const b of fresh) state.seenBadges.push(b.id);
  let more; bsCache = null;
  while ((more = BADGES.filter((b) => !state.seenBadges.includes(b.id) && b.test())).length) { for (const b of more) { state.seenBadges.push(b.id); fresh.push(b); } bsCache = null; }   // level badges can unlock from badge XP
  save();
  const gained = fresh.reduce((a, b) => a + (b.xp || 0), 0);
  toast(`${fresh[0].icon} ${fresh.length > 1 ? `${fresh.length} achievements` : `Achievement: ${fresh[0].name}`} · +${fmt(gained)} XP`, 4500);
}
// ---- the leaderboard: publish my numbers, rank friends by weekly goals, level or streak
function myStats() {
  const xp = totalXp(), L = levelFor(xp), prog = weekProgress(), g = state.weekGoals;
  const active = GOAL_DEFS.filter((d) => (g[d.key] || 0) > 0 && !(d.needs && !d.needs()));
  return { xp, level: L.lvl, streak: logStreak(), under_streak: underStreak(), week_goals_done: active.filter((d) => prog[d.key] >= g[d.key]).length, week_goals_total: active.length,
    week_pct: active.length ? Math.round(active.reduce((a, d) => a + Math.min(1, prog[d.key] / g[d.key]), 0) / active.length * 100) : 0, week_start: weekDates()[0] };
}
let statsSent = "";
function publishStats() {
  const c = window.cloud; if (!c || !c.user) return;
  const row = myStats(), key = JSON.stringify(row);
  if (key === statsSent) return;
  statsSent = key;
  c.publishStats(row).catch(() => { statsSent = ""; });   // table not made yet: stay quiet, try again later
}
let lbMode = "week", lbCache = null;
async function loadLeaderboard(force) {
  const c = window.cloud; if (!c || !c.user) return null;
  if (!force && lbCache && Date.now() - lbCache.at < 60000) return lbCache;
  try {
    const rows = await c.stats();
    const ids = rows.map((r) => r.user_id).filter((id) => !fr.people[id] && id !== c.uid);
    if (ids.length) { const people = await c.profiles(ids); for (const p of people) fr.people[p.user_id] = p; }
    lbCache = { at: Date.now(), rows };
  } catch (e) { lbCache = { at: Date.now(), rows: null, error: e }; }
  return lbCache;
}
function drawLeaderboard(el) {
  const c = window.cloud, me = c && c.uid; if (!el) return;
  if (!lbCache || !lbCache.rows) { el.innerHTML = `<div class="row muted">${lbCache && lbCache.error ? "The leaderboard isn't set up yet." : "Loading…"}</div>`; return; }
  const wk = weekDates()[0];
  const rows = lbCache.rows.map((r) => {
    const mine = r.user_id === me, st = mine ? myStats() : r, thisWeek = st.week_start === wk;
    return { uid: r.user_id, mine, name: mine ? "You" : personName(r.user_id), level: st.level || 1, xp: st.xp || 0, streak: st.streak || 0, under: st.under_streak || 0,
      done: thisWeek ? st.week_goals_done || 0 : 0, total: st.week_goals_total || 0, pct: thisWeek ? st.week_pct || 0 : 0 };
  });
  if (me && !rows.some((r) => r.mine)) { const st = myStats(); rows.push({ uid: me, mine: true, name: "You", level: st.level, xp: st.xp, streak: st.streak, under: st.under_streak, done: st.week_goals_done, total: st.week_goals_total, pct: st.week_pct }); }
  const sorters = { week: (a, b) => (b.pct - a.pct) || (b.done - a.done) || (b.xp - a.xp), level: (a, b) => (b.xp - a.xp), streak: (a, b) => (b.streak - a.streak) || (b.under - a.under) };
  rows.sort(sorters[lbMode]);
  el.innerHTML = "";
  rows.forEach((r, i) => {
    const row = document.createElement("div"); row.className = `row${r.mine ? " me" : ""}`;
    const main = lbMode === "week" ? `<b>${r.pct}%</b><small>${r.done} of ${r.total} goals</small>` : lbMode === "level" ? `<b>Lv ${r.level}</b><small>${fmt(r.xp)} XP</small>` : `<b>🔥 ${r.streak}</b><small>day${r.streak === 1 ? "" : "s"} logged</small>`;
    const sub = lbMode === "week" ? `Level ${r.level} · ${r.streak ? `${r.streak}-day streak` : "no streak"}` : lbMode === "level" ? `${r.done} of ${r.total} goals this week` : `${r.under}-day budget streak`;
    row.innerHTML = `<span class="medal m${i + 1}">${i + 1}</span>${avatar(r.uid, r.mine ? ((fr.profile && fr.profile.display_name) || "Me") : r.name)}<div class="who"><b>${esc(r.name)}</b><small>${esc(sub)}</small></div><div class="score">${main}</div>`;
    el.appendChild(row);
  });
  if (rows.length < 2) el.insertAdjacentHTML("beforeend", `<div class="row muted">Add friends to compete. Their levels show up once they open the app.</div>`);
}
async function renderLeaderboards(force) {
  const targets = ["#fr-lb", "#g-lb"].map((q) => $(q)).filter(Boolean);
  targets.forEach(drawLeaderboard);
  await loadLeaderboard(force);
  targets.forEach(drawLeaderboard);
  if (document.body.dataset.view === "friends" && fr.lastFriends) drawFriendRows(fr.lastFriends, fr.lastDayLabel);
}
document.addEventListener("click", (e) => {
  const b = e.target.closest(".lb-modes button"); if (!b) return;
  lbMode = b.dataset.m;
  $$(".lb-modes button").forEach((x) => x.classList.toggle("on", x.dataset.m === lbMode));
  ["#fr-lb", "#g-lb"].forEach((q) => drawLeaderboard($(q)));
});
function renderLevelCard() {
  const xp = totalXp(), L = levelFor(xp), prog = weekProgress(), g = state.weekGoals;
  const active = GOAL_DEFS.filter((d) => (g[d.key] || 0) > 0 && !(d.needs && !d.needs()));
  const done = active.filter((d) => prog[d.key] >= g[d.key]).length;
  $("#lv-title").textContent = `Level ${L.lvl} · ${L.name}`;
  $("#lv-sub").textContent = `${fmt(xp)} XP · ${L.next - xp} to next${active.length ? ` · ${done}/${active.length} goals this week` : ""}`;
  $("#lv-bar").style.width = `${Math.round(L.into / L.span * 100)}%`;
  checkBadges();
  publishStats();
}
function renderGoals() {
  renderPlanCards();
  const signed = !!(window.cloud && window.cloud.user);
  $("#g-lb-wrap").classList.toggle("hidden", !signed);
  if (signed) { publishStats(); renderLeaderboards(false); }
  const xp = totalXp(), L = levelFor(xp), prog = weekProgress(), g = state.weekGoals, ls = logStreak(), us = underStreak();
  $("#g-level").innerHTML = `<div class="lv-num">${L.lvl}</div><div class="lv-name">${L.name}</div><div class="muted tiny">${fmt(xp)} XP · ${L.next - xp} more for level ${L.lvl + 1}</div><span class="bar"><span style="width:${Math.round(L.into / L.span * 100)}%"></span></span>
    <div class="streaks">${ls ? `<span><i class="e">🔥</i>${ls} day${ls === 1 ? "" : "s"} logged</span>` : ""}${ls ? `<span class="rest">${streakInfo().restThisWeek ? "Rest day used this week" : "1 rest day left this week"}</span>` : ""}${us ? `<span><i class="e">🎯</i>${us} day${us === 1 ? "" : "s"} under budget</span>` : ""}${!ls && !us ? `<span>Log today to start a streak</span>` : ""}</div>`;
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
  const stats = badgeStats(); let earned = 0;
  for (const group of BADGE_GROUPS) {
    const list = BADGES.filter((b) => b.group === group); if (!list.length) continue;
    const got = list.filter((b) => state.seenBadges.includes(b.id) || b.test());
    earned += got.length;
    const sec = document.createElement("div"); sec.className = "badge-group";
    sec.innerHTML = `<h3>${group}<small>${got.length} of ${list.length}</small></h3><div class="badges"></div>`;
    const grid = sec.querySelector(".badges");
    // earned first, then the nearest to done
    const order = list.slice().sort((a, b) => (got.includes(b) - got.includes(a)) || ((b.target ? (stats[b.stat] || 0) / b.target : 0) - (a.target ? (stats[a.stat] || 0) / a.target : 0)));
    for (const b of order) {
      const has = got.includes(b), val = b.target ? Math.min(b.target, Math.floor(stats[b.stat] || 0)) : 0;
      const d = document.createElement("div"); d.className = `badge ${has ? "" : "locked"}`;
      d.innerHTML = `<span class="ic">${b.icon}</span><b>${b.name}</b><small>${has ? `Earned · +${b.xp} XP` : `${b.how} · +${b.xp} XP`}</small>${!has && b.target > 1 ? `<span class="prog"><span style="width:${Math.round(val / b.target * 100)}%"></span></span><small>${fmt(val)} / ${fmt(b.target)}</small>` : ""}`;
      grid.appendChild(d);
    }
    bl.appendChild(sec);
  }
  $("#g-badge-count").textContent = `${earned} of ${BADGES.length}`;
  $("#g-xp").innerHTML = [["Log a food (up to 10 a day)", XP.item], ["Log a day", XP.log], ["Finish a day under budget", XP.under], ["Hit your protein goal", XP.protein], ["Log a workout", XP.workout], ["Beat a lifting PB", XP.pb], ["Post to the feed", XP.post], ["Finish a weekly goal", XP.goal]].map(([k, v]) => `<div><span>${k}</span><b>+${v} XP</b></div>`).join("") + `<div><span>Earn an achievement</span><b>+25 to 800 XP</b></div>`;
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
        notifyFriend(f.id, "send", draft.name); state.sendCount = (state.sendCount || 0) + 1; save(false);
        const sendPhoto = await sharablePhoto(draft.photo);
        await c.sendItem(f.id, { name: draft.name, kcal, grams: a.grams != null ? Math.round(a.grams) : null, unit: draft.unit || "g", photo: sendPhoto, payload: basisOf(draft) });
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
  if (w.kind === "workout") return `<div class="dish"><span class="thumb-sm tone-coral"><svg><use href="#i-dumbbell"/></svg></span><div class="dish-main"><span class="dish-name">${esc(w.name)}</span><span class="dish-amt">${w.minutes} min · ${(w.lifts || []).length} exercise${(w.lifts || []).length === 1 ? "" : "s"}</span></div><div class="dish-kcal">${fmt(w.kcal)}<small>burned</small></div></div>`;
  const meal = w.kind === "meal", n = w.portions || 1;
  const amt = meal ? `${n} portion${n === 1 ? "" : "s"} · ${fmt(w.kcal)} kcal each` : (w.grams != null ? `${w.grams} ${w.unit || "g"}` : "1 serving");
  return `<div class="dish"><span class="thumb-sm ${meal ? "tone-peach" : wo ? "tone-coral" : ""}"><svg><use href="#i-${meal ? "meal" : wo ? "dumbbell" : "bowl"}"/></svg></span><div class="dish-main"><span class="dish-name">${esc(w.name)}</span><span class="dish-amt">${amt}</span></div><div class="dish-kcal">${fmt(w.kcal)}<small>kcal</small></div></div>`;
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
  $("#compose-edit").classList.toggle("hidden", !composePhoto);
  const small = $("#compose-small"); small.classList.add("hidden");
  if (composePhoto) { const probe = new Image(); probe.onload = () => small.classList.toggle("hidden", Math.min(probe.naturalWidth, probe.naturalHeight) >= 600); probe.src = composePhoto; }
}
$("#compose-media").onclick = () => $("#file-compose-cam").click();
async function composeAttach(file) { const out = await openPhotoEditor(file); if (out) { composePhoto = out; showComposePhoto(); } }
$("#compose-edit").onclick = async () => { if (!composePhoto) return; const out = await openPhotoEditor(composePhoto); if (out) { composePhoto = out; showComposePhoto(); } };
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
    const postPhoto = await sharablePhoto(composePhoto);
    await c.createPost({ kind: w.kind, caption: $("#compose-caption").value.trim(), photo: postPhoto, name: w.name, kcal: w.kcal, macros: w.kind === "workout" ? null : { p: w.p, c: w.c, f: w.f }, payload: w.kind === "meal" ? w.meal : w.kind === "workout" ? { minutes: w.minutes, lifts: w.lifts } : w.basis, extra: w.kind === "meal" ? { portions: w.portions } : w.kind === "workout" ? { minutes: w.minutes } : { grams: w.grams, unit: w.unit } });
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
    const meal = p.kind === "meal", wo = p.kind === "workout", ex = p.extra || {}, n = ex.portions || 1, lifts = wo ? ((p.payload || {}).lifts || []) : [];
    const amt = wo ? `${ex.minutes || (p.payload || {}).minutes || "?"} min · ${lifts.length} exercise${lifts.length === 1 ? "" : "s"}` : meal ? `${n} portion${n === 1 ? "" : "s"} · ${fmt(p.kcal)} kcal each` : (ex.grams != null ? `${ex.grams} ${ex.unit || "g"}` : "1 serving");
    const mine = p.owner === me, who = mine ? "You" : feedName(p.owner);
    const rx = feed.reactions.filter((r) => r.post_id === p.id);
    const cm = feed.comments.filter((x) => x.post_id === p.id);
    const showAll = openComments.has(p.id) || cm.length <= 2, shown = showAll ? cm : cm.slice(-2);
    const mac = p.macros && p.macros.p != null ? `<div class="pills"><span>P ${p.macros.p} g</span><span>C ${p.macros.c} g</span><span>F ${p.macros.f} g</span></div>` : "";
    card.innerHTML = `<div class="who">${avatar(p.owner, feedName(p.owner))}<div><div class="name">${esc(who)}</div><div class="when">${ago(p.created_at)}${meal ? " · shared a meal" : ""}</div></div>${mine ? `<button class="more" aria-label="Delete post"><svg><use href="#i-more"/></svg></button>` : ""}</div>
      ${p.photo ? `<div class="media"><img src="${esc(p.photo)}" alt=""></div>` : `<div class="media none ${meal ? "meal" : wo ? "wo" : ""}"><svg><use href="#i-${meal ? "meal" : wo ? "dumbbell" : "bowl"}"/></svg>${esc(p.name)}</div>`}
      <div class="body">
        ${p.caption ? `<div class="caption"><b>${esc(who)}</b>${esc(p.caption)}</div>` : ""}
        ${wo && lifts.length ? `<div class="post-lifts">${lifts.map((l) => `<div>${esc(liftText(l))}</div>`).join("")}</div>` : ""}
        <div class="dish"><span class="thumb-sm ${meal ? "tone-peach" : ""}"><svg><use href="#i-${meal ? "meal" : "bowl"}"/></svg></span><div class="dish-main"><span class="dish-name">${esc(p.name)}</span><span class="dish-amt">${amt}</span></div><div class="dish-kcal">${fmt(p.kcal)}<small>${wo ? "burned" : "kcal"}</small></div><button class="recipe-btn" data-act="recipe" aria-label="${wo ? "Use this workout" : "See the recipe"}"><svg><use href="#${wo ? "i-lift" : "i-book"}"/></svg><span>${wo ? "Use it" : "Recipe"}</span></button></div>
        ${mac}
        <div class="actions"><div class="reacts">${REACTS.map((e) => { const k = rx.filter((r) => r.emoji === e).length, on = rx.some((r) => r.emoji === e && r.user_id === me); return `<button data-emoji="${e}" class="${on ? "on" : ""}" aria-label="React ${e}">${e}${k ? `<small>${k}</small>` : ""}</button>`; }).join("")}</div></div>
        <div class="comments">${!showAll ? `<button class="view-all">View all ${cm.length} comments</button>` : ""}${shown.map((x) => `<div class="comment">${avatar(x.user_id, feedName(x.user_id))}<span><b>${esc(x.user_id === me ? "You" : feedName(x.user_id))}</b>${esc(x.text)}</span>${x.user_id === me ? `<button class="del" data-comment="${x.id}" aria-label="Delete">✕</button>` : ""}</div>`).join("")}
          <div class="chat">${avatar(me, feedName(me))}<input type="text" placeholder="Add a comment…" maxlength="300" autocapitalize="sentences"><button class="btn primary slim" data-act="comment">Post</button></div></div>
      </div>`;
    const delBtn = card.querySelector(".who .more");
    if (delBtn) delBtn.onclick = async () => { if (!await ask("Delete this post?")) return; try { await c.deletePost(p.id); renderFeed(); } catch (e) { toast(c.explain(e)); } };
    const va = card.querySelector(".view-all"); if (va) va.onclick = () => { openComments.add(p.id); drawFeed(); };
    card.querySelector("[data-act=recipe]").onclick = () => {
      if (wo) { if (state.session) { toast("Finish your current session first"); return; } startSession({ name: p.name, id: null, exercises: lifts.map((l) => ({ exercise: l.exercise, sets: l.sets, reps: l.reps, kg: l.kg })) }); stack = ["home", "workouts"]; show("workouts"); return; }
      openRecipe(p); go("recipe");
    };
    card.querySelectorAll("[data-emoji]").forEach((b) => b.onclick = async () => {
      const e = b.dataset.emoji, on = b.classList.contains("on");
      try { if (on) await c.unreact(p.id, e); else { await c.react(p.id, e); notifyFriend(p.owner, "react", p.name, { emoji: e }); state.reactCount = (state.reactCount || 0) + 1; save(); checkBadges(); } } catch (err) { toast(c.explain(err)); return; }
      if (on) feed.reactions = feed.reactions.filter((r) => !(r.post_id === p.id && r.user_id === me && r.emoji === e)); else feed.reactions.push({ post_id: p.id, user_id: me, emoji: e });
      drawFeed();
    });
    const input = card.querySelector(".chat input"), send = card.querySelector("[data-act=comment]");
    const doComment = async () => { const t = input.value.trim(); if (!t) return; try { const rows = await c.comment(p.id, t); notifyFriend(p.owner, "comment", t); state.commentCount = (state.commentCount || 0) + 1; save(); checkBadges(); feed.comments.push((rows && rows[0]) || { id: uid(), post_id: p.id, user_id: me, text: t, created_at: new Date().toISOString() }); openComments.add(p.id); drawFeed(); } catch (err) { toast(c.explain(err)); } };
    send.onclick = doComment; input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.target.blur(); doComment(); } });
    card.querySelectorAll("[data-comment]").forEach((b) => b.onclick = async () => { if (!await ask("Delete your comment?")) return; try { await c.deleteComment(b.dataset.comment); feed.comments = feed.comments.filter((x) => String(x.id) !== String(b.dataset.comment)); drawFeed(); } catch (err) { toast(c.explain(err)); } });
    list.appendChild(card);
  }
}

/** A friend's post as a recipe: what's in it, how to make it, and save it or have some today. */
function openRecipe(p) {
  const box = $("#recipe-body"), meal = p.kind === "meal", m = p.payload || {}, who = p.owner === window.cloud.uid ? "you" : feedName(p.owner);
  const head = `${p.photo ? `<img class="recipe-photo" src="${esc(p.photo)}" alt="">` : ""}<h2>${esc(p.name)}</h2><p class="muted tiny by">Shared by ${esc(who)}</p>`;
  const mac = p.macros || {};
  if (meal && (m.items || []).length) {
    const n = +m.portions || 1, items = m.items;
    box.innerHTML = `<div class="card recipe-view">${head}${statRow(p.kcal, mac.p || 0, mac.c || 0, mac.f || 0)}<p class="muted tiny">per portion · makes ${n}</p>
      <div class="field-title">Ingredients</div>
      <ul class="list">${items.map((it) => `<li><div class="body"><div class="name">${esc(it.name)}</div><div class="detail">${it.grams != null ? `${fmt(it.grams)} ${it.unit || "g"} · ` : ""}${fmt(it.kcal)} kcal</div></div></li>`).join("")}</ul>
      ${(m.steps || []).length ? `<div class="field-title">Method</div><ol class="method">${m.steps.map((st) => `<li>${esc(st)}</li>`).join("")}</ol>` : `<p class="muted tiny">No method was shared, just the ingredients.</p>`}
      <button class="btn primary" id="rc-save">Save to my meals</button><button class="btn mint" id="rc-have">Have a portion today</button></div>`;
    const copy = () => ({ id: uid(), name: m.name || p.name, portions: n, items: items.map((it) => ({ ...it, id: uid() })), steps: m.steps || [], saved: true, copiedFrom: "post:" + p.id, updatedAt: new Date().toISOString() });
    $("#rc-save").onclick = (e) => { state.meals.unshift(copy()); save(); e.target.textContent = "Saved to your meals"; e.target.disabled = true; toast(`${p.name} is in your meals`); };
    $("#rc-have").onclick = () => { draft = { ...mealBasis(copy()), mealId: null, note: "" }; openShare(); };
  } else {
    box.innerHTML = `<div class="card recipe-view">${head}${statRow(p.kcal, mac.p || 0, mac.c || 0, mac.f || 0)}
      <p class="muted">${esc(who === "you" ? "You" : who)} shared this as a food, so there's no recipe with it. The assistant can make you one with about the same calories.</p>
      <button class="btn primary" id="rc-ai">Make me a recipe like this</button><button class="btn mint" id="rc-have">Add it to today</button></div>`;
    $("#rc-ai").onclick = () => {
      if (!aiAvailable()) { aiHelp(); return; }
      go("ask"); newChat();
      $("#ask-text").value = `Give me a recipe for ${p.name}, about ${fmt(p.kcal)} kcal a portion${mac.p ? ` with around ${mac.p} g protein` : ""}.`;
      sendAsk();
    };
    $("#rc-have").onclick = () => { draft = { ...(p.payload || { name: p.name, kcalPerServing: p.kcal, unitLabel: "portion" }), note: "" }; openShare(p.kcal); };
  }
}

// ---------------------------------------------------------------- workouts: activities with a burn estimate, and a lifting log

// Typical intensity (MET) per activity; kcal = MET x weight (kg) x hours. Rough by nature, and labelled so.
const ACTIVITIES = [
  ["Walk", 3.5], ["Run", 9.8], ["Cycle", 7.5], ["Swim", 7], ["Gym weights", 5, true], ["HIIT", 8], ["Yoga / stretch", 2.8],
  ["Football", 8], ["Tennis / padel", 7.3], ["Hike", 6], ["Rowing", 7], ["Elliptical", 5], ["Dance", 5.5], ["Boxing", 9], ["Climbing", 7], ["Other", 5]
];
const EFFORT = { easy: 0.8, moderate: 1, hard: 1.25 };
let wType = "Walk";
/** "Bench press 60×8, 60×8, 65×6" when the sets were ticked one by one; "3×8 @ 60 kg" for a plain log. */
function liftText(l) {
  if (Array.isArray(l.detail) && l.detail.length) return `${l.exercise} ${l.detail.map((s) => `${s.kg ? `${s.kg}×` : ""}${s.reps}`).join(", ")}${l.detail.some((s) => s.kg) ? " kg" : ""}`;
  return `${l.exercise} ${l.sets}×${l.reps}${l.kg ? ` @ ${l.kg} kg` : ""}`;
}
/** Change how long a workout took (forgot to stop the timer?): the burn is worked out again. */
async function editWorkoutMinutes(w, done) {
  const v = await askText(`How many minutes was "${w.name}"?`, String(w.minutes || ""));
  const m = num(v); if (!m || m < 1 || m > 600) return;
  w.minutes = Math.round(m); if (w.type) w.kcal = burnFor(w.type, w.minutes, w.effort || "moderate");
  toast(`${w.name}: ${w.minutes} min`); done();
}
function postWorkout(w) {
  openCompose({ kind: "workout", name: w.name, kcal: Math.round(w.kcal || 0), minutes: w.minutes, lifts: (w.lifts || []).map((l) => ({ exercise: l.exercise, sets: l.sets, reps: l.reps, kg: l.kg, detail: l.detail || null })) }, null);
}
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
  const scan = (date, ws) => { for (const w of ws || []) for (const l of w.lifts || []) if ((l.exercise || "").toLowerCase() === key) { const kg = l.kg || 0, reps = l.reps || 1; out.push({ date, workout: w.name, sets: l.sets || 1, reps, kg, detail: Array.isArray(l.detail) ? l.detail : null, est1rm: kg ? Math.round(kg * (1 + reps / 30)) : 0 }); } };
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
  const list = $("#w-list"); list.innerHTML = "";
  for (const w of ws) {
    const li = document.createElement("li");
    const lifts = (w.lifts || []).map(liftText).join(" · ");
    li.innerHTML = `<span class="thumb-sm tone-coral"><svg><use href="#i-${(ACTIVITIES.find((x) => x[0] === w.type) || [])[2] ? "dumbbell" : "walk"}"/></svg></span><div class="body"><div class="name">${esc(w.name)}</div><div class="detail">${w.minutes} min · ${w.effort}${lifts ? `<div class="w-lifts">${esc(lifts)}</div>` : ""}</div></div><div class="kcal">${fmt(w.kcal)}</div><button class="del" aria-label="Remove">✕</button>`;
    li.querySelector(".del").onclick = async () => { if (!await ask(`Remove "${w.name}"?`)) return; tomb("wo", w.id); state.day.workouts = ws.filter((x) => x.id !== w.id); save(); renderWorkouts(); };
    if ((w.lifts || []).length && window.cloud && window.cloud.user) {
      li.querySelector(".del").insertAdjacentHTML("beforebegin", `<button class="w-post" aria-label="Post to the feed"><svg><use href="#i-share"/></svg></button>`);
      li.querySelector(".w-post").onclick = (e) => { e.stopPropagation(); postWorkout(w); };
    }
    li.querySelector(".body").onclick = () => editWorkoutMinutes(w, () => { save(); renderWorkouts(); });
    li.style.cursor = "pointer";
    list.appendChild(li);
  }
  $("#w-empty").classList.toggle("hidden", ws.length > 0);
  // routines
  const rl = $("#w-routines"); rl.innerHTML = "";
  for (const r of state.routines) {
    const b = document.createElement("button"); b.textContent = `▶ ${r.name}`; b.title = "Tap to start, hold to remove";
    let t; b.onpointerdown = () => { t = setTimeout(async () => { t = null; if (await ask(`Remove the routine "${r.name}"?`)) { tomb("routine", r.id); state.routines = state.routines.filter((x) => x.id !== r.id); save(); renderWorkouts(); } }, 600); };
    const clear = () => { if (t) { clearTimeout(t); t = null; } };
    b.onpointerup = () => { if (t) { clear(); startSession(r); } }; b.onpointerleave = clear; b.onpointercancel = clear; b.oncontextmenu = (e) => e.preventDefault();
    rl.appendChild(b);
  }
  $(".w-routines-wrap").classList.toggle("hidden", !state.routines.length);
  // a running session takes the gym card's place
  const live = !!state.session;
  $("#w-session").classList.toggle("hidden", !live);
  $("#w-gym").classList.toggle("hidden", live);
  if (live) renderSession();
  const types = $("#w-types"); types.innerHTML = "";
  for (const [name, , lifting] of ACTIVITIES) { if (lifting) continue; const b = document.createElement("button"); b.textContent = name; b.dataset.type = name; b.classList.toggle("on", name === wType); types.appendChild(b); }
  updateEstimate();
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
    li.querySelector(".body").onclick = () => {
      if ((ACTIVITIES.find((x) => x[0] === r.type) || [])[2]) { startSession({ name: r.name, id: null, exercises: (r.lifts || []).map((l) => ({ ...l })) }); return; }
      wType = r.type; $("#w-min").value = r.minutes; $("#w-effort").value = r.effort; $("#w-name").value = r.name; $("#w-form").classList.remove("hidden"); renderWorkouts(); window.scrollTo({ top: $("#w-types").getBoundingClientRect().top + window.scrollY - 80, behavior: "smooth" });
    };
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
function ensureExerciseList() {
  if (!$("#w-ex-list")) { const dl = document.createElement("datalist"); dl.id = "w-ex-list"; document.body.appendChild(dl); }
  $("#w-ex-list").innerHTML = Object.values(state.exercises).map((e) => `<option value="${esc(e.name)}">`).join("");
}
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
  logWorkout({ type: wType, name: $("#w-name").value.trim() || wType, minutes, effort: $("#w-effort").value, lifts: [] });
  $("#w-min").value = ""; $("#w-name").value = ""; $("#w-form").classList.add("hidden");
  toast("Workout logged");
};

// ---- a live gym session: exercises pre-filled from last time, tick sets off, rest timer between them
const REST_SECONDS = 90;
const restLength = () => Math.max(15, Math.min(600, state.restSeconds || REST_SECONDS));
const mmss = (sec) => `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, "0")}`;
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
  const ss = state.session; if (!ss || document.body.dataset.view !== "workouts") { clearInterval(sessionTimer); sessionTimer = null; $("#ws-float").classList.add("hidden"); return; }
  const el = Math.floor((Date.now() - ss.startedAt) / 1000);
  $("#ws-clock").textContent = `${Math.floor(el / 60)}:${String(el % 60).padStart(2, "0")}`;
  const rest = $("#ws-rest"), left = ss.restUntil ? Math.ceil((ss.restUntil - Date.now()) / 1000) : 0;
  $("#ws-rest-len").textContent = mmss(restLength());
  $("#wsf-clock").textContent = $("#ws-clock").textContent;
  $("#wsf-rest").classList.toggle("hidden", !(left > 0)); $("#wsf-tip").classList.toggle("hidden", left > 0);
  if (left > 0) $("#wsf-rest-time").textContent = mmss(left);
  if (left > 0) { rest.classList.remove("hidden"); $("#ws-rest-set").classList.add("hidden"); $("#ws-rest-time").textContent = mmss(left); }
  else { $("#ws-rest-set").classList.remove("hidden"); if (!rest.classList.contains("hidden")) { rest.classList.add("hidden"); if (ss.restUntil) { ss.restUntil = null; save(false); if (navigator.vibrate) navigator.vibrate([120, 60, 120]); toast("Rest's over: next set"); } } }
}
let wsFloatWatch = null;
function watchSessionTop() {   // the floating timer shows once the session's own clock scrolls out of view
  if (wsFloatWatch) wsFloatWatch.disconnect();
  const top = document.querySelector("#w-session .session-top"), fl = $("#ws-float");
  if (!top || !("IntersectionObserver" in window)) return;
  wsFloatWatch = new IntersectionObserver(([e]) => fl.classList.toggle("hidden", e.isIntersecting || !state.session || document.body.dataset.view !== "workouts"), { rootMargin: "-60px 0px 0px 0px" });
  wsFloatWatch.observe(top);
}
$("#wsf-skip").onclick = () => $("#ws-rest-skip").click();
$("#ws-float").onclick = (e) => { if (e.target.closest("button")) return; document.querySelector("#w-session .session-top").scrollIntoView({ block: "start", behavior: "smooth" }); };
function renderSession() {
  const ss = state.session; if (!ss) return;
  watchSessionTop();
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
      row.querySelector(".tick").onclick = () => { st.done = !st.done; if (st.done) { st.reps = num(reps.value) || st.reps || 1; st.kg = nz(kg.value) || 0; ss.restUntil = Date.now() + restLength() * 1000; } save(false); renderSession(); tickSession(); };
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
$("#ws-rest-skip").onclick = () => { if (state.session) { state.session.restUntil = null; save(false); $("#ws-rest").classList.add("hidden"); $("#ws-rest-set").classList.remove("hidden"); } };
// the usual rest, in 15-second steps, remembered for next time
const setRest = (d) => { state.restSeconds = Math.max(15, Math.min(600, restLength() + d)); save(); tickSession(); };
$("#ws-rest-less").onclick = () => setRest(-15);
$("#ws-rest-more").onclick = () => setRest(15);
// just this rest: a little longer or shorter
const nudgeRest = (d) => { const ss = state.session; if (!ss || !ss.restUntil) return; ss.restUntil = Math.max(Date.now() + 1000, ss.restUntil + d * 1000); save(false); tickSession(); };
$("#ws-rest-minus").onclick = () => nudgeRest(-15);
$("#ws-rest-plus").onclick = () => nudgeRest(15);
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
  let minutes = Math.max(1, Math.round((Date.now() - ss.startedAt) / 60000));
  if (minutes > 150) { const v = num(await askText(`The timer says ${minutes} min. Forgot to stop it? Put the real length in minutes.`, String(minutes))); if (v && v > 0) minutes = Math.round(v); }
  if (!lifts.length && !await ask(`Finish an empty ${minutes} min session?`)) return;
  const name = (ss.name || "").trim() || (ss.routineId && (state.routines.find((r) => r.id === ss.routineId) || {}).name) || "Gym session";
  const routineId = ss.routineId;
  state.session = null;
  logWorkout({ type: "Gym weights", name, minutes, effort: "moderate", lifts });
  toast(`Logged ${name}: ${minutes} min`);
  setTimeout(async () => {
    if (lifts.length && !routineId && await ask("Save this session as a routine, to start again next time?")) await saveRoutine(name, lifts.map((l) => ({ exercise: l.exercise, sets: l.sets, reps: l.reps, kg: l.kg })));
    const w = (state.day.workouts || [])[state.day.workouts.length - 1];
    if (lifts.length && w && window.cloud && window.cloud.user && await ask("Post this session to the feed for your friends?")) postWorkout(w);
  }, 500);
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
    ch.innerHTML = `<svg viewBox="0 0 ${W} ${H}"><polyline points="${pts.map((p, i) => `${x(i)},${y(p.est1rm)}`).join(" ")}" fill="none" style="stroke:var(--green)" stroke-width="2.5" stroke-linejoin="round"/>${pts.map((p, i) => `<circle cx="${x(i)}" cy="${y(p.est1rm)}" r="4" style="fill:var(--green)"/><text x="${x(i)}" y="${y(p.est1rm) - 9}" text-anchor="middle" font-size="11" style="fill:var(--green)" font-weight="700">${p.est1rm}</text><text x="${x(i)}" y="${H - 5}" text-anchor="middle" font-size="10" style="fill:var(--muted)">${new Date(p.date + "T12:00").toLocaleDateString(undefined, { day: "numeric", month: "short" })}</text>`).join("")}</svg>`;
  }
  const list = $("#ex-sessions"); list.innerHTML = "";
  for (const s of ses.slice(0, 20)) {
    const li = document.createElement("li");
    li.innerHTML = `<span class="thumb-sm tone-coral"><svg><use href="#i-lift"/></svg></span><div class="body"><div class="name">${s.date === localDate() ? "Today" : new Date(s.date + "T12:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" })}</div><div class="detail">${s.detail ? esc(s.detail.map((x) => `${x.kg ? `${x.kg}×` : ""}${x.reps}`).join(", ")) + (s.detail.some((x) => x.kg) ? " kg" : "") : `${s.sets}×${s.reps}${s.kg ? ` @ ${s.kg} kg` : ""}`} · ${esc(s.workout)}</div></div>${s.est1rm ? `<div class="kcal">${s.est1rm}<small> 1RM</small></div>` : ""}`;
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
  const blank = !d.kcalPer100 && !d.kcalPerServing;   // typing something in: the boxes are the point
  $("#details-title").textContent = blank ? (title || "Enter the details") : "Check the numbers";
  $("#f-name").value = d.name || ""; $("#f-brand").value = d.brand || "";
  $("#f-unit").value = d.unit || "g";
  $("#f-kcal100").value = d.kcalPer100 ?? ""; $("#f-serving").value = d.servingSize ?? "";
  $("#f-kcalserving").value = d.kcalPerServing ?? ""; $("#f-pack").value = d.packSize ?? ""; $("#f-pieces").value = d.piecesPerPack ?? "";
  $("#f-piece").value = d.unitLabel || "";
  $("#f-p100").value = d.p100 ?? ""; $("#f-c100").value = d.c100 ?? ""; $("#f-f100").value = d.f100 ?? "";
  $("#d-thumb").innerHTML = d.image ? `<img src="${esc(d.image)}" alt="">` : `<svg><use href="#i-image"/></svg>`;
  const src = { barcode: "Open Food Facts", label: "Read from label", claude: "AI estimate", search: "Food list" }[d.source] || "";
  $("#d-badge").textContent = src; $("#d-badge").classList.toggle("hidden", !src);
  $("#d-edit").open = blank; $("#d-edit-label").textContent = blank ? "The numbers" : "Edit the numbers";
  const note = $("#d-note"); note.textContent = d.note || ""; note.classList.toggle("hidden", !d.note);
  $("#details-lighter-out").innerHTML = "";
  syncUnitEcho(); renderDetailSummary();
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
/** The label-style summary, from whatever is in the boxes right now. */
function renderDetailSummary() {
  const v = (id) => num($(id).value), unit = $("#f-unit").value || "g";
  const k100 = v("#f-kcal100"), sv = v("#f-serving"), each = v("#f-kcalserving"), pack = v("#f-pack"), pcs = v("#f-pieces");
  const label = ($("#f-piece").value.trim().replace(/s$/, "") || "serving"), p = v("#f-p100"), c = v("#f-c100"), f = v("#f-f100");
  const box = $("#d-summary");
  if (!k100 && !each) { box.innerHTML = `<div class="empty-sum">No calories yet. Add them below, from the pack.</div>`; return; }
  const oneKcal = each || (k100 && sv ? k100 * sv / 100 : null);
  const lines = [];
  if (oneKcal && k100) lines.push(`1 ${esc(label)}${sv ? ` (${fmt(sv)} ${unit})` : ""} = <b>${fmt(oneKcal)} kcal</b>`);   // per-piece only: the big number already says it
  if (pack) lines.push(`pack ${fmt(pack)} ${unit}${pcs ? `, ${fmt(pcs)} ${esc(label)}${pcs === 1 ? "" : "s"}` : ""}`);
  const bar = (x, color) => `<span class="mb"><span style="width:${Math.min(100, (x || 0))}%;background:${color}"></span></span>`;
  box.innerHTML = `<div class="big">${k100 ? `${fmt(k100)}<small>kcal per 100 ${unit}</small>` : `${fmt(each)}<small>kcal per ${esc(label)}</small>`}</div>
    ${lines.length ? `<div class="line">${lines.join(" · ")}</div>` : ""}
    ${p != null || c != null || f != null ? `<div class="d-macros"><div>Protein<b>${fmt(p || 0, 1)} g</b>${bar(p, "#7f77dd")}</div><div>Carbs<b>${fmt(c || 0, 1)} g</b>${bar(c, "#e8a33d")}</div><div>Fat<b>${fmt(f || 0, 1)} g</b>${bar(f, "var(--coral)")}</div></div>` : ""}`;
}
$$("#d-edit input, #d-edit select").forEach((el) => el.addEventListener("input", renderDetailSummary));
function syncUnitEcho() { $$(".unit-echo").forEach((el) => el.textContent = $("#f-unit").value); }
$("#f-unit").onchange = () => { syncUnitEcho(); renderDetailSummary(); };
$("#details-next").onclick = () => {
  const d = readDetails();
  if (!d.kcalPer100 && !d.kcalPerServing) { $("#d-edit").open = true; toast("Add the calories first: per 100 g, or for one piece"); setTimeout(() => $("#f-kcal100").focus(), 50); return; }
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
// ---- photo editor: a square crop like the feed, drag to move, pinch / slide / scroll to zoom, rotate; returns a 1200 px JPEG
let peState = null;
function openPhotoEditor(src) {
  return new Promise(async (resolve) => {
    let img;
    try { img = await loadImage(src instanceof Blob ? src : await (await fetch(src)).blob()); } catch (e) { toast("Couldn't read that photo"); resolve(null); return; }
    const box = $("#photo-editor"), canvas = $("#pe-canvas"), stage = $("#pe-stage"), zoomIn = $("#pe-zoom");
    const st = peState = { img, rot: 0, zoom: 1, ox: 0, oy: 0, pointers: new Map(), pinch: null };
    box.classList.remove("hidden");
    const S = () => canvas.width;
    const dims = () => { const r = st.rot % 180 !== 0; return [r ? img.naturalHeight : img.naturalWidth, r ? img.naturalWidth : img.naturalHeight]; };
    const base = (size) => { const [w, h] = dims(); return size / Math.min(w, h); };   // the scale that just covers the square
    const clamp = () => {
      const [w, h] = dims(), k = base(S()) * st.zoom;
      const mx = Math.max(0, (w * k - S()) / 2), my = Math.max(0, (h * k - S()) / 2);
      st.ox = Math.max(-mx, Math.min(mx, st.ox)); st.oy = Math.max(-my, Math.min(my, st.oy));
    };
    const draw = (ctx, size, ox, oy) => {
      const k = base(size) * st.zoom;
      ctx.fillStyle = "#1a1f1c"; ctx.fillRect(0, 0, size, size);
      ctx.save(); ctx.translate(size / 2 + ox, size / 2 + oy); ctx.rotate(st.rot * Math.PI / 180); ctx.scale(k, k);
      ctx.imageSmoothingQuality = "high"; ctx.drawImage(img, -img.naturalWidth / 2, -img.naturalHeight / 2); ctx.restore();
    };
    const render = () => { clamp(); draw(canvas.getContext("2d"), S(), st.ox, st.oy); zoomIn.value = st.zoom; };
    const fit = () => { const px = Math.round(stage.clientWidth * (window.devicePixelRatio || 1)); if (!px) return; if (canvas.width !== px) { const f = px / (canvas.width || px); st.ox *= f; st.oy *= f; canvas.width = canvas.height = px; } render(); };
    render(); requestAnimationFrame(fit); setTimeout(fit, 80);   // once the editor is on screen, draw at the phone's full sharpness
    const setZoom = (z, cx = 0, cy = 0) => {   // zoom around a point, so what's under your fingers stays put
      const nz = Math.max(1, Math.min(5, z)), f = nz / st.zoom;
      st.ox = cx + (st.ox - cx) * f; st.oy = cy + (st.oy - cy) * f; st.zoom = nz; render();
    };
    const local = (e) => { const r = stage.getBoundingClientRect(), d = S() / r.width; return [(e.clientX - r.left) * d - S() / 2, (e.clientY - r.top) * d - S() / 2]; };
    stage.onpointerdown = (e) => { stage.setPointerCapture(e.pointerId); st.pointers.set(e.pointerId, local(e)); if (st.pointers.size === 2) { const [a, b] = [...st.pointers.values()]; st.pinch = { d: Math.hypot(a[0] - b[0], a[1] - b[1]), z: st.zoom }; } };
    stage.onpointermove = (e) => {
      if (!st.pointers.has(e.pointerId)) return;
      const prev = st.pointers.get(e.pointerId), now = local(e); st.pointers.set(e.pointerId, now);
      if (st.pointers.size === 1) { st.ox += now[0] - prev[0]; st.oy += now[1] - prev[1]; render(); }
      else if (st.pointers.size === 2 && st.pinch) { const [a, b] = [...st.pointers.values()]; const d = Math.hypot(a[0] - b[0], a[1] - b[1]); setZoom(st.pinch.z * d / st.pinch.d, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2); }
    };
    const up = (e) => { st.pointers.delete(e.pointerId); if (st.pointers.size < 2) st.pinch = null; };
    stage.onpointerup = up; stage.onpointercancel = up;
    stage.onwheel = (e) => { e.preventDefault(); const [x, y] = local(e); setZoom(st.zoom * (e.deltaY < 0 ? 1.08 : 1 / 1.08), x, y); };
    zoomIn.oninput = () => setZoom(+zoomIn.value);
    $("#pe-rotate").onclick = () => { st.rot = (st.rot + 90) % 360; st.ox = 0; st.oy = 0; render(); };
    $("#pe-reset").onclick = () => { st.rot = 0; st.zoom = 1; st.ox = 0; st.oy = 0; render(); };
    window.addEventListener("resize", fit);
    const finish = (out) => { window.removeEventListener("resize", fit); box.classList.add("hidden"); stage.onpointerdown = stage.onpointermove = stage.onpointerup = stage.onpointercancel = stage.onwheel = null; peState = null; resolve(out); };
    $("#pe-cancel").onclick = () => finish(null);
    $("#pe-done").onclick = () => {
      const size = 1200, o = document.createElement("canvas"); o.width = o.height = size;
      const f = size / S(); draw(o.getContext("2d"), size, st.ox * f, st.oy * f);
      finish(o.toDataURL("image/jpeg", 0.86));
    };
  });
}
async function thumbFrom(src) {
  const img = await loadImage(src instanceof Blob ? src : await (await fetch(src)).blob());
  const size = 512, c = document.createElement("canvas"); c.width = size; c.height = size;   // sharp on a phone screen, still small to keep
  const iw = img.naturalWidth, ih = img.naturalHeight, m = Math.min(iw, ih);
  c.getContext("2d").drawImage(img, (iw - m) / 2, (ih - m) / 2, m, m, 0, 0, size, size);
  return c.toDataURL("image/jpeg", 0.8);
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
  $("#search-past").textContent = pastAdd ? `Adding to ${pastLabel(pastAdd)}` : ""; $("#search-past").classList.toggle("hidden", !pastAdd);
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
    const parsed = await askAI(FOOD_SCHEMA, [{ type: "text", text: `Give typical nutrition for this food as commonly eaten: "${query}". If it's ambiguous, pick the most common preparation and say so in notes. Use standard reference values (USDA / McCance & Widdowson), not guesses.` }], "low");
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
// Free allowances are per model: about 20 a day for each Flash, about 500 for each Flash-Lite.
const GEMINI_FLASH = ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash"];
const GEMINI_LITE = ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-flash-lite-latest"];
const GEMINI_MODELS = GEMINI_FLASH.concat(GEMINI_LITE);
let aiProxyState = "unknown";   // "unknown" | "yes" | "no": whether the Supabase "ai" function is deployed
const aiAvailable = () => !!(state.geminiKey || state.apiKey || (window.cloud && window.cloud.user && aiProxyState !== "no"));
function aiHelp() { toast("AI features need a key: a free Google Gemini key or an Anthropic key, in Settings. Or ask whoever set the app up to switch on the shared one.", 6000); go("settings"); }
// ---- while the AI works: seconds ticking, honest words when it's slow, and a Cancel that always works
let aiCtl = null, aiTick = null, aiStart = 0, aiNote = "";
function aiProgress(note) { if (note != null) aiNote = note; const secs = Math.floor((Date.now() - aiStart) / 1000);
  const words = aiNote || (secs < 8 ? "" : secs < 25 ? "Still thinking…" : secs < 45 ? "Long answers take a little while…" : "The free AI is slow right now…");
  const sub = `${secs}s${words ? ` · ${words}` : ""}`;
  if (!$("#busy").classList.contains("hidden")) { $("#busy-sub").textContent = sub; $("#busy-cancel").classList.toggle("hidden", secs < 6); }
  $$(".ai-live .secs").forEach((el) => el.textContent = sub);
}
function cancelAI() { if (aiCtl) { aiCtl.cancelled = true; aiCtl.abort(); } }
$("#busy-cancel").onclick = () => { cancelAI(); busy(false); };
document.addEventListener("click", (e) => { if (e.target.closest(".ai-live .cancel")) { e.preventDefault(); cancelAI(); } });
async function askAI(schema, content, effort = "medium") {
  aiStart = Date.now(); aiNote = ""; clearInterval(aiTick); aiTick = setInterval(() => aiProgress(), 1000); aiProgress();
  try { return await askAIInner(schema, content, effort); }
  finally { clearInterval(aiTick); aiTick = null; aiCtl = null; }
}
async function askAIInner(schema, content, effort) {
  // 1) shared key via the Supabase function
  if (window.cloud && window.cloud.user && aiProxyState !== "no") {
    try { return await askGemini(schema, content, null, effort); }
    catch (err) { if (err.proxyMissing) aiProxyState = "no"; else throw err; }
  }
  // 2) a Gemini key on this phone
  if (state.geminiKey) return askGemini(schema, content, state.geminiKey, effort);
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
// ---- which models have used up today's free allowance. Google resets it at midnight Pacific time.
const AI_SPENT_KEY = "cheatday.aiSpent";
try { localStorage.removeItem("cheatday.aiModel"); } catch (e) {}   // the old "last model that answered" memory kept phones on Lite
function pacificDay() { return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles" }).format(new Date()); }
function aiSpent() {
  let r = null; try { r = JSON.parse(localStorage.getItem(AI_SPENT_KEY) || "null"); } catch (e) {}
  if (!r || r.day !== pacificDay()) r = { day: pacificDay(), spent: [], cool: {} };
  r.cool = r.cool || {}; return r;
}
function saveSpent(r) { try { localStorage.setItem(AI_SPENT_KEY, JSON.stringify(r)); } catch (e) {} }
function markSpent(model, forDay) {
  const r = aiSpent();
  if (forDay) { if (!r.spent.includes(model)) r.spent.push(model); }
  else r.cool[model] = Date.now() + 65000;   // a per-minute limit: rest it for a minute
  saveSpent(r);
}
function modelReady(model) { const r = aiSpent(); return !r.spent.includes(model) && !((r.cool[model] || 0) > Date.now()); }
/** When the free allowance comes back, in the phone's own time (8am in the UK most of the year). */
function aiResetTime() {
  const la = new Date(new Date().toLocaleString("en-US", { timeZone: "America/Los_Angeles" }));
  const msLeft = ((24 - la.getHours()) * 60 - la.getMinutes()) * 60000;
  return new Date(Date.now() + msLeft).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}
async function askGemini(schema, content, key, effort = "medium") {
  const parts = content.map((b) => b.type === "image" ? { inline_data: { mime_type: b.source.media_type, data: b.source.data } } : { text: b.text });
  const hasImage = content.some((b) => b.type === "image");
  let thinking = effort === "low" ? "minimal" : "low";   // reading a label or a screenshot needs no deliberation
  const bodyFor = (model) => {
    const generationConfig = { responseMimeType: "application/json", responseSchema: geminiSchema(schema), temperature: 0.2 };
    if (/^gemini-3/.test(model) && thinking) generationConfig.thinkingConfig = { thinkingLevel: thinking };
    return JSON.stringify({ contents: [{ parts }], generationConfig });
  };
  const send = async (model, signal) => {
    if (key) return fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, { method: "POST", headers: { "Content-Type": "application/json", "X-goog-api-key": key }, body: bodyFor(model), signal });
    const cfg = window.SUPABASE_CONFIG;
    return window.cloud.rawFetch(`${cfg.url}/functions/v1/ai?model=${model}`, { method: "POST", headers: { "Content-Type": "application/json", apikey: cfg.anonKey }, body: bodyFor(model), signal });
  };
  // Flash is kept for the jobs that need brains (food photos, chats, recipes); quick reading jobs go straight to Lite.
  // Models that have used up today's allowance are skipped without asking.
  const all = effort === "low" ? GEMINI_LITE.concat(GEMINI_FLASH) : GEMINI_FLASH.concat(GEMINI_LITE);
  let order = all.filter(modelReady);
  if (!order.length) { const r = aiSpent(); order = all.filter((m) => !r.spent.includes(m)); }   // only resting a minute: ask anyway
  if (!order.length) throw new Error(`Today's free AI allowance is used up. It comes back at ${aiResetTime()}.`);
  const limit = effort === "low" ? (hasImage ? 30000 : 20000) : 45000;   // a recipe or a plan is a long answer
  let resp, lastNet = null, timedOut = 0;
  for (let i = 0; i < order.length; i++) {
    const model = order[i];
    resp = null;
    for (let attempt = 0; attempt < 2 && !resp; attempt++) {
      const ctl = new AbortController(); aiCtl = ctl;
      const timer = setTimeout(() => ctl.abort(), limit);
      try { resp = await send(model, ctl.signal); }
      catch (e) {
        if (ctl.cancelled) { clearTimeout(timer); throw new Error("Cancelled"); }
        if (e.name === "AbortError") { timedOut++; break; }   // this model is too slow right now: move on rather than retry it
        lastNet = e; await new Promise((r) => setTimeout(r, 600));
      } finally { clearTimeout(timer); }
    }
    if (!resp) {
      if (timedOut && effort === "low") { aiProgress("Taking a while, trying a faster model…"); const lite = order.findIndex((m, j) => j > i && /lite/.test(m)); if (lite > i + 1) i = lite - 1; }
      else if (timedOut) aiProgress("Taking a while, trying another model…");
      if (timedOut >= 2) break;   // two slow models in a row: stop and say so
      continue;
    }
    if (!key && resp.status === 404) { const e = new Error("shared AI not set up"); e.proxyMissing = true; throw e; }
    if (resp.status === 400 && thinking) { const t = await resp.clone().text().catch(() => ""); if (/thinking/i.test(t)) { thinking = thinking === "minimal" ? "low" : null; i--; continue; } }   // older model: ask again without that setting
    if (!key && resp.ok) aiProxyState = "yes";
    if (resp.status === 429) {
      const t = await resp.clone().text().catch(() => "");
      const forDay = /PerDay|per day|daily/i.test(t);
      markSpent(model, forDay);
      if (i < order.length - 1) aiProgress(forDay ? "Today's allowance for that model is used, trying the next…" : "That model's busy, trying another…");
      continue;   // no need to wait: the next model has its own allowance
    }
    if (resp.status === 404 && key) { markSpent(model, true); continue; }   // this key can't use that model
    if (resp.status !== 503) break;
    markSpent(model, false);
    aiProgress("That model's busy, trying another…");
    await new Promise((r) => setTimeout(r, 400));
  }
  if (!resp && timedOut) throw new Error("The free AI didn't answer in time. Try again in a moment.");
  if (!resp) throw new Error(`Couldn't reach the AI service (${(lastNet && lastNet.message) || "no connection"}). Check the signal and try again.`);
  if (resp.status === 429 && aiSpent().spent.length >= GEMINI_MODELS.length) throw new Error(`Today's free AI allowance is used up. It comes back at ${aiResetTime()}.`);
  if (resp.status === 503 || resp.status === 429 || (resp.status === 404 && key)) throw new Error("Every free AI model is busy right now. Try again in a minute.");
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
  const dataUrl = drawScaled(img, 1024).toDataURL("image/jpeg", 0.8);
  const b64 = dataUrl.split(",")[1];
  const parsed = await askAI(LABEL_SCHEMA, [
    { type: "image", source: { type: "base64", media_type: "image/jpeg", data: b64 } },
    { type: "text", text: LABEL_PROMPT }
  ], "low");
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
async function attachPhoto(file) { const out = await openPhotoEditor(file); if (!out) return; try { draft.photo = await thumbFrom(out); showSharePhoto(); } catch (e) { toast("Couldn't read that photo"); } }
$("#share-photo-cam").onclick = () => $("#file-share-cam").click();
$("#share-photo-lib").onclick = () => $("#file-share-lib").click();
$("#file-share-cam").addEventListener("change", (e) => { const f = e.target.files[0]; e.target.value = ""; if (f) attachPhoto(f); });
$("#file-share-lib").addEventListener("change", (e) => { const f = e.target.files[0]; e.target.value = ""; if (f) attachPhoto(f); });
$("#share-photo-remove").onclick = () => { delete draft.photo; showSharePhoto(); };
let shareMeal = null, shareMode = "grams";
$("#share-meal").addEventListener("change", (e) => { shareMeal = e.target.value; });
function showAmountMode() {
  const c = conv(draft);
  $("#a-count-wrap").classList.toggle("hidden", shareMode !== "count");
  $("#a-grams-wrap").classList.toggle("hidden", shareMode !== "grams");
  $("#a-kcal-wrap").classList.toggle("hidden", shareMode !== "kcal");
  // a clear switch between the ways that suit this food
  const modes = [c.countKcal ? ["count", "Count"] : null, c.kcalPer100 ? ["grams", draft.unit === "ml" ? "Measure" : "Weigh"] : null, ["kcal", "Calories"]].filter(Boolean);
  $("#amt-seg").innerHTML = modes.map(([m, label]) => `<button data-mode="${m}" class="${m === shareMode ? "on" : ""}">${label}</button>`).join("");
  $("#amt-seg").classList.toggle("hidden", modes.length < 2);
}
$("#amt-seg").addEventListener("click", (e) => { const l = e.target.closest("[data-mode]"); if (!l) return; e.preventDefault(); shareMode = l.dataset.mode; showAmountMode(); fillAmounts(null); const f = { count: "#a-count", grams: "#a-grams", kcal: "#a-kcal" }[shareMode]; setTimeout(() => $(f).focus(), 50); });
/** Quick weights: one serving if the pack says, then a few sensible amounts. */
function renderGramChips(c) {
  const box = $("#gram-chips"); if (!c.kcalPer100) { box.innerHTML = ""; return; }
  const unit = draft.unit || "g", sv = draft.servingSize ? Math.round(draft.servingSize) : null;
  const nice = (g) => g < 50 ? Math.round(g / 5) * 5 : g < 200 ? Math.round(g / 10) * 10 : Math.round(g / 25) * 25;   // 25 g, 70 g, 250 g: easy numbers
  let list = sv ? [nice(sv / 2), nice(sv * 1.5), nice(sv * 2)] : unit === "ml" ? [100, 250, 330, 500] : [50, 100, 150, 200];
  list = [...new Set(list.filter((g) => g > 0 && g !== sv))].sort((x, y) => x - y).slice(0, sv ? 3 : 4);
  box.innerHTML = (sv ? `<button data-g="${sv}">1 serving · ${sv} ${unit}</button>` : "") + list.map((g) => `<button data-g="${g}">${g} ${unit}</button>`).join("");
}
$("#gram-chips").addEventListener("click", (e) => { const b = e.target.closest("button"); if (!b) return; $("#a-grams").value = b.dataset.g; setAmount(+b.dataset.g, "grams"); });
// the extras: one row opens the icons; each icon opens its own bit
$("#x-photo").onclick = () => { const r = $("#share-photo-row"), open = r.classList.toggle("hidden") === false; $("#x-photo").classList.toggle("on", open); if (open && !(draft && draft.photo)) $("#file-share-cam").click(); };

function openShare(prefillKcal) {
  const c = conv(draft);
  // A label read or an estimate came with a photo: keep a small copy of it with the entry
  if (!draft.photo && draft.image && String(draft.image).startsWith("data:")) thumbFrom(draft.image).then((t) => { if (draft) { draft.photo = t; showSharePhoto(); } }).catch(() => {});
  showSharePhoto();
  $("#share-name").textContent = draft.name;
  $("#share-add").textContent = pick ? "Add to the meal" : editId || pastEdit ? "Save changes" : pastAdd ? `Add to ${pastLabel(pastAdd)}` : "Add to today";
  const editing = editId && state.day.items.find((x) => x.id === editId);
  const pastIt = pastEdit && ((state.history.find((x) => x.date === pastEdit.date) || {}).items || [])[pastEdit.i];
  shareMeal = editing ? mealOf(editing) : pastIt ? mealOf(pastIt) : mealOf({ name: draft.name, addedAt: new Date().toISOString() });
  $("#share-meal").value = shareMeal; $("#share-meal").classList.toggle("hidden", !!pick);
  // one amount control: counted things get count chips, weighed things get gram chips; the others are a tap away
  shareMode = c.countKcal && (c.countLabel !== "serving" || !c.kcalPer100) ? "count" : c.kcalPer100 ? "grams" : "kcal";
  $("#share-extras").classList.toggle("hidden", !!pick || !!pastAdd || !!pastEdit);   // sharing is for today's food
  $("#share-photo-row").classList.toggle("hidden", !(draft && draft.photo)); $("#item-talk-row").classList.toggle("hidden", !!pick);
  $$(".x-ic").forEach((b) => b.classList.remove("on"));
  renderGramChips(c);
  $("#item-talk").value = ""; $("#item-talk-note").classList.add("hidden");
  $("#send-sheet").classList.add("hidden");
  $("#a-unit").textContent = draft.unit || "g";
  showAmountMode();
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
  const grams = (k != null && c.kcalPer100) ? k / c.kcalPer100 * 100 : null;
  $$("#gram-chips button").forEach((b) => b.classList.toggle("on", grams != null && Math.abs(grams - +b.dataset.g) < 0.6));
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


function updateResult() {
  const btn = $("#share-add"), bar = $("#r-bar");
  $("#share-post").disabled = !amountKcal || !!pick;
  $("#share-send").disabled = !amountKcal || !!pick;
  if (!amountKcal) { $("#r-kcal").textContent = "0"; $("#r-sub").textContent = "of your day"; bar.style.width = "0"; $("#r-lines").innerHTML = ""; $("#r-macros").innerHTML = ""; btn.disabled = true; return; }
  const kcal = Math.round(amountKcal);
  const frac = baseBudget() > 0 ? kcal / baseBudget() : 0;
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
/** The newest item goes in the meal picked on the How much screen, if that isn't what the clock would say. */
function keepMeal() { const it = state.day.items[state.day.items.length - 1]; if (it && shareMeal && shareMeal !== mealOf(it)) { it.meal = shareMeal; save(); renderHome(); } }
$("#share-post").onclick = () => {
  if (!amountKcal || !draft || pick) return;
  if (!(window.cloud && window.cloud.user)) { toast("Sharing needs an account: sign in from Settings"); return; }
  const kcal = Math.round(amountKcal);
  if (editId) { const it = state.day.items.find((x) => x.id === editId); if (it) { Object.assign(it, basisOf(draft)); it.kcal = kcal; it.shareLabel = `${fmt(kcal / baseBudget() * 100, 1)}% of the day`; save(); } editId = null; }
  else { addToDay(draft, kcal, `${fmt(kcal / baseBudget() * 100, 1)}% of the day`); keepMeal(); }
  const m = macrosFor(draft, kcal), a = amountsFor(draft, kcal);
  openCompose({ kind: "food", name: draft.name, kcal, grams: a.grams != null ? Math.round(a.grams) : null, unit: draft.unit || "g", p: m.p != null ? Math.round(m.p) : null, c: m.c != null ? Math.round(m.c) : null, f: m.f != null ? Math.round(m.f) : null, basis: basisOf(draft) }, draft.photo || null);
};
$("#share-add").onclick = () => {
  if (!amountKcal || !draft) return;
  const kcal = Math.round(amountKcal);
  if (pick) { mealTakeIngredient(draft, kcal); toast(`${draft.name} is in the meal`); return; }
  if (pastAdd || pastEdit) { savePastItem(kcal); return; }
  if (editId) {
    const it = state.day.items.find((x) => x.id === editId);
    if (it) { Object.assign(it, basisOf(draft)); it.kcal = kcal; it.shareLabel = `${fmt(kcal / baseBudget() * 100, 1)}% of the day`; if (shareMeal) it.meal = shareMeal; save(); }
    editId = null; toast(`Updated ${draft.name} · ${fmt(kcal)} kcal`); home(); return;
  }
  addToDay(draft, kcal, `${fmt(kcal / baseBudget() * 100, 1)}% of the day`);
  keepMeal();
  toast(`Added ${draft.name} · ${fmt(kcal)} kcal`);
  home();
};

// ---------------------------------------------------------------- account + sync (optional, see cloud.js)

const SYNC_KEYS = ["budget", "day", "history", "recent", "meals", "presetUses", "shareDay", "sharedMealIds", "goals", "chats", "notes", "weightKg", "eatBack", "recentWorkouts", "exercises", "routines", "session", "weekGoals", "seenBadges", "goalWins", "postCount", "pbCount", "body", "goalWeight", "goalStart", "simple", "onboarded", "reminders", "reactCount", "commentCount", "sendCount", "friendCount", "tombs", "dayBudgets", "profile", "plan", "restSeconds", "weighDays", "updatedAt"];   // the API key stays on the device
let pushTimer = null, pulledOnce = false;
function schedulePush() {
  if (!window.cloud || !window.cloud.user) return;
  if (!pulledOnce) return;   // never upload before this session has merged with what's in the cloud
  clearTimeout(pushTimer);
  pushTimer = setTimeout(() => {
    const data = {}; for (const k of SYNC_KEYS) data[k] = state[k];
    window.cloud.push(data).catch((err) => syncProblem(err));
    publishDay();
    offloadPhotos();
  }, 600);
}
function publishDay() {
  const c = window.cloud; if (!c || !c.user || !state.shareDay) return;
  const items = state.day.items.map((it) => ({ name: it.name, kcal: it.kcal, addedAt: it.addedAt || null, meal: mealOf(it) }))   // the meal is worked out here, in this phone's time zone.concat((state.day.workouts || []).map((w) => ({ name: `Workout: ${w.name}, ${w.minutes} min`, kcal: -Math.round(w.kcal || 0) })));
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
/** Merge another device's copy into this one, item by item: lists are joined by id, deletions are remembered,
 *  and for anything both sides changed (settings, the same item edited) the more recently saved copy wins. */
function mergeState(local, remote) {
  const lNew = (local.updatedAt || 0) >= (remote.updatedAt || 0), newer = lNew ? local : remote, older = lNew ? remote : local;
  const tombs = Object.assign({}, remote.tombs || {}, local.tombs || {});
  for (const [k, t] of Object.entries(remote.tombs || {})) tombs[k] = Math.max(t, tombs[k] || 0);
  const dead = (kind, id) => !!tombs[`${kind}:${id}`];
  /** Join two lists by key; the newer side's version of a shared entry wins; dead ones are dropped. */
  const join = (a, b, key, kind) => {
    const out = [], seen = new Set();
    for (const x of (a || []).concat(b || [])) { if (!x) continue; const k = key(x); if (k == null || seen.has(k) || (kind && dead(kind, k))) continue; seen.add(k); out.push(x); }
    return out;
  };
  const m = Object.assign({}, older, newer);   // settings and anything not listed below: newer copy
  m.tombs = tombs;
  // today: same day -> join the items; different days -> keep the later day and file the earlier one in history
  const ld = local.day || { items: [] }, rd = remote.day || { items: [] };
  const nd = newer.day || { items: [] }, od = older.day || { items: [] };
  let history = join(newer.history, older.history, (h) => h.date);
  if (ld.date === rd.date) {
    m.day = Object.assign({}, od, nd, { items: join(nd.items, od.items, (x) => x.id, "item"), workouts: join(nd.workouts, od.workouts, (x) => x.id, "wo") });
  } else {
    const later = String(ld.date) > String(rd.date) ? ld : rd, earlier = later === ld ? rd : ld;
    m.day = later;
    if (((earlier.items || []).length || (earlier.workouts || []).length) && !history.some((h) => h.date === earlier.date)) {
      const mac = sumMacros(earlier.items || []), burned = (earlier.workouts || []).reduce((a, w) => a + (w.kcal || 0), 0);
      const wb = m.dayBudgets && m.dayBudgets[new Date(earlier.date + "T12:00").getDay()];
      history.push({ date: earlier.date, budget: (wb > 0 ? wb : m.budget) + (m.eatBack ? burned : 0), kcal: (earlier.items || []).reduce((a, it) => a + (it.kcal || 0), 0), items: (earlier.items || []).map((it) => ({ ...basisOf(it), kcal: it.kcal, shareLabel: it.shareLabel })), p: Math.round(mac.p), c: Math.round(mac.c), f: Math.round(mac.f), burned, workouts: (earlier.workouts || []).map((w) => ({ name: w.name, minutes: w.minutes, kcal: w.kcal, lifts: w.lifts || [] })) });
    }
  }
  m.history = history.sort((a, b) => String(b.date).localeCompare(String(a.date))).slice(0, 400);
  m.recent = join(newer.recent, older.recent, (r) => r.key, "recent").sort((a, b) => String(b.lastUsed || "").localeCompare(String(a.lastUsed || ""))).slice(0, RECENT_MAX);
  m.meals = join(newer.meals, older.meals, (x) => x.id, "meal");
  m.chats = join(newer.chats, older.chats, (x) => x.id, "chat");
  m.routines = join(newer.routines, older.routines, (x) => x.id, "routine");
  m.recentWorkouts = join(newer.recentWorkouts, older.recentWorkouts, (x) => x.key);
  m.body = join(newer.body, older.body, (x) => x.day, "body").sort((a, b) => String(a.day).localeCompare(String(b.day)));
  m.exercises = Object.assign({}, older.exercises || {}, newer.exercises || {});
  for (const [k, e] of Object.entries(older.exercises || {})) { const n = m.exercises[k]; if (n && e && (e.best1rm || 0) > (n.best1rm || 0)) m.exercises[k] = Object.assign({}, n, { best1rm: e.best1rm, bestSet: e.bestSet || n.bestSet }); }
  m.presetUses = Object.assign({}, older.presetUses || {}); for (const [k, v] of Object.entries(newer.presetUses || {})) m.presetUses[k] = Math.max(v, m.presetUses[k] || 0);
  for (const k of ["seenBadges", "goalWins", "sharedMealIds"]) m[k] = [...new Set((newer[k] || []).concat(older[k] || []))];
  for (const k of ["postCount", "pbCount", "reactCount", "commentCount", "sendCount", "friendCount"]) m[k] = Math.max(newer[k] || 0, older[k] || 0);
  m.updatedAt = Math.max(local.updatedAt || 0, remote.updatedAt || 0);
  return m;
}
async function pull() {
  const c = window.cloud; if (!c || !c.user) return;
  let remote;
  try { remote = await c.pull(); } catch (err) { syncProblem(err); return; }
  pulledOnce = true;
  if (remote === null) { schedulePush(); return; }                       // fresh account: upload what we have
  if ((remote.updatedAt || 0) === (state.updatedAt || 0)) return;          // already the same
  const local = {}; for (const k of SYNC_KEYS) local[k] = state[k];
  const merged = mergeState(local, remote);
  for (const k of SYNC_KEYS) if (merged[k] !== undefined) state[k] = merged[k];
  save(false);
  // if this device added anything the cloud didn't have, send the merged copy back
  const sameAsRemote = JSON.stringify(SYNC_KEYS.map((k) => k === "updatedAt" ? 0 : merged[k])) === JSON.stringify(SYNC_KEYS.map((k) => k === "updatedAt" ? 0 : remote[k]));
  if (!sameAsRemote) { state.updatedAt = Date.now(); save(); }
  const current = stack[stack.length - 1];
  if (current === "home") renderHome();
  if (current === "settings") renderSettings();
  if (current === "body") drawBody();
  offloadPhotos();
}
// ---- photos: moved off the phone into Supabase Storage when signed in
let offloading = false, offloadAt = 0, photoBucketMissing = false;
async function offloadPhotos(force) {
  const c = window.cloud; if (!c || !c.user || offloading || photoBucketMissing) return;
  if (!force && Date.now() - offloadAt < 30000) return;
  offloading = true; offloadAt = Date.now();
  try {
    const fields = [];
    eachPhotoField((o, k) => fields.push([o, k]));
    if (!fields.length) return;
    // a big label picture next to a photo is redundant; on its own it becomes a small photo
    for (const [o, k] of fields.filter(([o, k]) => k === "image")) {
      if (o.photo) { delete o.image; continue; }
      try { o.photo = await thumbFrom(o.image); } catch (e) {}
      delete o.image;
    }
    const want = new Map();
    for (const [o, k] of fields) { const k2 = k === "image" ? "photo" : k; const v = o[k2]; if (typeof v === "string" && v.startsWith("data:")) { if (!want.has(v)) want.set(v, []); want.get(v).push([o, k2]); } }
    let done = 0;
    for (const [dataUrl, refs] of want) {
      if (done >= 25) break;   // a batch at a time; the rest go next time
      let url;
      try { url = await c.uploadPhoto(dataUrl); }
      catch (e) { if (e.status === 404 || e.status === 400 || /bucket/i.test(e.message)) photoBucketMissing = true; break; }
      for (const [o, k] of refs) if (o[k] === dataUrl) o[k] = url;
      done++;
    }
    save();
  } finally { offloading = false; }
}
/** A picture that's about to be shared: send a link rather than the picture itself when possible. */
async function sharablePhoto(p) {
  const c = window.cloud;
  if (!p || !String(p).startsWith("data:") || !c || !c.user || photoBucketMissing) return p || null;
  try { return await c.uploadPhoto(p); } catch (e) { return p; }
}
function renderAccount() {
  const c = window.cloud;
  $("#account-card").classList.remove("hidden");   // always visible: if sign-in couldn't load, say so and offer a retry
  $("#acct-down").classList.toggle("hidden", !!c);
  if (!c) { $("#acct-out").classList.add("hidden"); $("#acct-in").classList.add("hidden"); return; }
  $("#acct-out").classList.toggle("hidden", !!c.user);
  $("#acct-in").classList.toggle("hidden", !c.user);
  if (c.user) $("#acct-who").textContent = c.user.email || "";
}
function cloudInit() {
  const c = window.cloud;
  renderAccount();
  if (!c) return;
  c.onAuth((u) => { renderAccount(); if (u) { pull(); publishDay(); } else pulledOnce = false; });
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
$("#acct-retry").onclick = async () => {
  busy("Reloading…");
  try { if (window.caches) { const keys = await caches.keys(); await Promise.all(keys.map((k) => caches.delete(k))); } } catch (e) {}
  location.reload();
};
$("#acct-signin").onclick = () => acct("signin");
$("#acct-signup").onclick = () => acct("signup");
$("#acct-forgot").onclick = () => acct("forgot");
$("#acct-signout").onclick = async () => { try { await window.cloud.signOut(); toast("Signed out. This device keeps its own copy."); } catch (e) {} };
$("#acct-pass").addEventListener("keydown", (e) => { if (e.key === "Enter") acct("signin"); });

// ---------------------------------------------------------------- reminders: web push through the "push" function

const remPrefs = () => Object.assign({ lunch: true, weigh: "07:30", social: true }, state.reminders || {}, { days: weighDays() });   // weigh-in reminders only on your weigh-in days
/** Weigh-in days changed: tell the reminder server, if reminders are on. Uses the saved settings, not the Settings screen. */
function syncReminderDays() {
  if (!(window.cloud && window.cloud.user && state.reminders && state.reminders.weigh)) return;
  window.cloud.pushCall("prefs", { prefs: remPrefs(), tz: Intl.DateTimeFormat().resolvedOptions().timeZone }).catch(() => {});
}
const standalone = () => window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
const pushSupported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
function b64ToBytes(b64) { const pad = "=".repeat((4 - b64.length % 4) % 4), raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/")); return Uint8Array.from(raw, (ch) => ch.charCodeAt(0)); }
async function currentSub() { if (!pushSupported()) return null; const reg = await navigator.serviceWorker.getRegistration(); return reg ? reg.pushManager.getSubscription() : null; }
async function renderReminders() {
  const status = $("#rem-status"), on = $("#rem-on"), opts = $("#rem-opts");
  const signed = !!(window.cloud && window.cloud.user);
  const p = remPrefs();
  $("#rem-lunch").checked = p.lunch !== false; $("#rem-weigh-on").checked = !!p.weigh; $("#rem-weigh").value = p.weigh || "07:30"; $("#rem-social").checked = p.social !== false;
  const wd = weighDays(), daysText = wd.length === 7 ? "every day" : wd.length === 1 ? `${WEEKDAYS[wd[0]]}s` : wd.map((d) => WEEKDAYS[d].slice(0, 3)).join(", ");
  $("#rem-weigh-days").innerHTML = `Only on your weigh-in days (${daysText}). <a href="#" data-go="body">Change days</a>`;
  if (!signed) { status.textContent = "Reminders need an account: sign in above first."; on.classList.add("hidden"); opts.classList.add("hidden"); return; }
  if (!pushSupported()) { status.textContent = /iphone|ipad/i.test(navigator.userAgent) && !standalone() ? "On iPhone, reminders work once Cheat Days is on your home screen: tap Share, then Add to Home Screen, and open it from there." : "This browser can't show notifications."; on.classList.add("hidden"); opts.classList.add("hidden"); return; }
  const sub = await currentSub().catch(() => null);
  if (sub && Notification.permission === "granted") { status.textContent = "On for this phone."; on.classList.add("hidden"); opts.classList.remove("hidden"); }
  else { status.textContent = Notification.permission === "denied" ? "Notifications are blocked for Cheat Days. Turn them on in the phone's Settings → Notifications, then try again." : "Get a nudge to log, a weigh-in reminder, and a ping when friends react."; on.classList.remove("hidden"); opts.classList.add("hidden"); }
}
async function savePrefs() {
  state.reminders = { lunch: $("#rem-lunch").checked, weigh: $("#rem-weigh-on").checked ? ($("#rem-weigh").value || "07:30") : null, social: $("#rem-social").checked };
  save();
  try { await window.cloud.pushCall("prefs", { prefs: remPrefs(), tz: Intl.DateTimeFormat().resolvedOptions().timeZone }); } catch (e) { toast(e.message); }
}
$("#rem-on").onclick = () => enableReminders(Notification.requestPermission());   // asked straight from the tap, as iPhone needs
async function enableReminders(permission) {
  const c = window.cloud; if (!(c && c.user)) { toast("Sign in first"); return; }
  try {
    const perm = await permission;
    if (perm !== "granted") { toast("Notifications weren't allowed"); renderReminders(); return; }
    busy("Turning on reminders…");
    const reg = await navigator.serviceWorker.ready;
    const { publicKey } = await c.pushCall("key");
    let sub = await reg.pushManager.getSubscription();
    if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(publicKey) });
    await c.pushCall("subscribe", { subscription: sub.toJSON(), prefs: remPrefs(), tz: Intl.DateTimeFormat().resolvedOptions().timeZone });
    busy(false); toast("Reminders on"); renderReminders();
  } catch (e) { busy(false); toast("Couldn't turn on reminders: " + e.message, 6000); }
}
/** Once, on the home screen: ask whether to turn reminders on. "Not now" waits two weeks; a second no stops it. */
const REM_ASK = "cheatday.remAsk";
let remAskedThisVisit = false;
async function maybeAskReminders() {
  if (remAskedThisVisit || document.body.dataset.view !== "home" || !$("#ask-dialog").classList.contains("hidden")) return;
  const c = window.cloud; if (!(c && c.user)) return;
  let rec = {}; try { rec = JSON.parse(localStorage.getItem(REM_ASK) || "{}"); } catch (e) {}
  if (rec.done || (rec.no || 0) >= 2 || (rec.next && Date.now() < rec.next)) return;
  const iphone = /iphone|ipad/i.test(navigator.userAgent);
  const remember = (patch) => { try { localStorage.setItem(REM_ASK, JSON.stringify(Object.assign(rec, patch))); } catch (e) {} };
  if (!pushSupported() || (iphone && !standalone())) {
    if (!iphone || rec.tipShown) return;   // other browsers without push: nothing to offer
    remAskedThisVisit = true; remember({ tipShown: true });
    await ask("Want reminders to log and weigh in?\n\nOn iPhone they work once Cheat Days is on your home screen: tap the Share button, then Add to Home Screen, and open it from there.", { ok: "Got it", cancel: false });
    return;
  }
  if (Notification.permission === "denied") { remember({ done: true }); return; }
  if (Notification.permission === "granted" && await currentSub().catch(() => null)) { remember({ done: true }); return; }
  remAskedThisVisit = true;
  let permission = null;
  const yes = await ask("Turn on reminders?\n\nA nudge at 2pm if you haven't logged anything, a morning weigh-in reminder, and a ping when friends react to your posts.", { ok: "Turn on", cancel: "Not now", onOk: () => { permission = Notification.requestPermission(); } });
  if (yes) { remember({ done: true }); enableReminders(permission || Notification.requestPermission()); }
  else remember({ no: (rec.no || 0) + 1, next: Date.now() + 14 * 864e5 });
}
$("#rem-off").onclick = async () => {
  if (!await ask("Turn off reminders on this phone?")) return;
  try { const sub = await currentSub(); if (sub) { await window.cloud.pushCall("unsubscribe", { endpoint: sub.endpoint }).catch(() => {}); await sub.unsubscribe(); } toast("Reminders off"); } catch (e) { toast(e.message); }
  renderReminders();
};
$("#rem-test").onclick = async () => { try { const r = await window.cloud.pushCall("test"); toast(r.sent ? "Test sent: it should pop up in a moment" : "Nothing sent: try turning reminders off and on", 4000); } catch (e) { toast(e.message, 5000); } };
["#rem-lunch", "#rem-weigh-on", "#rem-weigh", "#rem-social"].forEach((q) => $(q).addEventListener("change", savePrefs));
/** Tell a friend something happened (reaction, comment, food sent). Quiet if reminders aren't set up. */
function notifyFriend(to, kind, text, extra = {}) {
  const c = window.cloud; if (!c || !c.user || !to || to === c.uid) return;
  c.pushCall("notify", { to, kind, text, ...extra }).catch(() => {});
}

// ---------------------------------------------------------------- backups: a second copy on the phone, cloud snapshots, files

const BK_DB = "cheatday-backup";
function bkOpen() {
  return new Promise((res, rej) => { if (!window.indexedDB) { rej(new Error("no IndexedDB")); return; } const r = indexedDB.open(BK_DB, 1); r.onupgradeneeded = () => r.result.createObjectStore("copies"); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
}
async function bkPut(key, value) { const db = await bkOpen(); return new Promise((res, rej) => { const tx = db.transaction("copies", "readwrite"); tx.objectStore("copies").put(value, key); tx.oncomplete = () => res(); tx.onerror = () => rej(tx.error); }); }
async function bkGetAll() { const db = await bkOpen(); return new Promise((res, rej) => { const out = []; const tx = db.transaction("copies", "readonly"); const cur = tx.objectStore("copies").openCursor(); cur.onsuccess = () => { const c = cur.result; if (c) { out.push({ key: c.key, value: c.value }); c.continue(); } else res(out); }; cur.onerror = () => rej(cur.error); }); }
async function bkDelete(key) { const db = await bkOpen(); return new Promise((res) => { const tx = db.transaction("copies", "readwrite"); tx.objectStore("copies").delete(key); tx.oncomplete = () => res(); tx.onerror = () => res(); }); }
/** How much a copy holds, to tell a real one from an empty one. */
const richness = (d) => !d ? 0 : (d.history || []).length * 3 + (d.meals || []).length * 2 + ((d.day && d.day.items) || []).length + (d.recent || []).length + (d.body || []).length;
let bkAt = 0;
/** Every couple of minutes: keep today's copy on the phone (one per day, last 7), separate from the main store. */
async function localBackup(force) {
  if (!force && Date.now() - bkAt < 120000) return;
  if (richness(state) < 2) return;   // never back up an empty app over a real backup
  bkAt = Date.now();
  try {
    const snap = {}; for (const k of SYNC_KEYS) snap[k] = state[k];
    await bkPut(`day:${localDate()}`, { at: Date.now(), data: snap });
    const all = await bkGetAll(), days = all.filter((x) => String(x.key).startsWith("day:")).sort((a, b) => String(b.key).localeCompare(String(a.key)));
    for (const old of days.slice(7)) await bkDelete(old.key);
  } catch (e) {}
}
/** At start-up: if the main copy is empty or unreadable but the phone backup has data, bring it back. */
async function recoverLocal() {
  if (!load.fresh && !load.unreadable && richness(state) > 0) return;
  try {
    const all = (await bkGetAll()).filter((x) => x.value && x.value.data).sort((a, b) => (b.value.at || 0) - (a.value.at || 0));
    const best = all.find((x) => richness(x.value.data) > richness(state));
    if (!best) return;
    const merged = mergeState(Object.assign({}, state, { updatedAt: 0 }), best.value.data);
    for (const k of SYNC_KEYS) if (merged[k] !== undefined) state[k] = merged[k];
    state.onboarded = true; load.fresh = load.unreadable = false;
    save(false); home();
    toast("Your data was missing on this phone, so it's been restored from the phone's backup.", 6000);
  } catch (e) {}
}
function restoreFrom(data, label) {
  const local = {}; for (const k of SYNC_KEYS) local[k] = state[k];
  const merged = mergeState(local, Object.assign({}, data, { updatedAt: 0 }));   // keep today's settings; bring back everything in the backup
  for (const k of SYNC_KEYS) if (merged[k] !== undefined && k !== "updatedAt") state[k] = merged[k];
  state.onboarded = true; bsCache = null;
  save(); home();
  toast(`Restored from ${label}: ${state.history.length} past days, ${state.meals.length} meals`, 5000);
}
/** Rebuild missing past days from the day summaries shared with friends (kept separately in the days table). */
async function rebuildFromDays() {
  const c = window.cloud; const rows = await c.myDays();
  const have = new Set(state.history.map((h) => h.date)); let added = 0;
  for (const r of rows) {
    if (r.day === state.day.date || have.has(r.day)) continue;
    const items = (r.items || []).filter((it) => (it.kcal || 0) >= 0).map((it) => ({ name: it.name, kcal: it.kcal, source: "manual" }));
    const wos = (r.items || []).filter((it) => (it.kcal || 0) < 0).map((it) => { const m = /^Workout: (.*), (\d+) min$/.exec(it.name || ""); return { name: m ? m[1] : it.name, minutes: m ? +m[2] : 0, kcal: -it.kcal, lifts: [] }; });
    if (!items.length && !wos.length) continue;
    state.history.push({ date: r.day, budget: r.budget, kcal: r.kcal, items, p: 0, c: 0, f: 0, burned: wos.reduce((a, w) => a + w.kcal, 0), workouts: wos });
    added++;
  }
  state.history.sort((a, b) => String(b.date).localeCompare(String(a.date)));
  state.history = state.history.slice(0, 400);
  bsCache = null; save(); return added;
}
async function renderBackups() {
  const box = $("#backup-list"); box.classList.remove("hidden"); box.innerHTML = `<p class="muted tiny">Looking for backups…</p>`;
  const rows = [];
  try { for (const x of (await bkGetAll()).filter((x) => x.value && x.value.data)) rows.push({ where: "On this phone", at: x.value.at, data: x.value.data }); } catch (e) {}
  const c = window.cloud; let cloudNote = "";
  if (c && c.user) {
    try { for (const b of await c.backups()) rows.push({ where: "Cloud", at: new Date(b.created_at).getTime(), data: b.data }); }
    catch (e) { cloudNote = "Cloud backups aren't set up yet."; }
  } else cloudNote = "Sign in to see cloud backups.";
  rows.sort((a, b) => b.at - a.at);
  box.innerHTML = "";
  for (const r of rows.filter((r) => richness(r.data) > 0)) {
    const d = r.data, row = document.createElement("div"); row.className = "backup-row";
    row.innerHTML = `<div><b>${r.where} · ${new Date(r.at).toLocaleString(undefined, { weekday: "short", day: "numeric", month: "short", hour: "numeric", minute: "2-digit" })}</b><small>${(d.history || []).length} past days · ${(d.meals || []).length} meals · ${(d.body || []).length} weigh-ins</small></div><button class="btn primary slim">Restore</button>`;
    row.querySelector("button").onclick = async () => { if (!await ask(`Restore this backup?\n\nIts days, meals and readings are added back. Nothing you have now is removed.`, { ok: "Restore" })) return; restoreFrom(d, r.where === "Cloud" ? "the cloud backup" : "the phone backup"); };
    box.appendChild(row);
  }
  if (c && c.user) {
    const row = document.createElement("div"); row.className = "backup-row";
    row.innerHTML = `<div><b>Rebuild from shared days</b><small>Past days' foods and totals from the summaries friends can see</small></div><button class="btn mint slim">Rebuild</button>`;
    row.querySelector("button").onclick = async () => { busy("Rebuilding your past days…"); try { const n = await rebuildFromDays(); busy(false); toast(n ? `Brought back ${n} past day${n === 1 ? "" : "s"}` : "No missing days found in the shared summaries", 5000); } catch (e) { busy(false); toast(c.explain(e), 5000); } };
    box.appendChild(row);
  }
  if (!box.children.length) box.innerHTML = `<p class="muted tiny">No backups found yet.</p>`;
  if (cloudNote) box.insertAdjacentHTML("beforeend", `<p class="muted tiny">${cloudNote}</p>`);
}
$("#backup-restore").onclick = () => renderBackups();
$("#backup-download").onclick = () => {
  const snap = {}; for (const k of SYNC_KEYS) snap[k] = state[k];
  const blob = new Blob([JSON.stringify({ app: "cheatdays", v: APP_VERSION, at: Date.now(), data: snap })], { type: "application/json" });
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = `cheat-days-backup-${localDate()}.json`; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
};
$("#backup-upload").onclick = () => $("#file-backup").click();
$("#file-backup").addEventListener("change", async (e) => {
  const f = e.target.files[0]; e.target.value = ""; if (!f) return;
  try { const j = JSON.parse(await f.text()); const d = j.data || j; if (!richness(d)) throw new Error("That file has no Cheat Days data in it"); if (!await ask(`Restore from this file?\n\n${(d.history || []).length} past days, ${(d.meals || []).length} meals. Nothing you have now is removed.`, { ok: "Restore" })) return; restoreFrom(d, "the file"); }
  catch (err) { toast(err.message || "Couldn't read that file", 5000); }
});
$("#wl-signin").onclick = () => { stack = ["home", "settings"]; show("settings"); setTimeout(() => { const el = $("#acct-email"); if (el) { el.scrollIntoView({ block: "center" }); } }, 100); toast("Sign in below and your data comes back from the cloud", 5000); };

// ---------------------------------------------------------------- appearance: match the phone, light or dark (this device only)

const darkQuery = window.matchMedia ? matchMedia("(prefers-color-scheme: dark)") : null;
function applyTheme() {
  const t = state.theme || "system", dark = t === "dark" || (t === "system" && darkQuery && darkQuery.matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  const meta = document.querySelector('meta[name="theme-color"]'); if (meta) meta.content = dark ? "#0f1411" : "#f5f6f1";
  $$("#s-theme button").forEach((b) => b.classList.toggle("on", b.dataset.t === t));
}
if (darkQuery && darkQuery.addEventListener) darkQuery.addEventListener("change", applyTheme);
$("#s-theme").addEventListener("click", (e) => { const b = e.target.closest("button"); if (!b) return; state.theme = b.dataset.t; save(false); applyTheme(); });

// ---------------------------------------------------------------- simple mode and the welcome guide

function applySimple() { document.body.classList.toggle("simple", !!state.simple); }
$("#s-simple").addEventListener("change", (e) => { state.simple = e.target.checked; save(); applySimple(); toast(state.simple ? "Simple mode on" : "Simple mode off"); });
$("#s-welcome").onclick = () => { wlStep(1); stack = ["welcome"]; show("welcome"); };
let wlBudget = null;
function wlStep(n) { for (const i of [1, 2, 3]) $(`#wl-${i}`).classList.toggle("hidden", i !== n); window.scrollTo(0, 0); }
$$("#view-welcome .wl-choice").forEach((b) => b.onclick = () => { state.simple = b.dataset.simple === "1"; save(false); applySimple(); wlBudget = state.budget; $$("#wl-budget button").forEach((x) => x.classList.toggle("on", +x.dataset.b === wlBudget)); wlStep(2); });
$("#wl-budget").addEventListener("click", (e) => { const b = e.target.closest("button"); if (!b) return; wlBudget = +b.dataset.b; $("#wl-custom").value = ""; $$("#wl-budget button").forEach((x) => x.classList.toggle("on", x === b)); });
$("#wl-custom").addEventListener("input", (e) => { const v = num(e.target.value); if (v) { wlBudget = Math.round(v); $$("#wl-budget button").forEach((x) => x.classList.remove("on")); } });
$("#wl-next").onclick = () => { if (!wlBudget || wlBudget < 800 || wlBudget > 6000) { toast("Pick a daily budget"); return; } state.budget = wlBudget; save(); wlStep(3); };
$("#wl-back-1").onclick = () => wlStep(1);
$("#wl-back-2").onclick = () => wlStep(2);
$("#wl-done").onclick = () => { state.onboarded = true; save(); home(); toast(`All set: ${fmt(state.budget)} kcal a day`); };
function needsWelcome() {
  if (state.onboarded) return false;
  const used = state.history.length || state.day.items.length || (state.recent || []).length || state.meals.length;
  if (used) { state.onboarded = true; save(false); return false; }   // someone already using the app never sees it
  return true;
}

// ---------------------------------------------------------------- boot

applySimple(); applyTheme();
recoverLocal();
if (needsWelcome()) { wlStep(1); stack = ["welcome"]; show("welcome"); } else show("home");
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
