# 요청 프록시 (Cloudflare Worker)

Supabase 앞단 게이트. 구버전·차단 대상 요청을 **Edge Function에 닿기 전에** 끊는다.

## 왜 필요한가

Edge Function은 426/403을 반환해도 **이미 실행된 것이라 invocation으로 과금된다.** 서버측
게이트(`min_version.ts`)는 `users.app_version`을 DB에서 읽어야 해서 함수가 실행된 뒤에나
판정할 수 있고, 그래서 호출 수를 전혀 줄이지 못한다.

2026-08 실측이 그 한계를 보여준다 — 구버전 3대가 8초 주기로 폴링해 월 약 69만건을 유발했는데
(무료 한도 50만), 이미 426으로 막고 있었음에도 호출량은 1건도 줄지 않았다. 구버전 클라는
응답 코드와 무관하게 `while !Task.isCancelled` 루프를 계속 돌린다.

요청이 Supabase에 도달하는 순간이 비용이므로, 도달 자체를 막아야 실효가 있다.

## ⚠️ 소급되지 않는다

이 게이트는 **프록시를 경유하는 클라에만** 걸린다. 이미 배포된 버전은 `Info.plist`에 박힌
`supabase.co`로 직행하므로 여기 오지 않는다.

즉 이 구조는 **다음에 같은 일이 생겼을 때 서버 비용 없이 끊기 위한 장치**다. 프록시 URL로
빌드된 버전부터 적용된다.

## 배포

```bash
cd cloudflare
npx wrangler login
npx wrangler deploy
```

배포되면 `https://aiusage-proxy.<계정>.workers.dev` 가 생긴다. 확인:

```bash
curl https://aiusage-proxy.<계정>.workers.dev/__health
# {"ok":true,"minVersion":"","blockedDevices":0}
```

## 클라가 프록시를 타게 하기

GitHub repo secret **`SUPABASE_URL`** 을 Worker 주소로 바꾸고 새 버전을 릴리스한다.

```
SUPABASE_URL = https://aiusage-proxy.<계정>.workers.dev
```

이 값이 `package.sh` → `Info.plist`의 `SupabaseURL` → `RankingAPI.baseURL` 로 흘러간다.
경로(`/functions/v1/...`)와 anon key는 그대로라 클라 코드는 손댈 필요가 없다.

되돌리려면 secret을 원래 `https://<ref>.supabase.co` 로 복구하고 다시 릴리스한다.

## 차단 운영

`wrangler.toml`의 `[vars]`를 고치고 `npx wrangler deploy`.

```toml
[vars]
MIN_APP_VERSION = "0.17.18"        # 이 미만이면 426. 비우면 버전 게이트 off
BLOCKED_DEVICE_IDS = "uuid1,uuid2" # 개별 차단. 대소문자 무관
```

- **버전 게이트** — 클라가 보내는 `X-App-Version` 헤더만 본다. DB 조회가 없다.
  헤더가 없으면 **통과시킨다**(fail-open). 헤더를 안 보내는 클라는 애초에 프록시 URL을
  모르므로 여기 올 수 없고, 누락으로 정상 사용자를 막는 사고가 차단 실패보다 비싸다.
- **deviceId 차단** — GET은 쿼리스트링, POST는 서명 payload에서 뽑는다. 확실한 차단은 이쪽이
  맡는다. 대상은 운영 대시보드(`aiusage-admin`)의 진척/abuse 탭에서 특정할 수 있다.

## 테스트

```bash
cd cloudflare && node worker.test.mjs
```

게이트 판정만 검증한다(실제 Supabase 포워딩은 하지 않는다). 버전 비교가 사전순이 아니라
숫자 단위인지(`0.17.9 < 0.17.18`), GET/POST 양쪽에서 deviceId를 뽑는지, fail-open이 지켜지는지를
본다.

## 알아둘 것

- **SPOF가 하나 늘어난다.** Worker가 죽으면 랭킹 기능 전체가 죽는다. 클라에 supabase 직행
  fallback을 두면 차단이 무력화되므로 의도적으로 두지 않았다.
- Cloudflare 무료 티어는 100,000 req/day(월 300만)라 현재 트래픽(일 2.3만) 대비 여유가 크다.
- `OPTIONS` preflight는 Worker에서 끝낸다 — 그것도 Supabase까지 보내면 invocation이다.
