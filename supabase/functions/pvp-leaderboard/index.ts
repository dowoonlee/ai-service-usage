// POST /pvp-leaderboard
// 아레나 레이팅 랭킹 + 내 순위·전적·오늘 판수 (기획 §2-7 / §5-1). 테넌트 스코프.
//
// (시즌 정산 finalize_previous_month_pvp_if_needed lazy 트리거는 T6에서 추가 — 여기선 랭킹 조회만.)
//
// HMAC: flat payload {action, deviceId, ts}. 내 순위 계산에 deviceId 필요.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { DAILY_RANK_LIMIT } from "../_shared/pvp_policy.ts";

interface LbPayload { action: string; deviceId: string; ts: number; }

const MAX_CLOCK_SKEW_SEC = 3600;
const TOP_N = 50;

function todayKst(): string {
  return new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: { payload: LbPayload; signature: string };
  try { body = await req.json(); } catch { return errorResponse(400, "invalid_json"); }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (p.action !== "leaderboard") return errorResponse(400, "invalid_action");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_payload_types");
  if (typeof body.signature !== "string" || body.signature.length !== 64) return errorResponse(400, "invalid_signature");
  if (Math.abs(Math.floor(Date.now() / 1000) - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  const db = getDb();
  const me = p.deviceId;

  const { data: user, error: userErr } = await db
    .from("users").select("hmac_key_b64, status, tenant_id").eq("device_id", me).single();
  if (userErr || !user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");
  const ok = await verifyHmac({ action: p.action, deviceId: me, ts: p.ts }, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");
  const tenant = (user.tenant_id as string) ?? "public";

  // 시즌 정산 lazy 트리거 — 직전 달 미정산이면 RP·확정권 지급(멱등). leaderboard 조회 때마다 체크.
  const { error: finErr } = await db.rpc("finalize_previous_month_pvp_if_needed");
  if (finErr) console.error("season finalize failed (ignored)", finErr);

  // Top N 레이팅.
  const { data: top, error: topErr } = await db
    .from("pvp_ratings").select("device_id, rating, wins, losses")
    .eq("tenant_id", tenant).order("rating", { ascending: false }).limit(TOP_N);
  if (topErr) { console.error("lb fetch failed", topErr); return errorResponse(500, "lb_read_failed"); }
  const rows = top ?? [];

  // 닉네임 일괄 조회.
  const ids = rows.map((r) => r.device_id as string);
  const nickById = new Map<string, string>();
  if (ids.length > 0) {
    const { data: us } = await db.from("users").select("device_id, nickname").in("device_id", ids);
    for (const u of us ?? []) nickById.set(u.device_id as string, (u.nickname as string) ?? "익명");
  }
  const entries = rows.map((r, i) => ({
    rank: i + 1,
    nickname: nickById.get(r.device_id as string) ?? "익명",
    rating: Number(r.rating),
    wins: Number(r.wins),
    losses: Number(r.losses),
    isMe: (r.device_id as string) === me,
  }));

  // 내 레이팅·전적·순위.
  const { data: mine } = await db
    .from("pvp_ratings").select("rating, wins, losses").eq("device_id", me).maybeSingle();
  let myRating: number | null = null, myWins = 0, myLosses = 0, myRank: number | null = null;
  if (mine) {
    myRating = Number(mine.rating); myWins = Number(mine.wins); myLosses = Number(mine.losses);
    const { count } = await db.from("pvp_ratings")
      .select("device_id", { count: "exact", head: true })
      .eq("tenant_id", tenant).gt("rating", myRating);
    myRank = (count ?? 0) + 1;
  }

  // 오늘 판수.
  const { data: dc } = await db
    .from("pvp_daily_counts").select("count").eq("device_id", me).eq("kst_date", todayKst()).maybeSingle();

  // 지난 시즌 시상대 — 가장 최근 정산 period의 챔피언(최고 RP grant) + 내 보상.
  let lastSeason: { period: string; championNickname: string | null; myRp: number } | null = null;
  const { data: seasonRow } = await db
    .from("pvp_seasons").select("period").order("period", { ascending: false }).limit(1).maybeSingle();
  if (seasonRow) {
    const period = seasonRow.period as string;
    const prefix = `pvp-season-${period}-`;
    const { data: champ } = await db.from("reward_grants")
      .select("device_id, amount").eq("currency", "rp")
      .like("grant_key", `${prefix}%`).order("amount", { ascending: false }).limit(1).maybeSingle();
    let championNickname: string | null = null;
    if (champ) {
      const { data: cu } = await db.from("users").select("nickname").eq("device_id", champ.device_id).maybeSingle();
      championNickname = (cu?.nickname as string) ?? null;
    }
    const { data: myG } = await db.from("reward_grants").select("amount")
      .eq("device_id", me).eq("currency", "rp").like("grant_key", `${prefix}%`).maybeSingle();
    lastSeason = { period, championNickname, myRp: myG ? Number(myG.amount) : 0 };
  }

  return jsonResponse({
    entries, myRank, myRating, myWins, myLosses,
    dailyUsed: dc ? Number(dc.count) : 0,
    dailyLimit: DAILY_RANK_LIMIT,
    lastSeason,
  });
});
