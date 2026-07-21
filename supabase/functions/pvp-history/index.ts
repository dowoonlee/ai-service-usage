// POST /pvp-history
// 내 최근 랭크전 이력 (기획 §5-1) — 재생용 팀 스냅샷·로그 포함. 도전자/방어자 양방향.
//
// HMAC: flat payload {action, deviceId, ts}.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface HistPayload { action: string; deviceId: string; ts: number; }

const MAX_CLOCK_SKEW_SEC = 3600;
const LIMIT = 20;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: { payload: HistPayload; signature: string };
  try { body = await req.json(); } catch { return errorResponse(400, "invalid_json"); }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (p.action !== "history") return errorResponse(400, "invalid_action");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_payload_types");
  if (typeof body.signature !== "string" || body.signature.length !== 64) return errorResponse(400, "invalid_signature");
  if (Math.abs(Math.floor(Date.now() / 1000) - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  const db = getDb();
  const me = p.deviceId;

  const { data: user, error: userErr } = await db
    .from("users").select("hmac_key_b64, status").eq("device_id", me).single();
  if (userErr || !user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");
  const ok = await verifyHmac({ action: p.action, deviceId: me, ts: p.ts }, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  const { data: matches, error: mErr } = await db
    .from("pvp_matches")
    .select("id, challenger, defender, winner, challenger_delta, defender_delta, log_json, created_at")
    .or(`challenger.eq.${me},defender.eq.${me}`)
    .order("created_at", { ascending: false }).limit(LIMIT);
  if (mErr) { console.error("history fetch failed", mErr); return errorResponse(500, "history_read_failed"); }
  const rows = matches ?? [];

  // 상대 닉네임 일괄 조회.
  const oppIds = new Set<string>();
  for (const r of rows) {
    oppIds.add((r.challenger as string) === me ? (r.defender as string) : (r.challenger as string));
  }
  const nickById = new Map<string, string>();
  if (oppIds.size > 0) {
    const { data: us } = await db.from("users").select("device_id, nickname").in("device_id", [...oppIds]);
    for (const u of us ?? []) nickById.set(u.device_id as string, (u.nickname as string) ?? "익명");
  }

  const items = rows.map((r) => {
    const iAmChallenger = (r.challenger as string) === me;
    const opponent = iAmChallenger ? (r.defender as string) : (r.challenger as string);
    const winner = r.winner as string | null;
    const result = winner === me ? "me" : (winner === null ? "draw" : "opp");
    const ratingDelta = iAmChallenger ? Number(r.challenger_delta ?? 0) : Number(r.defender_delta ?? 0);
    const lj = (r.log_json ?? {}) as Record<string, unknown>;
    return {
      id: r.id as string,
      createdAt: r.created_at as string,
      iAmChallenger,
      opponentNickname: nickById.get(opponent) ?? "익명",
      result,                      // "me" | "opp" | "draw"
      ratingDelta,
      teamA: lj.teamA ?? [],       // 도전자 팀
      teamB: lj.teamB ?? [],       // 방어자 팀
      events: lj.events ?? [],
      maxHpA: lj.maxHpA ?? null,   // HP 실링(신규 로그만). 구 로그엔 없어 클라가 로컬 폴백.
      maxHpB: lj.maxHpB ?? null,
    };
  });

  return jsonResponse({ matches: items });
});
