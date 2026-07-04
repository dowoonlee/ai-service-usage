// POST /guild-manage
// 길드장 전용 액션 묶음: kick(추방) / rotate_code(초대 코드 재발급) / disband(해체)
// / set_layout(가구 재배치). 1함수 1액션 관례의 의도적 예외 — 함수 수 억제 (docs/plans/guild.md §3).
//
// payload(서명 대상, flat): { action, deviceId, [layout,] targetDeviceId, ts }
//   - targetDeviceId는 kick에서만 의미. 나머지는 빈 문자열("").
//   - layout은 set_layout에서만 존재 — 클라이언트가 키 자체를 생략하므로 canonical 재현도
//     같은 조건으로 생략해야 서명이 일치한다.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import {
  generateInviteCode,
  JOIN_COOLDOWN_SEC,
  OFFICE_SLOT_COUNT,
} from "../_shared/guild_policy.ts";

type ManageAction = "kick" | "rotate_code" | "disband" | "set_layout";

interface ManagePayload {
  action: ManageAction;
  deviceId: string;
  targetDeviceId: string; // kick 외에는 ""
  // set_layout 전용 — "3,1,0,…" (포지션 순서대로 가구 세트 id, 0..11 순열).
  layout?: string;
  ts: number;
}
interface ManageRequest {
  payload: ManagePayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: ManageRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (
    p.action !== "kick" && p.action !== "rotate_code" && p.action !== "disband" &&
    p.action !== "set_layout"
  ) {
    return errorResponse(400, "invalid_action");
  }
  if (typeof p.targetDeviceId !== "string") return errorResponse(400, "invalid_target");
  if (p.action === "kick" && !isValidUUID(p.targetDeviceId)) {
    return errorResponse(400, "invalid_target");
  }
  // set_layout: 0..OFFICE_SLOT_COUNT-1 순열 검증.
  let layoutInts: number[] | null = null;
  if (p.action === "set_layout") {
    if (typeof p.layout !== "string") return errorResponse(400, "invalid_layout");
    layoutInts = p.layout.split(",").map((s) => Number(s.trim()));
    if (
      layoutInts.length !== OFFICE_SLOT_COUNT ||
      layoutInts.some((n) => !Number.isInteger(n)) ||
      [...layoutInts].sort((a, b) => a - b).some((n, i) => n !== i)
    ) {
      return errorResponse(400, "invalid_layout");
    }
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

  // layout 키는 클라이언트가 set_layout일 때만 직렬화 — canonical 재현도 동일 조건.
  const verifyObj: Record<string, unknown> = {
    action: p.action,
    deviceId: p.deviceId,
    targetDeviceId: p.targetDeviceId,
    ts: p.ts,
  };
  if (typeof p.layout === "string") verifyObj.layout = p.layout;
  const ok = await verifyHmac(verifyObj, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  // 길드장 검증 — 내 길드 조회 후 leader 일치 확인.
  const { data: membership } = await db
    .from("guild_members")
    .select("guild_id")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!membership) return errorResponse(404, "not_in_guild");

  const { data: guild } = await db
    .from("guilds")
    .select("id, leader_device_id")
    .eq("id", membership.guild_id)
    .maybeSingle();
  if (!guild) return errorResponse(404, "guild_not_found");
  if (guild.leader_device_id !== deviceId) return errorResponse(403, "not_leader");

  switch (p.action) {
    case "kick": {
      const target = p.targetDeviceId.toLowerCase();
      if (target === deviceId) return errorResponse(400, "cannot_kick_self");
      const { data: targetRow } = await db
        .from("guild_members")
        .select("device_id")
        .eq("guild_id", guild.id)
        .eq("device_id", target)
        .maybeSingle();
      if (!targetRow) return errorResponse(404, "target_not_in_guild");

      const { error: delErr } = await db
        .from("guild_members")
        .delete()
        .eq("guild_id", guild.id)
        .eq("device_id", target);
      if (delErr) {
        console.error("guild kick delete failed", delErr);
        return errorResponse(500, "kick_failed");
      }
      // 추방자도 탈퇴와 동일한 재가입 쿨다운 (코드 유출자 재입장 차단 겸용).
      const until = new Date(Date.now() + JOIN_COOLDOWN_SEC * 1000).toISOString();
      const { error: cdErr } = await db
        .from("guild_join_cooldowns")
        .upsert({ device_id: target, until });
      if (cdErr) console.error("guild kick cooldown upsert failed", cdErr);
      return jsonResponse({ ok: true });
    }

    case "rotate_code": {
      // 초대 코드 UNIQUE 충돌은 재시도로 흡수.
      for (let attempt = 0; attempt < 3; attempt++) {
        const code = generateInviteCode();
        const { error: updErr } = await db
          .from("guilds")
          .update({ invite_code: code })
          .eq("id", guild.id);
        if (!updErr) return jsonResponse({ ok: true, inviteCode: code });
        if (updErr.code !== "23505") {
          console.error("guild rotate_code failed", updErr);
          return errorResponse(500, "rotate_failed");
        }
      }
      return errorResponse(500, "rotate_failed");
    }

    case "disband": {
      // guilds 삭제 → guild_members CASCADE. 해체는 멤버 귀책이 아니므로 쿨다운 없음.
      const { error: delErr } = await db.from("guilds").delete().eq("id", guild.id);
      if (delErr) {
        console.error("guild disband failed", delErr);
        return errorResponse(500, "disband_failed");
      }
      return jsonResponse({ ok: true });
    }

    case "set_layout": {
      // 가구 재배치 — 포지션(장소·office_slot 의미)은 고정, 바닥 가구 세트 순열만 교체.
      const { error: updErr } = await db
        .from("guilds")
        .update({ office_layout: layoutInts })
        .eq("id", guild.id);
      if (updErr) {
        console.error("guild set_layout failed", updErr);
        return errorResponse(500, "layout_failed");
      }
      return jsonResponse({ ok: true, officeLayout: layoutInts });
    }
  }
});
