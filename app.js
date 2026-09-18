/* Cheat Days — spend your cheat-day calories on purpose.
 * Everything lives in localStorage on this device. The only network calls are
 * barcode lookups (Open Food Facts) and label photos (Anthropic, only if you've
 * entered an API key in Settings). */
"use strict";

const APP_VERSION = "7";   // keep in step with ?v= in index.html and CACHE in sw.js
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
  const base = { budget: 1600, apiKey: "", day: { date: localDate(), items: [] }, history: [], recent: [] };
  try { const raw = localStorage.getItem(STORE_KEY); if (raw) Object.assign(base, JSON.parse(raw)); } catch (e) {}
  if (!Array.isArray(base.recent)) base.recent = [];
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
const BASIS_KEYS = ["name", "brand", "source", "unit", "unitLabel", "kcalPer100", "servingSize", "kcalPerServing", "packSize", "piecesPerPack", "image"];
function basisOf(obj) {
  const b = {};
  for (const k of BASIS_KEYS) if (obj[k] != null && obj[k] !== "") b[k] = obj[k];
  if (b.image && String(b.image).startsWith("data:")) delete b.image;   // never store photos
  return b;
}

// ---------------------------------------------------------------- router

const VIEWS = ["home", "settings", "scan", "details", "share"];
let stack = ["home"];
function show(view) {
  for (const v of VIEWS) $(`#view-${v}`).classList.toggle("hidden", v !== view);
  window.scrollTo(0, 0);
  if (view !== "scan") stopCamera();
  if (view === "home") renderHome();
  if (view === "settings") renderSettings();
  if (view === "scan") startCamera();
}
function go(view) { stack.push(view); show(view); }
function back() { stack.pop(); if (!stack.length) stack = ["home"]; show(stack[stack.length - 1]); }
function home() { stack = ["home"]; show("home"); }

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
  return { barcode: "barcode", label: "camera", quick: "plus" }[source] || "pen";
}
function itemRow(it) {
  const li = document.createElement("li");
  const thumb = it.image ? `<img class="thumb-sm" src="${esc(it.image)}" alt="">` : `<span class="thumb-sm"><svg><use href="#i-${iconFor(it.source)}"/></svg></span>`;
  li.innerHTML = `${thumb}
    <div class="body"><div class="name">${esc(it.name || "Unnamed")}</div><div class="detail">${esc(shortAmounts(it))}</div></div>
    <div class="kcal">${fmt(it.kcal)}</div>
    <button class="del" aria-label="Remove">✕</button>`;
  li.querySelector(".del").onclick = () => { state.day.items = state.day.items.filter((x) => x.id !== it.id); save(); renderHome(); };
  return li;
}

// --- quick add: presets from presets.js + everything you've added before
function quickEntries() {
  const presets = (typeof PRESETS !== "undefined" ? PRESETS : []).map((p) => ({
    key: "preset:" + p.name, preset: true,
    basis: { name: p.name, source: "quick", unit: "ml", unitLabel: p.unit || "serving", kcalPerServing: Math.round(p.kcal) },
    detail: p.detail || "", lastKcal: Math.round(p.kcal), lastShareLabel: `${fmt(Math.round(p.kcal) / state.budget * 100, 1)}% of the day`
  }));
  return presets.concat(state.recent);
}
function renderQuick() {
  const list = $("#quick-list"); list.innerHTML = "";
  const entries = quickEntries();
  $("#quick-hint").classList.toggle("hidden", entries.length === 0);
  for (const q of entries) {
    const li = document.createElement("li");
    const b = q.basis;
    const detail = q.detail || shortAmounts({ ...b, kcal: q.lastKcal, shareLabel: q.lastShareLabel });
    const thumb = b.image ? `<img class="thumb-sm" src="${esc(b.image)}" alt="">` : `<span class="thumb-sm"><svg><use href="#i-${iconFor(b.source)}"/></svg></span>`;
    li.innerHTML = `${thumb}
      <div class="body"><div class="name">${esc(b.name)}</div><div class="detail">${esc(detail)}</div></div>
      <div class="kcal">${fmt(q.lastKcal)}</div><button class="add" aria-label="Add"><svg><use href="#i-plus"/></svg></button>`;
    li.querySelector(".add").onclick = (e) => { e.stopPropagation(); addToDay(b, q.lastKcal, q.lastShareLabel); toast(`Added ${b.name} · ${fmt(q.lastKcal)} kcal`); };
    li.querySelector(".body").onclick = () => { draft = { ...b, note: "" }; openShare(q.lastKcal); };
    if (!q.preset) longPress(li, () => {
      if (confirm(`Remove "${b.name}" from Quick add?`)) { state.recent = state.recent.filter((r) => r.key !== q.key); save(); renderQuick(); }
    });
    list.appendChild(li);
  }
}
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
  state.recent = state.recent.filter((r) => r.key !== key);
  state.recent.unshift({ key, basis, lastKcal: kcal, lastShareLabel: shareLabel, lastUsed: new Date().toISOString() });
  state.recent = state.recent.slice(0, RECENT_MAX);
}
function addToDay(basis, kcal, shareLabel) {
  kcal = Math.round(kcal);
  state.day.items.push({ id: uid(), ...basisOf(basis), kcal, shareLabel, addedAt: new Date().toISOString() });
  if (basis.source !== "quick") rememberRecent(basisOf(basis), kcal, shareLabel);
  save(); renderHome();
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

let reader = null;
let photoMode = "auto";   // what a fallback photo is for: "auto" (barcode, then label) or "label"
const cameraPossible = () => !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.isSecureContext);
function zxingHints() {
  const F = ZXing.BarcodeFormat, h = new Map();
  h.set(ZXing.DecodeHintType.POSSIBLE_FORMATS, [F.EAN_13, F.EAN_8, F.UPC_A, F.UPC_E, F.CODE_128, F.CODE_39, F.ITF, F.QR_CODE]);
  h.set(ZXing.DecodeHintType.TRY_HARDER, true);
  return h;
}
async function startCamera() {
  $("#scan-fallback").classList.add("hidden");
  $("#barcode-manual").classList.add("hidden");
  if (!cameraPossible()) { $("#scan-fallback").classList.remove("hidden"); return; }
  try {
    reader = new ZXing.BrowserMultiFormatReader(zxingHints(), 300);
    await reader.decodeFromConstraints({ video: { facingMode: "environment", width: { ideal: 1920 }, height: { ideal: 1080 } } }, $("#video"), (result) => {
      if (result) { const code = result.getText(); stopCamera(); lookupBarcode(code); }
    });
  } catch (err) {
    console.warn("camera", err);
    $("#scan-fallback").classList.remove("hidden");
  }
}
function stopCamera() {
  if (reader) { try { reader.reset(); } catch (e) {} reader = null; }
  const v = $("#video"); if (v.srcObject) { try { v.srcObject.getTracks().forEach((t) => t.stop()); } catch (e) {} v.srcObject = null; }
}

$("#scan-photo").onclick = () => { photoMode = "auto"; $("#file-scan").click(); };
$("#scan-label").onclick = () => {
  if (!state.apiKey) { toast("Add your Anthropic API key in Settings first"); go("settings"); return; }
  const video = $("#video");
  if (reader && video.videoWidth) {
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
  const zx = new ZXing.BrowserMultiFormatReader(zxingHints());
  for (const width of [1400, 1000, 700]) {
    for (const rot of [0, 90]) {
      try {
        const el = await canvasToImage(drawScaled(img, width, rot));
        const res = await zx.decodeFromImageElement(el);
        if (res) return res.getText();
      } catch (e) {}
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
  const ctx = c.getContext("2d");
  ctx.translate(c.width / 2, c.height / 2); ctx.rotate(rot * Math.PI / 180); ctx.drawImage(img, -w / 2, -h / 2, w, h);
  return c;
}
function canvasToImage(canvas) {
  return new Promise((resolve, reject) => {
    const el = new Image(); el.onload = () => resolve(el); el.onerror = reject; el.src = canvas.toDataURL("image/png");
  });
}

// ---------------------------------------------------------------- Open Food Facts

async function lookupBarcode(code) {
  busy(`Looking up ${code}…`);
  const fields = "product_name,product_name_en,brands,quantity,product_quantity,product_quantity_unit,serving_size,serving_quantity,nutriments,image_front_small_url";
  let data;
  try {
    const r = await fetch(`https://world.openfoodfacts.org/api/v2/product/${encodeURIComponent(code)}.json?fields=${fields}`);
    data = await r.json();
  } catch (e) {
    busy(false); toast("Couldn't reach Open Food Facts. Type the numbers in instead.");
    draft = blankItem("manual"); openDetails("Enter the details"); return;
  }
  busy(false);
  if (!data || data.status !== 1 || !data.product) {
    toast(`Barcode ${code} isn't on Open Food Facts yet.`, 4000);
    draft = blankItem("manual"); draft.note = `Barcode ${code} not found. Fill in from the pack, or go back and read the label.`; openDetails("Enter the details"); return;
  }
  const p = data.product, n = p.nutriments || {};
  const item = blankItem("barcode");
  item.name = p.product_name_en || p.product_name || "";
  item.brand = p.brands || "";
  item.image = p.image_front_small_url || null;
  const q = ((p.product_quantity_unit || "") + " " + (p.quantity || "")).toLowerCase();
  item.unit = /\bml\b|\bl\b|litre|liter/.test(q) ? "ml" : "g";
  item.kcalPer100 = num(n["energy-kcal_100g"]) || (num(n["energy_100g"]) ? n["energy_100g"] / 4.184 : null);
  if (item.kcalPer100) item.kcalPer100 = Math.round(item.kcalPer100);
  item.servingSize = num(p.serving_quantity) || num((p.serving_size || "").match(/(\d+(?:[.,]\d+)?)\s*(g|ml)/i)?.[1]?.replace(",", "."));
  item.kcalPerServing = num(n["energy-kcal_serving"]) ? Math.round(n["energy-kcal_serving"]) : null;
  item.packSize = num(p.product_quantity);
  if (!item.kcalPer100 && !item.kcalPerServing) item.note = "Open Food Facts has this product but no calorie data. Fill it in from the pack.";
  draft = item;
  openDetails("Product details");
}

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
    confidence: { type: "string", enum: ["high", "medium", "low"] },
    notes: { type: "string", description: "Anything unclear, e.g. 'values are per 30g portion; per-100 not shown'" }
  },
  required: ["name", "brand", "unit", "kcal_per_100", "serving_size", "kcal_per_serving", "pack_size", "pieces_per_pack", "confidence", "notes"],
  additionalProperties: false
};
const LABEL_PROMPT = `This is a photo of a food or drink product, its nutrition table, or both. Read the energy information off it.
Report only numbers you can actually read on the label; use null for anything not visible rather than guessing.
If energy is given in kJ only, convert to kcal (kcal = kJ / 4.184). If values are per portion only, fill kcal_per_serving and serving_size and leave kcal_per_100 null.`;

async function readLabelWithClaude(file) {
  const img = await loadImage(file);
  const dataUrl = drawScaled(img, 1280).toDataURL("image/jpeg", 0.85);
  const b64 = dataUrl.split(",")[1];
  const body = {
    model: CLAUDE_MODEL,
    max_tokens: 2048,
    fallbacks: "default",
    output_config: { effort: "medium", format: { type: "json_schema", schema: LABEL_SCHEMA } },
    messages: [{ role: "user", content: [
      { type: "image", source: { type: "base64", media_type: "image/jpeg", data: b64 } },
      { type: "text", text: LABEL_PROMPT }
    ] }]
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
  if (json.stop_reason === "refusal") throw new Error("Claude declined to read that image");
  if (json.stop_reason === "max_tokens") throw new Error("Claude's answer was cut off. Try again.");
  const text = (json.content || []).filter((b) => b.type === "text").map((b) => b.text).join("");
  let parsed;
  try { parsed = JSON.parse(text); } catch (e) { throw new Error("Couldn't understand Claude's answer. Try a clearer photo."); }

  const item = blankItem("label");
  item.name = parsed.name || ""; item.brand = parsed.brand || "";
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
  if (item.piecesPerPack && item.packSize && kcalPer100) { countKcal = item.packSize / item.piecesPerPack * kcalPer100 / 100; countLabel = "piece"; }
  else if (item.kcalPerServing) { countKcal = item.kcalPerServing; countLabel = item.unitLabel || "serving"; }
  else if (item.servingSize && kcalPer100) { countKcal = item.servingSize * kcalPer100 / 100; countLabel = "serving"; }
  return { kcalPer100, countKcal, countLabel };
}
function openShare(prefillKcal) {
  const c = conv(draft);
  $("#share-name").textContent = draft.name;
  $("#a-unit").textContent = draft.unit || "g";
  $("#a-grams-wrap").classList.toggle("hidden", !c.kcalPer100);
  $("#a-count-wrap").classList.toggle("hidden", !c.countKcal);
  if (c.countLabel) $("#a-count-label").textContent = c.countLabel.charAt(0).toUpperCase() + c.countLabel.slice(1) + "s";
  amountKcal = null;
  fillAmounts(null);
  if (prefillKcal) setAmount(prefillKcal, "kcal");
  go("share");
}
const tidy = (n) => n == null ? "" : (Math.abs(n) >= 10 ? Math.round(n) : Math.round(n * 10) / 10);
function fillAmounts(except) {
  const c = conv(draft), k = amountKcal;
  if (except !== "kcal") $("#a-kcal").value = k == null ? "" : Math.round(k);
  if (except !== "grams") $("#a-grams").value = (k == null || !c.kcalPer100) ? "" : tidy(k / c.kcalPer100 * 100);
  if (except !== "count") $("#a-count").value = (k == null || !c.countKcal) ? "" : tidy(k / c.countKcal);
  updateResult();
}
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
  addToDay(draft, kcal, `${fmt(kcal / state.budget * 100, 1)}% of the day`);
  toast(`Added ${draft.name} · ${fmt(kcal)} kcal`);
  home();
};

// ---------------------------------------------------------------- account + sync (optional, see cloud.js)

const SYNC_KEYS = ["budget", "day", "history", "recent", "updatedAt"];   // the API key stays on the device
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
// Portrait only where the browser lets us ask (Android installed app); iOS shows the CSS overlay instead.
try { if (screen.orientation && screen.orientation.lock) screen.orientation.lock("portrait").catch(() => {}); } catch (e) {}
// No pinch-zoom on iOS Safari, which ignores user-scalable=no.
document.addEventListener("gesturestart", (e) => e.preventDefault());
document.addEventListener("touchmove", (e) => { if (e.scale && e.scale !== 1) e.preventDefault(); }, { passive: false });
if ("serviceWorker" in navigator && window.isSecureContext) navigator.serviceWorker.register("sw.js").catch(() => {});
