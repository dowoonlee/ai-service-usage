// POST /pet-enhance
// 펫 강화(도박) — 서버 authoritative. 조작 방지의 축(기획 §2-9): 강화 레벨은 pet_enhancements 가
// SSOT이고 서버 crypto RNG로만 변동한다. VP 지출도 서버가 검증 → 실제로 번 VP만큼만 강화 가능.
//
// 가용 VP = users.total_coins(제출 VP) + Σ reward_grants(currency='vp') − Σ pet_enhancements.spent_vp
//   (지급 VP는 claimed 여부와 무관하게 서버 가용에 즉시 반영 — 가용은 순수 서버 파생값.)
//
// HMAC: daily-quiz 와 동일 골격. flat payload canonicalize → device hmac_key_b64 verify.
//
// action:
//   "state"   — 가용 VP + 내 모든 펫 강화 레벨 반환(강화소 진입 시).
//   "enhance" — kind 1회 강화 시도: 가용 검증 → 비용 차감(spent_vp) → 서버 RNG 롤 → level 갱신.
//               결과(성공/유지/강등/파괴)·전후 레벨·차감 비용·잔여 가용 VP 반환. 클라는 연출만.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { RARITY } from "../_shared/pet_meta_gen.ts";
import { rarityOf } from "../_shared/pvp_policy.ts";
import { SeededRNG, canEnhance, cost, roll, apply } from "../_shared/enhance_engine.ts";

interface EnhancePayload {
  action: string;      // "state" | "enhance"
  deviceId: string;
  kind?: string;       // enhance 전용: PetKind rawValue
  ts: number;
}
interface EnhanceRequest {
  payload: EnhancePayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

// 8바이트 crypto 난수 → 64비트 시드. SplitMix64 첫 출력은 잘 섞여 단발 롤에 충분.
function cryptoU64(): bigint {
  const b = crypto.getRandomValues(new Uint8Array(8));
  let v = 0n;
  for (const x of b) v = (v << 8n) | BigInt(x);
  return v;
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: EnhanceRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (p.action !== "state" && p.action !== "enhance") return errorResponse(400, "invalid_action");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_payload_types");
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  if (p.action === "enhance") {
    if (typeof p.kind !== "string" || !(p.kind in RARITY)) return errorResponse(400, "invalid_kind");
  }

  const db = getDb();

  // HMAC 검증 — device hmac_key_b64. 서명 payload 는 action별로 필드 고정.
  const { data: user, error: userErr } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status, total_coins")
    .eq("device_id", p.deviceId)
    .single();
  if (userErr || !user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const hmacPayload: Record<string, unknown> = p.action === "enhance"
    ? { action: p.action, deviceId: p.deviceId, kind: p.kind, ts: p.ts }
    : { action: p.action, deviceId: p.deviceId, ts: p.ts };
  const ok = await verifyHmac(hmacPayload, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  // 가용 VP 산출 (순수 서버 파생) — 세 소스 합산.
  const totalCoins = Number(user.total_coins ?? 0);
  const { data: grants, error: grantErr } = await db
    .from("reward_grants").select("amount").eq("device_id", p.deviceId).eq("currency", "vp");
  if (grantErr) { console.error("vp grants fetch failed", grantErr); return errorResponse(500, "vp_read_failed"); }
  const grantedVp = (grants ?? []).reduce((s, g) => s + Number(g.amount), 0);

  const { data: enh, error: enhErr } = await db
    .from("pet_enhancements").select("kind, level, spent_vp, fail_streak").eq("device_id", p.deviceId);
  if (enhErr) { console.error("enhancements fetch failed", enhErr); return errorResponse(500, "enh_read_failed"); }
  const rows = enh ?? [];
  const spentTotal = rows.reduce((s, e) => s + Number(e.spent_vp), 0);
  const availableVp = totalCoins + grantedVp - spentTotal;

  // ---- action: state ----
  if (p.action === "state") {
    const levels: Record<string, number> = {};
    for (const e of rows) levels[e.kind as string] = Number(e.level);
    return jsonResponse({ availableVp, totalCoins, grantedVp, spentVp: spentTotal, levels });
  }

  // ---- action: enhance ----
  const kind = p.kind as string;
  const cur = rows.find((e) => e.kind === kind);
  const beforeLevel = cur ? Number(cur.level) : 0;
  const beforeSpent = cur ? Number(cur.spent_vp) : 0;
  const beforeStreak = cur ? Number(cur.fail_streak ?? 0) : 0;

  if (!canEnhance(beforeLevel)) return errorResponse(409, "max_level");
  const rarity = rarityOf(kind);
  const attemptCost = cost(beforeLevel, rarity);
  if (availableVp < attemptCost) return errorResponse(409, "insufficient_vp");

  // 서버 crypto RNG 롤 → 결과 확정. 확률·적용은 enhance_engine(클라 미러) 규칙.
  const rng = new SeededRNG(cryptoU64());
  const outcome = roll(beforeLevel, rng);
  const newLevel = apply(beforeLevel, outcome);
  const newSpent = beforeSpent + attemptCost;
  const newStreak = outcome === "success" ? 0 : beforeStreak + 1;  // soft-pity 카운터(T5)
  const nowIso = new Date().toISOString();

  // 낙관적 동시성 — level=beforeLevel 조건부 UPDATE(없으면 INSERT). 실패 시 아무것도 안 바뀜(VP 무손실).
  // (다른 kind 동시 강화로 가용이 살짝 스테일할 순 있으나 = 자기 과지출·bounded, 익스플로잇 아님.)
  if (cur) {
    const { data: upd, error: updErr } = await db.from("pet_enhancements")
      .update({ level: newLevel, spent_vp: newSpent, fail_streak: newStreak, updated_at: nowIso })
      .eq("device_id", p.deviceId).eq("kind", kind).eq("level", beforeLevel)
      .select("kind");
    if (updErr) { console.error("enhance update failed", updErr); return errorResponse(500, "persist_failed"); }
    if (!upd || upd.length === 0) return errorResponse(409, "concurrent_modification");
  } else {
    const { error: insErr } = await db.from("pet_enhancements")
      .insert({ device_id: p.deviceId, kind, level: newLevel, spent_vp: newSpent, fail_streak: newStreak });
    if (insErr) {
      if (insErr.code === "23505") return errorResponse(409, "concurrent_modification");
      console.error("enhance insert failed", insErr);
      return errorResponse(500, "persist_failed");
    }
  }

  return jsonResponse({
    outcome,                          // "success" | "stay" | "downgrade" | "destroy"
    beforeLevel,
    newLevel,
    cost: attemptCost,
    availableVp: availableVp - attemptCost,
    failStreak: newStreak,
  });
});
