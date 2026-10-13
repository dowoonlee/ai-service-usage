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

import { jsonResponse, errorResponse, handleOptions, corsHeaders } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { furnitureWriteError, parseOfficeStudio, studioFromLegacy, studioLayout, studioTransitionError, isValidOfficeStudio } from "../_shared/guild_furniture.ts";
import { isValidUUID } from "../_shared/validation.ts";
import {
  generateInviteCode,
  JOIN_COOLDOWN_SEC,
  INVITE_EXPIRE_SEC,
  INVITE_REDECLINE_COOLDOWN_SEC,
  INVITE_MAX_PENDING_PER_GUILD,
  isValidGuildName,
  isValidGuildLogo,
  isValidGuildLogoPos,
  checkJoinCooldown,
} from "../_shared/guild_policy.ts";

type ManageAction =
  | "kick" | "rotate_code" | "disband" | "set_furniture" | "invite" | "cancel_invite" | "rename"
  | "set_logo" | "set_logo_pos" | "approve_request" | "reject_request";
const MANAGE_ACTIONS: ReadonlySet<string> = new Set([
  "kick", "rotate_code", "disband", "set_furniture", "invite", "cancel_invite", "rename",
  "set_logo", "set_logo_pos", "approve_request", "reject_request",
]);

interface ManagePayload {
  action: ManageAction;
  deviceId: string;
  targetDeviceId: string; // kick 외에는 ""
  // set_furniture 전용 — "kind:x:lane[:text];…" (보유 가구 인스턴스 직렬화, text는 percent-encoding).
  layout?: string;
  layoutVersion?: number;
  expectedLayout?: string;
  studio?: string;
  expectedRevision?: number;
  furnitureOperation?: string;
  purchaseKind?: number;
  // invite 전용 — 초대할 상대의 닉네임 (서버가 device로 해석).
  targetNickname?: string;
  // cancel_invite 전용 — 취소할 초대 id (UUID).
  inviteId?: string;
  // approve_request/reject_request 전용 — 처리할 가입신청 id (UUID).
  requestId?: string;
  // rename 전용 — 새 길드명 (2~24자, isValidGuildName).
  newName?: string;
  // set_logo 전용 — "s:<0..9>" 또는 "p:<base64 PNG>" (isValidGuildLogo).
  logo?: string;
  // set_logo_pos 전용 — 사무실 벽에서의 로고 중심 좌표(씬 논리 좌표).
  logoX?: number;
  logoY?: number;
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
  // set_logo: 샘플 인덱스이거나 PNG 시그니처를 가진 base64 (상한 8KB).
  if (p.action === "set_logo" && !isValidGuildLogo(p.logo)) {
    return errorResponse(400, "invalid_logo");
  }
  // set_logo_pos: 벽 밴드 안의 정수 좌표.
  if (p.action === "set_logo_pos" && !isValidGuildLogoPos(p.logoX, p.logoY)) {
    return errorResponse(400, "invalid_logo_pos");
  }
  if (p.action === "set_furniture") {
    const writeError = furnitureWriteError(p.layoutVersion, p.expectedLayout);
    // 구버전은 알 수 없는 409를 닉네임 중복으로 표시한다. 기존 최소 버전 게이트처럼
    // 평문 426을 사용해야 실제 업데이트 안내가 사용자에게 전달된다.
    if (writeError === "furniture_update_required") {
      return new Response("가구를 변경하려면 앱을 최신 버전으로 업데이트해 주세요. 상단 버전 칩에서 업데이트할 수 있습니다.", {
        status: 426,
        headers: { ...corsHeaders, "Content-Type": "text/plain; charset=utf-8" },
      });
    }
    if (writeError) return errorResponse(400, writeError);
    if (!parseOfficeStudio(p.studio) || !Number.isSafeInteger(p.expectedRevision) || p.expectedRevision! < 0) {
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
  if (typeof p.layoutVersion === "number") verifyObj.layoutVersion = p.layoutVersion;
  if (typeof p.expectedLayout === "string") verifyObj.expectedLayout = p.expectedLayout;
  if (typeof p.studio === "string") verifyObj.studio = p.studio;
  if (typeof p.expectedRevision === "number") verifyObj.expectedRevision = p.expectedRevision;
  if (typeof p.furnitureOperation === "string") verifyObj.furnitureOperation = p.furnitureOperation;
  if (typeof p.purchaseKind === "number") verifyObj.purchaseKind = p.purchaseKind;
  if (typeof p.inviteId === "string") verifyObj.inviteId = p.inviteId;
  if (typeof p.requestId === "string") verifyObj.requestId = p.requestId;
  if (typeof p.newName === "string") verifyObj.newName = p.newName;
  if (typeof p.logo === "string") verifyObj.logo = p.logo;
  if (typeof p.logoX === "number") verifyObj.logoX = p.logoX;
  if (typeof p.logoY === "number") verifyObj.logoY = p.logoY;
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
    .select("id, leader_device_id, tenant_id, office_furniture, office_studio, office_revision")
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
      if (guild.office_revision !== p.expectedRevision || guild.office_furniture !== p.expectedLayout) {
        return errorResponse(409, "furniture_conflict");
      }
      const state = parseOfficeStudio(p.studio)!;
      const previous = guild.office_studio ?? studioFromLegacy(guild.office_furniture);
      if (!isValidOfficeStudio(previous)) return errorResponse(409, "furniture_inventory_conflict");
      const transitionError = studioTransitionError(previous, state, p.furnitureOperation, p.purchaseKind);
      if (transitionError) return errorResponse(409, transitionError);
      const layout = studioLayout(state);
      const revision = p.expectedRevision! + 1;
      // 배치·소유권·프리셋을 같은 문장에서 갱신하고, 동시 수정/길드장 교체를 검사한다.
      const { data: updated, error: updErr } = await db
        .from("guilds")
        .update({ office_furniture: layout, office_studio: state, office_revision: revision })
        .eq("id", guild.id)
        .eq("leader_device_id", deviceId)
        .eq("office_revision", p.expectedRevision!)
        .eq("office_furniture", p.expectedLayout!)
        .select("id")
        .maybeSingle();
      if (updErr) {
        console.error("guild set_furniture failed", updErr);
        return errorResponse(500, "layout_failed");
      }
      if (!updated) return errorResponse(409, "furniture_conflict");
      return jsonResponse({ ok: true, officeFurniture: layout, officeStudio: state, officeRevision: revision });
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

    case "set_logo": {
      // 로고 변경 — 형식은 위에서 검증했고 여기서는 저장만. rename과 달리 유일성 제약이 없다.
      // RP 200 소모는 rename과 동일하게 클라이언트 로컬 경제라 서버가 검증하지 않는다.
      const logo = p.logo!;
      const { error: updErr } = await db
        .from("guilds")
        .update({ logo })
        .eq("id", guild.id);
      if (updErr) {
        console.error("guild set_logo failed", updErr);
        return errorResponse(500, "logo_failed");
      }
      return jsonResponse({ ok: true, logo });
    }

    case "set_logo_pos": {
      // 사무실 벽에서의 로고 위치. 가구 재배치와 같은 무료 조작이라 RP를 받지 않는다
      // (디자인 변경인 set_logo만 RP 200).
      const { error: updErr } = await db
        .from("guilds")
        .update({ logo_x: p.logoX!, logo_y: p.logoY! })
        .eq("id", guild.id);
      if (updErr) {
        console.error("guild set_logo_pos failed", updErr);
        return errorResponse(500, "logo_pos_failed");
      }
      return jsonResponse({ ok: true, logoX: p.logoX, logoY: p.logoY });
    }
  }
});
