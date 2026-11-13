// Deployed API + Claude smoke test using synthetic records. Always removes its own test account.
import { canonicalize, importHmacKey, signHex } from "../supabase/functions/_shared/hmac.ts";
import { SUMMARY_LIMITS, validateNarration } from "../supabase/functions/_shared/recap.ts";

const base = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "").replace(/\/rest\/v1$/, "");
const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
if (!base || !anon || !service) throw new Error("Missing Supabase environment");
const device = crypto.randomUUID();
const nickname = `RecapE2E${device.slice(0, 8)}`;
const summary = {
  ...Object.fromEntries(Object.keys(SUMMARY_LIMITS).map((k) => [k, 0])), partnerKind: "ninjaFrog",
  activeDays: 169, longestStreak: 17, claudeWeeklyGauges: 9.8, codexWeeklyGauges: 6.1,
  claudeFiveHourWallHits: 1, cursorUSD: 1137.6, goldenHour: 19, busiestWeekday: 0,
  pulls: 1802, speciesOwned: 195, shinySpecies: 173, prestigeSpecies: 1, partnerHours: 1835,
  badges: 70, collectionsCompleted: 19, arenaWins: 177, arenaBestRating: 1429,
  quizCorrect: 144, wellnessResponded: 208, claudeCoins: 8674, codexCoins: 22140, cursorCoins: 5642,
};
async function call(path: string, body: unknown) {
  const r = await fetch(`${base}/functions/v1/${path}`, {
    method: "POST", headers: { apikey: anon, Authorization: `Bearer ${anon}`, "Content-Type": "application/json" },
    body: JSON.stringify(body), signal: AbortSignal.timeout(25000),
  });
  return { status: r.status, data: await r.json() };
}
function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }

try {
  const reg = await call("register", { deviceId: device, nickname });
  assert(reg.status === 200 && typeof reg.data.hmacKey === "string", `register: HTTP ${reg.status}`);
  const hmac = await importHmacKey(reg.data.hmacKey);
  const request = async (pet: string, changed = false) => {
    const payload = { deviceId: device, petKind: pet,
      summaryJson: JSON.stringify(changed ? { ...summary, activeDays: 170 } : summary),
      ts: Math.floor(Date.now() / 1000), year: 2026 };
    return call("recap-narration", { payload, signature: await signHex(hmac, canonicalize(payload)) });
  };
  const saved: Record<string, unknown> = {};
  for (const pet of ["bear", "ninjaFrog"]) {
    const first = await Promise.all([request(pet), request(pet)]);
    assert(first.every((r) => r.status === 202 || r.status === 200), `initial ${pet}: HTTP ${first.map((r) => r.status)}`);
    let row;
    for (let i = 0; i < 50; i++) {
      const r = await request(pet);
      assert(r.status === 200 || r.status === 202, `poll ${pet}: HTTP ${r.status}`);
      assert(r.data.status !== "failed", `Claude generation failed for ${pet}`);
      if (r.data.status === "ready") { row = r.data.row; break; }
      await new Promise((resolve) => setTimeout(resolve, 3000));
    }
    assert(row, `Timed out waiting for ${pet}`);
    validateNarration(row);
    const again = await request(pet, true);
    assert(JSON.stringify(again.data.row) === JSON.stringify(row), "Cached story changed after repeated request");
    saved[pet] = row;
    console.log(`${pet}: 13 lines, repeated request identical. Persona: ${row.persona}`);
  }
  const check = await fetch(`${base}/rest/v1/recap_narrations?device_id=eq.${device}&select=pet_kind,status,attempts,model`, {
    headers: { apikey: service, Authorization: `Bearer ${service}` },
  });
  assert(check.ok, "Cannot inspect test cache");
  const rows = await check.json();
  assert(rows.length === 2 && rows.every((r: { attempts: number; status: string; model: string }) =>
    r.attempts === 1 && r.status === "ready" && r.model.startsWith("claude-")), "Expected one successful Claude attempt per pet");
  const output = Deno.env.get("RECAP_PREVIEW_OUT");
  if (output) await Deno.writeTextFile(output, JSON.stringify(saved, null, 2));
  console.log("PASS: Claude generation + DB cache + concurrent duplicate requests");
} finally {
  const r = await fetch(`${base}/rest/v1/users?device_id=eq.${device}`, {
    method: "DELETE", headers: { apikey: service, Authorization: `Bearer ${service}` },
  });
  await r.body?.cancel();
  assert(r.ok, `Test account cleanup failed: ${device}`);
  console.log("Test account and cached stories removed");
}
