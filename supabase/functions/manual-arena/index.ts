import { getDb } from "../_shared/db.ts";
import { handleOptions, jsonResponse, errorResponse } from "../_shared/cors.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { makeBattle, publicState, submit, State, Command, Branch } from "../_shared/manual_battle.ts";
import { BattlePetSnapshot } from "../_shared/battle_engine.ts";

// Flat signed payload: nested command / branches are canonical JSON strings from the client.
interface Payload { action: string; deviceId: string; ts: number; requestId: string;
  battleId: string; revision: number; commandJson: string; branchesJson: string }
interface SessionRow { id: string; state_json: State; status: string; expires_at: string; eligible_kinds: string[] }
const fingerprint = async (text: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))))
  .map(b => b.toString(16).padStart(2, "0")).join("");
const response = (row: SessionRow) => {
  const state = publicState(row.state_json);
  if (row.status === "expired" || (!state.outcome && Date.parse(row.expires_at) <= Date.now())) {
    state.outcome = { winner: null, reason: "expired" };
  }
  return { state, eligibleKinds: row.eligible_kinds, expiresAt: row.expires_at };
};

Deno.serve(async req => {
  const preflight = handleOptions(req); if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");
  try {
    const raw = await req.text();
    if (raw.length > 16000) return errorResponse(413, "payload_too_large");
    const body = JSON.parse(raw), p = body.payload as Payload;
    if (!p || !isValidUUID(p.deviceId) || !isValidUUID(p.requestId) || typeof p.action !== "string"
      || !["status", "start", "state", "command"].includes(p.action) || !Number.isInteger(p.ts)
      || Math.abs(Math.floor(Date.now() / 1000) - p.ts) > 3600 || typeof body.signature !== "string"
      || !/^[a-f0-9]{64}$/i.test(body.signature) || typeof p.battleId !== "string" || !Number.isInteger(p.revision)
      || typeof p.commandJson !== "string" || typeof p.branchesJson !== "string") return errorResponse(400, "invalid_payload");
    const db = getDb();
    const { data: user, error: userError } = await db.from("users").select("device_id,hmac_key_b64,status,tenant_id").eq("device_id", p.deviceId).single();
    if (userError || !user) return errorResponse(404, "device_not_registered");
    if (user.status === "banned") return errorResponse(403, "banned");
    const signed = { action: p.action, deviceId: p.deviceId, ts: p.ts, requestId: p.requestId,
      battleId: p.battleId, revision: p.revision, commandJson: p.commandJson, branchesJson: p.branchesJson };
    if (!await verifyHmac(signed, body.signature, user.hmac_key_b64)) return errorResponse(401, "bad_signature");
    if (Deno.env.get("MANUAL_ARENA_ENABLED") !== "true") return p.action === "status"
      ? jsonResponse({ enabled: false, records: {}, active: null }) : errorResponse(503, "not_enabled");
    const tenant = user.tenant_id ?? "public";
    if (p.action === "status") {
      const [records, sessions, achievements] = await Promise.all([
        db.from("manual_pet_mastery").select("kind,wins,original_wins,alternate_wins").eq("device_id", p.deviceId),
        db.from("manual_arena_sessions").select("*").eq("device_id", p.deviceId).eq("tenant_id", tenant)
          .eq("status", "active").gt("expires_at", new Date().toISOString()).maybeSingle(),
        db.from("manual_achievements").select("achievement_id,progress,unlocked_at").eq("device_id", p.deviceId),
      ]);
      if (records.error || sessions.error || achievements.error) return errorResponse(500, "state_read_failed");
      return jsonResponse({ enabled: true, records: Object.fromEntries((records.data ?? []).map(r => [r.kind,
        { wins: r.wins, originalWins: r.original_wins, alternateWins: r.alternate_wins }])),
        active: sessions.data ? response(sessions.data as SessionRow) : null,
        achievements: {
          progress: Object.fromEntries((achievements.data ?? []).map(a => [a.achievement_id, a.progress])),
          unlocked: (achievements.data ?? []).filter(a => a.unlocked_at != null).map(a => a.achievement_id),
        } });
    }
    if (p.action === "start") {
      const branches = JSON.parse(p.branchesJson) as Record<string, Branch>;
      if (!branches || Array.isArray(branches) || Object.keys(branches).length > 5
        || Object.values(branches).some(b => b !== "original" && b !== "alternate")) return errorResponse(400, "invalid_branch");
      const hash = await fingerprint(`${p.commandJson}:${p.branchesJson}`);
      const { data: prior, error: priorError } = await db.from("manual_arena_sessions").select("*")
        .eq("device_id", p.deviceId).eq("tenant_id", tenant).eq("start_request_id", p.requestId).maybeSingle();
      if (priorError) return errorResponse(500, "state_read_failed");
      if (prior) return prior.start_fingerprint === hash ? jsonResponse(response(prior as SessionRow)) : errorResponse(409, "request_conflict");
      const { data: registered, error: teamError } = await db.from("pvp_teams").select("team_json")
        .eq("device_id", p.deviceId).eq("tenant_id", tenant).maybeSingle();
      if (teamError) return errorResponse(500, "team_read_failed");
      if (!registered || !Array.isArray(registered.team_json) || registered.team_json.length !== 5) return errorResponse(409, "team_not_full");
      const requested = JSON.parse(p.commandJson) as BattlePetSnapshot[];
      if (!Array.isArray(requested) || requested.length !== 5 || requested.some((pet, index) => {
        const registeredPet = registered.team_json[index];
        return !pet || pet.kind !== registeredPet.kind || pet.variant !== registeredPet.variant || pet.progressUnits !== registeredPet.progressUnits;
      })) return errorResponse(409, "team_changed");
      const { data: pool, error: poolError } = await db.from("pvp_teams").select("team_json").eq("tenant_id", tenant).neq("device_id", p.deviceId).limit(100);
      if (poolError) return errorResponse(500, "opponent_read_failed");
      const candidates = (pool ?? []).filter(r => Array.isArray(r.team_json) && r.team_json.length === 5);
      if (!candidates.length) return errorResponse(409, "no_opponent");
      const [enhancements, verified] = await Promise.all([
        db.from("pet_enhancements").select("kind,level").eq("device_id", p.deviceId),
        db.from("manual_verified_pets").select("kind,variant,progress_units,verified_at").eq("device_id", p.deviceId),
      ]);
      if (enhancements.error || verified.error) return errorResponse(500, "ownership_read_failed");
      const levels = new Map((enhancements.data ?? []).map(r => [r.kind, Number(r.level)]));
      const team: BattlePetSnapshot[] = registered.team_json.map((m: BattlePetSnapshot) => ({ ...m, enhanceLevel: levels.get(m.kind) ?? 0 }));
      // Every member must be verified: one verified rainbow alongside forged teammates must not earn medals.
      const allVerified = team.every(pet => (verified.data ?? []).some(v => v.kind === pet.kind && v.variant >= pet.variant && v.progress_units >= pet.progressUnits));
      const eligible = allVerified ? team.filter(p => p.variant === 4).map(p => p.kind) : [];
      const seed = crypto.getRandomValues(new BigUint64Array(1))[0] || 1n;
      const opponent = candidates[crypto.getRandomValues(new Uint32Array(1))[0] % candidates.length].team_json;
      const state = makeBattle(team, opponent, seed, crypto.randomUUID(), branches);
      state.achievementsEligible = allVerified;
      const { data, error } = await db.rpc("manual_arena_start", { p_id: state.id, p_device: p.deviceId, p_tenant: tenant,
        p_request: p.requestId, p_fingerprint: hash, p_state: state, p_eligible: eligible });
      if (error) return errorResponse(409, ["active_battle", "daily_limit", "request_conflict"].find(c => error.message.includes(c)) ?? "start_failed");
      return jsonResponse(response(data as SessionRow));
    }
    if (!isValidUUID(p.battleId)) return errorResponse(400, "invalid_battle_id");
    const { data: row, error } = await db.from("manual_arena_sessions").select("*").eq("id", p.battleId)
      .eq("device_id", p.deviceId).eq("tenant_id", tenant).maybeSingle();
    if (error) return errorResponse(500, "state_read_failed");
    if (!row) return errorResponse(404, "battle_not_found");
    if (p.action === "state") return jsonResponse(response(row as SessionRow));
    const hash = await fingerprint(`${p.revision}:${p.commandJson}`);
    const { data: cached, error: cacheError } = await db.from("manual_arena_requests").select("fingerprint,response")
      .eq("battle_id", p.battleId).eq("request_id", p.requestId).maybeSingle();
    if (cacheError) return errorResponse(500, "request_read_failed");
    if (cached) return cached.fingerprint === hash ? jsonResponse(cached.response) : errorResponse(409, "request_conflict");
    if (row.status !== "active" || Date.parse(row.expires_at) <= Date.now()) return errorResponse(409, "battle_closed");
    if (row.revision !== p.revision) return errorResponse(409, "revision_conflict");
    const state = submit(row.state_json as State, JSON.parse(p.commandJson) as Command);
    const publicResponse = response({ ...row, state_json: state } as SessionRow);
    const { data, error: commitError } = await db.rpc("manual_arena_commit", { p_id: p.battleId, p_device: p.deviceId,
      p_tenant: tenant, p_request: p.requestId, p_fingerprint: hash, p_revision: p.revision, p_state: state, p_response: publicResponse });
    if (commitError) return errorResponse(409, ["revision_conflict", "request_conflict", "battle_closed"].find(c => commitError.message.includes(c)) ?? "commit_failed");
    return jsonResponse(data);
  } catch (error) {
    if (error instanceof SyntaxError) return errorResponse(400, "invalid_json");
    if (error instanceof Error && ["invalid_command", "invalid_team", "invalid_branch"].includes(error.message)) return errorResponse(400, error.message);
    console.error("manual-arena request failed", error instanceof Error ? error.name : "unknown");
    return errorResponse(500, "internal_error");
  }
});
