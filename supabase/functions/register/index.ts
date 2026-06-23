// POST /register
// 첫 옵트인 시 1회 호출. 신규 device_id에 per-install hmac_key + recovery_code 발급.
// 닉네임 case-insensitive 충돌 시 409, github_user_id 중복 시 409.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { generateHmacKeyB64 } from "../_shared/hmac.ts";
import {
  generateRecoveryCode,
  hashRecoveryCode,
  isValidNickname,
  isValidUUID,
} from "../_shared/validation.ts";

interface RegisterRequest {
  deviceId: string;
  nickname: string;
  githubLogin?: string | null;
  githubUserId?: number | null;
  // 옵트인 시점에 클라이언트가 보유한 coinsTotalEarned. "누적값 인정" 정책 — 서버 total_coins
  // 초기값으로 직접 저장. 0~1M sanity cap (cheater 첫 등록 시 무한 인입 차단).
  initialCoins?: number;
  // 트레이너 카드 + stats opaque blob. 서버는 저장/응답만, 해석 안 함.
  profileJson?: unknown;
}

const MAX_INITIAL_COINS = 1_000_000;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: RegisterRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }

  if (!isValidUUID(body.deviceId)) return errorResponse(400, "invalid_device_id");
  if (!isValidNickname(body.nickname)) return errorResponse(400, "invalid_nickname");

  const db = getDb();
  const normalized = body.nickname.toLowerCase();

  // 1) device_id 선검사 — 이미 등록된 device면 즉시 명시적 에러. 멱등 처리 안 함 (recovery
  //    흐름이 따로 있음).
  const { data: existingDevice } = await db
    .from("users")
    .select("device_id")
    .eq("device_id", body.deviceId)
    .maybeSingle();
  if (existingDevice) return errorResponse(409, "device_already_registered");

  // githubUserId는 number만 신뢰 — 문자열이 PostgREST .or() 필터에 그대로 보간되면 필터
  // 인젝션(예: "x,nickname_normalized.eq.victim")이 되므로 타입/정수 검증을 통과 못 하면 null로 떨군다.
  const githubUserId =
    typeof body.githubUserId === "number" && Number.isInteger(body.githubUserId)
      ? body.githubUserId
      : null;

  // 2) nickname + github_user_id 충돌 검사 — 한 번에 select로 처리해 race 줄임.
  const conflictFilters = [`nickname_normalized.eq.${normalized}`];
  if (githubUserId !== null) conflictFilters.push(`github_user_id.eq.${githubUserId}`);
  const { data: conflicts } = await db
    .from("users")
    .select("nickname_normalized, github_user_id")
    .or(conflictFilters.join(","));

  if (conflicts && conflicts.length > 0) {
    const nameClash = conflicts.find((c) => c.nickname_normalized === normalized);
    if (nameClash) return errorResponse(409, "nickname_taken");
    const ghClash = conflicts.find((c) => c.github_user_id === githubUserId);
    if (ghClash) return errorResponse(409, "github_already_bound");
  }

  const hmacKey = generateHmacKeyB64();
  const recoveryCode = generateRecoveryCode();
  const recoveryHash = await hashRecoveryCode(recoveryCode);

  const initialCoinsRaw = typeof body.initialCoins === "number" ? body.initialCoins : 0;
  const initialCoins = Math.max(0, Math.min(MAX_INITIAL_COINS, Math.floor(initialCoinsRaw)));

  const { error } = await db.from("users").insert({
    device_id: body.deviceId,
    nickname: body.nickname,
    nickname_normalized: normalized,
    github_login: body.githubLogin ?? null,
    github_user_id: githubUserId,
    hmac_key_b64: hmacKey,
    recovery_code_hash: recoveryHash,
    total_coins: initialCoins,
    status: "active",
    profile_json: body.profileJson ?? null,
  });

  if (error) {
    // UNIQUE 위반 — 위에서 못 잡은 race condition. 409로 통일.
    if (error.code === "23505") return errorResponse(409, "duplicate");
    console.error("register insert failed", error);
    return errorResponse(500, "register_failed");
  }

  // initialCoins > 0면 synthetic submission 한 행 insert — 이번 달 monthly_leaderboard에
  // 즉시 등장하도록. accepted=true, cap_applied=false. 이게 없으면 monthly view가 보지 못함.
  if (initialCoins > 0) {
    await db.from("submissions").insert({
      device_id: body.deviceId,
      delta_coins: initialCoins,
      accepted_coins: initialCoins,
      elapsed_seconds: 0,
      accepted: true,
      cap_applied: false,
      reject_reason: null,
    });
  }

  return jsonResponse({
    hmacKey,
    recoveryCode,
    nickname: body.nickname,
  });
});
