// POST /register
// 첫 옵트인 시 1회 호출. 신규 device_id에 per-install hmac_key + recovery_code 발급.
// 닉네임 case-insensitive 충돌 시 409, github_user_id 중복 시 409.
//
// [어뷰징 방어] 신규 등록은 항상 total_coins=0부터 시작한다. 과거 initialCoins로 클라이언트가
// 보낸 누적값을 그대로 인정하던 경로는 submit의 시간비례 cap을 우회하는 farming 통로였음
// (device_id를 클라가 자유 생성 → delete 후 재등록 → 한방 주입). 이제 클라가 보내는
// initialCoins는 받되 완전히 무시한다(구버전 클라 호환). 옵트인 이후 사용량만 submit으로 누적.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { clientIp, ipRateLimited } from "../_shared/ratelimit.ts";
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
  // [폐기] 과거 "누적값 인정" 정책의 잔재. 신규 등록은 항상 0부터 시작하므로 받되 무시한다.
  // 구버전 클라가 여전히 보낼 수 있어 타입만 유지.
  initialCoins?: number;
  // 트레이너 카드 + stats opaque blob. 서버는 저장/응답만, 해석 안 함.
  profileJson?: unknown;
}

// register rate-limit: 같은 IP의 window 내 성공 등록이 MAX 이상이면 429.
// 정상 사용자(보통 생애 1회)는 막지 않도록 넉넉히. farming/스팸 가입만 완화한다.
const REGISTER_IP_WINDOW_SEC = 24 * 3600;
const REGISTER_IP_MAX = 10;

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

  // 0) IP rate-limit — 같은 IP의 최근 window 성공 등록 수가 한도 이상이면 차단.
  const ip = clientIp(req);
  if (await ipRateLimited(db, {
    table: "register_attempts", ip,
    windowSec: REGISTER_IP_WINDOW_SEC, max: REGISTER_IP_MAX,
  })) {
    return errorResponse(429, "rate_limited");
  }

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

  // 2) nickname + github_user_id 충돌 검사.
  //    .or() 문자열 보간은 닉네임에 콤마/점(isValidNickname이 허용)이 섞이면 필터 인젝션이
  //    된다 — 위 githubUserId 정수 방어와 달리 문자열 쪽이 뚫려 있었으므로, 보간 없는
  //    .eq() 두 개로 분리한다. 유일성의 최종 방어는 여전히 DB UNIQUE 인덱스.
  const { data: nameClash } = await db
    .from("users")
    .select("device_id")
    .eq("nickname_normalized", normalized)
    .limit(1);
  if (nameClash && nameClash.length > 0) return errorResponse(409, "nickname_taken");
  if (githubUserId !== null) {
    const { data: ghClash } = await db
      .from("users")
      .select("device_id")
      .eq("github_user_id", githubUserId)
      .limit(1);
    if (ghClash && ghClash.length > 0) return errorResponse(409, "github_already_bound");
  }

  const hmacKey = generateHmacKeyB64();
  const recoveryCode = generateRecoveryCode();
  const recoveryHash = await hashRecoveryCode(recoveryCode);

  // 신규 등록은 항상 0부터. initialCoins는 무시 (위 헤더 주석 참조).
  const { error } = await db.from("users").insert({
    device_id: body.deviceId,
    nickname: body.nickname,
    nickname_normalized: normalized,
    github_login: body.githubLogin ?? null,
    github_user_id: githubUserId,
    hmac_key_b64: hmacKey,
    recovery_code_hash: recoveryHash,
    total_coins: 0,
    status: "active",
    profile_json: body.profileJson ?? null,
    // 폐기 이후 등록 — total_coins는 baseline 이후 증가분만 담는 상대값. recover 시 클라가
    // 모드를 맞춰야 over-credit이 안 나므로 권위 있게 저장한다.
    uses_zero_baseline: true,
  });

  if (error) {
    // UNIQUE 위반 — 위에서 못 잡은 race condition. 409로 통일.
    if (error.code === "23505") return errorResponse(409, "duplicate");
    console.error("register insert failed", error);
    return errorResponse(500, "register_failed");
  }

  // 성공 등록만 카운트 — 닉네임 충돌 등 실패 재시도는 정상 사용자도 하므로 제외.
  // best-effort: 기록 실패가 등록 자체를 막지 않도록 에러 무시.
  if (ip) {
    await db.from("register_attempts").insert({ ip });
  }

  return jsonResponse({
    hmacKey,
    recoveryCode,
    nickname: body.nickname,
  });
});
