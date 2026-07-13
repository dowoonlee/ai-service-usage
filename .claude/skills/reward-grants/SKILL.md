---
name: reward-grants
description: AIUsage 사용자에게 RP/코인을 서버에서 지급(보상)하는 절차 — 버그 보상, 이벤트 보상, 개별/대량 지급. "보상 지급", "RP 지급", "코인 지급", "버그 보상", "reward grant", "compensation", "RP 뿌려", "이벤트 보상" 요청 시 사용. 서버 배포/마이그레이션은 supabase-ranking, 클라 릴리스는 release-app skill.
---

# 사용자 보상(RP/코인) 지급

RP·코인을 특정 사용자(들)에게 서버에서 지급하는 운영 절차. **RP가 대량 보상의 기본 경로**다.
환경변수·curl·service_role 규약은 [[supabase-ranking]] 전제(`source scripts/ranking.env`).

## 0. 핵심 원리 — 잔액은 클라 로컬, 서버는 "미수령 보상" 소스

RP·코인 **총 잔액은 각 기기의 로컬 원장**(`RankPointLedger` / `CoinLedger`)에 있다. 서버 테이블은
"아직 안 받은 보상"을 담아둘 뿐이다. 지급 흐름:

1. 서버 테이블에 **미수령 행**(claimed=NULL)을 INSERT.
2. 클라가 leaderboard 폴링 때 `pendingRpReward`/`pendingReward`로 그 행을 받음(가장 오래된 1건).
3. 클라가 **로컬 원장에 +크레딧**하고 claim 처리(서버 `*_claimed_at` 세팅). dedup은 클라의
   `claimedRpRewards`/`claimedPodiumPeriods`가 담당.

**함의(반드시 인지):**
- **전달은 다음 폴링 때** — 활성 사용자 ≤5분(300s 주기), 그 외 다음 실행 시.
- **한 번 클라가 크레딧하면 회수 불가** — 서버가 로컬 원장을 못 건드린다. **미수령(claimed=NULL)
  상태에서만** 삭제로 취소 가능. 지급은 되돌리기 어려운 outward 작업 → 대상·금액·인원 확인 후.
- leaderboard는 **미수령 1건씩** 반환 → 여러 건은 여러 폴링에 걸쳐 순차 수령(가장 오래된 것 먼저).
- 지급은 사내망 TLS 때문에 **`/usr/bin/curl`**(keychain CA)로. anaconda/homebrew python·curl은
  `CERTIFICATE_VERIFY_FAILED`. (supabase-ranking 참조)

## 1. RP 지급 (대량 보상의 기본 경로) — `rp_rewards`

per-device 원장이라 인원 무제한·금액 자유. 월간 RP는 **조용히 적립**(알림 없음).

**행 스펙:** `{ period, period_type, device_id, rank, rp_amount }`, `claimed_at`=NULL.
- `period_type`: CHECK `('monthly','weekly','guild-monthly')`. **`'monthly'` 사용**(silent). ⚠️
  `'guild-monthly'`는 클라가 "우리 길드 N등" **알림을 띄운다** — 보상용으론 쓰지 말 것.
- `period`: claim 정규식 `^\d{4}-(\d{2}|W\d{2})$` 통과 필요. **실제 정산과 충돌 안 하는 sentinel**을
  쓴다(실제 월간=진짜 YYYY-MM, 주간=YYYY-Www). 월 `00`은 실존 안 함 → `'2026-00'` 형태.
  UNIQUE `(period_type, period, device_id)`라 **같은 사람에게 다시 주려면 다른 period** — 캠페인마다
  새 sentinel(예: 1차 `2026-00`, 2차 `2027-00`).
- `rank`: RP는 `≥1`. 표시 안 되니 `1` 고정.
- `rp_amount`: 지급액.

**지급(활성 사용자 중 일부 제외, 대량):**
```bash
source scripts/ranking.env
H=(-H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}")
EXCLUDE="<제외할 device_id>"            # 없으면 빈 문자열
# 1) 대상 조회 → 페이로드 생성 (python은 로컬 파싱만, fetch/POST는 /usr/bin/curl)
/usr/bin/curl -s "${SUPABASE_URL}/rest/v1/users?select=device_id,nickname&status=eq.active" "${H[@]}" > /tmp/u.json
python3 - /tmp/u.json "$EXCLUDE" /tmp/rows.json <<'PY'
import sys, json
users=json.load(open(sys.argv[1])); ex=sys.argv[2].lower()
t=[u for u in users if u["device_id"].lower()!=ex]
json.dump([{"period":"2026-00","period_type":"monthly","device_id":u["device_id"],"rank":1,"rp_amount":500} for u in t], open(sys.argv[3],"w"))
print(f"대상 {len(t)}명:", ", ".join(sorted(u["nickname"] for u in t)))
PY
# 2) 벌크 INSERT
/usr/bin/curl -s -w '\nHTTP %{http_code}\n' -X POST "${SUPABASE_URL}/rest/v1/rp_rewards" "${H[@]}" \
  -H "Content-Type: application/json" -H "Prefer: return=representation" --data-binary @/tmp/rows.json
# 3) 검증 — 미수령 행수
/usr/bin/curl -s "${SUPABASE_URL}/rest/v1/rp_rewards?select=device_id&period=eq.2026-00&claimed_at=is.null" "${H[@]}" -H "Prefer: count=exact" -I 2>/dev/null | grep -i content-range
```
개별 지급은 `/tmp/rows.json`을 한 사람짜리 배열로 만들면 된다.

## 1.5 통합 지급 (reward_grants) — RP·코인 공용, **코인의 권장 경로** (v0.16.4+)

`reward_grants` 테이블 하나로 **RP·코인 어느 통화든** per-device 지급한다. rp_rewards의 깔끔한 흐름을
코인까지 확장한 것 — podium/정산/메달과 완전히 분리돼 **부작용 없음**(가짜 "명예의 전당 N등" 알림 X,
평생 메달 오염 X, previousMonth 화면 오염 X). 클라는 `🎁 보상 도착` 알림만 띄운다.

> ⚠️ **클라 버전 요건**: `pendingGrant`를 이해하는 **v0.16.4+ 클라만** 수령 가능. 그 이전 버전 유저에겐
> 행이 미수령으로 남아있다가 업데이트 후 적립된다. 구버전 유저 코인 즉시 지급이 꼭 필요하면 §2 podium.

**행 스펙:** `{ device_id, currency, amount, grant_key, reason }`, `claimed_at`=NULL.
- `currency`: `'rp'`(→RankPointLedger) | `'coin'`(→CoinLedger). CHECK 강제.
- `amount`: 지급액(>0).
- `grant_key`: dedup 키(캠페인/사유 슬러그). `^[A-Za-z0-9._-]{1,64}$`. **UNIQUE `(device_id, grant_key)`** —
  같은 사람 재지급은 새 grant_key. 클라 claim 서명의 period 슬롯에 실려오므로 서명-safe 문자만.
- `reason`: 운영 메모(표시 안 함, 감사용).

**지급(개별/대량 공용 — currency만 바꾸면 됨):**
```bash
source scripts/ranking.env
H=(-H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}")
/usr/bin/curl -s -w '\nHTTP %{http_code}\n' -X POST "${SUPABASE_URL}/rest/v1/reward_grants" "${H[@]}" \
  -H "Content-Type: application/json" -H "Prefer: return=representation" -d '[
    {"device_id":"<uuid>","currency":"coin","amount":3000,"grant_key":"guild-loss-2026-07","reason":"길드 소실 보상"}
  ]'
# 검증 — 미수령 행수
/usr/bin/curl -s "${SUPABASE_URL}/rest/v1/reward_grants?select=device_id&grant_key=eq.guild-loss-2026-07&claimed_at=is.null" "${H[@]}" -H "Prefer: count=exact" -I 2>/dev/null | grep -i content-range
```
대량은 `-d`에 배열로 여러 행. 전달은 §0과 동일(다음 폴링, ≤5분). 취소는 §3(미수령 DELETE).

## 2. 코인 지급(레거시) — `monthly_winners` (podium 전용, 대량 부적합)

> **v0.16.4+에선 §1.5 reward_grants가 권장.** 아래는 구버전 유저에게 코인을 **즉시** 줘야 할 때만.
> podium 경로는 가짜 달 "명예의 전당 N등" 알림 + `device_medals` 금/은/동 오염 + previousMonth 표시
> 오염이 따라온다(§1.5가 이걸 없애려 만들어짐).

코인은 로컬 사용량 경제라 서버→클라 지급 경로가 **podium 하나뿐**이다. 제약이 크다:
- **UNIQUE `(period, rank)`** + `rank ∈ {1,2,3}` → **한 period에 최대 3명**. 대량이면 sentinel period를
  돌려써야 함(비추천).
- claim 정규식은 코인이 더 엄격: `^\d{4}-\d{2}$`(월간만, 주간 불가).
- claimed 플래그는 `reward_claimed_at`. 조회 필드 `reward_coins`.
- NOT NULL: `final_score`, `nickname_snapshot`, `reward_coins`(+ rank CHECK 1..3). `profile_json_snapshot`은 nullable.

**소수(≤3) 지급 예:**
```bash
/usr/bin/curl -s -w '\nHTTP %{http_code}\n' -X POST "${SUPABASE_URL}/rest/v1/monthly_winners" "${H[@]}" \
  -H "Content-Type: application/json" -H "Prefer: return=representation" -d '[
    {"period":"2026-00","device_id":"<uuid>","rank":1,"final_score":0,"nickname_snapshot":"grant","reward_coins":500}
  ]'
```
> 대량 코인 보상이 필요하면 재고: (a) **RP로 대체**(권장), (b) 클라측 일회성 코인 지급 마이그레이션
> (`Settings.applyOnceMigration`, CLAUDE.md 참조)로 릴리스에 실어 배포. 서버 podium 우회는 지양.

## 3. 취소 / 정리

- **미수령(claimed=NULL)**: 행 DELETE로 취소 가능 (전달 전).
  `DELETE .../rp_rewards?period=eq.2026-00&claimed_at=is.null`
- **이미 수령**: 로컬 원장에 들어가 **회수 불가**. 서버 행만 지워도 잔액은 안 줄어든다.
- 잘못 넣었으면 즉시(폴링 전에) 미수령 행을 지워라.

## 4. 선례 — v0.15.1 길드 정산 버그 보상 (2026-07-07)

길드 무경쟁 무임 지급 버그로 1명(Joripje)이 500 RP를 이미 수령(회수 불가). 형평을 위해 **활성
13명(그 1명 제외)에게 500 RP**를 위 §1 방식(`period='2026-00'`, monthly, silent)으로 지급. 공지엔
RP 언급 생략(조용히 적립). 정산 버그 자체는 서버 마이그레이션으로 수정(supabase-ranking).

## 체크리스트

- [ ] 대상·금액·인원 확정, 되돌리기 어려움 인지(수령 후 회수 불가)
- [ ] 통화·경로 선택: RP/코인 **모두 §1.5 reward_grants가 기본**(v0.16.4+). RP 대량은 §1도 가능.
      코인을 구버전 유저에게 **즉시** 줘야 할 때만 §2 podium(부작용 감수)
- [ ] reward_grants: `grant_key` UNIQUE(device당) — 재지급이면 새 grant_key. §1 RP면 sentinel period 규칙
- [ ] `/usr/bin/curl` + service_role로 INSERT, 미수령 행수 검증
- [ ] 공지에 넣을지 결정(기본: 조용히 적립이라 생략 가능)
