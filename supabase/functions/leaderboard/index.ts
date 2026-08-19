// GET /leaderboard?deviceId=<uuid>
// 월간 랭킹 — KST 기준 1일 00:00 ~ 다음 달 1일 00:00 윈도우. monthly_leaderboard view 사용.
// deviceId 없으면 익명 조회 (myRank/myTotalCoins = null).

//
// 조회 본체는 `_shared/leaderboard_query.ts` — `sync`가 같은 로직을 쓴다(stripBackup 포함).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { resolveTenant } from "../_shared/tenant.ts";
import { fetchLeaderboard, LeaderboardFetchError } from "../_shared/leaderboard_query.ts";

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return errorResponse(405, "method_not_allowed");

  const url = new URL(req.url);
  const deviceIdRaw = url.searchParams.get("deviceId");
  if (deviceIdRaw && !isValidUUID(deviceIdRaw)) {
    return errorResponse(400, "invalid_device_id");
  }
  // UUID 정규화(lowercase) — 클라이언트(Swift UUID.uuidString)는 대문자로 보내지만 Postgres는
  // 소문자로 저장. PostgREST .eq/.in(UUID 컬럼)은 대소문자 무시라 top myRank는 맞았지만,
  // 아래 JS 매칭(medalsByDevice.get / filtered.find)은 대소문자 구분이라 myMedals/previousMonth.myRank가
  // 깨졌다(소문자 DB값 !== 대문자 쿼리값). lowercase로 통일해 양쪽 다 매칭되게 한다.
  const deviceId = deviceIdRaw ? deviceIdRaw.toLowerCase() : null;

  const db = getDb();

  // 정산 lazy trigger는 아래 fetchLeaderboard 안에서 돈다(_shared/leaderboard_query.ts).
  // 여기서 또 부르면 요청당 3회가 6회가 된다 — 그 사이에 조기 return 경로도 없다.

  // 호출자 테넌트 결정. 미등록/익명(deviceId 없음)은 기본 테넌트(public) 보드를 본다.
  // 클라는 tenant를 주장할 수 없다 — 서버가 device_id로만 판정(§2-1).
  let tenant = "public";
  if (deviceId) {
    const t = await resolveTenant(db, deviceId);
    if (t) tenant = t;
  }

  try {
    return jsonResponse(await fetchLeaderboard(db, { tenant, deviceId }));
  } catch (error) {
    if (error instanceof LeaderboardFetchError) return errorResponse(500, "fetch_failed");
    throw error;
  }
});
