/* Cheat Days — spend your cheat-day calories on purpose.
 * Everything lives in localStorage on this device. The only network calls are
 * barcode lookups (Open Food Facts) and label photos (Anthropic, only if you've
 * entered an API key in Settings). */
"use strict";

const STORE_KEY = "cheatday.v1";
const CLAUDE_MODEL = "claude-opus-5";
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

// ---------------------------------------------------------------- state

function localDate(d = new Date()) {
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}
function load() {
  const base = { budget: 1600, apiKey: "", day: { date: localDate(), items: [] }, history: [] };
  try { const raw = localStorage.getItem(STORE_KEY); if (raw) Object.assign(base, JSON.parse(raw)); } catch (e) {}
  return base;
}
function save() {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch (e) { toast("Couldn't save (storage blocked?)"); }
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
const fmt1 = (n) => (n == null || !isFinite(n)) ? "–" : (Math.abs(n) >= 10 ? n.toFixed(0) : n.toFixed(1));
const num = (v) => { const n = parseFloat(v); return isFinite(n) && n > 0 ? n : null; };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/** "10%", "1/6", "0.15", "15" (→15%) or "250 kcal" → {fraction} or {kcal}. */
function parseShare(text) {
  const s = String(text).trim().toLowerCase().replace(/\s+/g, "");
  if (!s) return null;
  if (s === "rest") return { kcal: Math.max(0, state.budget - usedKcal()), label: "what's left" };
  let m;
  if ((m = s.match(/^(\d+(?:\.\d+)?)(?:kcal|cal|k)$/))) return { kcal: +m[1], label: `${m[1]} kcal` };
  if ((m = s.match(/^(\d+(?:\.\d+)?)\/(\d+(?:\.\d+)?)$/))) {
    const f = +m[1] / +m[2];
    return isFinite(f) && f > 0 ? { fraction: f, label: `${m[1]}/${m[2]} of the day` } : null;
  }
  if ((m = s.match(/^(\d+(?:\.\d+)?)%$/))) return { fraction: +m[1] / 100, label: `${m[1]}% of the day` };
  if ((m = s.match(/^(\d+(?:\.\d+)?)$/))) {
    const v = +m[1]; if (v <= 0) return null;
    return v <= 1 ? { fraction: v, label: `${Math.round(v * 1000) / 10}% of the day` } : { fraction: v / 100, label: `${v}% of the day` };
  }
  return null;
}

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
function describeAmounts(a) {
  const lines = [];
  if (a.grams != null) lines.push(`<b>${fmt1(a.grams)} ${a.unit}</b>`);
  if (a.servings != null) lines.push(`<b>${fmt1(a.servings)}</b> serving${a.servings >= 1.95 ? "s" : ""}`);
  if (a.pieces != null) lines.push(`<b>${fmt1(a.pieces)}</b> piece${a.pieces >= 1.95 ? "s" : ""}`);
  if (a.packFraction != null) lines.push(`<b>${fmt(a.packFraction * 100)}%</b> of the pack`);
  return lines;
}
function shortAmounts(item) {
  if (item.unitLabel) return `1 ${item.unitLabel} · ${item.shareLabel}`;
  const a = amountsFor(item, item.kcal), parts = [];
  if (a.grams != null) parts.push(`${fmt1(a.grams)} ${a.unit}`);
  if (a.pieces != null) parts.push(`${fmt1(a.pieces)} pcs`);
  else if (a.servings != null) parts.push(`${fmt1(a.servings)} serv`);
  parts.push(item.shareLabel);
  return parts.join(" · ");
}

// ---------------------------------------------------------------- router

const VIEWS = ["home", "settings", "scan-barcode", "scan-label", "details", "share"];
let stack = ["home"];
function show(view) {
  for (const v of VIEWS) $(`#view-${v}`).classList.toggle("hidden", v !== view);
  window.scrollTo(0, 0);
  if (view !== "scan-barcode") stopBarcodeCamera();
  if (view !== "scan-label") stopLabelCamera();
  if (view === "home") renderHome();
  if (view === "settings") renderSettings();
  if (view === "scan-barcode") startBarcodeCamera();
  if (view === "scan-label") startLabelCamera();
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
function renderQuick() {
  const list = $("#quick-list"); list.innerHTML = "";
  const presets = typeof PRESETS !== "undefined" ? PRESETS : [];
  presets.forEach((p, i) => {
    const li = document.createElement("li");
    li.innerHTML = `<div class="body"><div class="name">${esc(p.name)}</div><div class="detail">${esc(p.detail || "")}</div></div>
      <div class="kcal">${fmt(p.kcal)}</div><span class="add"><svg><use href="#i-plus"/></svg></span>`;
    li.onclick = () => addPreset(p);
    list.appendChild(li);
  });
  list.previousElementSibling.classList.toggle("hidden", presets.length === 0);
}
function addPreset(p) {
  const kcal = Math.round(p.kcal);
  state.day.items.push({
    id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
    source: "quick", name: p.name, unitLabel: p.unit || "serving",
    kcalPerServing: kcal, kcal,
    shareLabel: `${fmt(kcal / state.budget * 100, 1)}% of the day`,
    addedAt: new Date().toISOString()
  });
  save(); renderHome();
  toast(`Added ${p.name} · ${fmt(kcal)} kcal`);
}
function itemRow(it) {
  const li = document.createElement("li");
  const thumb = it.image ? `<img class="thumb-sm" src="${esc(it.image)}" alt="">` : `<span class="thumb-sm"><svg><use href="#i-${it.source === "barcode" ? "barcode" : it.source === "label" ? "camera" : it.source === "quick" ? "plus" : "pen"}"/></svg></span>`;
  li.innerHTML = `${thumb}
    <div class="body"><div class="name">${esc(it.name || "Unnamed")}</div><div class="detail">${esc(shortAmounts(it))}</div></div>
    <div class="kcal">${fmt(it.kcal)}</div>
    <button class="del" aria-label="Remove">✕</button>`;
  li.querySelector(".del").onclick = () => { state.day.items = state.day.items.filter((x) => x.id !== it.id); save(); renderHome(); };
  return li;
}

// ---------------------------------------------------------------- settings

function renderSettings() {
  $("#s-budget").value = state.budget;
  $("#s-apikey").value = state.apiKey;
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
$("#btn-new-day").onclick = () => {
  if (state.day.items.length && !confirm("Start a fresh day? Today's list moves to past days.")) return;
  if (state.day.items.length) {
    state.history.unshift({ date: state.day.date, budget: state.budget, kcal: usedKcal(), items: state.day.items.length });
    state.history = state.history.slice(0, 60);
  }
  state.day = { date: localDate(), items: [] };
  save(); toast("New day started"); home();
};

// ---------------------------------------------------------------- items

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
  $("#share-name").textContent = d.name;
  resetShare();
  go("share");
};

// ---------------------------------------------------------------- barcode camera + decode

let barcodeReader = null;
function barcodeFormats() {
  const F = ZXing.BarcodeFormat;
  return [F.EAN_13, F.EAN_8, F.UPC_A, F.UPC_E, F.CODE_128, F.CODE_39, F.ITF, F.QR_CODE];
}
function zxingHints() {
  const h = new Map();
  h.set(ZXing.DecodeHintType.POSSIBLE_FORMATS, barcodeFormats());
  h.set(ZXing.DecodeHintType.TRY_HARDER, true);
  return h;
}
const cameraPossible = () => !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.isSecureContext);

async function startBarcodeCamera() {
  $("#barcode-fallback").classList.add("hidden");
  $("#barcode-manual").classList.add("hidden");
  if (!cameraPossible()) { $("#barcode-fallback").classList.remove("hidden"); return; }
  try {
    barcodeReader = new ZXing.BrowserMultiFormatReader(zxingHints(), 300);
    await barcodeReader.decodeFromConstraints({ video: { facingMode: "environment" } }, $("#video-barcode"), (result) => {
      if (result) { const code = result.getText(); stopBarcodeCamera(); lookupBarcode(code); }
    });
  } catch (err) {
    console.warn("camera", err);
    $("#barcode-fallback").classList.remove("hidden");
  }
}
function stopBarcodeCamera() { if (barcodeReader) { try { barcodeReader.reset(); } catch (e) {} barcodeReader = null; } }

$("#barcode-photo").onclick = () => $("#file-barcode").click();
$("#barcode-manual-toggle").onclick = () => { $("#barcode-manual").classList.toggle("hidden"); $("#code-input").focus(); };
$("#code-go").onclick = () => { const c = $("#code-input").value.replace(/\D/g, ""); if (c) lookupBarcode(c); };
$("#code-input").addEventListener("keydown", (e) => { if (e.key === "Enter") $("#code-go").click(); });
$("#file-barcode").addEventListener("change", async (e) => {
  const file = e.target.files[0]; e.target.value = "";
  if (!file) return;
  busy("Reading the barcode…");
  try {
    const code = await decodeBarcodeFromFile(file);
    busy(false);
    if (!code) { toast("No barcode found. Try closer and flatter, or type the number."); $("#barcode-manual").classList.remove("hidden"); return; }
    lookupBarcode(code);
  } catch (err) { busy(false); console.error(err); toast("Couldn't read that photo"); }
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
    draft = blankItem("manual"); draft.note = `Barcode ${code} not found. Fill in from the pack, or try a label photo.`; openDetails("Enter the details"); return;
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

// ---------------------------------------------------------------- label camera + Claude

let labelStream = null;
async function startLabelCamera() {
  const video = $("#video-label");
  if (!cameraPossible()) return;
  try {
    labelStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment", width: { ideal: 1920 } }, audio: false });
    video.srcObject = labelStream;
  } catch (err) { console.warn("camera", err); labelStream = null; }
}
function stopLabelCamera() {
  if (labelStream) { labelStream.getTracks().forEach((t) => t.stop()); labelStream = null; }
  $("#video-label").srcObject = null;
}
$("#label-capture").onclick = async () => {
  if (!state.apiKey) { toast("Add your Anthropic API key in Settings first"); go("settings"); return; }
  const video = $("#video-label");
  if (labelStream && video.videoWidth) {
    const canvas = drawScaled(video, 1600);
    canvas.toBlob((blob) => readLabel(blob), "image/jpeg", 0.9);
  } else {
    $("#file-label").click();
  }
};
$("#file-label").addEventListener("change", (e) => {
  const file = e.target.files[0]; e.target.value = "";
  if (file) readLabel(file);
});
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

// ---------------------------------------------------------------- fraction of day

let currentShare = null;
function resetShare() {
  currentShare = null;
  $("#share-input").value = "";
  $$("#chips button").forEach((b) => b.classList.remove("on"));
  updateResult();
}
$("#chips").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  $$("#chips button").forEach((x) => x.classList.toggle("on", x === b));
  $("#share-input").value = "";
  currentShare = parseShare(b.dataset.f);
  updateResult();
});
$("#share-input").addEventListener("input", (e) => {
  $$("#chips button").forEach((x) => x.classList.remove("on"));
  currentShare = parseShare(e.target.value);
  updateResult();
});
$("#share-reset").onclick = resetShare;

function shareKcal() { return Math.round(currentShare.kcal != null ? currentShare.kcal : state.budget * currentShare.fraction); }
function updateResult() {
  const btn = $("#share-add"), bar = $("#r-bar");
  if (!currentShare) { $("#r-kcal").textContent = "0"; $("#r-sub").textContent = "of your day"; bar.style.width = "0"; $("#r-lines").innerHTML = ""; btn.disabled = true; return; }
  const kcal = shareKcal();
  const frac = state.budget > 0 ? kcal / state.budget : 0;
  $("#r-kcal").textContent = fmt(kcal);
  $("#r-sub").textContent = `≈ ${fmt(frac * 100, 1)}% of your day`;
  bar.style.width = `${Math.min(100, frac * 100)}%`;
  const lines = describeAmounts(amountsFor(draft, kcal));
  const leftAfter = state.budget - usedKcal() - kcal;
  lines.push(leftAfter >= 0 ? `leaves <b>${fmt(leftAfter)}</b> kcal for the rest of the day` : `<b style="color:var(--bad)">${fmt(-leftAfter)} kcal over</b> your day`);
  $("#r-lines").innerHTML = lines.map((l) => `<div>${l}</div>`).join("");
  btn.disabled = false;
}
$("#share-add").onclick = () => {
  if (!currentShare || !draft) return;
  const kcal = shareKcal();
  const { image, note, ...basis } = draft;
  state.day.items.push({
    id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
    ...basis,
    image: image && !image.startsWith("data:") ? image : null,   // keep OFF thumbnails, not photos
    kcal: Math.round(kcal),
    shareLabel: currentShare.label,
    addedAt: new Date().toISOString()
  });
  save();
  toast(`Added ${draft.name} · ${fmt(kcal)} kcal`);
  home();
};

// ---------------------------------------------------------------- boot

show("home");
if ("serviceWorker" in navigator && window.isSecureContext) navigator.serviceWorker.register("sw.js").catch(() => {});
