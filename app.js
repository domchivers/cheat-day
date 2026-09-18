/* Cheat Day — a tiny budget tracker for your cheat day.
 * Everything lives in localStorage on this device; nothing is sent anywhere
 * except barcode lookups (Open Food Facts) and label photos (Anthropic, only
 * if you've entered an API key in Settings). */
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
  try {
    const raw = localStorage.getItem(STORE_KEY);
    if (raw) Object.assign(base, JSON.parse(raw));
  } catch (e) { /* first run or blocked storage */ }
  return base;
}
function save() {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch (e) { toast("Couldn't save (storage blocked?)"); }
}
const state = load();

const usedKcal = () => state.day.items.reduce((s, it) => s + it.kcal, 0);

// ---------------------------------------------------------------- helpers

function toast(msg, ms = 2600) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.remove("hidden");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.add("hidden"), ms);
}

const fmt = (n, dp = 0) => {
  if (n == null || !isFinite(n)) return "–";
  const r = Number(n.toFixed(dp));
  return r.toLocaleString();
};
const fmt1 = (n) => (n == null || !isFinite(n)) ? "–" : (Math.abs(n) >= 10 ? n.toFixed(0) : n.toFixed(1));
const num = (v) => { const n = parseFloat(v); return isFinite(n) && n > 0 ? n : null; };

/** Parse "10%", "1/6", "0.15", "15" (→15%) or "250 kcal" into {fraction} or {kcal}. */
function parseShare(text) {
  const s = String(text).trim().toLowerCase().replace(/\s+/g, "");
  if (!s) return null;
  if (s === "rest") {
    return { kcal: Math.max(0, state.budget - usedKcal()), label: "what's left" };
  }
  let m;
  if ((m = s.match(/^(\d+(?:\.\d+)?)(?:kcal|cal|k)$/))) return { kcal: +m[1], label: `${m[1]} kcal` };
  if ((m = s.match(/^(\d+(?:\.\d+)?)\/(\d+(?:\.\d+)?)$/))) {
    const f = +m[1] / +m[2];
    return isFinite(f) && f > 0 ? { fraction: f, label: `${m[1]}/${m[2]} of the day` } : null;
  }
  if ((m = s.match(/^(\d+(?:\.\d+)?)%$/))) return { fraction: +m[1] / 100, label: `${m[1]}% of the day` };
  if ((m = s.match(/^(\d+(?:\.\d+)?)$/))) {
    const v = +m[1];
    if (v <= 0) return null;
    return v <= 1 ? { fraction: v, label: `${Math.round(v * 1000) / 10}% of the day` }
                  : { fraction: v / 100, label: `${v}% of the day` };
  }
  return null;
}

/** Turn a target kcal into grams / servings / pieces for the item. */
function amountsFor(item, kcal) {
  const out = { kcal };
  const u = item.unit || "g";
  let kcalPer100 = item.kcalPer100;
  if (!kcalPer100 && item.kcalPerServing && item.servingSize) kcalPer100 = item.kcalPerServing / item.servingSize * 100;
  if (kcalPer100) out.grams = kcal / kcalPer100 * 100;
  if (item.kcalPerServing) out.servings = kcal / item.kcalPerServing;
  else if (item.servingSize && out.grams != null) out.servings = out.grams / item.servingSize;
  if (item.packSize && out.grams != null) {
    out.packFraction = out.grams / item.packSize;
    if (item.piecesPerPack) out.pieces = out.packFraction * item.piecesPerPack;
  } else if (item.piecesPerPack && out.servings != null && !item.packSize) {
    // No pack weight, but a serving count: treat pieces as servings-per-pack scale if it's all we have.
    out.pieces = null;
  }
  out.unit = u;
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

// ---------------------------------------------------------------- main render

function render() {
  const used = usedKcal();
  const left = state.budget - used;
  $("#kcal-left").textContent = fmt(left);
  $("#kcal-used").textContent = fmt(used);
  $("#btn-budget").textContent = fmt(state.budget);
  $("#share-budget").textContent = fmt(state.budget);

  const ring = $("#ring-fill");
  const circ = 2 * Math.PI * 52;
  const frac = Math.min(1, state.budget > 0 ? used / state.budget : 0);
  ring.style.strokeDashoffset = circ * (1 - frac);
  ring.classList.toggle("over", left < 0);

  const d = state.day.date;
  $("#day-label").textContent = d === localDate() ? "Today" : new Date(d + "T12:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });

  const list = $("#item-list");
  list.innerHTML = "";
  for (const it of state.day.items) {
    const li = document.createElement("li");
    li.className = "item";
    const a = amountsFor(it, it.kcal);
    const parts = [];
    if (a.grams != null) parts.push(`${fmt1(a.grams)} ${a.unit}`);
    if (a.servings != null) parts.push(`${fmt1(a.servings)} serv`);
    if (a.pieces != null) parts.push(`${fmt1(a.pieces)} pcs`);
    parts.push(it.shareLabel);
    li.innerHTML = `
      <div class="body">
        <div class="name">${esc(it.name || "Unnamed")}</div>
        <div class="detail">${esc(parts.join(" · "))}</div>
      </div>
      <div class="kcal">${fmt(it.kcal)}</div>
      <button class="del" aria-label="Remove">✕</button>`;
    li.querySelector(".del").onclick = () => {
      state.day.items = state.day.items.filter((x) => x.id !== it.id);
      save(); render();
    };
    list.appendChild(li);
  }
  $("#empty").classList.toggle("hidden", state.day.items.length > 0);
}
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// ---------------------------------------------------------------- add-item sheet

const STEPS = ["source", "scan", "code", "busy", "item", "share"];
let draft = null;      // the item being added
let stepHistory = [];

function showStep(name, title) {
  for (const s of STEPS) $(`#step-${s}`).classList.toggle("hidden", s !== name);
  $("#sheet-title").textContent = title || { source: "Add an item", scan: "Scan barcode", code: "Barcode", busy: "One moment", item: "Check the details", share: "Your share" }[name];
  if (stepHistory[stepHistory.length - 1] !== name) stepHistory.push(name);
  $("#sheet-back").classList.toggle("hidden", stepHistory.length <= 1 || name === "busy");
  if (name !== "scan") stopCamera();
}

function openSheet() {
  draft = null;
  stepHistory = [];
  $("#sheet").classList.remove("hidden");
  showStep("source");
}
function closeSheet() {
  stopCamera();
  $("#sheet").classList.add("hidden");
}
function goBack() {
  stepHistory.pop();
  const prev = stepHistory.pop() || "source";
  if (prev === "busy" || prev === "scan") { stepHistory = []; showStep("source"); return; }
  showStep(prev);
}

$("#btn-add").onclick = openSheet;
$("#sheet-close").onclick = closeSheet;
$("#sheet-back").onclick = goBack;
$("#sheet").addEventListener("click", (e) => { if (e.target === $("#sheet")) closeSheet(); });

// --- sources
$("#src-barcode").onclick = () => {
  if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.isSecureContext) startCamera();
  else $("#file-barcode").click();   // plain http on the LAN: the camera app still works via the file picker
};
$("#src-label").onclick = () => {
  if (!state.apiKey) { toast("Add your Anthropic API key in Settings first"); openSettings(); return; }
  $("#file-label").click();
};
$("#src-manual").onclick = () => { draft = blankItem("manual"); fillItemForm(); showStep("item"); };
$("#scan-photo").onclick = () => $("#file-barcode").click();
$("#scan-type").onclick = () => showStep("code");
$("#code-go").onclick = () => { const c = $("#code-input").value.replace(/\D/g, ""); if (c) lookupBarcode(c); };
$("#code-input").addEventListener("keydown", (e) => { if (e.key === "Enter") $("#code-go").click(); });

$("#file-barcode").addEventListener("change", async (e) => {
  const file = e.target.files[0]; e.target.value = "";
  if (!file) return;
  showStep("busy"); $("#busy-text").textContent = "Reading the barcode…";
  try {
    const code = await decodeBarcodeFromFile(file);
    if (!code) { toast("Couldn't find a barcode in that photo. Try closer, flatter, in good light — or type the number."); showStep("code"); return; }
    lookupBarcode(code);
  } catch (err) { console.error(err); toast("Barcode reading failed"); showStep("code"); }
});

$("#file-label").addEventListener("change", async (e) => {
  const file = e.target.files[0]; e.target.value = "";
  if (!file) return;
  showStep("busy"); $("#busy-text").textContent = "Reading the label with Claude…";
  try {
    const item = await readLabelWithClaude(file);
    draft = item;
    fillItemForm();
    showStep("item");
  } catch (err) { console.error(err); toast(err.message || "Label reading failed", 5000); showStep("source"); }
});

function blankItem(source) {
  return { source, name: "", brand: "", unit: "g", kcalPer100: null, servingSize: null, kcalPerServing: null, packSize: null, piecesPerPack: null, image: null, note: "" };
}

// --- live camera (secure contexts only)
let reader = null;
function stopCamera() {
  if (reader) { try { reader.reset(); } catch (e) {} reader = null; }
}
async function startCamera() {
  showStep("scan");
  $("#scan-hint").textContent = "Point the camera at the barcode.";
  try {
    const hints = new Map();
    hints.set(ZXing.DecodeHintType.POSSIBLE_FORMATS, barcodeFormats());
    hints.set(ZXing.DecodeHintType.TRY_HARDER, true);
    reader = new ZXing.BrowserMultiFormatReader(hints, 300);
    const video = $("#video");
    const onResult = (result, err) => {
      if (result) {
        const code = result.getText();
        stopCamera();
        lookupBarcode(code);
      }
    };
    await reader.decodeFromConstraints({ video: { facingMode: "environment" } }, video, onResult);
  } catch (err) {
    console.error(err);
    $("#scan-hint").textContent = "Camera not available here. Take a photo instead.";
  }
}
function barcodeFormats() {
  const F = ZXing.BarcodeFormat;
  return [F.EAN_13, F.EAN_8, F.UPC_A, F.UPC_E, F.CODE_128, F.CODE_39, F.ITF, F.QR_CODE];
}

// --- decode a barcode from a still photo
async function decodeBarcodeFromFile(file) {
  const img = await loadImage(file);
  // 1) Native detector when the browser has one (fast, robust).
  if ("BarcodeDetector" in window) {
    try {
      const det = new BarcodeDetector({ formats: ["ean_13", "ean_8", "upc_a", "upc_e", "code_128", "code_39", "itf", "qr_code"] });
      const found = await det.detect(img);
      if (found.length) return found[0].rawValue;
    } catch (e) { /* fall through to ZXing */ }
  }
  // 2) ZXing at a few sizes and rotations - phone photos are often too big or blurry at full res.
  const hints = new Map();
  hints.set(ZXing.DecodeHintType.POSSIBLE_FORMATS, barcodeFormats());
  hints.set(ZXing.DecodeHintType.TRY_HARDER, true);
  const zx = new ZXing.BrowserMultiFormatReader(hints);
  for (const width of [1400, 1000, 700]) {
    for (const rot of [0, 90]) {
      const canvas = drawScaled(img, width, rot);
      try {
        const el = await canvasToImage(canvas);
        const res = await zx.decodeFromImageElement(el);
        if (res) return res.getText();
      } catch (e) { /* not found at this size */ }
    }
  }
  return null;
}

function loadImage(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => { resolve(img); };
    img.onerror = reject;
    img.src = url;
  });
}
function drawScaled(img, maxW, rot = 0) {
  const scale = Math.min(1, maxW / Math.max(img.naturalWidth, img.naturalHeight));
  const w = Math.round(img.naturalWidth * scale), h = Math.round(img.naturalHeight * scale);
  const c = document.createElement("canvas");
  if (rot === 90) { c.width = h; c.height = w; } else { c.width = w; c.height = h; }
  const ctx = c.getContext("2d");
  ctx.translate(c.width / 2, c.height / 2);
  ctx.rotate(rot * Math.PI / 180);
  ctx.drawImage(img, -w / 2, -h / 2, w, h);
  return c;
}
function canvasToImage(canvas) {
  return new Promise((resolve, reject) => {
    const el = new Image();
    el.onload = () => resolve(el);
    el.onerror = reject;
    el.src = canvas.toDataURL("image/png");
  });
}

// --- Open Food Facts lookup
async function lookupBarcode(code) {
  showStep("busy"); $("#busy-text").textContent = `Looking up ${code}…`;
  const fields = "product_name,product_name_en,brands,quantity,product_quantity,product_quantity_unit,serving_size,serving_quantity,nutriments,image_front_small_url";
  let data;
  try {
    const r = await fetch(`https://world.openfoodfacts.org/api/v2/product/${encodeURIComponent(code)}.json?fields=${fields}`);
    data = await r.json();
  } catch (e) {
    toast("Couldn't reach Open Food Facts. Type the numbers in instead.");
    draft = blankItem("manual"); fillItemForm(); showStep("item"); return;
  }
  if (!data || data.status !== 1 || !data.product) {
    toast(`Barcode ${code} isn't on Open Food Facts. Try a label photo or type it in.`, 4000);
    draft = blankItem("manual"); draft.note = `Barcode ${code} not found - fill in from the pack.`; fillItemForm(); showStep("item"); return;
  }
  const p = data.product, n = p.nutriments || {};
  const item = blankItem("barcode");
  item.name = p.product_name_en || p.product_name || "";
  item.brand = p.brands || "";
  item.image = p.image_front_small_url || null;
  const unit = (p.product_quantity_unit || p.quantity || "").toLowerCase().includes("ml") || (p.quantity || "").toLowerCase().includes(" l") ? "ml" : "g";
  item.unit = unit;
  item.kcalPer100 = num(n["energy-kcal_100g"]) || (num(n["energy_100g"]) ? n["energy_100g"] / 4.184 : null);
  if (item.kcalPer100) item.kcalPer100 = Math.round(item.kcalPer100);
  item.servingSize = num(p.serving_quantity) || num((p.serving_size || "").match(/(\d+(?:[.,]\d+)?)\s*(g|ml)/i)?.[1]?.replace(",", "."));
  item.kcalPerServing = num(n["energy-kcal_serving"]) ? Math.round(n["energy-kcal_serving"]) : null;
  item.packSize = num(p.product_quantity);
  if (!item.kcalPer100 && !item.kcalPerServing) item.note = "Open Food Facts has this product but no calorie data - fill it in from the pack.";
  draft = item;
  fillItemForm();
  showStep("item");
}

// --- Claude reads a label photo
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
  const canvas = drawScaled(img, 1280);
  const dataUrl = canvas.toDataURL("image/jpeg", 0.85);
  const b64 = dataUrl.split(",")[1];

  const body = {
    model: CLAUDE_MODEL,
    max_tokens: 2048,
    fallbacks: "default",
    output_config: { effort: "medium", format: { type: "json_schema", schema: LABEL_SCHEMA } },
    messages: [{
      role: "user",
      content: [
        { type: "image", source: { type: "base64", media_type: "image/jpeg", data: b64 } },
        { type: "text", text: LABEL_PROMPT }
      ]
    }]
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
    const msg = json?.error?.message || `HTTP ${resp.status}`;
    if (resp.status === 401) throw new Error("API key rejected - check it in Settings");
    throw new Error(`Claude error: ${msg}`);
  }
  if (json.stop_reason === "refusal") throw new Error("Claude declined to read that image");
  if (json.stop_reason === "max_tokens") throw new Error("Claude's answer was cut off - try again");
  const text = (json.content || []).filter((b) => b.type === "text").map((b) => b.text).join("");
  let parsed;
  try { parsed = JSON.parse(text); } catch (e) { throw new Error("Couldn't understand Claude's answer - try a clearer photo"); }

  const item = blankItem("label");
  item.name = parsed.name || "";
  item.brand = parsed.brand || "";
  item.unit = parsed.unit === "ml" ? "ml" : "g";
  item.kcalPer100 = num(parsed.kcal_per_100) ? Math.round(parsed.kcal_per_100) : null;
  item.servingSize = num(parsed.serving_size);
  item.kcalPerServing = num(parsed.kcal_per_serving) ? Math.round(parsed.kcal_per_serving) : null;
  item.packSize = num(parsed.pack_size);
  item.piecesPerPack = num(parsed.pieces_per_pack);
  item.image = dataUrl;
  const bits = [];
  if (parsed.confidence && parsed.confidence !== "high") bits.push(`Claude's confidence: ${parsed.confidence}.`);
  if (parsed.notes) bits.push(parsed.notes);
  item.note = bits.join(" ");
  return item;
}

// --- item form
function fillItemForm() {
  const d = draft;
  $("#f-name").value = d.name || "";
  $("#f-brand").value = d.brand || "";
  $("#f-unit").value = d.unit || "g";
  $("#f-kcal100").value = d.kcalPer100 ?? "";
  $("#f-serving").value = d.servingSize ?? "";
  $("#f-kcalserving").value = d.kcalPerServing ?? "";
  $("#f-pack").value = d.packSize ?? "";
  $("#f-pieces").value = d.piecesPerPack ?? "";
  const img = $("#item-image");
  if (d.image) { img.src = d.image; img.hidden = false; } else { img.hidden = true; img.removeAttribute("src"); }
  const note = $("#item-note");
  note.textContent = d.note || ""; note.hidden = !d.note;
  syncUnitEcho();
}
function readItemForm() {
  const d = draft;
  d.name = $("#f-name").value.trim();
  d.brand = $("#f-brand").value.trim();
  d.unit = $("#f-unit").value;
  d.kcalPer100 = num($("#f-kcal100").value);
  d.servingSize = num($("#f-serving").value);
  d.kcalPerServing = num($("#f-kcalserving").value);
  d.packSize = num($("#f-pack").value);
  d.piecesPerPack = num($("#f-pieces").value);
  return d;
}
function syncUnitEcho() { $$(".unit-echo").forEach((el) => el.textContent = $("#f-unit").value); }
$("#f-unit").onchange = syncUnitEcho;
$("#item-next").onclick = () => {
  const d = readItemForm();
  if (!d.kcalPer100 && !(d.kcalPerServing)) { toast("I need kcal per 100 or kcal per serving"); return; }
  if (!d.name) d.name = d.brand || "Something tasty";
  $("#share-name").textContent = d.name;
  $("#share-input").value = "";
  $$("#chips button").forEach((b) => b.classList.remove("on"));
  currentShare = null;
  updateResult();
  showStep("share");
};

// --- share step
let currentShare = null;
$("#chips").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  $$("#chips button").forEach((x) => x.classList.toggle("on", x === b));
  $("#share-input").value = b.dataset.f === "rest" ? "" : "";
  currentShare = parseShare(b.dataset.f);
  updateResult();
});
$("#share-input").addEventListener("input", (e) => {
  $$("#chips button").forEach((x) => x.classList.remove("on"));
  currentShare = parseShare(e.target.value);
  updateResult();
});
function updateResult() {
  const btn = $("#share-add");
  if (!currentShare) { $("#r-kcal").textContent = "–"; $("#r-lines").innerHTML = ""; btn.disabled = true; return; }
  const kcal = currentShare.kcal != null ? currentShare.kcal : state.budget * currentShare.fraction;
  const a = amountsFor(draft, kcal);
  $("#r-kcal").textContent = fmt(kcal);
  const lines = describeAmounts(a);
  const leftAfter = state.budget - usedKcal() - kcal;
  lines.push(leftAfter >= 0 ? `leaves <b>${fmt(leftAfter)}</b> kcal for the rest of the day` : `<b style="color:var(--bad)">${fmt(-leftAfter)} kcal over</b> your day`);
  $("#r-lines").innerHTML = lines.map((l) => `<div>${l}</div>`).join("");
  btn.disabled = false;
}
$("#share-add").onclick = () => {
  if (!currentShare || !draft) return;
  const kcal = currentShare.kcal != null ? currentShare.kcal : state.budget * currentShare.fraction;
  const { image, note, ...basis } = draft;   // don't keep photos in storage
  state.day.items.push({
    id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
    ...basis,
    kcal: Math.round(kcal),
    shareLabel: currentShare.label,
    addedAt: new Date().toISOString()
  });
  save(); render(); closeSheet();
  toast(`Added ${draft.name} - ${fmt(kcal)} kcal`);
};

// ---------------------------------------------------------------- budget / day / settings

$("#btn-budget").onclick = openSettings;
$("#budget-card").onclick = (e) => { if (e.target.id !== "btn-budget") openSettings(); };

$("#btn-new-day").onclick = () => {
  if (state.day.items.length && !confirm("Start a fresh day? Today's list moves to history.")) return;
  if (state.day.items.length) {
    state.history.unshift({ date: state.day.date, budget: state.budget, kcal: usedKcal(), items: state.day.items.length });
    state.history = state.history.slice(0, 60);
  }
  state.day = { date: localDate(), items: [] };
  save(); render();
};

function openSettings() {
  $("#s-budget").value = state.budget;
  $("#s-apikey").value = state.apiKey;
  const h = $("#history");
  h.innerHTML = state.history.length ? "" : "<li>No past days yet.</li>";
  for (const d of state.history) {
    const li = document.createElement("li");
    li.innerHTML = `<span>${esc(d.date)} · ${d.items} item${d.items === 1 ? "" : "s"}</span><span><b>${fmt(d.kcal)}</b> / ${fmt(d.budget)}</span>`;
    h.appendChild(li);
  }
  $("#settings").classList.remove("hidden");
}
$("#settings-close").onclick = () => $("#settings").classList.add("hidden");
$("#settings").addEventListener("click", (e) => { if (e.target === $("#settings")) $("#settings").classList.add("hidden"); });
$("#settings-save").onclick = () => {
  const b = num($("#s-budget").value);
  if (!b) { toast("Budget needs to be a number of kcal"); return; }
  state.budget = Math.round(b);
  state.apiKey = $("#s-apikey").value.trim();
  save(); render();
  $("#settings").classList.add("hidden");
  toast("Saved");
};

// ---------------------------------------------------------------- boot

render();
if ("serviceWorker" in navigator && window.isSecureContext) {
  navigator.serviceWorker.register("sw.js").catch(() => {});
}
