// POST /pvp-challenge
// 랭크전 도전 (기획 §2-2 / §2-7 / §4). 서버가 authoritative로 승패를 확정한다 — 클라는 로그 재생만.
//
// 흐름: 일일 제한 검사 → 내 등록 팀 로드 → 유사 레이팅 상대 무작위 추출 → battle_engine 서버 시뮬
//   → Elo ±K 갱신 → pvp_matches 로그 → 일일 카운트 증가 → 승리 코인(로컬 경제)·로그 반환.
// 승패 위조 불가(서버 시뮬), 상대 지정 불가(무작위 추출)라 부계정 펌핑 방지.
//
// HMAC: flat payload {action, deviceId, ts} canonicalize.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { RATING_K, DAILY_RANK_LIMIT, WIN_COIN_BASE, RANKED_TEAM_SIZE } from "../_shared/pvp_policy.ts";
import { simulate, finalStats, BattleTeam } from "../_shared/battle_engine.ts";

interface ChallengePayload { action: string; deviceId: string; ts: number; }

const MAX_CLOCK_SKEW_SEC = 3600;
const RATING_WINDOW = 200;

function cryptoU63(): bigint {
  const b = crypto.getRandomValues(new Uint8Array(8));
  let v = 0n;
  for (const x of b) v = (v << 8n) | BigInt(x);
  return v >> 1n;   // 63비트 — 부호있는 BIGINT 범위에 안전.
}
function todayKst(): string {
  return new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: { payload: ChallengePayload; signature: string };
  try { body = await req.json(); } catch { return errorResponse(400, "invalid_json"); }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (p.action !== "challenge") return errorResponse(400, "invalid_action");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_payload_types");
  if (typeof body.signature !== "string" || body.signature.length !== 64) return errorResponse(400, "invalid_signature");
  if (Math.abs(Math.floor(Date.now() / 1000) - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  const db = getDb();
  const me = p.deviceId;

  const { data: user, error: userErr } = await db
    .from("users").select("device_id, hmac_key_b64, status, tenant_id").eq("device_id", me).single();
  if (userErr || !user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");
  const ok = await verifyHmac({ action: p.action, deviceId: me, ts: p.ts }, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");
  const tenant = (user.tenant_id as string) ?? "public";

  // 1) 일일 제한.
  const today = todayKst();
  const { data: dc } = await db
    .from("pvp_daily_counts").select("count").eq("device_id", me).eq("kst_date", today).maybeSingle();
  const dailyUsed = dc ? Number(dc.count) : 0;
  if (dailyUsed >= DAILY_RANK_LIMIT) return errorResponse(409, "daily_limit");

  // 2) 내 등록 팀.
  const { data: myTeamRow } = await db
    .from("pvp_teams").select("team_json").eq("device_id", me).maybeSingle();
  if (!myTeamRow) return errorResponse(409, "no_team");
  const myTeam = myTeamRow.team_json as BattleTeam;
  // 랭크전은 5v5 대칭 — 도전자도 5마리 풀팀 강제(클라 rankedReady==5 재확인, 서버 authoritative).
  if (!Array.isArray(myTeam) || myTeam.length !== RANKED_TEAM_SIZE) return errorResponse(409, "team_not_full");

  // 3) 상대 추출 — 같은 테넌트, 본인 아님, 유사 레이팅 우선(없으면 확장).
  let pool: { device_id: string; team_json: unknown; rating: number }[] = [];
  {
    const near = await db.from("pvp_teams").select("device_id, team_json, rating")
      .eq("tenant_id", tenant).neq("device_id", me)
      .gte("rating", 0).limit(100);   // 전체 후보 로드 후 JS에서 윈도우/무작위(레이팅 인덱스는 적음).
    // 5v5 대칭 강제 — 레거시 <5 등록 팀은 매칭 후보에서 제외(3v5 거저주기 방지). 재등록 시 재편입.
    pool = ((near.data ?? []) as typeof pool)
      .filter((o) => Array.isArray(o.team_json) && (o.team_json as unknown[]).length === RANKED_TEAM_SIZE);
  }
  if (pool.length === 0) return errorResponse(409, "no_opponent");
  const myRatingRow = await db.from("pvp_ratings").select("rating, wins, losses").eq("device_id", me).maybeSingle();
  const myRating = myRatingRow.data ? Number(myRatingRow.data.rating) : 1000;
  // 유사 레이팅 윈도우 우선.
  const near = pool.filter((o) => Math.abs(Number(o.rating) - myRating) <= RATING_WINDOW);
  const candidates = near.length > 0 ? near : pool;
  const opp = candidates[Math.floor(Math.random() * candidates.length)];
  const oppTeam = opp.team_json as BattleTeam;

  // 4) 서버 시뮬.
  const seed = cryptoU63();
  const result = simulate(myTeam, oppTeam, seed);
  // HP 바 실링(팀 시너지 + HP 스케일 반영). 클라가 로컬 재도출하면 엔진 버전 스큐 때 desync되므로
  // 서버가 계산해 응답/로그에 실어 클라가 그대로 렌더하게 한다(버전 무관). 팀 순서.
  const maxHpA = myTeam.map((m) => finalStats(m, myTeam).hp);
  const maxHpB = oppTeam.map((m) => finalStats(m, oppTeam).hp);
  const winSide = result.winner;   // "a"(나) | "b"(상대) | null(무승부)

  // 5) Elo.
  const oppRatingRow = await db.from("pvp_ratings").select("rating, wins, losses").eq("device_id", opp.device_id).maybeSingle();
  const oppRating = oppRatingRow.data ? Number(oppRatingRow.data.rating) : 1000;
  const expectedMe = 1 / (1 + Math.pow(10, (oppRating - myRating) / 400));
  const scoreMe = winSide === "a" ? 1 : (winSide === null ? 0.5 : 0);
  const nominalDelta = Math.round(RATING_K * (scoreMe - expectedMe));
  // 제로섬: 실제 이동량 = 패자가 실제로 내놓을 수 있는 만큼(0 바닥에 걸리면 그만큼만). 승자 획득 =
  // 패자 손실이라 총점이 보존된다 — 0 클램프로 승자만 전액 받던 기존 인플레(점수 순주입)를 봉합.
  const deltaMe = nominalDelta >= 0
    ? Math.min(nominalDelta, oppRating)     // opp → me (패자가 0 아래로는 못 내려감)
    : -Math.min(-nominalDelta, myRating);   // me → opp (내가 0 아래로는 못 내려감)
  const myNew = myRating + deltaMe;
  const oppNew = oppRating - deltaMe;

  const myWins = (myRatingRow.data ? Number(myRatingRow.data.wins) : 0) + (winSide === "a" ? 1 : 0);
  const myLosses = (myRatingRow.data ? Number(myRatingRow.data.losses) : 0) + (winSide === "b" ? 1 : 0);
  const oppWins = (oppRatingRow.data ? Number(oppRatingRow.data.wins) : 0) + (winSide === "b" ? 1 : 0);
  const oppLosses = (oppRatingRow.data ? Number(oppRatingRow.data.losses) : 0) + (winSide === "a" ? 1 : 0);
  const nowIso = new Date().toISOString();

  // 6) 매치 로그.
  const winnerDevice = winSide === "a" ? me : (winSide === "b" ? opp.device_id : null);
  // log_json에 팀 스냅샷도 저장 → pvp-history 재생 시 HP 바 렌더 가능. teamA=도전자, teamB=방어자.
  await db.from("pvp_matches").insert({
    tenant_id: tenant, challenger: me, defender: opp.device_id, seed: seed.toString(),
    winner: winnerDevice, challenger_delta: deltaMe, defender_delta: -deltaMe,
    log_json: { events: result.log, teamA: myTeam, teamB: oppTeam, maxHpA, maxHpB },
  });

  // 7) 레이팅 갱신(양측) + pvp_teams.rating 캐시.
  await db.from("pvp_ratings").upsert({ device_id: me, tenant_id: tenant, rating: myNew, wins: myWins, losses: myLosses, updated_at: nowIso });
  await db.from("pvp_ratings").upsert({ device_id: opp.device_id, tenant_id: tenant, rating: oppNew, wins: oppWins, losses: oppLosses, updated_at: nowIso });
  await db.from("pvp_teams").update({ rating: myNew }).eq("device_id", me);
  await db.from("pvp_teams").update({ rating: oppNew }).eq("device_id", opp.device_id);

  // 8) 일일 카운트 증가.
  await db.from("pvp_daily_counts").upsert({ device_id: me, kst_date: today, count: dailyUsed + 1 });

  // 9) 승리 코인(로컬 경제 — 서버는 금액만 반환, 클라가 CoinLedger로 크레딧).
  let coinReward = winSide === "a" ? WIN_COIN_BASE : (winSide === null ? 10 : 5);
  if (winSide === "a" && oppRating > myRating) coinReward += Math.min(30, Math.floor((oppRating - myRating) / 20));

  const oppUser = await db.from("users").select("nickname").eq("device_id", opp.device_id).maybeSingle();

  return jsonResponse({
    winner: winSide === "a" ? "me" : (winSide === "b" ? "opp" : "draw"),
    ratingDelta: deltaMe,
    newRating: myNew,
    coinReward,
    opponentNickname: (oppUser.data?.nickname as string) ?? "상대",
    myTeam, oppTeam, maxHpA, maxHpB,
    log: result.log,
    rounds: result.rounds,
    seed: seed.toString(),
    dailyUsed: dailyUsed + 1,
    dailyLimit: DAILY_RANK_LIMIT,
  });
});
