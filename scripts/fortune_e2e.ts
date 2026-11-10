// 배포된 fortune Edge Function E2E — 테스트 device를 등록하고 HMAC 서명한 운세 요청을 보낸 뒤 정리한다.
// Claude 키는 Supabase secret에만 있으면 된다(로컬 키 불필요). sanity_check_ranking.sh와 같은 방식.
//
//   bash scripts/fortune_e2e.sh            # ranking.env 를 source 하고 이 파일을 실행
//
// 필요 env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY(정리용).
import { canonicalize, importHmacKey, signHex } from "../supabase/functions/_shared/hmac.ts";

const url = Deno.env.get("SUPABASE_URL") ?? "";
const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
if (!url || !anon || !service) {
  console.error("SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY 가 필요합니다 (scripts/ranking.env).");
  Deno.exit(2);
}

// sanity_check와 겹치지 않는 고정 테스트 device — 이전 실행이 중단됐어도 사전 정리로 복구된다.
const TEST_DEVICE_ID = "00000000-0000-0000-0000-00000000f0e7";
// 카나리 배포(예: fortune-canary)를 때릴 때 FORTUNE_FN 으로 함수 이름을 바꾼다. 기본은 운영 함수.
const FORTUNE_FN = Deno.env.get("FORTUNE_FN") || "fortune";
const TEST_NICKNAME = "FortuneE2EUser";

async function fn(path: string, body: unknown): Promise<{ status: number; json: Record<string, unknown> }> {
  const resp = await fetch(`${url}/functions/v1/${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${anon}`, apikey: anon, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await resp.text();
  let json: Record<string, unknown> = {};
  try { json = JSON.parse(text); } catch { json = { raw: text.slice(0, 200) }; }
  return { status: resp.status, json };
}

async function cleanup(): Promise<number> {
  // users 삭제 → daily_fortunes는 ON DELETE CASCADE.
  const resp = await fetch(`${url}/rest/v1/users?device_id=eq.${TEST_DEVICE_ID}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${service}`, apikey: service },
  });
  return resp.status;
}

function todayKst(): string {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: "Asia/Seoul", year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(new Date());
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "00";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

let failed = false;
const ok = (m: string) => console.log(`  ✓ ${m}`);
const bad = (m: string) => { failed = true; console.log(`  ✗ ${m}`); };

console.log(`target=${FORTUNE_FN}`);
console.log("1. 사전 정리"); console.log(`  users delete → HTTP ${await cleanup()}`);

console.log("2. register");
const reg = await fn("register", { deviceId: TEST_DEVICE_ID, nickname: TEST_NICKNAME });
const hmacKey = typeof reg.json.hmacKey === "string" ? reg.json.hmacKey : "";
if (reg.status === 200 && hmacKey) ok("200 + hmacKey"); else bad(`register ${reg.status} ${JSON.stringify(reg.json).slice(0, 120)}`);

if (hmacKey) {
  const key = await importHmacKey(hmacKey);
  const saju = {
    year: { stem: 6, branch: 7 }, month: { stem: 3, branch: 10 }, day: { stem: 0, branch: 2 }, hour: { stem: 8, branch: 0 },
    fiveElementCounts: ["목", 3, "화", 1, "토", 2, "금", 1, "수", 1],
  };
  const daily = { today: { stem: 2, branch: 5 }, relation: "상생" };
  const call = async (label: string) => {
    const payload = {
      date: todayKst(),
      dailyJson: JSON.stringify(daily),
      deviceId: TEST_DEVICE_ID,
      sajuJson: JSON.stringify(saju),
      ts: Math.floor(Date.now() / 1000),
    };
    const signature = await signHex(key, canonicalize(payload));
    const t0 = performance.now();
    const r = await fn(FORTUNE_FN, { payload, signature });
    const ms = Math.round(performance.now() - t0);
    const row = (r.json.row ?? {}) as Record<string, unknown>;
    console.log(`${label}: HTTP ${r.status} ${ms}ms model=${row.model ?? "-"} cached=${row.cached ?? "-"}`);
    if (r.status !== 200) bad(`fortune ${r.status} ${JSON.stringify(r.json).slice(0, 200)}`);
    return row;
  };

  console.log("3. fortune (캐시 미스 → Claude 호출)");
  const first = await call("  first");
  if (typeof first.model === "string" && first.model.startsWith("claude-")) ok(`model 라벨 ${first.model}`); else bad(`model 라벨이 claude-* 가 아님: ${first.model}`);
  if (first.cached === false) ok("cached=false"); else bad(`cached=${first.cached}`);
  const text = typeof first.fortuneText === "string" ? first.fortuneText : "";
  if (text.length >= 80) ok(`fortuneText ${text.length}자`); else bad(`fortuneText 너무 짧음(${text.length}자)`);
  console.log("  ---"); console.log("  " + text.replace(/\n/g, "\n  ")); console.log("  ---");

  console.log("4. fortune 재호출 (같은 라벨 → 캐시)");
  const second = await call("  second");
  if (second.cached === true && second.fortuneText === text) ok("cached=true, 동일 텍스트"); else bad(`cached=${second.cached}`);
}

console.log("5. 사후 정리"); console.log(`  users delete → HTTP ${await cleanup()}`);
console.log(failed ? "\nFAIL" : "\nPASS");
Deno.exit(failed ? 1 : 0);
