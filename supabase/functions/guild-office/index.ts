// POST /guild-office
// 사무실 액션 묶음 (P1 스팟 + P2b 꾸미기):
//   set_spot     — 내 스팟 선택(0..11)/비우기(-1). 선착순 UNIQUE 위반 시 409 slot_taken.
//   place_decor  — 데코 슬롯(0..9)에 아이템 배치/교체 구매 (멤버 누구나 — 기부 모델).
//                  코인은 클라 로컬 경제라 서버는 기록만 (생성권과 동일 원칙, 기획 §2).
//   remove_decor — 데코 제거 (기부자 본인 또는 길드장).
//   set_theme    — 인테리어 테마 (길드장 전용). item="floor"|"wall", slot=테마 index.
//
// payload(서명 대상, flat — 액션 무관 고정 형태): { action, deviceId, item, slot, ts }
//   item은 place_decor(아이템 kind)/set_theme("floor"|"wall") 외에는 "".

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { OFFICE_SLOT_COUNT } from "../_shared/guild_policy.ts";

// 데코 슬롯 수 / 테마 범위 — 클라 카탈로그(OfficeLayout)와 쌍.
const DECOR_SLOT_COUNT = 10;
const FLOOR_THEME_MAX = 8;   // 2dPig floors 0..8
const WALL_THEME_MAX = 3;    // 틴트 변형 0..3

type OfficeAction = "set_spot" | "place_decor" | "remove_decor" | "set_theme";

interface OfficePayload {
  action: OfficeAction;
  deviceId: string;
  item: string;   // 액션별 의미 — 헤더 참조. 미사용이면 ""
  slot: number;
  ts: number;
}
interface OfficeRequest {
  payload: OfficePayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: OfficeRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (
    p.action !== "set_spot" && p.action !== "place_decor" &&
    p.action !== "remove_decor" && p.action !== "set_theme"
  ) {
    return errorResponse(400, "invalid_action");
  }
  if (typeof p.item !== "string" || p.item.length > 40) {
    return errorResponse(400, "invalid_item");
  }
  if (typeof p.slot !== "number" || !Number.isInteger(p.slot)) {
    return errorResponse(400, "invalid_slot");
  }
  // 액션별 slot 범위.
  const slotOk = (() => {
    switch (p.action) {
      case "set_spot": return p.slot >= -1 && p.slot < OFFICE_SLOT_COUNT;
      case "place_decor":
      case "remove_decor": return p.slot >= 0 && p.slot < DECOR_SLOT_COUNT;
      case "set_theme":
        return p.item === "floor"
          ? (p.slot >= 0 && p.slot <= FLOOR_THEME_MAX)
          : (p.slot >= 0 && p.slot <= WALL_THEME_MAX);
    }
  })();
  if (!slotOk) return errorResponse(400, "invalid_slot");
  if (p.action === "place_decor" && p.item.length === 0) {
    return errorResponse(400, "invalid_item");
  }
  if (p.action === "set_theme" && p.item !== "floor" && p.item !== "wall") {
    return errorResponse(400, "invalid_item");
  }
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");

  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) {
    return errorResponse(400, "clock_skew");
  }

  const deviceId = p.deviceId.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { action: p.action, deviceId: p.deviceId, item: p.item, slot: p.slot, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  const { data: membership } = await db
    .from("guild_members")
    .select("guild_id")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!membership) return errorResponse(404, "not_in_guild");
  const guildId = membership.guild_id;

  switch (p.action) {
    case "set_spot": {
      const newSlot = p.slot === -1 ? null : p.slot;
      const { error: updErr } = await db
        .from("guild_members")
        .update({ office_slot: newSlot })
        .eq("device_id", deviceId);
      if (updErr) {
        // partial UNIQUE(guild_id, office_slot) 위반 = 방금 다른 멤버가 선점.
        if (updErr.code === "23505") return errorResponse(409, "slot_taken");
        console.error("guild office set_spot failed", updErr);
        return errorResponse(500, "office_failed");
      }
      return jsonResponse({ ok: true, slot: newSlot });
    }

    case "place_decor": {
      // 교체 구매 = UPSERT (기존 아이템 소멸·환불 없음 — 기획 §2). 기부자 명판 갱신.
      const { error: upErr } = await db
        .from("guild_furniture")
        .upsert({
          guild_id: guildId,
          slot_id: p.slot,
          item_kind: p.item,
          purchased_by: deviceId,
          purchased_at: new Date().toISOString(),
        }, { onConflict: "guild_id,slot_id" });
      if (upErr) {
        console.error("guild office place_decor failed", upErr);
        return errorResponse(500, "office_failed");
      }
      return jsonResponse({ ok: true });
    }

    case "remove_decor": {
      const { data: row } = await db
        .from("guild_furniture")
        .select("slot_id, purchased_by")
        .eq("guild_id", guildId)
        .eq("slot_id", p.slot)
        .maybeSingle();
      if (!row) return errorResponse(404, "decor_not_found");
      // 제거 권한 — 기부자 본인 또는 길드장.
      if (row.purchased_by !== deviceId) {
        const { data: guild } = await db
          .from("guilds")
          .select("leader_device_id")
          .eq("id", guildId)
          .maybeSingle();
        if (!guild || guild.leader_device_id !== deviceId) {
          return errorResponse(403, "not_leader");
        }
      }
      const { error: delErr } = await db
        .from("guild_furniture")
        .delete()
        .eq("guild_id", guildId)
        .eq("slot_id", p.slot);
      if (delErr) {
        console.error("guild office remove_decor failed", delErr);
        return errorResponse(500, "office_failed");
      }
      return jsonResponse({ ok: true });
    }

    case "set_theme": {
      const { data: guild } = await db
        .from("guilds")
        .select("leader_device_id")
        .eq("id", guildId)
        .maybeSingle();
      if (!guild || guild.leader_device_id !== deviceId) {
        return errorResponse(403, "not_leader");
      }
      const patch = p.item === "floor" ? { floor_theme: p.slot } : { wall_theme: p.slot };
      const { error: updErr } = await db.from("guilds").update(patch).eq("id", guildId);
      if (updErr) {
        console.error("guild office set_theme failed", updErr);
        return errorResponse(500, "office_failed");
      }
      return jsonResponse({ ok: true });
    }
  }
});
