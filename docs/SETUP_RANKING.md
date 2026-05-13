# 랭킹 시스템 — 사용자 외부 작업 가이드

이 문서는 AIUsage에 글로벌 랭킹 보드를 도입하기 위해 **사용자(개발자)가 직접** 외부 서비스에서 수행해야 하는 작업을 정리합니다. 클라이언트 코드 변경, DB schema, Edge Function 코드는 별도로 제공됩니다.

## 작업 분담

| 항목 | 누가 |
|---|---|
| Supabase 프로젝트 생성 | **사용자** (이 문서) |
| HMAC secret 생성 | **사용자** (이 문서) |
| 처리방침 페이지 호스팅 | **사용자** (이 문서) |
| GitHub OAuth App | **불필요** — 기존 `GitHubClientID`(Contributor Bonus용) 재사용 |
| DB schema (SQL) | 자동 생성 — 별도 파일 (`db/schema.sql`) |
| Edge Function (TS) | 자동 생성 — 별도 파일 (`supabase/functions/...`) |
| 클라이언트 코드 변경 | 자동 — 이 repo에 직접 패치 |

## 사전 준비물 체크리스트

- [ ] Supabase 계정 (GitHub 로그인 가능)
- [ ] Supabase CLI 설치 (`brew install supabase/tap/supabase`) — Edge Function 배포용
- [ ] 처리방침 호스팅 위치 결정 (Notion 공개 페이지 / GitHub Pages 중 선호)

## Step 1 — Supabase 프로젝트 생성

1. [dashboard.supabase.com](https://dashboard.supabase.com) 접속 → **New project**
2. 입력 값:
   - **Name**: `aiusage-ranking` (자유)
   - **Database Password**: 강력한 비밀번호 생성 후 1Password 등에 보관 (분실 시 DB 직접 접속 불가)
   - **Region**: `Northeast Asia (Tokyo)` 또는 `Northeast Asia (Seoul)` — latency 최소화
   - **Pricing Plan**: Free
3. 프로젝트 생성 후 **Settings → API** 페이지에서 다음 값 4개를 복사해 안전한 곳에 보관:
   - **Project URL**: `https://<project-ref>.supabase.co`
   - **anon (public) key**: `eyJhb...` (브라우저/클라이언트에 노출 OK)
   - **service_role key**: `eyJhb...` (**절대 클라이언트에 포함 금지** — Edge Function 환경변수로만)
   - **Project Reference ID**: Settings 좌상단의 `<project-ref>` 부분

> **참고**: 무료 프로젝트는 7일 비활성 시 자동 일시정지됩니다. AIUsage는 사용자 폴링으로 자동 활성 유지되므로 실 사용 시작 후엔 영구 가동.

## Step 2 — HMAC Master Secret 생성

서버가 클라이언트에 per-install HMAC 키를 발급할 때 사용하는 마스터 secret입니다. 이 값으로 클라이언트 키를 derive하므로 노출 시 전체 어뷰징 방어선이 무력화됩니다.

```bash
# 32바이트 랜덤 → base64
openssl rand -base64 32
```

출력 예시: `H8s2k9XaP4mR7nQ1uV3wY6zA0bC5dE8fG1hI2jK3lM4=`

이 값은 **Supabase Edge Function의 환경변수**로만 저장합니다. Step 5에서 등록.

## Step 3 — 처리방침 페이지 호스팅

랭킹 옵트인 시점에 동의 체크박스 옆에 노출할 URL이 필요합니다. **닉네임은 개인정보**에 해당하므로 한국 개인정보보호법상 처리방침 게시가 필수입니다.

### 옵션 A — Notion 공개 페이지 (권장, 5분)

1. Notion에서 새 페이지 생성: 제목 `AIUsage 랭킹 — 개인정보처리방침`
2. 본문 템플릿:

```
## 1. 수집하는 정보
- 디바이스 식별자 (UUID, 익명)
- 닉네임 (사용자가 지정 또는 자동 생성)
- GitHub 사용자명 (사용자가 GitHub 연동 옵트인한 경우만)
- 코인 누적량 및 적립 시각

## 2. 수집 목적
글로벌 랭킹 보드 운영 및 통계 집계.

## 3. 보관 기간
- 활성 계정: 무기한
- 사용자가 [설정 → 랭킹 → 계정 삭제]를 선택한 경우 즉시 삭제
- 12개월 이상 미활성 계정: 자동 삭제

## 4. 처리 위탁
Supabase Inc. (DB 호스팅, 서버 위치: Tokyo/Seoul region)

## 5. 사용자 권리
열람·정정·삭제 요청 — <연락처 이메일> 로 요청 또는 앱 내 [계정 삭제] 버튼

## 6. 변경 이력
- YYYY-MM-DD: 최초 게시
```

3. 우상단 **Share → Publish → Publish to web** → 생성된 URL 복사

### 옵션 B — GitHub Pages

이미 `dowoonlee.github.io` 등을 운영 중이면 `aiusage/privacy.md`로 추가하고 raw URL 사용. Notion보다 신뢰감 있음.

> **중요**: 처리방침 URL은 Step 5에서 클라이언트에 환경변수로 주입됩니다.

## Step 4 — Supabase CLI 로그인 + 프로젝트 연결

```bash
# 설치 (이미 했으면 skip)
brew install supabase/tap/supabase

# 로그인 — 브라우저 OAuth
supabase login

# 이 repo에서 프로젝트 연결
cd /Users/a11706/.dev/claude_usage
supabase link --project-ref <project-ref>
```

`<project-ref>`는 Step 1에서 복사한 값.

## Step 5 — 환경변수 전달

이제 Step 1~4에서 얻은 값을 다음 채널로 전달해주세요:

### A. Edge Function secret (Supabase 측)

```bash
# Step 2의 HMAC master secret
supabase secrets set HMAC_MASTER_SECRET="<base64 string>"
```

이 값은 Supabase에만 저장되며 git에 들어가지 않습니다.

### B. 클라이언트 빌드 환경변수 (이 repo의 빌드 시)

`scripts/package.sh` 실행 시 다음 환경변수가 주입됩니다 (별도 패치 예정):

```bash
SUPABASE_URL="https://<project-ref>.supabase.co"
SUPABASE_ANON_KEY="<anon key from Step 1>"
PRIVACY_POLICY_URL="<Step 3 URL>"
```

`anon_key`는 클라이언트에 노출돼도 안전한 값입니다 (Row Level Security가 권한 통제).

GitHub Actions release workflow에는 위 3개를 secret으로 등록:
- `Settings → Secrets and variables → Actions → New repository secret`
- 이름: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `PRIVACY_POLICY_URL`

## 검증 체크리스트

여기까지 끝나면 다음이 모두 만족되어야 합니다:

- [ ] Supabase 대시보드에 빈 프로젝트 1개 존재
- [ ] `supabase secrets list` 출력에 `HMAC_MASTER_SECRET` 존재
- [ ] `supabase link` 후 `supabase status` 정상 출력
- [ ] 처리방침 URL을 브라우저에서 열면 본문 정상 표시
- [ ] GitHub Actions secrets 3개 등록 확인 (또는 로컬 빌드용 `.envrc`)

위 체크가 모두 끝났다면 **DB schema 적용 + Edge Function 배포 + 클라이언트 코드 변경**으로 넘어갑니다. 이 단계는 자동으로 진행됩니다.

## 트러블슈팅

**Q. `supabase login`이 브라우저에서 멈춰요.**
A. 시크릿 창이거나 GitHub 로그인 세션이 없는 경우. 일반 브라우저에서 GitHub 먼저 로그인 후 재시도.

**Q. Project URL이 어디 있는지 모르겠어요.**
A. Supabase 대시보드 → 프로젝트 클릭 → 좌측 사이드바 **Settings** (톱니) → **API** → **Project URL** 섹션.

**Q. 무료티어 한도가 넘을까봐 걱정돼요.**
A. 50명 가정 기준 ~25MB/월, 1.5년 후 500MB 한도 도달. 그때 Pro($25/월) 또는 자체 PG로 마이그레이션. 한도 근접 시 Supabase가 이메일 알림.

**Q. HMAC secret을 분실했어요.**
A. 새로 생성 후 `supabase secrets set`로 갱신. 단, 기존 클라이언트들이 받은 per-install 키는 모두 무효화되므로 재등록 필요. 사용자 이관 시나리오에서만 발생하는 작업.
