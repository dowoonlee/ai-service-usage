// POST /pvp-register-team
// 배틀 팀 스냅샷 등록/갱신 (기획 §2-6). 등록된 팀은 다른 유저의 도전 상대(고스트 방어 대상)가 된다.
//
// 클라는 [{kind, variant, progressUnits}] ×≤3 (리드 순서)를 보낸다. 서버가 각 kind의 강화 레벨을
// pet_enhancements(SSOT)에서 조회해 스냅샷 [{kind, variant, enhanceLevel, progressUnits}]로 동결하고
// power(시너지·강화 포함 총 전투력)를 재계산해 저장한다. 강화 레벨을 클라가 못 실으니 스탯 위조 불가.
// variant/progressUnits는 저상한 로컬 축이라 서버가 클램프만 한다(§2-9).
//
// HMAC: flat payload {action, deviceId, teamJson, ts} canonicalize.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { RARITY } from "../_shared/pet_meta_gen.ts";
import { OVERFLOW_START_UNITS } from "../_shared/pvp_policy.ts";
import { finalStats, BattleTeam } from "../_shared/battle_engine.ts";

interface RegisterPayload {
  action: string;    // "register"
  deviceId: string;
  teamJson: string;  // JSON: [{kind, variant, progressUnits}] 리드 순서
  ts: number;
}

const MAX_CLOCK_SKEW_SEC = 3600;
const MAX_TEAM = 5;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: { payload: RegisterPayload; signature: string };
  try { body = await req.json(); } catch { return errorResponse(400, "invalid_json"); }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (p.action !== "register") return errorResponse(400, "invalid_action");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.teamJson !== "string" || p.teamJson.length > 2000) return errorResponse(400, "invalid_team");
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_payload_types");
  if (typeof body.signature !== "string" || body.signature.length !== 64) return errorResponse(400, "invalid_signature");
  if (Math.abs(Math.floor(Date.now() / 1000) - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  // 팀 파싱·검증.
  let raw: unknown;
  try { raw = JSON.parse(p.teamJson); } catch { return errorResponse(400, "invalid_team"); }
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > MAX_TEAM) return errorResponse(400, "invalid_team_size");
  const members: { kind: string; variant: number; progressUnits: number }[] = [];
  const seen = new Set<string>();
  for (const m of raw as Record<string, unknown>[]) {
    const kind = String(m?.kind ?? "");
    if (!(kind in RARITY)) return errorResponse(400, "invalid_kind");
    if (seen.has(kind)) return errorResponse(400, "duplicate_kind");   // 종 유니크
    seen.add(kind);
    const variant = Math.min(4, Math.max(0, Math.floor(Number(m?.variant ?? 0))));
    const progressUnits = Math.min(OVERFLOW_START_UNITS, Math.max(0, Number(m?.progressUnits ?? 0)));
    members.push({ kind, variant, progressUnits });
  }

  const db = getDb();

  // HMAC 검증.
  const { data: user, error: userErr } = await db
    .from("users").select("device_id, hmac_key_b64, status, tenant_id").eq("device_id", p.deviceId).single();
  if (userErr || !user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");
  const ok = await verifyHmac(
    { action: p.action, deviceId: p.deviceId, teamJson: p.teamJson, ts: p.ts }, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  // 강화 레벨을 pet_enhancements에서 조회해 스냅샷 동결.
  const { data: enh, error: enhErr } = await db
    .from("pet_enhancements").select("kind, level").eq("device_id", p.deviceId);
  if (enhErr) { console.error("enh fetch failed", enhErr); return errorResponse(500, "enh_read_failed"); }
  const levelOf = new Map<string, number>();
  for (const e of enh ?? []) levelOf.set(e.kind as string, Number(e.level));

  const snapshot = members.map((m) => ({
    kind: m.kind, variant: m.variant,
    enhanceLevel: levelOf.get(m.kind) ?? 0, progressUnits: m.progressUnits,
  }));

  // power = 시너지 포함 총 전투력.
  const team = snapshot as BattleTeam;
  const power = team.reduce((s, m) => {
    const st = finalStats(m, team);
    return s + st.hp + st.atk + st.def + st.spd;
  }, 0);

  const tenant = (user.tenant_id as string) ?? "public";
  const nowIso = new Date().toISOString();

  // 현재 레이팅(있으면 유지, 없으면 1000) — pvp_teams.rating 캐시에 미러.
  const { data: rateRow } = await db
    .from("pvp_ratings").select("rating").eq("device_id", p.deviceId).maybeSingle();
  const rating = rateRow ? Number(rateRow.rating) : 1000;

  // pvp_ratings 행 보장(신규면 1000).
  if (!rateRow) {
    await db.from("pvp_ratings").insert({ device_id: p.deviceId, tenant_id: tenant, rating: 1000 });
  }

  // pvp_teams upsert.
  const { error: upErr } = await db.from("pvp_teams").upsert({
    device_id: p.deviceId, tenant_id: tenant,
    team_json: snapshot, power, rating, updated_at: nowIso,
  });
  if (upErr) { console.error("pvp_teams upsert failed", upErr); return errorResponse(500, "register_failed"); }

  return jsonResponse({ power, rating, teamSize: snapshot.length });
});
