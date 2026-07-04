// POST /guild-manage
// 길드장 전용 액션 묶음: kick(추방) / rotate_code(초대 코드 재발급) / disband(해체).
// 1함수 1액션 관례의 의도적 예외 — 함수 수 억제 (docs/plans/guild.md §3).
//
// payload(서명 대상, flat): { action, deviceId, targetDeviceId, ts }
//   - targetDeviceId는 kick에서만 의미. rotate_code/disband는 빈 문자열("")로 보내
//     canonical 직렬화 형태를 액션과 무관하게 고정한다 (Swift 클라이언트 단순화).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { generateInviteCode, JOIN_COOLDOWN_SEC } from "../_shared/guild_policy.ts";

type ManageAction = "kick" | "rotate_code" | "disband";

interface ManagePayload {
  action: ManageAction;
  deviceId: string;
  targetDeviceId: string; // kick 외에는 ""
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
  if (p.action !== "kick" && p.action !== "rotate_code" && p.action !== "disband") {
    return errorResponse(400, "invalid_action");
  }
  if (typeof p.targetDeviceId !== "string") return errorResponse(400, "invalid_target");
  if (p.action === "kick" && !isValidUUID(p.targetDeviceId)) {
    return errorResponse(400, "invalid_target");
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
    { action: p.action, deviceId: p.deviceId, targetDeviceId: p.targetDeviceId, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
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
  }
});
