// HMAC 서명 파리티 — 서버(TS) ↔ 클라(Swift).
//
// 랭킹 인증의 근간이다. 클라는 `JSONEncoder([.sortedKeys, .withoutEscapingSlashes])`로 payload를
// 직렬화해 HMAC-SHA256하고, 서버는 `canonicalize()`로 **같은 문자열을 재현**해 검증한다.
// 두 구현이 한 글자라도 갈라지면 서명이 어긋나 그 사용자만 조용히 막힌다 — 로그에는 401만 남는다.
//
// 배틀 엔진은 골든으로 잠겨 있으면서 정작 인증 경로엔 가드가 없었다. 아래 골든은
// `Tests/ClaudeUsageTests/HMACParityTests.swift`가 실제 Swift 구현으로 만든 값이며, 양쪽이
// **같은 상수**를 들고 있다. 한쪽 직렬화가 바뀌면 그쪽 테스트가 깨진다.
//
// 주의: canonicalize는 flat object만 지원한다. payload에 중첩 객체·배열을 넣는 순간 두 구현이
// 갈라지므로, 필드를 추가할 때는 여기 케이스도 함께 늘릴 것.
//
//   deno test supabase/functions/_shared/

import { canonicalize, importHmacKey, signHex, verifyHmac } from "./hmac.ts";

function assertEquals(got: unknown, exp: unknown, msg?: string) {
  const g = JSON.stringify(got), e = JSON.stringify(exp);
  if (g !== e) throw new Error(`${msg ? msg + " — " : ""}불일치\n  got: ${g}\n  exp: ${e}`);
}
function assert(cond: unknown, msg = "참이어야 한다"): asserts cond {
  if (!cond) throw new Error(msg);
}

/**
 * 테스트 전용 결정적 키 — 바이트 0…31. Swift `HMACParityTests.key`와 같은 값이며, 양쪽 다
 * base64 리터럴을 박지 않고 코드로 만든다(시크릿 스캐너가 실제 키로 오인한다).
 */
const KEY = btoa(String.fromCharCode(...Array.from({ length: 32 }, (_, i) => i)));
const DEVICE = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";

async function sign(payload: Record<string, unknown>): Promise<string> {
  return await signHex(await importHmacKey(KEY), canonicalize(payload));
}

Deno.test("submit payload 서명 — Swift 골든과 일치", async () => {
  assertEquals(
    await sign({ deviceId: DEVICE, delta: 1234, prevTotal: 56789, ts: 1800000000 }),
    "e774d82dd04e3273283fb23cef28fe812bb90978c8c2c19a36fa230c1ec92fbd");
});

Deno.test("claim-reward payload 서명 — Swift 골든과 일치", async () => {
  assertEquals(
    await sign({ deviceId: DEVICE, period: "2026-07", rank: 1, ts: 1800000000 }),
    "d1e89a2b73b4a32ff10322509cbafe7b9a9d19f2b31cb6600fcdbbcdde2b5ba7");
});

Deno.test("podium 메시지 서명 — 한글·슬래시·따옴표가 섞여도 일치", async () => {
  // 사용자가 입력한 한글이 그대로 서명 대상이 되는 유일한 payload다. non-ASCII를 raw UTF-8로
  // 낼 것인가 \\u 이스케이프할 것인가, `/`를 이스케이프할 것인가 — 셋 다 갈라질 수 있는 지점.
  assertEquals(
    await sign({ deviceId: DEVICE, message: '1등 했다! gg/wp "vibe"', period: "2026-07", rank: 1, ts: 1800000000 }),
    "99f920ba03db1f9c595f2aed5181e26f2ce24e7d00d8d0c273cf03adcb1cf8fc");
});

Deno.test("canonical 문자열 자체 — Swift JSONEncoder 출력과 바이트 동일", () => {
  // 서명만 비교하면 두 구현이 **둘 다** 같은 방식으로 틀렸을 때를 못 잡고, 실패해도 어디가
  // 어긋났는지 안 보인다. 중간 산물을 직접 고정한다.
  assertEquals(
    canonicalize({ deviceId: "dev-1", message: "한글/slash", period: "2026-07", rank: 2, ts: 42 }),
    '{"deviceId":"dev-1","message":"한글/slash","period":"2026-07","rank":2,"ts":42}');
});

Deno.test("canonicalize — 키를 정렬하고 입력 순서에 영향받지 않는다", () => {
  const a = canonicalize({ ts: 1, deviceId: "d", delta: 2 });
  const b = canonicalize({ delta: 2, deviceId: "d", ts: 1 });
  assertEquals(a, b, "키 순서가 다른 같은 객체");
  assertEquals(a, '{"delta":2,"deviceId":"d","ts":1}');
});

Deno.test("canonicalize — 슬래시를 이스케이프하지 않는다", () => {
  // Swift의 .withoutEscapingSlashes와 맞춰야 한다. JSON.stringify는 기본이 이미 그 동작이지만,
  // 누군가 커스텀 replacer를 넣는 순간 갈라지므로 고정해둔다.
  assertEquals(canonicalize({ u: "a/b/c" }), '{"u":"a/b/c"}');
});

Deno.test("verifyHmac — 올바른 서명은 통과, 한 글자만 달라도 거절", async () => {
  const payload = { deviceId: DEVICE, delta: 1, prevTotal: 0, ts: 1800000000 };
  const sig = await sign(payload);
  assert(await verifyHmac(payload, sig, KEY));

  // payload 변조
  assert(!await verifyHmac({ ...payload, delta: 2 }, sig, KEY), "delta를 바꾸면 실패해야 한다");
  // 서명 변조 (같은 길이 유지 — timingSafeEqualHex의 길이 선검사를 우회해 비교까지 가게 한다)
  const flipped = sig.slice(0, -1) + (sig.endsWith("a") ? "b" : "a");
  assert(!await verifyHmac(payload, flipped, KEY), "서명 한 글자만 달라도 실패해야 한다");
  // 길이가 다른 서명
  assert(!await verifyHmac(payload, sig.slice(0, -2), KEY));
  // 다른 키
  const otherKey = btoa(String.fromCharCode(...Array.from({ length: 32 }, () => 7)));
  assert(!await verifyHmac(payload, sig, otherKey));
});
