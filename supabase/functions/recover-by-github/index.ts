// POST /recover-by-github
// 새 디바이스에서 사용자가 GitHub OAuth 토큰 → 서버가 GitHub API로 user 확인 후
// github_user_id 매칭되는 user에 hmac_key 재발급.
//
// recovery code 분실 + 등록 시 GitHub 연동한 사용자의 fallback. 두 번째 복구 수단.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { generateHmacKeyB64 } from "../_shared/hmac.ts";
import { fetchGitHubUser } from "../_shared/github.ts";

interface RecoverByGitHubRequest {
  githubToken: string;
  newDeviceId?: string; // 호환 위해 받지만 사용 안 함.
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: RecoverByGitHubRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  if (typeof body.githubToken !== "string" || body.githubToken.length < 20) {
    return errorResponse(400, "invalid_github_token");
  }

  let gh;
  try {
    gh = await fetchGitHubUser(body.githubToken);
  } catch (e) {
    console.error("github verification failed", e);
    return errorResponse(401, "github_verification_failed");
  }

  const db = getDb();
  const { data: user } = await db
    .from("users")
    .select("device_id, nickname, total_coins, status, profile_json, uses_zero_baseline")
    .eq("github_user_id", gh.id)
    .single();

  if (!user) return errorResponse(404, "no_account_linked_to_github");
  if (user.status === "banned") return errorResponse(403, "banned");

  const newKey = generateHmacKeyB64();
  const { error } = await db
    .from("users")
    .update({
      hmac_key_b64: newKey,
      github_login: gh.login, // login 변경된 경우 갱신
    })
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
