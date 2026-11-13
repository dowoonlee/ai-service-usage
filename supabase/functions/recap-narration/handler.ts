import { errorResponse, handleOptions, jsonResponse } from "../_shared/cors.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { knownPet, RECAP_YEAR, validateNarration, validateSummary, type RecapNarration, type RecapSummary } from "../_shared/recap.ts";

export interface SavedRecap {
  recap_year: number;
  pet_kind: string;
  narration: RecapNarration | null;
  generated_at: string | null;
  status: string;
}
export type RecapClaim =
  | { status: "generate"; facts: RecapSummary }
  | { status: "ready"; row: SavedRecap }
  | { status: "pending" | "failed"; retryAfter: number };
export interface RecapStore {
  user(device: string): Promise<{ hmac_key_b64: string; status: string } | null>;
  read(device: string, year: number, pet: string): Promise<SavedRecap | null>;
  claim(device: string, year: number, pet: string, facts: RecapSummary, token: string): Promise<RecapClaim>;
  finish(device: string, year: number, pet: string, token: string, narration: RecapNarration, model: string): Promise<boolean>;
  fail(device: string, year: number, pet: string, token: string): Promise<void>;
}
export interface RecapDependencies {
  store: RecapStore;
  generate?: (pet: string, facts: RecapSummary) => Promise<{ narration: RecapNarration; model: string }>;
  waitUntil: (job: Promise<void>) => void;
  now?: () => number;
}

async function readBody(req: Request): Promise<unknown> {
  // content-length가 없는 chunked 요청도 크기를 제한한다.
  const reader = req.body?.getReader();
  if (!reader) throw new Error("invalid_json");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > 20000) { await reader.cancel(); throw new Error("payload_too_large"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const data = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
  return JSON.parse(new TextDecoder().decode(data));
}

function ready(row: SavedRecap): Response {
  if (!row.generated_at) throw new Error("invalid_saved_recap");
  const narration = validateNarration(row.narration);
  return jsonResponse({ status: "ready", row: {
    year: row.recap_year, petKind: row.pet_kind, generatedAt: row.generated_at, ...narration,
  } });
}

export function createRecapHandler(deps: RecapDependencies): (req: Request) => Promise<Response> {
  return async (req) => {
    const preflight = handleOptions(req);
    if (preflight) return preflight;
    if (req.method !== "POST") return errorResponse(405, "method_not_allowed");
    let body: unknown;
    try { body = await readBody(req); } catch { return errorResponse(400, "invalid_request_body"); }
    if (!body || typeof body !== "object" || Array.isArray(body)) return errorResponse(400, "missing_payload");
    const { payload, signature } = body as Record<string, unknown>;
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) return errorResponse(400, "missing_payload");
    const p = payload as Record<string, unknown>;
    if (Object.keys(p).sort().join(",") !== "deviceId,petKind,summaryJson,ts,year"
      || !isValidUUID(p.deviceId) || p.year !== RECAP_YEAR || !knownPet(p.petKind)
      || typeof p.summaryJson !== "string" || p.summaryJson.length > 12000
      || typeof p.ts !== "number" || !Number.isSafeInteger(p.ts)
      || typeof signature !== "string" || !/^[a-f0-9]{64}$/.test(signature)) {
      return errorResponse(400, "invalid_payload");
    }
    const device = p.deviceId as string, year = p.year as number, pet = p.petKind as string;
    if (Math.abs(Math.floor((deps.now?.() ?? Date.now()) / 1000) - p.ts) > 3600) return errorResponse(400, "clock_skew");
    let facts: RecapSummary;
    try { facts = validateSummary(JSON.parse(p.summaryJson)); } catch { return errorResponse(400, "invalid_summary"); }

    try {
      const user = await deps.store.user(device);
      if (!user) return errorResponse(404, "device_not_registered");
      if (user.status === "banned") return errorResponse(403, "banned");
      if (!await verifyHmac(p, signature, user.hmac_key_b64)) return errorResponse(401, "bad_signature");

      const existing = await deps.store.read(device, year, pet);
      if (existing?.status === "ready") return ready(existing);
      if (!deps.generate) return errorResponse(503, "claude_not_configured");
      const token = crypto.randomUUID();
      const claim = await deps.store.claim(device, year, pet, facts, token);
      if (claim.status === "ready") return ready(claim.row);
      if (claim.status !== "generate") return jsonResponse(claim, { status: claim.status === "pending" ? 202 : 200 });

      const generate = deps.generate;
      deps.waitUntil((async () => {
        try {
          const result = await generate(pet, claim.facts);
          const narration = validateNarration(result.narration);
          // 일시적인 DB 오류에는 생성된 본문 저장만 재시도한다. Claude를 다시 호출하지 않는다.
          for (let attempt = 0; attempt < 3; attempt++) {
            try {
              await deps.store.finish(device, year, pet, token, narration, result.model);
              return; // false는 lease 만료다. 새 작업의 결과를 덮어쓰지 않는다.
            } catch {
              if (attempt === 2) throw new Error("recap_save_failed");
              await new Promise((resolve) => setTimeout(resolve, 250));
            }
          }
        } catch {
          // 집계·대사·Claude 오류 본문은 로그에 남기지 않는다.
          console.error("recap generation or persistence failed");
          try { await deps.store.fail(device, year, pet, token); }
          catch { console.error("recap failure state save failed"); }
        }
      })());
      return jsonResponse({ status: "pending", retryAfter: 3 }, { status: 202 });
    } catch {
      console.error("recap request failed");
      return errorResponse(500, "recap_unavailable");
    }
  };
}
