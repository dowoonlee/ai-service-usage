// POST /dm-settings — 쪽지 수신 정책 + 차단 관리 (P3). 모두 요청자 HMAC 서명.
//
// payload(서명 대상, flat): { action, deviceId, [allowFrom|targetNickname|targetDevice], ts }
//   - get:     { action:"get", deviceId, ts }                         → 현재 상태
//   - set:     { action:"set", deviceId, allowFrom, ts }              → 수신 정책 변경
//   - block:   { action:"block", deviceId, targetNickname, ts }       → 닉네임 차단
//   - unblock: { action:"unblock", deviceId, targetDevice, ts }       → 차단 해제(device 지정)
//   키는 액션별로만 직렬화 — canonical 재현도 present-only(dm-keys/guild-invite 패턴).
//
// 모든 액션은 갱신 후 현재 상태 { allowFrom, blocked:[{device,nickname}] } 를 돌려준다(1콜 새로고침).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import type { AllowFrom } from "../_shared/dm_policy.ts";

type SettingsAction = "get" | "set" | "block" | "unblock";
const ACTIONS: ReadonlySet<string> = new Set(["get", "set", "block", "unblock"]);
const ALLOW_VALUES: ReadonlySet<string> = new Set(["anyone", "guild", "none"]);
const MAX_CLOCK_SKEW_SEC = 3600;

interface SettingsPayload {
  action: SettingsAction;
  deviceId: string;
  allowFrom?: AllowFrom;
  targetNickname?: string;
  targetDevice?: string;
  ts: number;
}
interface SettingsRequest {
  payload: SettingsPayload;
  signature: string;
}

/// 현재 수신 정책 + 차단 목록(닉네임 동봉).
async function currentState(db: SupabaseClient, deviceId: string) {
  const { data: s } = await db
    .from("dm_settings").select("allow_from").eq("device_id", deviceId).maybeSingle();
  const allowFrom = s?.allow_from ?? "anyone";
  const { data: blocks } = await db
    .from("dm_blocks").select("blocked_device").eq("blocker_device", deviceId);
  const ids = (blocks ?? []).map((b) => b.blocked_device);
  const nickById = new Map<string, string>();
  if (ids.length > 0) {
    const { data: us } = await db.from("users").select("device_id, nickname").in("device_id", ids);
    for (const u of us ?? []) nickById.set(u.device_id, u.nickname);
  }
  return {
    allowFrom,
    blocked: ids.map((d) => ({ device: d, nickname: nickById.get(d) ?? null })),
  };
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: SettingsRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (!ACTIONS.has(p.action)) return errorResponse(400, "invalid_action");
  if (p.action === "set" && (typeof p.allowFrom !== "string" || !ALLOW_VALUES.has(p.allowFrom))) {
    return errorResponse(400, "invalid_allow_from");
  }
  if (p.action === "block") {
    const n = p.targetNickname;
    if (typeof n !== "string" || n.length < 3 || n.length > 24) {
      return errorResponse(400, "invalid_nickname");
    }
  }
  if (p.action === "unblock" && !isValidUUID(p.targetDevice)) {
    return errorResponse(400, "invalid_target");
  }
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  const deviceId = p.deviceId.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users").select("device_id, hmac_key_b64, status").eq("device_id", deviceId).maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const verifyObj: Record<string, unknown> = { action: p.action, deviceId: p.deviceId, ts: p.ts };
  if (typeof p.allowFrom === "string") verifyObj.allowFrom = p.allowFrom;
  if (typeof p.targetNickname === "string") verifyObj.targetNickname = p.targetNickname;
  if (typeof p.targetDevice === "string") verifyObj.targetDevice = p.targetDevice;
  const ok = await verifyHmac(verifyObj, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  switch (p.action) {
    case "set": {
      const { error } = await db.from("dm_settings").upsert({
        device_id: deviceId,
        allow_from: p.allowFrom,
        updated_at: new Date().toISOString(),
      });
      if (error) {
        console.error("dm-settings set failed", error);
        return errorResponse(500, "update_failed");
      }
      break;
    }
    case "block": {
      const { data: target } = await db
        .from("users").select("device_id")
        .eq("nickname_normalized", p.targetNickname!.trim().toLowerCase()).maybeSingle();
      if (!target) return errorResponse(404, "cannot_block");        // 존재 여부 뭉갬
      if (target.device_id === deviceId) return errorResponse(400, "cannot_block");
      const { error } = await db.from("dm_blocks").upsert(
        { blocker_device: deviceId, blocked_device: target.device_id },
        { onConflict: "blocker_device,blocked_device", ignoreDuplicates: true },
      );
      if (error) {
        console.error("dm-settings block failed", error);
        return errorResponse(500, "update_failed");
      }
      break;
    }
    case "unblock": {
      const { error } = await db
        .from("dm_blocks").delete()
        .eq("blocker_device", deviceId).eq("blocked_device", p.targetDevice!.toLowerCase());
      if (error) {
        console.error("dm-settings unblock failed", error);
        return errorResponse(500, "update_failed");
      }
      break;
    }
    case "get":
      break;
  }

  return jsonResponse(await currentState(db, deviceId));
});
