// POST /guild-guestbook
// 다른 길드 사무실 방명록 — 작성(write) / 삭제(delete). docs/plans/guild-visit.md M2.
//
// 규칙:
//   write  — 타 길드에만(자기 길드는 403 own_guild). GitHub 미연동은 게시판과 같은 게이트
//            (403 github_required). 같은 길드 24h·전체 10분 쿨다운은 guild_guestbook_write RPC가
//            한 트랜잭션에서 원자적으로 선점한다(병렬 요청 우회 불가). shadow_banned는 가짜 200.
//   delete — 작성자는 GUESTBOOK_DELETE_WINDOW_SEC 안에서, 해당 길드의 길드장은 언제나.
//            쿨다운은 삭제와 무관하게 유지된다(writes 테이블이 별도라서).
//
// payload(서명 대상, flat, present-only): { action, deviceId, guildId, [content], [entryId], ts }

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { resolveTenant } from "../_shared/tenant.ts";
import { boardInteractionBlocked } from "../_shared/board_policy.ts";
import {
  GUESTBOOK_DELETE_WINDOW_SEC,
  GUESTBOOK_GLOBAL_COOLDOWN_SEC,
  GUESTBOOK_GUILD_COOLDOWN_SEC,
  GUESTBOOK_MAX_LEN,
} from "../_shared/guild_policy.ts";

interface GuestbookPayload {
  action: "write" | "delete";
  deviceId: string;
  guildId: string;
  content?: string;
  entryId?: number;
  ts: number;
}
interface GuestbookRequest {
  payload: GuestbookPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: GuestbookRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (p.action !== "write" && p.action !== "delete") return errorResponse(400, "invalid_action");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (!isValidUUID(p.guildId)) return errorResponse(400, "invalid_guild_id");
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  if (p.action === "write" && typeof p.content !== "string") {
    return errorResponse(400, "invalid_content");
  }
  if (p.action === "delete" &&
      (typeof p.entryId !== "number" || !Number.isInteger(p.entryId) || p.entryId <= 0)) {
    return errorResponse(400, "invalid_entry_id");
  }

  const deviceId = p.deviceId.toLowerCase();
  const guildId = p.guildId.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status, nickname, github_login, profile_json")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  // present-only — 액션에 쓰인 키만 서명 대상 (guild-request와 같은 규약).
  const verifyObj: Record<string, unknown> = {
    action: p.action,
    deviceId: p.deviceId,
    guildId: p.guildId,
    ts: p.ts,
  };
  if (typeof p.content === "string") verifyObj.content = p.content;
  if (typeof p.entryId === "number") verifyObj.entryId = p.entryId;
  const ok = await verifyHmac(verifyObj, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  const { data: guild } = await db
    .from("guilds")
    .select("id, name, tenant_id, leader_device_id")
    .eq("id", guildId)
    .maybeSingle();
  if (!guild) return errorResponse(404, "guild_not_found");

  const tenant = await resolveTenant(db, deviceId);
  if (!tenant || guild.tenant_id !== tenant) return errorResponse(403, "cross_tenant");

  // 내 소속 — write의 own_guild 판정 + 작성자 길드명 스냅샷.
  const { data: membership } = await db
    .from("guild_members")
    .select("guild_id, guilds(name)")
    .eq("device_id", deviceId)
    .maybeSingle();
  const myGuildId = membership?.guild_id ? String(membership.guild_id).toLowerCase() : null;
  const myGuildName = (membership?.guilds as unknown as { name: string } | null)?.name ?? null;

  // ---------------------------------------------------------------- write
  if (p.action === "write") {
    if (myGuildId === guild.id.toLowerCase()) return errorResponse(403, "own_guild");
    if (boardInteractionBlocked(user)) return errorResponse(403, "github_required");

    const content = (p.content as string).trim();
    if (content.length === 0) return errorResponse(400, "empty_content");
    if (content.length > GUESTBOOK_MAX_LEN) return errorResponse(400, "content_too_long");

    const avatar = (user.profile_json as { card?: { avatar?: { kind?: unknown; variant?: unknown } } } | null)
      ?.card?.avatar;
    const petKind = typeof avatar?.kind === "string" ? avatar.kind : null;
    const petVariant = typeof avatar?.variant === "number" ? avatar.variant : 0;

    // shadow_banned — 남에게 보이지 않아야 하므로 insert 없이 성공처럼 응답.
    if (user.status === "shadow_banned") {
      return jsonResponse({
        ok: true,
        entry: {
          id: 0, nickname: user.nickname, guildName: myGuildName, petKind, petVariant,
          content, createdAt: new Date().toISOString(), isMine: true,
        },
      });
    }

    const { data: rows, error: rpcErr } = await db.rpc("guild_guestbook_write", {
      p_device: deviceId,
      p_guild: guild.id,
      p_tenant: tenant,
      p_content: content,
      p_nickname: user.nickname,
      p_guild_name: myGuildName,
      p_pet_kind: petKind,
      p_pet_variant: petVariant,
      p_guild_cooldown_sec: GUESTBOOK_GUILD_COOLDOWN_SEC,
      p_global_cooldown_sec: GUESTBOOK_GLOBAL_COOLDOWN_SEC,
    });
    if (rpcErr) {
      // RPC가 '<code>:<retryAfterSec>'로 거절 사유를 던진다 — 쿨다운 두 종류만 정상 경로.
      const m = /(rate_limited|guestbook_cooldown):(\d+)/.exec(rpcErr.message ?? "");
      if (m) {
        const retryAfterSec = Math.max(1, Number(m[2]));
        return jsonResponse(
          { error: m[1], retryAfterSec },
          { status: m[1] === "rate_limited" ? 429 : 403 },
        );
      }
      console.error("guestbook write rpc failed", rpcErr);
      return errorResponse(500, "insert_failed");
    }
    const row = (rows as Array<{ out_id: number; out_created_at: string }> | null)?.[0];
    if (!row) return errorResponse(500, "insert_failed");

    return jsonResponse({
      ok: true,
      entry: {
        id: row.out_id, nickname: user.nickname, guildName: myGuildName, petKind, petVariant,
        content, createdAt: row.out_created_at, isMine: true,
      },
    });
  }

  // ---------------------------------------------------------------- delete
  const { data: entry } = await db
    .from("guild_guestbook")
    .select("id, guild_id, author_device_id, created_at")
    .eq("id", p.entryId as number)
    .maybeSingle();
  if (!entry || String(entry.guild_id).toLowerCase() !== guild.id.toLowerCase()) {
    return errorResponse(404, "entry_not_found");
  }
  const isAuthor = entry.author_device_id != null &&
    String(entry.author_device_id).toLowerCase() === deviceId;
  const isLeader = String(guild.leader_device_id ?? "").toLowerCase() === deviceId;
  if (!isAuthor && !isLeader) return errorResponse(403, "not_entry_owner");
  if (isAuthor && !isLeader) {
    const ageSec = (Date.now() - new Date(entry.created_at).getTime()) / 1000;
    if (ageSec > GUESTBOOK_DELETE_WINDOW_SEC) return errorResponse(403, "delete_window_expired");
  }

  const { error: delErr } = await db.from("guild_guestbook").delete().eq("id", entry.id);
  if (delErr) {
    console.error("guestbook delete failed", delErr);
    return errorResponse(500, "delete_failed");
  }
  return jsonResponse({ ok: true });
});
