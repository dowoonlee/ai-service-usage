// GET /board?deviceId=<uuid>
// 최근 100개 게시글 + 각 글의 좋아요 정보 (count + 누른 사람 목록).
//
// deviceId 옵션:
//   * isMine — 본인 글 표시
//   * likedByMe — 본인이 좋아요 누른 글 표시
//   * cooldownRemainingSec — 다음 글 작성까지 남은 초 (10분 cooldown 기준)
//
// likers는 popover 호버용 — 50명 커뮤니티 가정으로 매 응답에 inline 포함 (별도 fetch X).
//
// 조회 본체는 `_shared/board_query.ts` — `sync`가 같은 로직을 쓴다(익명 닉네임 시드 포함).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { outdatedClientResponse } from "../_shared/min_version.ts";
import { resolveTenant } from "../_shared/tenant.ts";
import { fetchBoard, BoardFetchError } from "../_shared/board_query.ts";
Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return errorResponse(405, "method_not_allowed");

  const url = new URL(req.url);
  const deviceId = url.searchParams.get("deviceId");
  if (deviceId && !isValidUUID(deviceId)) {
    return errorResponse(400, "invalid_device_id");
  }
  // Postgres UUID 컬럼은 소문자로 정규화 저장되는데 클라(Swift UUID)는 대문자를 보낸다.
  // isMine/likedByMe를 JS 문자열 `===`로 비교하므로 양쪽을 소문자로 맞추지 않으면 항상 false가
  // 되어 재진입 시 하트/'나' 배지가 사라진다(leaderboard/index.ts:52 선례).
  const deviceIdLower = deviceId ? deviceId.toLowerCase() : null;

  const db = getDb();

  // 구버전 게이트 — 아래 글/좋아요/댓글 조회 전에 끊는다. 익명(deviceId 없음)은 버전을 알 수 없어 통과.
  if (deviceIdLower) {
    const { data: caller } = await db
      .from("users")
      .select("app_version")
      .eq("device_id", deviceIdLower)
      .maybeSingle();
    const outdated = outdatedClientResponse(caller?.app_version);
    if (outdated) return outdated;
  }

  // 호출자 테넌트 — 미등록/익명(deviceId 없음)은 기본(public) 게시판. 클라는 tenant를 주장 못 한다(§2-1).
  let tenant = "public";
  if (deviceId) {
    const t = await resolveTenant(db, deviceId);
    if (t) tenant = t;
  }

  try {
    return jsonResponse(await fetchBoard(db, { tenant, deviceId, deviceIdLower }));
  } catch (error) {
    if (error instanceof BoardFetchError) return errorResponse(500, "fetch_failed");
    throw error;
  }
});
