// POST /recover-by-code
// 새 디바이스에서 사용자가 recovery code 입력 → 서버가 그 user의 hmac_key 재발급.
//
// 설계: device_id는 서버측 원본을 그대로 유지. 클라이언트가 "newDeviceId"를 보내든 말든
// 무시하고 응답에 기존 device_id 반환. 클라이언트는 그걸 받아 자기 로컬 rankingDeviceID에
// 저장. → submissions FK 변경 불필요, 깔끔.
//
// 기존 디바이스의 hmac_key는 invalidate (rotation). 잃어버린 디바이스에서 들어오는 submit은
// 401 bad_signature로 거부됨.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { generateHmacKeyB64 } from "../_shared/hmac.ts";
import { hashRecoveryCode } from "../_shared/validation.ts";

interface RecoverByCodeRequest {
  recoveryCode: string;
  newDeviceId?: string; // 무시. 호환 위해 받지만 사용 안 함.
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: RecoverByCodeRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  if (typeof body.recoveryCode !== "string" || body.recoveryCode.length < 8) {
    return errorResponse(400, "invalid_recovery_code");
  }

  const hash = await hashRecoveryCode(body.recoveryCode);
  const db = getDb();
  const { data: user } = await db
    .from("users")
    .select("device_id, nickname, total_coins, status, profile_json, uses_zero_baseline")
    .eq("recovery_code_hash", hash)
    .single();

  if (!user) return errorResponse(404, "recovery_code_not_found");
  if (user.status === "banned") return errorResponse(403, "banned");

  const newKey = generateHmacKeyB64();
  const { error } = await db
    .from("users")
    .update({ hmac_key_b64: newKey })
    .eq("device_id", user.device_id);
  if (error) {
    console.error("hmac rotation failed", error);
    return errorResponse(500, "rotation_failed");
  }

  // profile_json 전체(backup 포함) 반환 — 새 디바이스가 펫 인벤토리·코인 잔액·설정 복원.
  // leaderboard와 달리 본인 응답이므로 strip 안 함.
  return jsonResponse({
    deviceId: user.device_id,
    hmacKey: newKey,
    nickname: user.nickname,
    totalCoins: user.total_coins,
    profileJson: user.profile_json,
    // 클라가 baseline 계산 모드를 맞춰 over-credit을 막는다. 구버전 클라는 이 필드 무시.
    usesZeroBaseline: user.uses_zero_baseline ?? false,
  });
});
