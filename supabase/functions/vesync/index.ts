// PARKED (v70): not used by the app. VeSync returned no readings for the ESF-551; kept for reference.
// Cheat Days <-> VeSync (Etekcity) link. Signed-in users connect their VeSync account once; this function logs in with
// the same protocol the VeSync app uses (unofficial: the same one pyvesync / Home Assistant use), keeps ONLY the session
// token (never the password), finds the scale, and on "sync" pulls the readings into body_metrics.
// Deploy: Supabase dashboard -> Edge Functions -> Deploy a new function -> name it "vesync", paste this, Deploy.
// Keep "Verify JWT" ON: the app calls it with the user's own login. Needs a vesync_links table (SQL in the README).
import { createClient } from "npm:@supabase/supabase-js@2";
import { crypto as stdCrypto } from "jsr:@std/crypto@1";
import { encodeHex } from "jsr:@std/encoding@1/hex";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (obj: unknown, status = 200) => new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });

const BASES: Record<string, string> = { US: "https://smartapi.vesync.com", EU: "https://smartapi.vesync.eu" };
const APP_VERSION = "5.9.70", CLIENT_VERSION = `VeSync ${APP_VERSION}`, APP_ID = "eldodkfj", CLIENT_TYPE = "vesyncApp";
const PHONE_BRAND = "CheatDays", PHONE_OS = "iOS", LANG = "en", TZ = "Australia/Sydney";
let traceN = 0;
const traceId = (terminalId: string) => `APP${terminalId.replace(/-/g, "").slice(-4)}${Math.floor(Date.now() / 1000)}-${String(++traceN).padStart(5, "0")}`;
const md5 = async (s: string) => encodeHex(await stdCrypto.subtle.digest("MD5", new TextEncoder().encode(s)));

type Resp = { code?: number; msg?: string; result?: any };
async function post(base: string, path: string, body: Record<string, unknown>, headers: Record<string, string> = {}): Promise<Resp> {
  const r = await fetch(base + path, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body) });
  try { return await r.json(); } catch { return { code: -1, msg: `HTTP ${r.status}` }; }
}
const expired = (r: Resp) => r.code === -11201022 || r.code === -11012022;

const CROSS_REGION = -11260022;
/** Two-step login. If VeSync says the account lives in another region, it tells us which: repeat step two there with the
 *  one-time bizToken, exactly as the VeSync app (and pyvesync) do. Returns the region that finally answered. */
async function login(region: string, country: string, email: string, password: string, terminalId: string) {
  const hashed = await md5(password);
  const common = { acceptLanguage: LANG, accountID: "", clientInfo: PHONE_BRAND, clientType: CLIENT_TYPE, clientVersion: CLIENT_VERSION, debugMode: false, osInfo: PHONE_OS, terminalId, timeZone: TZ, token: "" };
  const a = await post(BASES[region], "/globalPlatform/api/accountAuth/v1/authByPWDOrOTM", { ...common, userCountryCode: country, email, method: "authByPWDOrOTM", password: hashed, authProtocolType: "generic", appID: APP_ID, sourceAppID: APP_ID, traceId: traceId(terminalId) });
  if (a.code !== 0 || !a.result) throw new Error(a.msg || `VeSync login failed (${a.code})`);
  let bizToken: string | null = null;
  for (let hop = 0; hop < 3; hop++) {
    const b = await post(BASES[region], "/user/api/accountManage/v1/loginByAuthorizeCode4Vesync", { ...common, userCountryCode: country, method: "loginByAuthorizeCode4Vesync", authorizeCode: a.result.authorizeCode, emailSubscriptions: false, traceId: traceId(terminalId), ...(bizToken ? { bizToken, regionChange: "lastRegion" } : {}) });
    if (b.code === CROSS_REGION && b.result) {
      const r = b.result;
      region = String(r.currentRegion || "").toUpperCase() in BASES ? String(r.currentRegion).toUpperCase() : (region === "US" ? "EU" : "US");
      country = r.countryCode || country;
      bizToken = r.bizToken || null;
      continue;
    }
    if (b.code !== 0 || !b.result) throw new Error(b.msg || `VeSync login failed (${b.code})`);
    return { token: b.result.token as string, accountId: b.result.accountID as string, region, country };
  }
  throw new Error("VeSync kept bouncing the login between regions");
}
const session = (s: { token: string; accountId: string; terminalId: string }) => ({ accountID: s.accountId, token: s.token, timeZone: TZ, appVersion: APP_VERSION, phoneBrand: PHONE_BRAND, phoneOS: PHONE_OS, acceptLanguage: LANG, traceId: traceId(s.terminalId) });
const legacyHeaders = (s: { token: string; accountId: string }) => ({ "accept-language": LANG, accountId: s.accountId, appVersion: APP_VERSION, tk: s.token, tz: TZ });

async function devices(base: string, s: { token: string; accountId: string; terminalId: string }) {
  const r = await post(base, "/cloud/v1/deviceManaged/devices", { ...session(s), method: "devices", pageNo: 1, pageSize: 100 });
  if (expired(r)) throw new Error("expired");
  if (r.code !== 0) throw new Error(r.msg || "Couldn't list devices");
  return (r.result?.list || []) as any[];
}
const isScale = (d: any) => /scale|esf|fit-?8|efs/i.test(`${d.deviceType || ""} ${d.deviceName || ""} ${d.configModule || ""}`);

/** The readings array, wherever VeSync put it: a known name, else the first array of objects anywhere in the result. */
function firstArray(res: any): any[] {
  if (!res || typeof res !== "object") return [];
  for (const k of ["weightDatas", "weighingDatas", "items", "list", "dataList", "records", "data"]) if (Array.isArray(res[k]) && res[k].length) return res[k];
  for (const v of Object.values(res)) { if (Array.isArray(v) && v.length && typeof v[0] === "object") return v; if (v && typeof v === "object") { const inner = firstArray(v); if (inner.length) return inner; } }
  return [];
}
const trim = (v: unknown) => { const s = JSON.stringify(v) || ""; return s.length > 1500 ? s.slice(0, 1500) + "…" : v; };
/** Try the two reading endpoints the community has seen; return the raw rows and which endpoint answered. */
async function readings(base: string, s: { token: string; accountId: string; terminalId: string }, dev: any) {
  const mobileId = String(1_000_000_000_000_000 + Math.floor(Math.random() * 9_000_000_000_000_000));
  const now = Date.now(), ids = { cid: dev.cid, uuid: dev.uuid, configModule: dev.configModule, deviceId: dev.cid, macID: dev.macID };
  // Parameter shapes to try, in order. The first that returns rows wins; every answer is reported so the right one can be found.
  const tries: { label: string; path: string; body: Record<string, unknown> }[] = [
    { label: "v2 configModule", path: "/cloud/v2/deviceManaged/getWeighingDataV2", body: { method: "getWeighingDataV2", configModule: dev.configModule, mobileId, pageSize: 100, page: 1, debugMode: false, allData: true } },
    { label: "v2 +ids", path: "/cloud/v2/deviceManaged/getWeighingDataV2", body: { method: "getWeighingDataV2", ...ids, mobileId, pageSize: 100, page: 1, debugMode: false, allData: true } },
    { label: "v2 +time", path: "/cloud/v2/deviceManaged/getWeighingDataV2", body: { method: "getWeighingDataV2", ...ids, mobileId, pageSize: 100, page: 1, debugMode: false, allData: false, startTime: 0, endTime: now, subUserID: 0 } },
    { label: "fatScale ids", path: "/cloud/v1/deviceManaged/fatScale/getWeighData", body: { method: "getWeighData", ...ids, mobileId } },
    { label: "fatScale paged", path: "/cloud/v1/deviceManaged/fatScale/getWeighData", body: { method: "getWeighData", ...ids, mobileId, page: 1, pageSize: 100 } },
    { label: "fatScale time", path: "/cloud/v1/deviceManaged/fatScale/getWeighData", body: { method: "getWeighData", ...ids, mobileId, startTime: 0, endTime: now, subUserID: 0 } },
    { label: "fatScale minimal", path: "/cloud/v1/deviceManaged/fatScale/getWeighData", body: { method: "getWeighData", configModule: dev.configModule, uuid: dev.uuid } },
    { label: "fatScale seconds", path: "/cloud/v1/deviceManaged/fatScale/getWeighData", body: { method: "getWeighData", ...ids, startTime: 0, endTime: Math.floor(now / 1000), page: 1, pageSize: 100, allData: true } },
    { label: "v1 getWeighingData", path: "/cloud/v1/deviceManaged/getWeighingData", body: { method: "getWeighingData", ...ids, mobileId, pageSize: 100, page: 1, allData: true } },
    { label: "v2 subUsers", path: "/cloud/v2/deviceManaged/getSubUsers", body: { method: "getSubUsers", ...ids, mobileId } },
  ];
  const report: unknown[] = [];
  for (const t of tries) {
    const r = await post(base, t.path, { ...session(s), ...t.body }, legacyHeaders(s));
    if (expired(r)) throw new Error("expired");
    const rows = r.code === 0 && r.result ? firstArray(r.result) : [];
    report.push({ [t.label]: `${r.code} ${r.msg || ""}${r.code === 0 ? ` · ${JSON.stringify(trim(r.result)).slice(0, 160)}` : ""}` });
    if (rows.length && !/subUsers/.test(t.label)) return { rows, from: t.label, raw: report };
  }
  return { rows: [], from: "none", raw: report };
}

const n = (v: unknown) => { const x = Number(v); return isFinite(x) ? x : null; };
/** Scale a raw number into a plausible range (VeSync sends grams, x10, x100 depending on the field/generation). */
function fit(v: number | null, lo: number, hi: number) { if (v == null) return null; for (const d of [1, 10, 100, 1000]) { const x = v / d; if (x >= lo && x <= hi) return Math.round(x * 10) / 10; } return null; }
const pick = (row: any, keys: string[]) => { for (const k of keys) if (row[k] != null) return n(row[k]); return null; };
function toMetrics(row: any) {
  const kg = fit(pick(row, ["weightG", "weight", "weightKg"]), 20, 400);
  const out: Record<string, number> = {};
  if (kg != null) out.weight = kg;
  const fat = fit(pick(row, ["bodyFat", "fat", "fatRate", "bodyFatRate", "bodyFatPercentage"]), 3, 70); if (fat != null) out.fat = fat;
  const muscle = fit(pick(row, ["muscle", "muscleMass", "muscleKg", "skeletalMuscle"]), 10, 120); if (muscle != null) out.muscle = muscle;
  const water = fit(pick(row, ["water", "bodyWater", "waterRate", "bodyWaterRate"]), 30, 80); if (water != null) out.water = water;
  const bone = fit(pick(row, ["bone", "boneMass", "boneKg"]), 1, 10); if (bone != null) out.bone = bone;
  const visceral = fit(pick(row, ["visceralFat", "visceral", "visceralFatLevel"]), 1, 60); if (visceral != null) out.visceral = visceral;
  const bmr = fit(pick(row, ["bmr", "basalMetabolism", "basalMetabolicRate"]), 600, 4000); if (bmr != null) out.bmr = Math.round(bmr);
  const age = fit(pick(row, ["bodyAge", "metabolicAge", "physicalAge"]), 10, 100); if (age != null) out.age = Math.round(age);
  const bmi = fit(pick(row, ["bmi", "BMI"]), 10, 60); if (bmi != null) out.bmi = bmi;
  return out;
}
function dayOf(row: any) {
  const t = n(row.timestamp ?? row.time ?? row.createTime ?? row.weighTime);
  if (t == null) return null;
  const ms = t > 1e12 ? t : t * 1000;
  return new Date(ms + 10 * 3600 * 1000).toISOString().slice(0, 10);   // Sydney-ish day boundary
}

Deno.serve(async (req) => {
  try { return await handle(req); } catch (e) { return json({ error: `Function error: ${(e as Error).message}` }, 500); }
});

async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const user = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } } });
  const { data: { user: me } } = await user.auth.getUser();
  if (!me) return json({ error: "Sign in to use this" }, 401);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let body: any = {}; try { body = await req.json(); } catch {}
  const action = String(body.action || "");

  if (action === "status") {
    const { data } = await admin.from("vesync_links").select("device_name, region, last_sync, last_count, last_keys").eq("user_id", me.id).maybeSingle();
    return json({ linked: !!data, ...(data || {}) });   // region shown in the app
  }
  if (action === "disconnect") { await admin.from("vesync_links").delete().eq("user_id", me.id); return json({ ok: true }); }

  if (action === "connect") {
    const email = String(body.email || "").trim(), password = String(body.password || "");
    if (!email || !password) return json({ error: "Email and password needed" }, 400);
    const terminalId = globalThis.crypto.randomUUID();
    // Australia (and everywhere outside US/CA/MX/JP) is served from VeSync's EU cluster; the login hops if it's wrong anyway
    const country = String(body.country || "AU").toUpperCase();
    const startRegion = body.region && BASES[body.region] ? body.region : (["US", "CA", "MX", "JP"].includes(country) ? "US" : "EU");
    try {
      const s = { ...(await login(startRegion, country, email, password, terminalId)), terminalId };
      const list = await devices(BASES[s.region], s);
      const scale = list.find(isScale) || null;
      await admin.from("vesync_links").upsert({ user_id: me.id, region: s.region, token: s.token, account_id: s.accountId, terminal_id: terminalId, device: scale, device_name: scale ? (scale.deviceName || scale.deviceType) : null, updated_at: new Date().toISOString() }, { onConflict: "user_id" });
      return json({ ok: true, region: s.region, device: scale ? { name: scale.deviceName, type: scale.deviceType, model: scale.configModule } : null, devices: list.map((d) => `${d.deviceName || "?"} (${d.deviceType || "?"})`) });
    } catch (e) { return json({ error: (e as Error).message || "Couldn't log in to VeSync" }, 400); }
  }

  if (action === "sync") {
    const { data: link } = await admin.from("vesync_links").select("*").eq("user_id", me.id).maybeSingle();
    if (!link) return json({ error: "Not linked" }, 400);
    if (!link.device) return json({ error: "No scale found on that VeSync account. Weigh in with the VeSync app once, then reconnect." }, 400);
    const s = { token: link.token, accountId: link.account_id, terminalId: link.terminal_id };
    // The account's own server first, then the other one: accounts moved between regions can keep data on either
    const order = [link.region in BASES ? link.region : "EU", ...Object.keys(BASES).filter((r) => r !== link.region)];
    let got: any = null; const tried: unknown[] = [];
    for (const region of order) {
      try { const g = await readings(BASES[region], s, link.device); tried.push({ [region]: g.raw }); if (g.rows.length) { got = { ...g, from: `${region} · ${g.from}` }; break; } }
      catch (e) { if ((e as Error).message === "expired" && region === order[0]) { await admin.from("vesync_links").delete().eq("user_id", me.id); return json({ error: "VeSync signed you out; connect again" }, 401); } tried.push({ [region]: (e as Error).message }); }
    }
    if (!got) got = { rows: [], from: "none", raw: tried };
    const byDay: Record<string, Record<string, number>> = {};
    for (const row of got.rows) { const day = dayOf(row); if (!day) continue; const m = toMetrics(row); if (!Object.keys(m).length) continue; byDay[day] = { ...(byDay[day] || {}), ...m }; }
    const days = Object.keys(byDay).sort();
    const upserts = days.map((day) => ({ user_id: me.id, day, ...byDay[day], updated_at: new Date().toISOString() }));
    if (upserts.length) { const { error } = await admin.from("body_metrics").upsert(upserts, { onConflict: "user_id,day" }); if (error) return json({ error: error.message }, 500); }
    const keys = got.rows[0] ? Object.keys(got.rows[0]) : [];
    await admin.from("vesync_links").update({ last_sync: new Date().toISOString(), last_count: got.rows.length, last_keys: keys }).eq("user_id", me.id);
    return json({ ok: true, from: got.from, readings: got.rows.length, days: days.length, latest: days.length ? { day: days[days.length - 1], ...byDay[days[days.length - 1]] } : null, keys, sample: got.rows[0] || null, raw: got.rows.length ? undefined : got.raw });
  }
  return json({ error: "Unknown action" }, 400);
}
