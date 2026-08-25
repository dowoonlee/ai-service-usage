// 서버 정책 모듈의 순수 로직 테스트.
//
// 여기 있는 함수들은 전부 "거절/허용"을 가르는 경계다. 클라이언트 검증은 UX 보조일 뿐이고
// 실제 방어선은 이쪽인데, 지금까지 테스트가 한 건도 없었다 — 배틀/강화 엔진만 파리티 골든으로
// 잠겨 있고 나머지 정책은 배포해봐야 알 수 있는 상태였다.
//
//   deno test supabase/functions/_shared/
//
// DB를 타는 함수(resolveTenant, checkJoinCooldown 등)는 여기서 다루지 않는다. 경계 판정 로직만
// 잘라서 본다 — 그 부분이 바뀌면 사용자가 조용히 막히거나 조용히 뚫린다.

// 외부 의존을 두지 않는다 — 사내망에서 JSR 다운로드가 막혀 CI/로컬 어느 쪽도 못 돌게 된다.
// pvp_engine.parity.test.ts도 같은 이유로 자체 assert를 쓴다.
function assert(cond: unknown, msg = "참이어야 한다"): asserts cond {
  if (!cond) throw new Error(msg);
}
function assertFalse(cond: unknown, msg = "거짓이어야 한다") {
  if (cond) throw new Error(msg);
}
function assertEquals(got: unknown, exp: unknown, msg?: string) {
  const g = JSON.stringify(got), e = JSON.stringify(exp);
  if (g !== e) throw new Error(`${msg ? msg + " — " : ""}불일치\n  got: ${g}\n  exp: ${e}`);
}

import { evaluateCap, maxAllowedDelta } from "./caps.ts";
import { generateRecoveryCode, hashRecoveryCode, isValidNickname, isValidUUID } from "./validation.ts";
import { emailDomain, isReverifyExpired, maskEmails, normDeviceId } from "./tenant.ts";
import { compareVersions, MIN_APP_VERSION, outdatedClientResponse } from "./min_version.ts";
import { boardInteractionBlocked } from "./board_policy.ts";
import {
  generateInviteCode,
  GUILD_LOGO_SAMPLE_COUNT,
  isValidGuildLogo,
  isValidGuildLogoPos,
  isValidGuildName,
  INVITE_CODE_LEN,
} from "./guild_policy.ts";
import { stripBackup } from "./profile.ts";

// ============================================================================
// caps — 코인 delta 상한
// ============================================================================

Deno.test("캡 — 경과 시간에 비례하되 floor/ceiling으로 잘린다", () => {
  // 짧은 경과라도 floor 5000은 보장한다. 컬렉션 보너스 burst(Legendary 25,000)와
  // catch-up 누적 제출을 흡수하기 위한 값 (1000 시절 정상 제출이 잘려 영구 소실됐다).
  assertEquals(maxAllowedDelta(0), 5000);
  assertEquals(maxAllowedDelta(-99), 5000, "음수 경과는 0으로 클램프");
  // 0.05 coin/sec — floor를 넘어서는 건 100,000s(~28h)부터. 하루(86400s)는 아직 floor.
  assertEquals(maxAllowedDelta(86_400), 5000);
  assertEquals(maxAllowedDelta(2 * 86_400), 8640);
  // ceiling 50,000을 넘지 않는다. 한 달 비활성 후 복귀해도 여기서 잘린다.
  assertEquals(maxAllowedDelta(30 * 86_400), 50_000);
  assertEquals(maxAllowedDelta(365 * 86_400), 50_000);
});

Deno.test("캡 — 상한 이하는 통과, 초과는 잘라서 수용", () => {
  const base = { elapsedSeconds: 2 * 86_400, prevTotalReported: 10_000, prevTotalServer: 10_000 };
  assertEquals(evaluateCap({ ...base, delta: 100 }), { kind: "ok", accepted: 100 });
  assertEquals(evaluateCap({ ...base, delta: 8640 }), { kind: "ok", accepted: 8640 });
  // 초과분은 거절이 아니라 절삭 — 정상 사용자가 오래 쉬었다 돌아온 경우를 막지 않기 위해서다.
  assertEquals(evaluateCap({ ...base, delta: 999_999 }),
    { kind: "truncated", accepted: 8640, requested: 999_999 });
});

Deno.test("캡 — 망가진 입력은 거절", () => {
  const base = { elapsedSeconds: 86_400, prevTotalReported: 0, prevTotalServer: 0 };
  for (const delta of [-1, NaN, Infinity, 2_000_000_000]) {
    assertEquals(evaluateCap({ ...base, delta }).kind, "rejected", `delta=${delta}`);
  }
  assertEquals(evaluateCap({ delta: 10, elapsedSeconds: -1, prevTotalReported: 0, prevTotalServer: 0 }).kind,
    "rejected");
  assertEquals(evaluateCap({ delta: 10, elapsedSeconds: NaN, prevTotalReported: 0, prevTotalServer: 0 }).kind,
    "rejected");
});

Deno.test("캡 — prevTotal 드리프트는 작으면 허용, 크면 거절", () => {
  const mk = (reported: number, server: number) =>
    evaluateCap({ delta: 10, elapsedSeconds: 86_400, prevTotalReported: reported, prevTotalServer: server });
  // 절대 허용치 1000 — 잔액이 작을 때 네트워크 race/캐시 stale을 흡수한다.
  assertEquals(mk(1000, 0).kind, "ok");
  assertEquals(mk(1001, 0).kind, "rejected");
  // 잔액이 크면 10%까지 허용 (100,000의 10% = 10,000).
  assertEquals(mk(110_000, 100_000).kind, "ok");
  assertEquals(mk(110_001, 100_000).kind, "rejected");
  // 방향 무관 — 서버가 더 큰 경우도 같은 폭으로 본다.
  assertEquals(mk(90_000, 100_000).kind, "ok");
  assertEquals(mk(89_000, 100_000).kind, "rejected");
});

// ============================================================================
// validation — 닉네임 / UUID / 복구 코드
// ============================================================================

Deno.test("닉네임 — 길이 경계와 공백·제어문자 금지", () => {
  assertFalse(isValidNickname("ab"), "2자는 짧다");
  assert(isValidNickname("abc"));
  assert(isValidNickname("a".repeat(24)));
  assertFalse(isValidNickname("a".repeat(25)));
  assert(isValidNickname("한글닉네임"), "한글은 허용");
  assert(isValidNickname("emoji🎉ok"), "이모지는 막지 않는다");

  assertFalse(isValidNickname("has space"));
  assertFalse(isValidNickname("tab\there"));
  assertFalse(isValidNickname("new\nline"));
  assertFalse(isValidNickname("ctrl\x01char"));
  assertFalse(isValidNickname("del\x7f"));
  assertFalse(isValidNickname(123 as unknown));
  assertFalse(isValidNickname(null));
  assertFalse(isValidNickname(undefined));
});

Deno.test("UUID — 형식만 보고 버전은 따지지 않는다", () => {
  assert(isValidUUID("3f2504e0-4f89-11d3-9a0c-0305e82c3301"));
  assert(isValidUUID("3F2504E0-4F89-11D3-9A0C-0305E82C3301"), "대문자 허용");
  assertFalse(isValidUUID("3f2504e04f8911d39a0c0305e82c3301"), "dash 없으면 거절");
  assertFalse(isValidUUID("3f2504e0-4f89-11d3-9a0c-0305e82c330"), "짧으면 거절");
  assertFalse(isValidUUID("zzzzzzzz-4f89-11d3-9a0c-0305e82c3301"), "hex 아닌 문자");
  assertFalse(isValidUUID(""));
  assertFalse(isValidUUID(42 as unknown));
});

Deno.test("복구 코드 — 헷갈리는 글자를 쓰지 않고 형식이 고정된다", () => {
  const code = generateRecoveryCode();
  assert(/^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(code), code);
  // O/0, I/1, L/S/Z 같은 혼동 문자는 애초에 후보에서 빠져 있다 — 사용자가 받아적는 값이라 중요하다.
  for (const banned of ["O", "I", "L", "S", "Z", "0", "1"]) {
    assertFalse(code.includes(banned), `${banned} 가 코드에 있으면 안 된다: ${code}`);
  }
});

Deno.test("복구 코드 해시 — 대소문자·dash를 무시하고 같은 값이 된다", async () => {
  const a = await hashRecoveryCode("ABCD-EFGH-JKMN");
  assertEquals(await hashRecoveryCode("abcd-efgh-jkmn"), a, "소문자 입력");
  assertEquals(await hashRecoveryCode("ABCDEFGHJKMN"), a, "dash 없는 입력");
  assertEquals(await hashRecoveryCode("aBcD-EfGh-JkMn"), a, "혼합");
  assertEquals(a.length, 64, "SHA-256 hex");
  assert(a !== await hashRecoveryCode("ABCD-EFGH-JKMP"), "다른 코드는 다른 해시");
});

// ============================================================================
// tenant — 격리 판정
// ============================================================================

Deno.test("device_id — 항상 소문자로 정규화", () => {
  // 클라(Swift)는 대문자로 보내고 DB는 소문자로 저장한다. JS에서 매칭할 때 케이스가 어긋나면
  // 조용히 "다른 사람"이 된다(leaderboard 메달 매칭이 실제로 그렇게 깨졌다).
  assertEquals(normDeviceId("3F2504E0-4F89-11D3-9A0C-0305E82C3301"),
               "3f2504e0-4f89-11d3-9a0c-0305e82c3301");
  assertEquals(normDeviceId("already-lower"), "already-lower");
});

Deno.test("재인증 만료 — 기한 없음/미래는 유효, 과거는 만료", () => {
  assertFalse(isReverifyExpired(null), "기한 없음 = 재인증 요구 없음");
  assertFalse(isReverifyExpired(undefined));
  assertFalse(isReverifyExpired(""), "빈 문자열도 요구 없음으로");
  const future = new Date(Date.now() + 86_400_000).toISOString();
  const past = new Date(Date.now() - 86_400_000).toISOString();
  assertFalse(isReverifyExpired(future));
  assert(isReverifyExpired(past));
});

Deno.test("이메일 도메인 추출 — 정규화하고 형식이 아니면 null", () => {
  assertEquals(emailDomain("User@SK.com"), "sk.com");
  assertEquals(emailDomain("  spaced@sk.com  "), "sk.com");
  assertEquals(emailDomain("sub@mail.sk.co.kr"), "mail.sk.co.kr");
  assertEquals(emailDomain("no-at-sign"), null);
  assertEquals(emailDomain("no@tld"), null, "점 없는 도메인은 거절");
  assertEquals(emailDomain("two@@at.com"), null);
  assertEquals(emailDomain("has space@sk.com"), null);
});

Deno.test("이메일 마스킹 — 로컬파트 첫 글자만 남는다", () => {
  // SMTP 거부 응답이 수신 주소를 echo해 로그로 새는 걸 막는 장치라, 원문이 남으면 안 된다.
  assertEquals(maskEmails("user@sk.com"), "u***@sk.com");
  assertEquals(maskEmails("RCPT failed: alice.kim@sk.com not found"),
               "RCPT failed: a***@sk.com not found");
  assertEquals(maskEmails("a@b.co and c@d.co"), "a***@b.co and c***@d.co");
  assertEquals(maskEmails("no email here"), "no email here");
});

// ============================================================================
// min_version — 구버전 클라이언트 게이트
// ============================================================================

Deno.test("버전 비교 — 자리수가 달라도 숫자로 비교", () => {
  assertEquals(compareVersions("1.0.0", "1.0.0"), 0);
  assertEquals(compareVersions("0.17.10", "0.17.9"), 1, "10 > 9 — 문자열 비교였다면 뒤집힌다");
  assertEquals(compareVersions("0.9.0", "0.10.0"), -1);
  assertEquals(compareVersions("1.0", "1.0.0"), 0, "짧은 쪽은 0으로 채운다");
  assertEquals(compareVersions("1.0.1", "1.0"), 1);
  assertEquals(compareVersions("", "0.0.0"), 0, "빈 문자열은 0.0.0");
});

Deno.test("게이트 — 버전 미상은 통과시키고 구버전만 426", async () => {
  // 등록 직후 첫 submit 전에는 users.app_version이 비어 있다. 여기서 막으면 신규 사용자가
  // 시작도 못 한다.
  assertEquals(outdatedClientResponse(null), null);
  assertEquals(outdatedClientResponse(undefined), null);
  assertEquals(outdatedClientResponse(""), null);

  assertEquals(outdatedClientResponse(MIN_APP_VERSION), null, "최소 버전 자체는 통과");
  assertEquals(outdatedClientResponse("99.0.0"), null);

  const res = outdatedClientResponse("0.1.0");
  assert(res, "구버전은 응답이 나와야 한다");
  assertEquals(res.status, 426);
  // 평문이어야 한다 — 구버전 클라의 에러 매핑이 JSON body를 그대로 노출한다.
  assert(res.headers.get("Content-Type")?.startsWith("text/plain"));
  assert((await res.text()).includes(MIN_APP_VERSION), "안내에 목표 버전이 있어야 한다");
});

// ============================================================================
// board / guild 정책
// ============================================================================

Deno.test("게시판 쓰기 게이트 — GitHub 미연동은 차단", () => {
  assert(boardInteractionBlocked({ github_login: null }));
  assert(boardInteractionBlocked({ github_login: undefined }));
  assert(boardInteractionBlocked({}));
  assert(boardInteractionBlocked({ github_login: "" }), "빈 문자열도 미연동");
  assertFalse(boardInteractionBlocked({ github_login: "dowoonlee" }));
});

Deno.test("길드명 — 내부 공백은 허용하되 앞뒤·연속 공백은 금지", () => {
  assert(isValidGuildName("Works on My Machine"), "내부 단일 공백은 길드명 특성상 허용");
  assert(isValidGuildName("가".repeat(24)));
  assert(isValidGuildName("데드락클럽"));
  assertFalse(isValidGuildName("a"), "2자 미만");
  assertFalse(isValidGuildName("a".repeat(25)));
  assertFalse(isValidGuildName(" 앞공백"));
  assertFalse(isValidGuildName("뒷공백 "));
  assertFalse(isValidGuildName("연속  공백"), "normalized 충돌 혼란 방지");
  assertFalse(isValidGuildName("ctrl\x01"));
  assertFalse(isValidGuildName(42 as unknown));
});

Deno.test("초대 코드 — 길이와 문자 집합이 고정", () => {
  const code = generateInviteCode();
  assertEquals(code.length, INVITE_CODE_LEN);
  assert(/^[A-Z0-9]+$/.test(code), code);
});

Deno.test("길드 로고 — 샘플 인덱스 범위와 PNG 매직만 통과", () => {
  assert(isValidGuildLogo("s:0"));
  assert(isValidGuildLogo(`s:${GUILD_LOGO_SAMPLE_COUNT - 1}`));
  assertFalse(isValidGuildLogo(`s:${GUILD_LOGO_SAMPLE_COUNT}`), "범위 밖 인덱스");
  assertFalse(isValidGuildLogo("s:-1"));
  assertFalse(isValidGuildLogo("s:1.5"));
  assertFalse(isValidGuildLogo("s:"));

  // PNG 매직(89 50 4E 47)으로 시작하지 않는 base64는 거절 — 아무 바이트나 올리지 못하게.
  const png = btoa(String.fromCharCode(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13));
  assert(isValidGuildLogo(`p:${png}`));
  assertFalse(isValidGuildLogo(`p:${btoa("not a png at all")}`));
  assertFalse(isValidGuildLogo("p:!!!not-base64!!!"));
  assertFalse(isValidGuildLogo("unknown:prefix"));
  assertFalse(isValidGuildLogo(""));
  assertFalse(isValidGuildLogo(null));
});

Deno.test("길드 로고 위치 — 정수 범위 밖은 거절", () => {
  assert(isValidGuildLogoPos(0, 0));
  assertFalse(isValidGuildLogoPos(-1, 0));
  assertFalse(isValidGuildLogoPos(0, -1));
  assertFalse(isValidGuildLogoPos(1.5, 0), "정수만");
  assertFalse(isValidGuildLogoPos("10" as unknown, 0), "문자열 거절");
  assertFalse(isValidGuildLogoPos(99_999, 0), "상한 밖");
});

// ============================================================================
// profile — backup 누출 차단
// ============================================================================
// 보안 경계인데 커버리지가 0이었다. DB 쪽에도 같은 규칙이 SQL로 복제되어 있어서
// (monthly_leaderboard 뷰 / finalize 스냅샷, 20260818000000 마이그레이션)
// 두 구현의 의미가 어긋나면 한쪽으로 backup이 샌다 — 여기가 그 기준선이다.

Deno.test("stripBackup — backup 키만 떨구고 나머지는 그대로", () => {
  const card = { avatar: { kind: "fox", variant: 2 }, title: "t" };
  assertEquals(
    stripBackup({ card, nickname: "n", backup: { coins: 999, ownedPets: ["fox"] } }),
    { card, nickname: "n" },
    "backup 외 필드는 보존",
  );
  // backup이 없으면 손대지 않는다 — 뷰의 `- 'backup'`도 없는 키엔 no-op이라 동일.
  assertEquals(stripBackup({ card }), { card });
  assertEquals(stripBackup({}), {});
});

Deno.test("stripBackup — 객체가 아니면 그대로 통과", () => {
  // SQL 쪽은 jsonb_typeof(...) = 'object' 가드가 이 케이스를 담당한다.
  // (`jsonb - text`를 스칼라에 쓰면 "cannot delete from scalar"로 에러가 난다.)
  assertEquals(stripBackup(null), null);
  assertEquals(stripBackup(undefined), undefined);
  assertEquals(stripBackup("backup"), "backup");
  assertEquals(stripBackup(42), 42);
  assertEquals(stripBackup([{ backup: 1 }]), [{ backup: 1 }], "배열은 손대지 않는다");
});

Deno.test("stripBackup — 원본을 변형하지 않는다", () => {
  // 같은 row 객체를 다른 곳에서 재사용해도 안전해야 한다(복구 경로가 원본을 필요로 함).
  const original = { card: { title: "t" }, backup: { coins: 1 } };
  const stripped = stripBackup(original) as Record<string, unknown>;
  assert("backup" in original, "원본에는 backup이 남아 있어야 한다");
  assertFalse("backup" in stripped);
});
