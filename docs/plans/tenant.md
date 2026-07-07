# 테넌트 (완전 격리형 멀티테넌시) — 기획

랭킹·쪽지·게시판·길드 등 **모든 상호작용을 테넌트 경계 안으로 격리**한다. 서로 다른 테넌트에
속한 유저는 어떤 화면에서도 서로 보이지 않고 상호작용할 수 없다(리더보드에도 상호 노출 안 됨).

- 기본 테넌트 `public` — 외부인(누구나). 신규 설치의 기본값.
- 게이트 테넌트 `skax` — **sk.com 이메일 인증**을 마친 디바이스만 편입. 인증 후 **고정**(one-way).

> 길드와의 차이: 길드는 *같은 데이터 풀 안*의 그룹이다(다른 길드도 같은 보드에서 경쟁, 쪽지 가능).
> 테넌트는 *데이터 풀 그 자체를 분리*한다. 길드는 테넌트 안에 종속된다.

---

## 0. 결론 요약

- `users.tenant_id`(→ `tenants.slug`)가 디바이스의 **현재 소속**. 신규 = `public`.
- **랭킹 계열**(리더보드/메달/월간 우승/RP)은 `users.tenant_id`로 파티션 → 디바이스는 *정확히 한
  보드*(=현재 테넌트)에만 등장. skax 유저의 닉네임은 public 보드에 절대 안 뜬다.
- **콘텐츠 계열**(게시판/쪽지/길드)은 row에 `tenant_id`를 **작성 시점에 스탬프**하고, 읽기는 전부
  `WHERE tenant_id = 호출자 테넌트`로 필터. 과거 글/스레드는 원래 테넌트에 남는다.
- 모든 Edge Function은 진입 시 `resolveTenant(deviceId)` 1회 → 그 값으로만 질의. 타깃 디바이스가
  있는 함수(쪽지·길드 가입 등)는 `타깃.tenant == 호출자.tenant` 아니면 403 `cross_tenant`.
- skax 편입은 커스텀 OTP: `/tenant-verify-request`(코드 발송, **Gmail SMTP**, From=개인 Gmail 주소) →
  `/tenant-verify-confirm`(검증 후 `tenant_id`=skax 고정). **이메일 주소는 DB에 저장하지 않는다**(OTP 대조 후 폐기).
- 공지는 **전역**(`announcements`, 버전 패치노트)과 **테넌트**(`tenant_announcements`, 멤버 대상)를 별도 기능으로 분리.
- 허용 이메일 도메인은 **테넌트↔도메인 1:N**(`tenant_email_domains` 테이블) — 추가는 row INSERT만(재배포 X).
  클라는 `/tenant-domains`를 받아 **도메인 드롭다운**으로 노출. 발송자(From)는 **개발자 소유·검증 도메인**(sk.com 아님).
- 롤아웃 P0(스키마+격리 배선, 전원 public → 무변화) → P1(이메일 인증+클라 UI) → P2(테넌트별 공지·운영).

---

## 1. 확정 결정

| # | 결정 | 값 |
|---|---|---|
| D1 | 테넌트 모델 | `tenants` 레지스트리 테이블 (skax = 데이터 1 row) |
| D2 | 소속 정책 | 인증 후 **skax 고정** (public→gated 편입은 되돌릴 수 없음, 관리자 예외만) |
| D3 | 이메일 발송 | Edge Function이 6자리 OTP 생성 → **Gmail SMTP**(`smtp.gmail.com`, denomailer)로 발송. `GMAIL_USER`/`GMAIL_APP_PASSWORD` secret. From=개인 Gmail 고정 |
| D4 | 랭킹 파티션 | `users.tenant_id`(현재 테넌트) 기준 — 디바이스는 현재 테넌트 보드에만 등장, 전환 시 사용량 carry |
| D5 | 콘텐츠 파티션 | row-level `tenant_id`를 작성 시점에 스탬프 — 과거 콘텐츠는 원 테넌트에 잔류 |
| D6 | 격리 범위 | 랭킹·메달·RP·게시판·쪽지·길드 전부. 운세·펫카탈로그·rate-limit은 테넌트 무관 |
| D7 | 공지 구조 | **전역 공지**(기존 `announcements`, 버전 패치노트)와 **테넌트 공지**(신규 `tenant_announcements`)를 별도 테이블·엔드포인트로 분리 |
| D8 | 이메일 비저장 | OTP 대조용으로만 잠깐 쓰고 폐기. 이메일 주소·인증 이력을 DB에 영구 저장하지 않음 (`users.tenant_id`만 남김) |
| D9 | 도메인 관리 | 테넌트↔도메인 **1:N** `tenant_email_domains`. 기본 seed = `sk.com`, **추가 전용** 운영(멤버십은 `users.tenant_id`에 독립 저장 → 도메인 삭제로 기존 소속 안 끊김). 클라는 `/tenant-domains`로 드롭다운 |
| D10 | 발송자(From) | **Gmail SMTP 확정 + 검증완료**(2026-07-07 `aiusage.noreply@gmail.com` → `arcturus12@sk.com` 실발송: TCP·인증·딜리버리·한글 모두 정상). From=개인 Gmail 고정. denomailer는 `mimeContent`+charset+base64 필수(§3-4) |
| D11 | 메달 = 평생 업적 | 전환해도 **유지·표시**. `device_medals`는 테넌트 무관 평생 집계로 재설계. 명예의전당·보상·finalize만 테넌트별 필터 → 타 테넌트 유저·보드·점수·우승자명단 일절 비노출(교차노출차단) |

---

## 2. 격리 모델 (핵심 규칙)

### 2-1. 소속의 단일 진실 = `users.tenant_id`

- 디바이스당 정확히 하나의 테넌트. `users.tenant_id TEXT NOT NULL DEFAULT 'public'`.
- 신규 `register`는 항상 `public`. skax 편입은 오직 `/tenant-verify-confirm` 경로로만.
- 호출자의 테넌트는 서버가 `device_id`로 조회해 결정한다. **클라이언트는 테넌트를 주장할 수 없다**
  (요청 바디에 tenant를 실어도 무시). anon key는 그대로, 격리는 Edge Function 코드가 강제.

### 2-2. 무엇을 무엇으로 파티션하나

두 부류로 나눈 이유: 랭킹은 "현재 코호트와의 경쟁"이라 소속을 따라 움직이는 게 자연스럽고,
콘텐츠는 "대화 이력"이라 작성된 자리에 남아야 한다.

| 계열 | 파티션 키 | 스탬프 시점 | 전환 시 |
|---|---|---|---|
| 랭킹(리더보드/월간우승/메달/RP) | `users.tenant_id` (현재) | — (join으로 파생) | 사용량이 새 테넌트로 carry |
| 콘텐츠(게시판/댓글/좋아요) | row `tenant_id` | 작성 시 호출자 테넌트 | 과거 글은 원 테넌트 잔류(본인엔 비노출) |
| 쪽지(direct_messages/user_keys 조회) | row `tenant_id` + 양측 테넌트 일치 검사 | 발신 시 | 과거 스레드 비노출, 신규 발신 차단 |
| 길드(guilds/members/정산) | `guilds.tenant_id` | 생성 시 | 전환 시 타 테넌트 길드 자동 탈퇴 |

> `submissions`에는 `tenant_id`를 **추가하지 않는다**. 랭킹은 `users`와 join해 현재 테넌트로 집계하므로
> 스탬프가 불필요하고, 스탬프하면 "carry vs freeze"가 뒤섞여 버그 표면이 는다. (freeze를 원하면 §7 대안 참조.)

### 2-3. 전 테이블 격리 전략 (빠짐 방지 체크리스트)

| 테이블/뷰 | 전략 |
|---|---|
| `users` | **`tenant_id` 추가** (앵커) |
| `submissions`, `abuse_flags` | 컬럼 미추가 — 랭킹은 users join, abuse는 운영용(device로 테넌트 파생 가능) |
| `monthly_leaderboard`(view) | users.tenant_id 컬럼 노출 + 함수가 필터 |
| `monthly_winners` | **`tenant_id` 추가**, `UNIQUE(tenant_id, period, rank)`, finalize를 테넌트별로 |
| `device_medals`(view) | **테넌트 필터 안 함** — 평생 개인 집계(D11). 전환해도 유지 |
| `rp_rewards` | **`tenant_id` 추가**, 정산 테넌트별로 |
| `board_posts` | **`tenant_id` 스탬프** |
| `board_post_likes` / `board_post_comments` / `board_post_comment_likes` | **`tenant_id` 스탬프**(글의 테넌트 상속) — 직접 필터 가능하게 비정규화 |
| `direct_messages` | **`tenant_id` 스탬프** + 발신 시 양측 일치 검사 |
| `user_keys` | 컬럼 미추가 — 공개키 디렉터리 조회를 **같은 테넌트 유저로 제한**(users join) |
| `dm_blocks` / `dm_settings` | 컬럼 미추가 — device 소유, 조회 시 상대 테넌트 검사로 충분 |
| `guilds` | **`tenant_id` 추가**, 이름 유니크를 `(tenant_id, name_normalized)`로 |
| `guild_members`/`guild_invites`/`guild_join_cooldowns`/`guild_furniture`/`guild_monthly_winners`/`guild_settlement_log` | 길드의 테넌트 상속(guilds join). 가입 시 `device.tenant == guild.tenant` 강제 |
| `guild_monthly_scores`/`guild_member_monthly_vp`(view) | guilds.tenant_id 파티션 |
| `announcements` | **변경 없음** — 전역 버전 패치노트 유지(테넌트 무관) |
| (신규) `tenant_announcements` | 테넌트 전용 공지 (버전 무관, 멤버 대상) — 전역 공지와 분리(D7) |
| `daily_fortunes` | 무관 (개인 운세, 비소셜) |
| `codex_usage_samples` | 무관 (진단 텔레메트리) — 필요 시 분석용 태깅만 |
| `pet_metadata` | 무관 (전역 카탈로그) |
| `register_attempts` / `guild_create_attempts` | 무관 (IP rate-limit, 전역) |
| (신규) `tenant_email_domains` | 테넌트↔도메인 1:N 매핑 + 드롭다운 소스 (D9) — §3-1 |
| (신규) `tenants` / `tenant_otp` | §3-1 (이메일 원장 테이블 없음 — D8) |

### 2-4. public → skax 전환의 부수효과 (confirm 트랜잭션 내 처리)

인증 성공 시 `tenant_id`를 바꾸는 것만으로 대부분 자동 격리되지만, 아래는 명시 처리한다.

1. **길드**: 호출자가 속한 길드의 tenant가 skax가 아니면 그 멤버십을 삭제(→ 기존 승계/해체 트리거가
   처리). skax 유저는 skax 길드에만 있을 수 있다.
2. **콘텐츠 잔류**: 과거 public 게시글/쪽지 스레드는 public에 남아 본인 화면에선 사라진다(읽기 필터
   불일치). 상대(public) 입장에선 과거 글/스레드는 보이나, 신규 발신은 `cross_tenant`로 차단.
3. **랭킹 carry**: 리더보드가 `users.tenant_id` 기준이라, 전환 즉시 이번 달 사용량이 skax 보드로 옮겨온다.
   인증은 보통 초기에 일어나므로 이월량은 작다(§7에 freeze 대안).
4. **메달(개인 업적)**: 전환해도 **유지**된다(D11). `device_medals`는 테넌트 무관 *평생 집계*라 public
   시절 금/은/동이 skax 카드에도 계속 뜬다. 반면 **명예의 전당(직전 달 Top3)·보상·finalize는 테넌트별**로
   필터 → 타 테넌트 우승자 명단·보드·점수는 일절 비노출(교차노출차단). 교차하는 건 *본인 집계 숫자*뿐.
5. **밴 회피 금지**: 전환은 `status`를 초기화하지 않는다. banned/shadow_banned는 그대로 승계.

---

## 3. 서버 설계

### 3-1. 스키마 (migrations)

새 마이그레이션 `20260708000000_tenants.sql` 골격:

```sql
-- 1) 레지스트리
CREATE TABLE tenants (
    slug         TEXT PRIMARY KEY,               -- 'public' | 'skax' | …
    display_name TEXT NOT NULL,
    join_policy  TEXT NOT NULL DEFAULT 'open'    -- 'open' | 'email_domain' | 'admin_only'
                 CHECK (join_policy IN ('open','email_domain','admin_only')),
    is_default   BOOLEAN NOT NULL DEFAULT FALSE, -- 신규 디바이스 기본 소속 (정확히 1개 TRUE)
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX tenants_default_uniq ON tenants (is_default) WHERE is_default;

-- 1-b) 테넌트 ↔ 허용 이메일 도메인 = 1:N (D9). 도메인 추가/숨김은 이 테이블 row 조작만.
--   domain PK = 전역 유니크 → 한 도메인은 정확히 한 테넌트로만 매핑(모호성 없음).
CREATE TABLE tenant_email_domains (
    domain      TEXT PRIMARY KEY,               -- 정규화 lowercase (예: 'sk.com')
    tenant_slug TEXT NOT NULL REFERENCES tenants(slug) ON DELETE CASCADE,
    label       TEXT,                           -- 드롭다운 표시 override(선택). NULL이면 domain 그대로
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,  -- 삭제 없이 숨김: 신규 인증만 막고 기존 소속은 유지
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX tenant_email_domains_tenant ON tenant_email_domains (tenant_slug) WHERE is_active;

INSERT INTO tenants (slug, display_name, join_policy, is_default) VALUES
    ('public', '외부',  'open',         TRUE),
    ('skax',   'SKAX',  'email_domain', FALSE);
INSERT INTO tenant_email_domains (domain, tenant_slug) VALUES
    ('sk.com', 'skax');
    -- 계열사 확장 예: INSERT ('sktelecom.com','skax'), ('sk.co.kr','skax') … (마이그레이션/재배포 불필요)

-- 2) 앵커: 기존 유저 전원 public 백필
ALTER TABLE users ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
CREATE INDEX users_tenant_coins ON users (tenant_id, total_coins DESC, registered_at ASC)
    WHERE status = 'active';

-- 3) 콘텐츠 테이블 스탬프 컬럼 (기존 row = 'public')
ALTER TABLE board_posts               ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE board_post_likes          ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE board_post_comments       ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE board_post_comment_likes  ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE direct_messages           ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE guilds                    ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE monthly_winners           ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE rp_rewards                ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
-- announcements(전역 패치노트)는 손대지 않는다. 테넌트 공지는 아래 별도 테이블(D7).

CREATE INDEX board_posts_tenant_time     ON board_posts (tenant_id, created_at DESC);
CREATE INDEX direct_messages_tenant_idx  ON direct_messages (tenant_id, recipient_device, created_at DESC);

-- 길드 이름 유니크를 테넌트별로 (기존 전역 유니크 대체)
DROP INDEX guilds_name_normalized_uniq;
CREATE UNIQUE INDEX guilds_tenant_name_uniq ON guilds (tenant_id, name_normalized);

-- monthly_winners 유니크를 테넌트별로
DROP INDEX monthly_winners_period_rank;
CREATE UNIQUE INDEX monthly_winners_tenant_period_rank ON monthly_winners (tenant_id, period, rank);

-- 4) OTP (휘발성). 이메일 원장/감사 테이블은 두지 않는다 — D8.
CREATE TABLE tenant_otp (
    id           BIGSERIAL PRIMARY KEY,
    device_id    UUID NOT NULL,               -- FK 없음: 미등록 상태 대비 (register는 선행)
    tenant_slug  TEXT NOT NULL REFERENCES tenants(slug),
    code_hash    TEXT NOT NULL,               -- SHA-256 hex of 6-digit code
    expires_at   TIMESTAMPTZ NOT NULL,
    attempts     SMALLINT NOT NULL DEFAULT 0,
    consumed_at  TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX tenant_otp_device_recent ON tenant_otp (device_id, created_at DESC);
-- ⚠ email 컬럼 없음. request가 코드 발송에만 이메일을 쓰고 즉시 버린다. 대조는 device+code_hash로.

-- 5) 테넌트 전용 공지 (전역 announcements와 분리 — 버전 무관, 멤버 대상). D7.
CREATE TABLE tenant_announcements (
    id           BIGSERIAL PRIMARY KEY,
    tenant_slug  TEXT NOT NULL REFERENCES tenants(slug),
    title        TEXT NOT NULL,
    body         TEXT NOT NULL,
    published_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT tenant_ann_title_not_empty CHECK (LENGTH(title) > 0),
    CONSTRAINT tenant_ann_body_not_empty  CHECK (LENGTH(body) > 0)
);
CREATE INDEX tenant_announcements_feed ON tenant_announcements (tenant_slug, published_at DESC)
    WHERE is_active;

ALTER TABLE tenants               ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_otp            ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_announcements  ENABLE ROW LEVEL SECURITY;
-- 정책 없음 → anon 차단, Edge Function(service_role) 전용 (기존 테이블과 동일).
```

> 이메일 주소는 DB 어디에도 저장하지 않는다(D8). request가 코드를 발송하는 순간에만 메모리에서 쓰고 버린다.
> 인증 성공의 유일한 흔적은 `users.tenant_id`. "누가 어떤 이메일로 인증했는지"는 설계상 추적 불가(의도).

### 3-2. 뷰 / finalize 함수 변경

- `monthly_leaderboard` 뷰: `SELECT`에 `u.tenant_id` 추가. `leaderboard` 함수가
  `.eq("tenant_id", tenant)`로 필터. (Top N·myRank·총원 모두 테넌트 내로.)
- `device_medals` 뷰: **테넌트 무관 평생 집계 유지** — `GROUP BY device_id`(tenant 필터 없음). 전환해도
  개인 메달이 보존·표시(D11). `monthly_winners.tenant_id`는 finalize·보상·명예의전당 필터 용도로만.
- **명예의 전당(previousMonth)**: `leaderboard` 함수가 `monthly_winners`를 **caller 테넌트로 필터** →
  타 테넌트 우승자 명단 비노출(교차노출차단). 개인 메달 집계(myMedals/entry.medals)와 별개 표면.
- `finalize_previous_month_if_needed()`: 테넌트별 Top 3를 각각 산출.
  랭킹 서브쿼리에 `PARTITION BY u.tenant_id`를 넣고 `tenant_id`도 INSERT.
  이미-finalized 가드는 `EXISTS(... WHERE period=prev AND tenant_id=?)`처럼 테넌트별로.
  → 테넌트가 늘면 "테넌트마다 자기 Top 3"가 자동 생성.
- `finalize_monthly_rp_if_needed()` / `finalize_weekly_rp_if_needed()`: 동일하게 테넌트별 순위 정산.
- 길드 뷰 `guild_member_monthly_vp` / `guild_monthly_scores`: `guilds.tenant_id`를 끌어와
  `guild-leaderboard` 함수가 caller 테넌트로 필터. (길드 랭킹도 테넌트 내.)

### 3-3. 공용 헬퍼 + 함수별 적용

`_shared/tenant.ts` 신규:

```ts
// device_id → 현재 테넌트 slug. 미등록이면 null (호출부가 404 처리).
export async function resolveTenant(db, deviceId: string): Promise<string | null> {
  const { data } = await db.from("users").select("tenant_id").eq("device_id", deviceId).maybeSingle();
  return data?.tenant_id ?? null;
}
// 두 디바이스가 같은 테넌트인지 (쪽지·길드가입 등 타깃 있는 액션 가드).
export async function assertSameTenant(db, a: string, b: string): Promise<boolean> { … }
```

적용 표 (핵심만):

| 함수 | 변경 |
|---|---|
| `register` | insert에 `tenant_id: 'public'` 명시(또는 default 위임) |
| `submit` | 변경 없음(users.total_coins만 갱신, 보드는 뷰가 파티션) |
| `leaderboard` | `resolveTenant` → monthly_leaderboard/device_medals/monthly_winners/rp_rewards 전부 `.eq(tenant)` |
| `board`/`post`/`comment`/`like`/`comment-like` | 읽기 `.eq("tenant_id", tenant)`, 쓰기 `tenant_id: tenant` 스탬프 |
| `delete-post`/`delete-comment` | 대상 row의 tenant가 caller와 다르면 403 |
| `dm-send` | `assertSameTenant(sender, recipient)` 아니면 403 `cross_tenant`; insert에 tenant 스탬프 |
| `dm-inbox`/`dm-thread`/`dm-read`/`dm-delete` | `.eq("tenant_id", tenant)` |
| `dm-keys` | 공개키 조회를 같은 테넌트 유저로 제한 |
| `guild-create` | `tenant_id: caller.tenant` 스탬프, 이름 유니크 테넌트별 |
| `guild-join`/`guild-invite` | 대상 길드 tenant == caller.tenant 아니면 403 |
| `guild-info`/`guild-leaderboard`/`guild-office`/`guild-manage`/`guild-leave` | caller 테넌트로 필터/검사 |
| `announcements` | **변경 없음** — 전역 버전 패치노트 (테넌트 무관) |
| (신규) `tenant-announcements` | `resolveTenant` → `WHERE is_active AND tenant_slug = caller.tenant ORDER BY published_at DESC` |
| (신규) `tenant-domains` | `tenant_email_domains`(is_active) ⨝ tenants → 드롭다운용 목록 (인증 불필요) |
| (신규) `tenant-verify-request`/`tenant-verify-confirm` | §3-4 |
| `recover-by-code`/`recover-by-github`/`peek-by-github` | 복구는 tenant를 바꾸지 않음(원 소속 유지). peek은 같은 테넌트만 |
| `fortune`/`pet-metadata`/`codex-sample` | 변경 없음 |

> 원칙: **읽기는 필터, 쓰기는 스탬프, 타깃 있는 액션은 일치 검사.** 세 패턴만 반복된다.

### 3-4. 이메일 인증 함수 (Gmail SMTP)

**`GET /tenant-domains`** — 드롭다운 소스 (deviceId 불필요, 공개 목록)
- `tenant_email_domains`(is_active) ⨝ `tenants` → `{ domains: [{ domain, label, tenant, tenantName }] }`.
- 클라가 인증 폼의 도메인 드롭다운을 채운다. 선택한 도메인의 `tenant`가 편입될 테넌트.

**`POST /tenant-verify-request`** `{ deviceId, email }`
1. `resolveTenant(deviceId)` — 미등록 404. 이미 gated 테넌트면 409 `already_gated`.
2. `email` 정규화(trim+lowercase). `@` 뒤 도메인을 `tenant_email_domains`에서 조회
   (`WHERE domain = d AND is_active`). 없으면 400 `domain_not_allowed`. 있으면 그 row의 `tenant_slug`가
   편입 대상. 도메인은 전역 유니크라 매핑이 유일 — 서브도메인/접미사 변형은 정확 일치 실패로 자동 거부.
3. rate-limit: device당 60초 1회 / 24h 5회, IP 24h M회 (`register_attempts` 패턴).
   (이메일을 저장하지 않으므로 per-email 제한은 없음 — device/IP로만.)
4. 6자리 코드 생성 → SHA-256 → `tenant_otp` insert(device_id·tenant_slug·code_hash, 만료 10분).
   **이메일 주소는 저장하지 않는다** — 아래 발송에만 쓰고 버린다.
5. **Gmail SMTP**로 발송 (denomailer) — ⚠ `content`만 넘기면 charset 미표기로 한글이 mojibake.
   **반드시 `mimeContent`로 charset=utf-8 + base64 명시**(2026-07-07 실발송으로 검증된 레시피):
   ```ts
   import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";
   const client = new SMTPClient({ connection: {
     hostname: "smtp.gmail.com", port: 465, tls: true,
     auth: { username: Deno.env.get("GMAIL_USER")!, password: Deno.env.get("GMAIL_APP_PASSWORD")! },
   }});
   await client.send({
     from: Deno.env.get("GMAIL_USER")!,       // Gmail은 인증 계정으로 From 강제 — 다른 From 불가
     to: email, subject: "AIUsage SKAX 인증 코드",
     mimeContent: [{
       mimeType: "text/plain; charset=utf-8",
       content: `인증 코드: ${code} (10분 유효)`,
       transferEncoding: "base64",
     }],
   });
   await client.close();
   ```
   코드는 **로그에 남기지 않는다**. 응답 `{ ok: true, tenant: 'skax', expiresInSec: 600 }`.
   ✅ 검증 완료(2026-07-07): TCP(465)·앱비번 인증·**sk.com 받은편지함 딜리버리**·한글 인코딩 모두 정상.

**`POST /tenant-verify-confirm`** `{ deviceId, code }`  ← 이메일 안 받음
1. 해당 device의 최신 미소비 `tenant_otp` 조회. 없음/만료/`attempts>=5` → 400.
   (코드 소유 = 메일함 접근 증명이므로 confirm에서 이메일 재확인이 불필요.)
2. `code_hash` 대조 실패 → `attempts++`, 400 `bad_code`. 성공 → 트랜잭션(RPC로 묶음):
   - `users.tenant_id = tenant_slug` (단, 현재가 default 테넌트일 때만; gated면 거부).
   - 타 테넌트 길드 멤버십 삭제(§2-4-1).
   - `tenant_otp.consumed_at = now()`.
3. 응답 `{ ok: true, tenant: 'skax' }`. 클라는 보드/화면 리프레시.

> 이메일 비저장(D8)의 대가: "1 이메일 = N 디바이스" 제한이나 인증 감사 로그를 만들 수 없다(대조할
> 원장이 없음). 공유 사내 주소로 다계정 남용 방어는 device/IP rate-limit + 순위 하드캡에 위임(수용).

---

## 4. 악용 방지 / 보안

- **테넌트 위조 불가**: 클라가 보낸 tenant 값은 전부 무시. 서버가 `device_id`로만 결정.
- **OTP**: 6자리 해시 저장, 10분 만료, 5회 시도 제한, 소비 1회성. 요청/확인 모두 rate-limit.
- **도메인 매칭**: 정규화 후 `@` 뒤를 `tenant_email_domains`(is_active)에서 **정확 일치** 조회.
  `x@sk.com.evil.com`, `x@evilsk.com`, 대문자·공백 변형은 일치 실패로 거부. 목록에 없는 도메인은 전부 차단.
  클라 드롭다운은 편의일 뿐, **서버가 도메인을 재검증**한다(임의 도메인 요청 주입 방지).
- **밴 회피 차단**: 전환이 `status`를 초기화하지 않음.
- **이메일 비저장(D8)**: 주소를 DB에 남기지 않는다. OTP row에도 email 컬럼이 없어 발송 후 흔적 없음.
- **enumeration**: request는 도메인 불일치 외엔 존재 여부를 흘리지 않는 일반 응답. 코드 소유(=메일함
  접근)가 유일한 인증 근거이므로 sk.com 주소를 알아도 메일 수신 없이는 통과 못 함.
- **`GMAIL_APP_PASSWORD`**(16자리 앱 비밀번호)는 `supabase secrets set`로만. 리포지토리/로그 금지.
  개인 메인 계정 노출·한도 리스크 분리를 위해 **발송 전용 Gmail 계정**을 새로 파는 걸 권장.
- **크로스테넌트 403**: 쪽지/길드/삭제 등 타깃 액션은 명시적 `cross_tenant` 에러로 통일(정보 최소 노출).

---

## 5. 클라이언트 설계

서버가 테넌트를 권위 있게 정하므로 클라 변경은 **표시 + 인증 UI**로 국한된다.

- **테넌트 배지**: `RankingView` 헤더에 현재 테넌트 표시(`외부` / `SKAX 🔒`). `leaderboard`/`register`
  응답에 `tenant` 필드를 추가해 클라가 캐시.
- **skax 인증 플로우**(설정 또는 랭킹 탭 진입점):
  1. 안내 + 경고: *"인증 시 SKAX로 고정되며 외부 보드·게시글·쪽지에는 다시 접근할 수 없습니다."*
  2. 이메일 입력: 로컬파트 칸 + **도메인 드롭다운**(`/tenant-domains`로 채움) → `[hong] @ [sk.com ▼]`.
     드롭다운에 테넌트명(예: "SKAX")을 병기해 어디로 편입되는지 표시. 조합한 full email로 `/tenant-verify-request`.
  3. 6자리 코드 입력 → `/tenant-verify-confirm` → 성공 시 배지·보드 리프레시.
- **에러 카피**: `domain_not_allowed`("허용된 도메인만 인증 가능"), `already_gated`("이미 SKAX 소속"),
  `bad_code`/만료 재요청 등 한국어 메시지.
- **공지 분리 표시(D7)**: 전역 패치노트(기존 `announcements`)는 그대로 유지. 테넌트 공지
  (`tenant_announcements`)는 별도 섹션/배너로 노출(버전 무관, 멤버 대상). **두 소스를 UI에서 섞지 않는다.**
- 클라는 tenant를 로컬에 저장하되 **신뢰 원천은 서버**. 위조해도 서버가 무시.
- `RankingAPI.swift`에 인증 2엔드포인트 래퍼 + `TenantVerifyView`(2단계 폼) + 테넌트 공지 fetch 추가.
  나머지 보드/쪽지/길드 뷰는 서버 응답이 이미 테넌트로 걸러져 오므로 **로직 변경 없음**.

---

## 6. 마이그레이션 & 롤아웃 단계

- **P0 — 격리 배선(무변화 배포)**: `tenants`/`users.tenant_id` + 콘텐츠/랭킹 테이블 컬럼 백필(전원
  public), 뷰/finalize 테넌트화, `resolveTenant` 헬퍼로 모든 함수 읽기-필터/쓰기-스탬프 배선.
  이 시점엔 skax 유저가 0이라 **사용자 체감 변화 없음** — 순수 인프라 준비.
  - **P0-a 마이그레이션 `20260708000000_tenants.sql`** (작성·로컬검증 완료): 신규 테이블 4종 + 컬럼
    백필 + **코어 랭킹 테넌트화**(monthly_leaderboard·monthly_winners·RP finalize를 tenant 파티션,
    monthly_winners 유니크 스왑). device_medals는 무변경(D11 평생집계).
  - **P0-b (작성·타입체크 완료)**: `_shared/tenant.ts`(resolveTenant/sameTenant) + 소셜 Edge Function
    배선 — leaderboard, board/post/comment/like/comment-like/delete-post/delete-comment,
    dm-send/dm-keys/dm-inbox/dm-thread/dm-read/dm-delete. submit/register/dm-settings/announcements/
    fortune/peek·recover는 무변경(사유: 개인/전역/신원-복구는 tenant 무관 또는 DB default가 처리).
  - **P0-c (작성·검증 완료)**: `20260709000000_tenant_guilds.sql`(길드 이름유니크·guild_monthly_winners
    유니크·guild_monthly_scores 뷰·finalize를 테넌트별 경쟁으로) + 길드 함수 배선(create 스탬프/테넌트별
    이름유니크, join·invite-accept·manage-invite 테넌트 일치검사, leaderboard 필터). office/leave/info는
    멤버십 스코프라 무변경. 로컬 기능검증: public 2길드→rank1만, skax 3길드→rank1·2 시상(경쟁가드 per-tenant).
- **P1 — skax 오픈**: 선행(Gmail 2FA+앱비번, secret 등록)·발송 검증 완료(2026-07-07).
  - **P1 서버 (작성·검증 완료)**: `20260710000000_tenant_switch_rpc.sql`(apply_tenant_switch — tenant_id
    갱신 + 타 테넌트 길드 자동탈퇴, one-way 가드) + 함수 `tenant-verify-request`(Gmail OTP, 서명 필수)
    `tenant-verify-confirm`(RPC 편입) `tenant-domains`(드롭다운) `tenant-announcements`(테넌트 공지) +
    leaderboard 응답에 `tenant` 필드. 로컬 검증: 전환 시 solo길드 해체/리더 승계/one-way 가드 정상.
  - **P1 클라 (작성·빌드 완료, 별도 앱 릴리스)**: `RankingAPI`에 tenant 모델·4메서드(domains/
    verify-request/confirm/announcements)·`tenantError` 처리 + `LeaderboardResponse.tenant`.
    `RankingView` 헤더에 테넌트 배지 + "사내 인증" 진입 + 테넌트 공지 배너. `TenantVerifyView`
    (로컬파트+도메인 드롭다운 → 6자리 코드 2단계). 서버가 하위호환이라 서버 먼저 배포 후 앱 릴리스.
- **P2 — 운영**: 테넌트 공지(`tenant_announcements` 작성·노출 + 클라 별도 섹션), 관리자 도구
  (디바이스 강제 이동/이관), 테넌트별 통계.

배포 순서 주의: **P0 서버 먼저** → 구버전 클라도 정상(전원 public). P1 클라는 서버 P1 배포 후.
서버/DB 배포는 `supabase-ranking` skill, 클라 릴리스는 `release-app` skill.

---

## 7. 결정 이력 / 열린 이슈

- **[확정]** D1~D8 (§1). carry(D4)·이메일 비저장(D8)·공지 분리(D7) 반영 완료.
- **[확정] 랭킹 carry**: D4대로 `users.tenant_id` 기준(carry). freeze 대안(`submissions.tenant_id`
  스탬프 + 그 컬럼 파티션)은 skax 닉네임이 과거 public 코인으로 public 보드에 잔존하는 교차노출을
  만들어 격리 원칙과 상충 → 채택 안 함.
- **[해소] 1 이메일 = N 시트**: 이메일 비저장(D8)이라 시트 제한/감사는 원천적으로 포기.
  남용 방어는 device/IP rate-limit + 순위 하드캡에 위임.
- **[해소] 공지 구조**: 전역/테넌트 공지를 별도 테이블·엔드포인트로 분리(D7). 기존 `announcements` 무변경.
- **[확정] 메달 = 평생 개인 업적(D11)**: 전환에도 유지·표시. `device_medals`를 테넌트 무관 집계로
  재설계(`monthly_winners`는 tenant 태깅 유지 — finalize/보상/명예의전당 필터용). 잔여 교차노출은
  *본인 집계 숫자*가 새 테넌트 카드에 보이는 것뿐(타 테넌트 유저·보드·점수·우승자명단은 일절 비노출). 수용.
- **[검증완료] 발송 경로 / From**: **Gmail SMTP**(도메인 미구입, 사내 릴레이 없음). From=개인 Gmail 고정.
  2026-07-07 실발송으로 TCP(465)·앱비번 인증·**sk.com 받은편지함 딜리버리**·한글 인코딩 모두 정상 확인.
  남은 리스크는 **Gmail 일 500통 한도**뿐(초기 점진 공개로 흡수). denomailer는 `mimeContent`+base64 필수(§3-4).
- **[열림·리뷰] 전환 후 쪽지 열람**: 현재 dm-inbox/thread/read/delete가 현재 테넌트로 필터 → 전환 시
  과거 스레드(미확인 E2EE 포함)가 영구 비노출. 완화안 = 읽기 필터 제거(dm-send 교차차단은 유지)로 본인
  이력 보존 + 코드 단순화. **사용자 결정 대기** (권장: 완화). skax 유저 0이라 배포 차단 아님.
- **[열림·리뷰] finalize 오귀속**: 지난달 정산(명예의전당·RP)이 현재 tenant_id 기준이라, 경쟁 후 월초
  전환 시 지난달 우승/RP가 새 테넌트로 이동(+ public은 1등 상실, podium 한마디 등록 불가). carry의
  스냅샷 부작용. **사용자 결정 대기** (권장: 현행+문서화 / 대안: 전환 가드 or submissions.tenant_id freeze).
- **[열림·리뷰] resolveTenant fail-open**: users 조회 transient 에러 시 null→public 폴백(gated 유저가
  잠시 public 보드 노출). 읽기 전용·다음 폴링 자가복구라 경미. 하드닝은 선택.
- **[해소·리뷰] OTP 발송 실패 rate-limit 소모**: 발송 실패 시 OTP row 삭제로 수정(재시도 잠금 방지).
- **[해소·리뷰] 클라 에러 오표시**: 403 cross_tenant→"차단", verify 429→게시판 문구, dead state 수정.
- **[열림] OTP purge**: 만료/소비 row 정리를 lazy(조회 시) vs 크론 — P1에서 확정.
- **[비고]** `daily_fortunes`·`codex_usage_samples`는 비소셜이라 격리 제외했으나, 사내 데이터 분리
  정책상 태깅이 필요하면 P2에서 tenant_id 추가 가능(파괴적 변경 아님).
```
