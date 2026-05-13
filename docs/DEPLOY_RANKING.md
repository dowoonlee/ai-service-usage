# 랭킹 시스템 — 배포 가이드

`scripts/ranking.env`가 채워진 상태를 전제로, 서버(Supabase)와 클라이언트 양쪽 배포를 진행합니다.

## 사전 확인

```bash
cd /Users/a11706/.dev/claude_usage

# ranking.env 검증
source scripts/ranking.env
echo "URL: ${SUPABASE_URL:-MISSING}"
echo "REF: ${SUPABASE_PROJECT_REF:-MISSING}"
echo "ANON: ${SUPABASE_ANON_KEY:+OK}"
echo "SERVICE: ${SUPABASE_SERVICE_ROLE_KEY:+OK}"
echo "HMAC: ${HMAC_MASTER_SECRET:+OK}"
```

5개 모두 `OK`/`MISSING` 아닌 값으로 나와야 합니다. (`PRIVACY_POLICY_URL`은 비어 있어도 무방.)

## Step 1 — Supabase CLI 로그인 + 프로젝트 연결

```bash
# 설치 확인
brew list supabase/tap/supabase || brew install supabase/tap/supabase

# 로그인 (브라우저 OAuth 1회)
supabase login

# 프로젝트 연결
supabase link --project-ref "${SUPABASE_PROJECT_REF}"

# 정상 출력 예: "Finished supabase link."
```

## Step 2 — DB schema 적용

```bash
supabase db push
```

`supabase/migrations/20260513000000_init_ranking.sql`이 자동으로 실행됩니다.

검증:
```bash
# 대시보드 → SQL Editor에서 실행
# 또는 psql 직접 접속해서
supabase db remote commit  # 현재 schema 확인 (선택)
```

대시보드 Table Editor에서 `users`, `submissions`, `abuse_flags` 3개 테이블 + `public_leaderboard` 1개 view가 보여야 정상.

## Step 3 — Edge Function secret 등록

`SUPABASE_URL`과 `SUPABASE_SERVICE_ROLE_KEY`는 Edge Function 런타임에 자동 주입되므로 등록 불필요. 추가로 등록할 secret:

```bash
supabase secrets set HMAC_MASTER_SECRET="${HMAC_MASTER_SECRET}"

# 확인
supabase secrets list
```

> **참고**: 현재 Edge Function 구현에는 HMAC_MASTER_SECRET을 직접 쓰지 않습니다 (per-install random key 방식). 향후 admin endpoint 서명 / 어뷰징 alert 인증 등에 사용 예정으로 미리 등록만 해둠. 비어도 현재 기능엔 영향 없음.

## Step 4 — Edge Functions 배포

총 6개 함수:

```bash
supabase functions deploy register
supabase functions deploy submit
supabase functions deploy leaderboard
supabase functions deploy recover-by-code
supabase functions deploy recover-by-github
supabase functions deploy delete
```

또는 한 줄로:

```bash
for fn in register submit leaderboard recover-by-code recover-by-github delete; do
  supabase functions deploy "$fn"
done
```

각각 "Deployed Functions on project ... <function-name>" 출력되면 성공.

## Step 5 — 서버 sanity check (curl)

배포된 endpoint가 살아있는지 확인:

```bash
# register 호출 (실제 DB row 생성됨 — 테스트 후 정리 필요)
curl -X POST "${SUPABASE_URL}/functions/v1/register" \
  -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
  -H "apikey: ${SUPABASE_ANON_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "deviceId": "00000000-0000-0000-0000-000000000001",
    "nickname": "TestTrainer1"
  }'
```

예상 응답:
```json
{
  "hmacKey": "...",
  "recoveryCode": "XXXX-XXXX-XXXX",
  "nickname": "TestTrainer1"
}
```

테스트 row 정리:
```bash
# 대시보드 SQL Editor에서
DELETE FROM users WHERE device_id = '00000000-0000-0000-0000-000000000001';
```

leaderboard 호출:
```bash
curl "${SUPABASE_URL}/functions/v1/leaderboard" \
  -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
  -H "apikey: ${SUPABASE_ANON_KEY}"
```

예상 응답:
```json
{"entries": [], "myRank": null, "myTotalCoins": null, "total": 0}
```

## Step 6 — 클라이언트 빌드 + 검증

```bash
bash scripts/package.sh
```

빌드 출력에서:
- `NOTE: SUPABASE_URL/SUPABASE_ANON_KEY 미설정...` 경고가 **안 떠야** 함 (ranking.env 정상 source)
- `dist/AIUsage.app`이 생성됨

실행:
```bash
open dist/AIUsage.app
```

설정 (Cmd+,) → **랭킹** 섹션에서:
- "이 빌드에 포함되지 않았습니다" 메시지가 **안 보여야** 함
- 처리방침 동의 체크박스 + 닉네임 입력 필드 + "참여 시작" 버튼이 보이면 정상

옵트인 → 등록 성공 시:
- 복구 코드 alert 자동 표시
- 설정 화면 상단에 "참여 중" 토글로 전환
- "보드 열기" 버튼으로 RankingView 진입 가능

## Step 7 (선택) — GitHub Actions release secrets

자동 release workflow에 secret 등록 (Sparkle 자동 배포 사용 중인 경우):

저장소 → Settings → Secrets and variables → Actions → New repository secret. 다음 3개:

| Secret 이름 | 값 |
|---|---|
| `SUPABASE_URL` | `${SUPABASE_URL}` |
| `SUPABASE_ANON_KEY` | `${SUPABASE_ANON_KEY}` |
| `PRIVACY_POLICY_URL` | `${PRIVACY_POLICY_URL}` (호스팅 후) |

`.github/workflows/release.yml`에 env로 노출 추가 필요 (별도 패치). 지금 단계엔 로컬 빌드만으로 충분.

## 트러블슈팅

**`supabase functions deploy`에서 "Project not linked" 에러**
→ Step 1의 `supabase link`를 다시 실행. `.supabase/` 디렉토리에 link 정보 저장됨.

**Edge Function 호출 시 401 "Invalid JWT"**
→ Authorization header에 `Bearer ${SUPABASE_ANON_KEY}` 사용 중인지 확인. service_role을 잘못 쓰면 (절대 안 됨) 다른 에러 메시지.

**submit이 항상 401 bad_signature**
→ 클라이언트가 sortedKeys JSON으로 정확히 직렬화하는지 확인. Swift의 `.withoutEscapingSlashes` 플래그 누락 시 `/` 가 escape돼 서버 canonicalize와 어긋남.

**보드에 본인이 안 보임**
→ `total_coins > 0` 조건이 view에 걸려 있음. 첫 옵트인 직후엔 baseline = coinsTotalEarned로 잡혀 첫 submit delta가 0이라 보드에 안 뜸. 폴링 cycle 한 번 돌고 코인이 신규 적립돼야 보드 진입.

**무료티어 한도 초과**
→ Supabase 대시보드 → Settings → Usage에서 DB 크기 모니터. 500MB 근접 시 자동 이메일 알림. 50명 가정 기준 ~1.5년까지 무료.

## 다음 단계 (Phase 후속)

- 처리방침 페이지 호스팅 후 `PRIVACY_POLICY_URL` 채우고 재빌드
- 운영 대시보드 (수동 큐레이션용 admin Edge Function — abuse_flags 조회/수동 ban)
- 시계열 분석 (주간/월간 랭킹) — 같은 Edge Function URL에 `?period=weekly` 파라미터 추가
