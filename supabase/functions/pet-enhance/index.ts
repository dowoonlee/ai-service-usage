// POST /pet-enhance
// 펫 강화(도박) — 서버 authoritative. 강화 레벨은 pet_enhancements 가 SSOT이고 서버 crypto RNG로만
// 변동한다. VP 지출도 서버가 검증(기획 §2-9).
//
// 가용 VP = users.total_coins + Σ reward_grants('vp') − Σ pet_enhancements.spent_vp − enhance_items.spent_vp
//
// action:
//   "state"   — 가용 VP + 펫 강화 레벨 + 완화 아이템 수 + 진행 중 이벤트 반환.
//   "enhance" — kind 1회 강화. safe(안전)/useProtect(보호권)/useGuarantee(확정권) 반영 + 이벤트 할인.
//   "buy"     — 완화 아이템(protect/guarantee) VP 구매(sink).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { RARITY } from "../_shared/pet_meta_gen.ts";
import { rarityOf } from "../_shared/pvp_policy.ts";
import {
  SeededRNG, canEnhance, cost, roll, apply,
  canSafeEnhance, safeCost, rollSafe,
  PROTECT_PRICE_VP, GUARANTEE_PRICE_VP,
} from "../_shared/enhance_engine.ts";

interface EnhancePayload {
  action: string;          // "state" | "enhance" | "buy"
  deviceId: string;
  kind?: string;           // enhance: PetKind rawValue
  safe?: boolean;          // enhance: 안전 강화
  useProtect?: boolean;    // enhance: 보호권 사용
  useGuarantee?: boolean;  // enhance: 확정권 사용
  item?: string;           // buy: "protect" | "guarantee"
  ts: number;
}

const MAX_CLOCK_SKEW_SEC = 3600;

function cryptoU64(): bigint {
  const b = crypto.getRandomValues(new Uint8Array(8));
  let v = 0n;
  for (const x of b) v = (v << 8n) | BigInt(x);
  return v;
}

// 강화 이벤트 — KST 주말이면 VP 할인. (확률/파괴는 안 건드림 → 파리티 무관.)
function currentEvent(): { active: boolean; discount: number; label: string } {
  const kst = new Date(Date.now() + 9 * 3600 * 1000);
  const day = kst.getUTCDay();   // 0=일 … 6=토 (KST 벽시계)
  if (day === 0 || day === 6) return { active: true, discount: 0.20, label: "주말 강화 이벤트 — VP 20% 할인" };
  return { active: false, discount: 0, label: "" };
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: { payload: EnhancePayload; signature: string };
  try { body = await req.json(); } catch { return errorResponse(400, "invalid_json"); }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (p.action !== "state" && p.action !== "enhance" && p.action !== "buy") return errorResponse(400, "invalid_action");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_payload_types");
  if (typeof body.signature !== "string" || body.signature.length !== 64) return errorResponse(400, "invalid_signature");
  if (Math.abs(Math.floor(Date.now() / 1000) - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  if (p.action === "enhance") {
    if (typeof p.kind !== "string" || !(p.kind in RARITY)) return errorResponse(400, "invalid_kind");
    for (const f of [p.safe, p.useProtect, p.useGuarantee]) {
      if (f !== undefined && typeof f !== "boolean") return errorResponse(400, "invalid_payload_types");
    }
  }
  if (p.action === "buy") {
    if (p.item !== "protect" && p.item !== "guarantee") return errorResponse(400, "invalid_item");
  }

  const db = getDb();

  const { data: user, error: userErr } = await db
    .from("users").select("device_id, hmac_key_b64, status, total_coins").eq("device_id", p.deviceId).single();
  if (userErr || !user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  let hmacPayload: Record<string, unknown>;
  if (p.action === "enhance") {
    hmacPayload = {
      action: p.action, deviceId: p.deviceId, kind: p.kind, safe: p.safe === true,
      useProtect: p.useProtect === true, useGuarantee: p.useGuarantee === true, ts: p.ts,
    };
  } else if (p.action === "buy") {
    hmacPayload = { action: p.action, deviceId: p.deviceId, item: p.item, ts: p.ts };
  } else {
    hmacPayload = { action: p.action, deviceId: p.deviceId, ts: p.ts };
  }
  const ok = await verifyHmac(hmacPayload, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  // 가용 VP 산출.
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

  const { data: itemRow } = await db
    .from("enhance_items").select("protect_count, guarantee_count, spent_vp").eq("device_id", p.deviceId).maybeSingle();
  const protectCount = itemRow ? Number(itemRow.protect_count) : 0;
  const guaranteeCount = itemRow ? Number(itemRow.guarantee_count) : 0;
  const itemSpent = itemRow ? Number(itemRow.spent_vp) : 0;

  const availableVp = totalCoins + grantedVp - spentTotal - itemSpent;
  const event = currentEvent();
  const nowIso = new Date().toISOString();

  // ---- action: state ----
  if (p.action === "state") {
    const levels: Record<string, number> = {};
    for (const e of rows) levels[e.kind as string] = Number(e.level);
    return jsonResponse({
      availableVp, totalCoins, grantedVp, spentVp: spentTotal + itemSpent, levels,
      protectCount, guaranteeCount,
      protectPrice: PROTECT_PRICE_VP, guaranteePrice: GUARANTEE_PRICE_VP,
      eventActive: event.active, eventDiscount: event.discount, eventLabel: event.label,
    });
  }

  // ---- action: buy ----
  if (p.action === "buy") {
    const price = p.item === "protect" ? PROTECT_PRICE_VP : GUARANTEE_PRICE_VP;
    if (availableVp < price) return errorResponse(409, "insufficient_vp");
    const newProtect = protectCount + (p.item === "protect" ? 1 : 0);
    const newGuarantee = guaranteeCount + (p.item === "guarantee" ? 1 : 0);
    const { error: buyErr } = await db.from("enhance_items").upsert({
      device_id: p.deviceId, protect_count: newProtect, guarantee_count: newGuarantee,
      spent_vp: itemSpent + price, updated_at: nowIso,
    });
    if (buyErr) { console.error("buy failed", buyErr); return errorResponse(500, "buy_failed"); }
    return jsonResponse({
      item: p.item, protectCount: newProtect, guaranteeCount: newGuarantee, availableVp: availableVp - price,
    });
  }

  // ---- action: enhance ----
  const kind = p.kind as string;
  const cur = rows.find((e) => e.kind === kind);
  const beforeLevel = cur ? Number(cur.level) : 0;
  const beforeSpent = cur ? Number(cur.spent_vp) : 0;
  const beforeStreak = cur ? Number(cur.fail_streak ?? 0) : 0;

  if (!canEnhance(beforeLevel)) return errorResponse(409, "max_level");
  const safe = p.safe === true;
  if (safe && !canSafeEnhance(beforeLevel)) return errorResponse(409, "safe_unavailable");
  const useGuarantee = p.useGuarantee === true && guaranteeCount > 0;
  const useProtect = p.useProtect === true && protectCount > 0;

  const rarity = rarityOf(kind);
  const baseCost = safe ? safeCost(beforeLevel, rarity) : cost(beforeLevel, rarity);
  const attemptCost = Math.round(baseCost * (1 - event.discount));   // 이벤트 VP 할인
  if (availableVp < attemptCost) return errorResponse(409, "insufficient_vp");

  // 결과 확정: 확정권이면 RNG 우회 확정 성공. 아니면 롤 후, 파괴 시 보호권 있으면 유지로 전환.
  let outcome: string;
  let guaranteeUsed = false, protectUsed = false;
  if (useGuarantee) {
    outcome = "success";
    guaranteeUsed = true;
  } else {
    const rng = new SeededRNG(cryptoU64());
    outcome = safe ? rollSafe(beforeLevel, beforeStreak, rng) : roll(beforeLevel, rng);
    if (outcome === "destroy" && useProtect) { outcome = "stay"; protectUsed = true; }
  }
  const newLevel = apply(beforeLevel, outcome as "success" | "stay" | "downgrade" | "destroy");
  const newSpent = beforeSpent + attemptCost;
  const newStreak = outcome === "success" ? 0 : beforeStreak + 1;

  // 낙관적 동시성 — level 조건부 갱신.
  if (cur) {
    const { data: upd, error: updErr } = await db.from("pet_enhancements")
      .update({ level: newLevel, spent_vp: newSpent, fail_streak: newStreak, updated_at: nowIso })
      .eq("device_id", p.deviceId).eq("kind", kind).eq("level", beforeLevel).select("kind");
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

  // 소비된 아이템 차감.
  const newProtect = protectCount - (protectUsed ? 1 : 0);
  const newGuarantee = guaranteeCount - (guaranteeUsed ? 1 : 0);
  if (protectUsed || guaranteeUsed) {
    await db.from("enhance_items").upsert({
      device_id: p.deviceId, protect_count: newProtect, guarantee_count: newGuarantee,
      spent_vp: itemSpent, updated_at: nowIso,
    });
  }

  return jsonResponse({
    outcome, beforeLevel, newLevel, cost: attemptCost,
    availableVp: availableVp - attemptCost, failStreak: newStreak,
    protectUsed, guaranteeUsed, protectCount: newProtect, guaranteeCount: newGuarantee,
  });
});
