// Cheat Days <-> VeSync (Etekcity) link. Signed-in users connect their VeSync account once; this function logs in with
// the same protocol the VeSync app uses (unofficial: the same one pyvesync / Home Assistant use), keeps ONLY the session
// token (never the password), finds the scale, and on "sync" pulls the readings into body_metrics.
// Deploy: Supabase dashboard -> Edge Functions -> Deploy a new function -> name it "vesync", paste this, Deploy.
// Keep "Verify JWT" ON: the app calls it with the user's own login. Needs a vesync_links table (SQL in the README).
import { createClient } from "npm:@supabase/supabase-js@2";
import { crypto } from "jsr:@std/crypto@1";
import { encodeHex } from "jsr:@std/encoding@1/hex";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (obj: unknown, status = 200) => new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });

const BASES: Record<string, string> = { US: "https://smartapi.vesync.com", EU: "https://smartapi.vesync.eu" };
const APP_VERSION = "5.6.60", CLIENT_VERSION = `VeSync ${APP_VERSION}`, APP_ID = "eldodkfj", CLIENT_TYPE = "vesyncApp";
const PHONE_BRAND = "CheatDays", PHONE_OS = "iOS", LANG = "en", TZ = "Australia/Sydney";
let traceN = 0;
const traceId = (terminalId: string) => `APP${terminalId.replace(/-/g, "").slice(-4)}${Math.floor(Date.now() / 1000)}-${String(++traceN).padStart(5, "0")}`;
const md5 = async (s: string) => encodeHex(await crypto.subtle.digest("MD5", new TextEncoder().encode(s)));

type Resp = { code?: number; msg?: string; result?: any };
async function post(base: string, path: string, body: Record<string, unknown>, headers: Record<string, string> = {}): Promise<Resp> {
  const r = await fetch(base + path, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body) });
  try { return await r.json(); } catch { return { code: -1, msg: `HTTP ${r.status}` }; }
}
const expired = (r: Resp) => r.code === -11201022 || r.code === -11012022;

async function login(base: string, country: string, email: string, password: string, terminalId: string) {
  const hashed = await md5(password);
  const common = { acceptLanguage: LANG, accountID: "", clientInfo: PHONE_BRAND, clientType: CLIENT_TYPE, clientVersion: CLIENT_VERSION, debugMode: false, osInfo: PHONE_OS, terminalId, timeZone: TZ, token: "", userCountryCode: country };
  const a = await post(base, "/globalPlatform/api/accountAuth/v1/authByPWDOrOTM", { ...common, email, method: "authByPWDOrOTM", password: hashed, authProtocolType: "generic", appID: APP_ID, sourceAppID: APP_ID, traceId: traceId(terminalId) });
  if (a.code !== 0 || !a.result) throw new Error(a.msg || `VeSync login failed (${a.code})`);
  const b = await post(base, "/user/api/accountManage/v1/loginByAuthorizeCode4Vesync", { ...common, method: "loginByAuthorizeCode4Vesync", authorizeCode: a.result.authorizeCode, emailSubscriptions: false, traceId: traceId(terminalId) });
  if (b.code !== 0 || !b.result) throw new Error(b.msg || `VeSync login failed (${b.code})`);
  return { token: b.result.token as string, accountId: b.result.accountID as string };
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

/** Try the two reading endpoints the community has seen; return the raw rows and which endpoint answered. */
async function readings(base: string, s: { token: string; accountId: string; terminalId: string }, dev: any) {
  const mobileId = String(1_000_000_000_000_000 + Math.floor(Math.random() * 9_000_000_000_000_000));
  const v2 = await post(base, "/cloud/v2/deviceManaged/getWeighingDataV2", { ...session(s), method: "getWeighingDataV2", configModule: dev.configModule, mobileId, pageSize: 100, page: 1, debugMode: false, allData: true }, legacyHeaders(s));
  if (expired(v2)) throw new Error("expired");
  if (v2.code === 0 && v2.result) { const rows = v2.result.weightDatas || v2.result.items || v2.result.list || []; if (rows.length) return { rows, from: "getWeighingDataV2", raw: v2.result }; }
  const fs = await post(base, "/cloud/v1/deviceManaged/fatScale/getWeighData", { ...session(s), method: "getWeighData", cid: dev.cid, uuid: dev.uuid, configModule: dev.configModule, mobileId }, legacyHeaders(s));
  if (expired(fs)) throw new Error("expired");
  if (fs.code === 0 && fs.result) { const rows = fs.result.weightDatas || fs.result.items || fs.result.list || []; return { rows, from: "fatScale/getWeighData", raw: fs.result }; }
  return { rows: [], from: "none", raw: { v2: { code: v2.code, msg: v2.msg }, fatScale: { code: fs.code, msg: fs.msg } } };
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
    return json({ linked: !!data, ...(data || {}) });
  }
  if (action === "disconnect") { await admin.from("vesync_links").delete().eq("user_id", me.id); return json({ ok: true }); }

  if (action === "connect") {
    const email = String(body.email || "").trim(), password = String(body.password || "");
    if (!email || !password) return json({ error: "Email and password needed" }, 400);
    const terminalId = crypto.randomUUID();
    const tries = body.region && BASES[body.region] ? [[body.region, body.country || body.region]] : [["US", body.country || "AU"], ["EU", body.country || "AU"], ["US", "US"]];
    let last = "";
    for (const [region, country] of tries) {
      try {
        const s = { ...(await login(BASES[region], country, email, password, terminalId)), terminalId };
        const list = await devices(BASES[region], s);
        const scale = list.find(isScale) || null;
        await admin.from("vesync_links").upsert({ user_id: me.id, region, token: s.token, account_id: s.accountId, terminal_id: terminalId, device: scale, device_name: scale ? (scale.deviceName || scale.deviceType) : null, updated_at: new Date().toISOString() }, { onConflict: "user_id" });
        return json({ ok: true, region, device: scale ? { name: scale.deviceName, type: scale.deviceType, model: scale.configModule } : null, devices: list.map((d) => `${d.deviceName || "?"} (${d.deviceType || "?"})`) });
      } catch (e) { last = (e as Error).message; if (/password|account|not exist|incorrect/i.test(last)) break; }
    }
    return json({ error: last || "Couldn't log in to VeSync" }, 400);
  }

  if (action === "sync") {
    const { data: link } = await admin.from("vesync_links").select("*").eq("user_id", me.id).maybeSingle();
    if (!link) return json({ error: "Not linked" }, 400);
    if (!link.device) return json({ error: "No scale found on that VeSync account. Weigh in with the VeSync app once, then reconnect." }, 400);
    const base = BASES[link.region] || BASES.US, s = { token: link.token, accountId: link.account_id, terminalId: link.terminal_id };
    let got;
    try { got = await readings(base, s, link.device); }
    catch (e) { if ((e as Error).message === "expired") { await admin.from("vesync_links").delete().eq("user_id", me.id); return json({ error: "VeSync signed you out; connect again" }, 401); } return json({ error: (e as Error).message }, 500); }
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
});
