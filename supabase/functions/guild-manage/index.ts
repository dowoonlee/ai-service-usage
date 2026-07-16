// POST /guild-manage
// 길드장 전용 액션 묶음: kick(추방) / rotate_code(초대 코드 재발급) / disband(해체)
// / set_furniture(가구 자유 배치) / rename(길드명 변경). 1함수 1액션 관례의 의도적 예외 — 함수 수 억제 (docs/plans/guild.md §3).
//
// payload(서명 대상, flat): { action, deviceId, [layout,] [newName,] targetDeviceId, ts }
//   - targetDeviceId는 kick에서만 의미. 나머지는 빈 문자열("").
//   - layout은 set_furniture에서만 존재 — 클라이언트가 키 자체를 생략하므로 canonical 재현도
//     같은 조건으로 생략해야 서명이 일치한다.
//   - newName은 rename에서만 존재 (layout과 동일한 present-only 규약).
//
// rename의 RP 300 소모는 클라이언트 로컬 경제(생성권·데코와 동일)라 서버가 검증하지 않는다 —
// 서버는 이름 규칙(isValidGuildName)·유일성·길드장 권한만 강제한다.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import {
  generateInviteCode,
  JOIN_COOLDOWN_SEC,
  INVITE_EXPIRE_SEC,
  INVITE_REDECLINE_COOLDOWN_SEC,
  INVITE_MAX_PENDING_PER_GUILD,
  FURNITURE_KIND_COUNT,
  FURNITURE_WALL_KINDS,
  FURNITURE_TEXT_KINDS,
  FURNITURE_WALL_LANE,
  FURNITURE_MAX_INSTANCES,
  FURNITURE_TEXT_MAX,
  isValidGuildName,
  checkJoinCooldown,
} from "../_shared/guild_policy.ts";

type ManageAction =
  | "kick" | "rotate_code" | "disband" | "set_furniture" | "invite" | "cancel_invite" | "rename"
  | "approve_request" | "reject_request";
const MANAGE_ACTIONS: ReadonlySet<string> = new Set([
  "kick", "rotate_code", "disband", "set_furniture", "invite", "cancel_invite", "rename",
  "approve_request", "reject_request",
]);

interface ManagePayload {
  action: ManageAction;
  deviceId: string;
  targetDeviceId: string; // kick 외에는 ""
  // set_furniture 전용 — "kind:x:lane[:text];…" (보유 가구 인스턴스 직렬화, text는 percent-encoding).
  layout?: string;
  // invite 전용 — 초대할 상대의 닉네임 (서버가 device로 해석).
  targetNickname?: string;
  // cancel_invite 전용 — 취소할 초대 id (UUID).
  inviteId?: string;
  // approve_request/reject_request 전용 — 처리할 가입신청 id (UUID).
  requestId?: string;
  // rename 전용 — 새 길드명 (2~24자, isValidGuildName).
  newName?: string;
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
  if (!MANAGE_ACTIONS.has(p.action)) return errorResponse(400, "invalid_action");
  if (typeof p.targetDeviceId !== "string") return errorResponse(400, "invalid_target");
  if (p.action === "kick" && !isValidUUID(p.targetDeviceId)) {
    return errorResponse(400, "invalid_target");
  }
  // invite: 닉네임 형식(3..24, 제어문자 금지). cancel_invite: inviteId UUID.
  if (p.action === "invite") {
    const n = p.targetNickname;
    if (typeof n !== "string" || n.length < 3 || n.length > 24 || /[\x00-\x1f\x7f]/.test(n)) {
      return errorResponse(400, "invalid_nickname");
    }
  }
  if (p.action === "cancel_invite" && !isValidUUID(p.inviteId ?? "")) {
    return errorResponse(400, "invalid_invite_id");
  }
  if ((p.action === "approve_request" || p.action === "reject_request") &&
      !isValidUUID(p.requestId ?? "")) {
    return errorResponse(400, "invalid_request_id");
  }
  // rename: 새 길드명 형식(2~24자, 제어문자·앞뒤공백·연속공백 금지) — guild-create와 동일 규칙.
  if (p.action === "rename" && !isValidGuildName(p.newName)) {
    return errorResponse(400, "invalid_guild_name");
  }
  // set_furniture: "kind:x:lane[:y[:text]];…" 검증 — 카탈로그 kind 범위, 벽/바닥 lane 정합,
  // 벽 가구 자유 y(4번째 필드), 액자 문구(5번째, percent-encoding). kind 중복 허용.
  // 좌표는 클라 논리 좌표(씬 280×150, 바닥 레인 0..2, 벽 3). 서버는 형식·범위만 권위 검증.
  // 추가 필드(y·text)는 위치 대신 "숫자면 좌표, 아니면 문구"로 관대하게 판정 (레거시 4필드
  // text와 신형 4필드 y를 모두 수용). 문구는 TEXT_KIND 한정 + 길이/제어문자 방어.
  if (p.action === "set_furniture") {
    if (typeof p.layout !== "string" || p.layout.length > 1500) {
      return errorResponse(400, "invalid_layout");
    }
    const entries = p.layout.length === 0 ? [] : p.layout.split(";");
    if (entries.length > FURNITURE_MAX_INSTANCES) {
      return errorResponse(400, "invalid_layout");
    }
    for (const e of entries) {
      const parts = e.split(":");
      if (parts.length < 3 || parts.length > 5) {
        return errorResponse(400, "invalid_layout");
      }
      const kind = Number(parts[0]);
      const x = Number(parts[1]);
      const lane = Number(parts[2]);
      if (
        !Number.isInteger(kind) || kind < 0 || kind >= FURNITURE_KIND_COUNT ||
        !Number.isFinite(x) || x < 0 || x > 280 ||
        !Number.isInteger(lane) ||
        (FURNITURE_WALL_KINDS.has(kind)
          ? lane !== FURNITURE_WALL_LANE
          : lane < 0 || lane > 2)
      ) {
        return errorResponse(400, "invalid_layout");
      }
      // 추가 필드 4·5: 숫자면 좌표(y), 비숫자면 문구.
      for (const field of parts.slice(3)) {
        if (field.length === 0) continue;
        const asNum = Number(field);
        if (Number.isFinite(asNum)) {
          if (asNum < 0 || asNum > 150) return errorResponse(400, "invalid_layout"); // 씬 y 범위
          continue;
        }
        // 문구 — 액자 등 TEXT_KIND 한정.
        if (!FURNITURE_TEXT_KINDS.has(kind) || field.length > 120) {
          return errorResponse(400, "invalid_layout");
        }
        let text: string;
        try {
          text = decodeURIComponent(field);
        } catch {
          return errorResponse(400, "invalid_layout");
        }
        // 클라는 grapheme 10자 캡 — 이모지 ZWJ 시퀀스는 code point가 더 많으므로
        // 서버는 ×2 여유로 검증 (형식 방어가 목적, 정확한 글자 수는 클라 UX 책임).
        if (
          text.length === 0 || [...text].length > FURNITURE_TEXT_MAX * 2 ||
          /[\x00-\x1f\x7f;:]/.test(text)
        ) {
          return errorResponse(400, "invalid_layout");
        }
      }
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
    .select("device_id, hmac_key_b64, status, tenant_id")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  // layout 키는 클라이언트가 set_furniture일 때만 직렬화 — canonical 재현도 동일 조건.
  const verifyObj: Record<string, unknown> = {
    action: p.action,
    deviceId: p.deviceId,
    targetDeviceId: p.targetDeviceId,
    ts: p.ts,
  };
  if (typeof p.layout === "string") verifyObj.layout = p.layout;
  // 클라이언트가 액션별로만 키를 직렬화 → canonical 재현도 동일 조건(present-only).
  if (typeof p.targetNickname === "string") verifyObj.targetNickname = p.targetNickname;
  if (typeof p.inviteId === "string") verifyObj.inviteId = p.inviteId;
  if (typeof p.requestId === "string") verifyObj.requestId = p.requestId;
  if (typeof p.newName === "string") verifyObj.newName = p.newName;
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
    .select("id, leader_device_id, tenant_id")
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

    case "invite": {
      // 닉네임 → 피초대자 device 해석 (case-insensitive).
      const nickNorm = p.targetNickname!.trim().toLowerCase();
      const { data: invitee } = await db
        .from("users")
        .select("device_id, status, tenant_id")
        .eq("nickname_normalized", nickNorm)
        .maybeSingle();
      // 프라이버시 — 존재/소속/쿨다운 여부를 구분해 노출하지 않고 하나로 뭉갠다.
      if (!invitee || invitee.status === "banned") return errorResponse(404, "cannot_invite");
      // 다른 테넌트 사용자는 "존재하지 않음"과 동일 취급 — 타 테넌트로는 초대 불가(존재 노출 없이 격리).
      if (invitee.tenant_id !== guild.tenant_id) return errorResponse(404, "cannot_invite");
      if (invitee.device_id === deviceId) return errorResponse(400, "cannot_invite_self");

      // 이미 어떤 길드에 소속?
      const { data: existingMember } = await db
        .from("guild_members")
        .select("device_id")
        .eq("device_id", invitee.device_id)
        .maybeSingle();
      if (existingMember) return errorResponse(409, "cannot_invite");

      // 재가입 쿨다운(탈퇴/추방 7일) 중이면 초대 불가.
      const { data: cd } = await db
        .from("guild_join_cooldowns")
        .select("until")
        .eq("device_id", invitee.device_id)
        .maybeSingle();
      if (cd && new Date(cd.until).getTime() > Date.now()) {
        return errorResponse(409, "cannot_invite");
      }

      // 거절 재초대 쿨다운 — 이 길드가 이 유저에게 최근 거절당했으면 24h 대기.
      const reInviteFloor = new Date(Date.now() - INVITE_REDECLINE_COOLDOWN_SEC * 1000).toISOString();
      const { data: recentDecline } = await db
        .from("guild_invites")
        .select("id")
        .eq("guild_id", guild.id)
        .eq("invitee_device_id", invitee.device_id)
        .eq("status", "declined")
        .gt("responded_at", reInviteFloor)
        .limit(1)
        .maybeSingle();
      if (recentDecline) return errorResponse(429, "redecline_cooldown");

      // 길드당 대기중 초대 상한 (스팸 방지).
      const { count: pendingCount } = await db
        .from("guild_invites")
        .select("id", { count: "exact", head: true })
        .eq("guild_id", guild.id)
        .eq("status", "pending");
      if ((pendingCount ?? 0) >= INVITE_MAX_PENDING_PER_GUILD) {
        return errorResponse(429, "too_many_pending");
      }

      const expiresAt = new Date(Date.now() + INVITE_EXPIRE_SEC * 1000).toISOString();
      const { error: insErr } = await db.from("guild_invites").insert({
        guild_id: guild.id,
        invitee_device_id: invitee.device_id,
        inviter_device_id: deviceId,
        expires_at: expiresAt,
      });
      if (insErr) {
        if (insErr.code === "23505") return errorResponse(409, "already_invited"); // pending 중복
        console.error("guild invite insert failed", insErr);
        return errorResponse(500, "invite_failed");
      }
      return jsonResponse({ ok: true });
    }

    case "cancel_invite": {
      // 내 길드의 대기중 초대만 취소 가능.
      const { data: inv } = await db
        .from("guild_invites")
        .select("id, guild_id, status")
        .eq("id", p.inviteId!)
        .maybeSingle();
      if (!inv || inv.guild_id !== guild.id || inv.status !== "pending") {
        return errorResponse(404, "invite_not_found");
      }
      const { error: updErr } = await db
        .from("guild_invites")
        .update({ status: "cancelled", responded_at: new Date().toISOString() })
        .eq("id", inv.id);
      if (updErr) {
        console.error("guild cancel_invite failed", updErr);
        return errorResponse(500, "cancel_failed");
      }
      return jsonResponse({ ok: true });
    }

    case "approve_request": {
      // 이 길드로 온 대기중 + 미만료 가입신청만 승인 → 신청자를 멤버로 편입.
      const { data: reqRow } = await db
        .from("guild_join_requests")
        .select("id, guild_id, requester_device_id, status, expires_at")
        .eq("id", p.requestId!)
        .maybeSingle();
      if (!reqRow || reqRow.guild_id !== guild.id || reqRow.status !== "pending") {
        return errorResponse(404, "request_not_found");
      }
      if (new Date(reqRow.expires_at).getTime() <= Date.now()) {
        return errorResponse(410, "request_expired");
      }
      const requester = reqRow.requester_device_id;
      const nowIso = new Date().toISOString();

      // 신청자 자격 재검사 (신청 후 상태 변화 방어) — 존재·미차단·동일 테넌트.
      const { data: requesterUser } = await db
        .from("users")
        .select("device_id, status, tenant_id")
        .eq("device_id", requester)
        .maybeSingle();
      // 신청자 소멸/차단, 또는 신청 후 타 테넌트로 전환(one-way) → 가입 불가, 신청 정리 후 404.
      if (!requesterUser || requesterUser.status === "banned" ||
          requesterUser.tenant_id !== guild.tenant_id) {
        await db.from("guild_join_requests")
          .update({ status: "cancelled", responded_at: nowIso })
          .eq("id", reqRow.id);
        return errorResponse(404, "request_not_found");
      }

      // 재가입 쿨다운(탈퇴/추방) 중이면 승인 불가 — 신청은 유지(쿨다운 해제 후 재승인 가능).
      const cooldownResp = await checkJoinCooldown(db, requester);
      if (cooldownResp) return cooldownResp;

      const { error: insErr } = await db
        .from("guild_members")
        .insert({ guild_id: guild.id, device_id: requester });
      if (insErr) {
        if (insErr.code === "23505") {
          // 신청자가 이미 다른 길드 소속 → 이 신청은 무의미, 정리 후 409.
          await db.from("guild_join_requests")
            .update({ status: "cancelled", responded_at: nowIso })
            .eq("id", reqRow.id);
          return errorResponse(409, "already_in_guild");
        }
        console.error("guild approve_request insert failed", insErr);
        return errorResponse(500, "approve_failed");
      }

      // 이 신청 accepted, 신청자의 나머지 대기중 신청/받은 초대는 무의미 → 정리.
      // 멤버십(guild_members INSERT)은 이미 확정 — 여기 UPDATE가 일시 실패하면 가입은 됐는데
      // pending 신청/초대가 본인 목록에 계속 노출되므로, 최소한 로그로 남겨 추적 가능하게 한다.
      const { error: acceptErr } = await db.from("guild_join_requests")
        .update({ status: "accepted", responded_at: nowIso })
        .eq("id", reqRow.id);
      if (acceptErr) console.error("guild approve_request: mark accepted failed", acceptErr);
      const { error: cancelReqErr } = await db.from("guild_join_requests")
        .update({ status: "cancelled", responded_at: nowIso })
        .eq("requester_device_id", requester)
        .eq("status", "pending");
      if (cancelReqErr) console.error("guild approve_request: cancel other requests failed", cancelReqErr);
      const { error: cancelInvErr } = await db.from("guild_invites")
        .update({ status: "cancelled", responded_at: nowIso })
        .eq("invitee_device_id", requester)
        .eq("status", "pending");
      if (cancelInvErr) console.error("guild approve_request: cancel invites failed", cancelInvErr);

      return jsonResponse({ ok: true });
    }

    case "reject_request": {
      // 이 길드로 온 대기중 신청만 거절 (거절 후 이 신청자는 이 길드에 24h 재신청 쿨다운).
      const { data: reqRow } = await db
        .from("guild_join_requests")
        .select("id, guild_id, status")
        .eq("id", p.requestId!)
        .maybeSingle();
      if (!reqRow || reqRow.guild_id !== guild.id || reqRow.status !== "pending") {
        return errorResponse(404, "request_not_found");
      }
      const { error: updErr } = await db
        .from("guild_join_requests")
        .update({ status: "declined", responded_at: new Date().toISOString() })
        .eq("id", reqRow.id);
      if (updErr) {
        console.error("guild reject_request failed", updErr);
        return errorResponse(500, "reject_failed");
      }
      return jsonResponse({ ok: true });
    }

    case "set_furniture": {
      // 가구 자유 배치 — 멤버 자리(office_slot 포지션)는 고정, 가구 좌표만 교체.
      const { error: updErr } = await db
        .from("guilds")
        .update({ office_furniture: p.layout })
        .eq("id", guild.id);
      if (updErr) {
        console.error("guild set_furniture failed", updErr);
        return errorResponse(500, "layout_failed");
      }
      return jsonResponse({ ok: true, officeFurniture: p.layout });
    }

    case "rename": {
      // 길드명 변경 — name + name_normalized 동시 갱신 (create와 동일한 저장 패턴).
      const newName = p.newName!;
      const normalized = newName.toLowerCase();
      // 유일성 선검사 — 다른 길드가 이미 그 이름이면 거부. 대소문자만 바꾸는 self-rename은
      // normalized가 같아 자기 자신이 걸리므로 id 비교로 통과시킨다. UNIQUE 인덱스가 race 최종 방어.
      const { data: nameClash } = await db
        .from("guilds")
        .select("id")
        .eq("tenant_id", guild.tenant_id)
        .eq("name_normalized", normalized)
        .maybeSingle();
      if (nameClash && nameClash.id !== guild.id) return errorResponse(409, "name_taken");

      const { error: updErr } = await db
        .from("guilds")
        .update({ name: newName, name_normalized: normalized })
        .eq("id", guild.id);
      if (updErr) {
        if (updErr.code === "23505") return errorResponse(409, "name_taken");
        console.error("guild rename failed", updErr);
        return errorResponse(500, "rename_failed");
      }
      return jsonResponse({ ok: true, name: newName });
    }
  }
});
