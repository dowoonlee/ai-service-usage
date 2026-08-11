// worker.js의 게이트 로직 검증 — 실제 Supabase 포워딩은 하지 않고 차단 판정만 본다.
const mod = await import('./worker.js');
const worker = mod.default;

let pass = 0, fail = 0;
const check = (name, cond) => { cond ? pass++ : (fail++, console.log("  ✗ " + name)); };

const env = {
  MIN_APP_VERSION: "0.17.18",
  BLOCKED_DEVICE_IDS: "60796649-6F33-4FF3-9EBC-4ACA814092DB, e38d111f-e11c-42a1-8084-cc09d4de9d67",
};

// 1) health
let r = await worker.fetch(new Request("https://p.dev/__health"), env);
const health = await r.json();
check("health 200", r.status === 200);
check("health가 차단 수 보고", health.blockedDevices === 2 && health.minVersion === "0.17.18");

// 2) 버전 게이트
r = await worker.fetch(new Request("https://p.dev/functions/v1/sync", {
  method: "POST", headers: { "X-App-Version": "0.16.10" }, body: "{}" }), env);
check("구버전 426", r.status === 426);

r = await worker.fetch(new Request("https://p.dev/functions/v1/sync", {
  method: "POST", headers: { "X-App-Version": "0.17.9" }, body: "{}" }), env);
check("0.17.9 < 0.17.18 → 426", r.status === 426);

// 숫자 비교 확인 — 사전순이면 "0.17.9" > "0.17.18" 로 잘못 통과한다
r = await worker.fetch(new Request("https://p.dev/functions/v1/sync", {
  method: "POST", headers: { "X-App-Version": "0.17.20" }, body: "{}" }), env);
check("0.17.20 통과(사전순 버그 아님)", r.status !== 426);

// 3) deviceId 차단 — GET 쿼리
r = await worker.fetch(new Request(
  "https://p.dev/functions/v1/board?deviceId=60796649-6F33-4FF3-9EBC-4ACA814092DB",
  { headers: { "X-App-Version": "0.17.18" } }), env);
check("GET 쿼리 deviceId 403", r.status === 403);

// 4) deviceId 차단 — POST payload (대소문자 무관)
r = await worker.fetch(new Request("https://p.dev/functions/v1/dm-thread", {
  method: "POST", headers: { "X-App-Version": "0.17.18" },
  body: JSON.stringify({ payload: { deviceId: "E38D111F-E11C-42A1-8084-CC09D4DE9D67" }, signature: "x" }) }), env);
check("POST payload deviceId 403 (대소문자 무관)", r.status === 403);

// 5) 헤더 없으면 fail-open (버전 게이트 통과)
r = await worker.fetch(new Request("https://p.dev/__health"), { ...env, MIN_APP_VERSION: "9.9.9" });
check("헤더 없는 요청은 버전 게이트 통과", r.status === 200);

// 6) OPTIONS는 Supabase로 안 감
r = await worker.fetch(new Request("https://p.dev/functions/v1/sync", { method: "OPTIONS" }), env);
check("OPTIONS 204 로컬 종료", r.status === 204);

console.log(`\n통과 ${pass} / 실패 ${fail}`);
process.exit(fail ? 1 : 0);
