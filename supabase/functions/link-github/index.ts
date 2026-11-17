// POST /link-github
// 이미 등록된 device가 GitHub 계정을 랭킹 계정에 연결. HMAC-signed payload로 본인 인증 +
// GitHub access token을 서버가 직접 GitHub API로 검증해 login/id를 확정한다.
// payload(서명 대상, flat): { deviceId, githubToken, ts }
//
// 배경(#293): users.github_login을 쓰는 경로가 register(등록 시점에 이미 연결돼 있던 경우)와
// recover-by-github(이미 연결된 계정 복구)뿐이었다. 즉 **랭킹 등록을 먼저 하고 GitHub을 나중에
// 연결한 계정**은 서버에 연결 사실을 전할 방법이 없어, 게시판 쓰기 게이트(board_policy.ts)가
// 영구히 잠긴 채였다 — 안내 카드의 "GitHub 연결…" 버튼을 눌러 인증을 마쳐도 달라지는 게 없었다.
//
// 토큰은 서명 대상에 포함한다 — 서명된 요청을 가로채 다른 토큰으로 바꿔 끼우는 것을 막는다.
// GitHub 토큰은 [A-Za-z0-9_]뿐이라 canonicalize 파리티에 영향이 없다.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { fetchGitHubUser } from "../_shared/github.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface Payload {
  deviceId: string;
  githubToken: string;
  ts: number;
}
interface Req {
  payload: Payload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: Req;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.githubToken !== "string" || p.githubToken.length < 20 || p.githubToken.length > 512) {
    return errorResponse(400, "invalid_github_token");
  }
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  // UUID 소문자 정규화 — 클라(Swift)는 대문자로 보내고 DB는 소문자. 서명 검증은 raw 값으로.
  const deviceId = p.deviceId.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status, github_login, github_user_id")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  // HMAC을 먼저 — 미인증 호출이 서버를 GitHub API 프록시로 쓰지 못하게 한다.
  const ok = await verifyHmac(
    { deviceId: p.deviceId, githubToken: p.githubToken, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  let gh;
  try {
    gh = await fetchGitHubUser(p.githubToken);
  } catch (e) {
    console.error("link-github: github verification failed", e);
    return errorResponse(401, "github_verification_failed");
  }

  // 멱등 — 이미 같은 계정이면 쓰기 없이 성공.
  if (Number(user.github_user_id) === gh.id && user.github_login === gh.login) {
    return jsonResponse({ githubLogin: gh.login, githubUserId: gh.id });
  }

  // 충돌 선검사 — 이 GitHub 계정이 다른 랭킹 계정에 이미 묶여 있으면 거부한다(한 GitHub = 한 user,
  // users_github_user_id_uniq). 그 사용자는 "GitHub으로 계정 복구"로 원래 계정을 되찾는 게 맞다.
  const { data: clash } = await db
    .from("users")
    .select("device_id")
    .eq("github_user_id", gh.id)
    .neq("device_id", deviceId)
    .limit(1);
  if (clash && clash.length > 0) return errorResponse(409, "github_linked_elsewhere");

  const { data: updated, error } = await db
    .from("users")
    .update({ github_login: gh.login, github_user_id: gh.id })
    .eq("device_id", deviceId)
    .select("github_login, github_user_id")
    .maybeSingle();
  if (error) {
    // UNIQUE 위반 — 선검사와 UPDATE 사이의 race. 409로 통일.
    if (error.code === "23505") return errorResponse(409, "github_linked_elsewhere");
    console.error("link-github update failed", error);
    return errorResponse(500, "update_failed");
  }
  if (!updated) return errorResponse(404, "device_not_registered");

  return jsonResponse({ githubLogin: updated.github_login, githubUserId: Number(updated.github_user_id) });
});
