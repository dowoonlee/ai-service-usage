-- 완전 격리형 멀티테넌시 P0 — 스키마 + 코어 랭킹 테넌트화. docs/plans/tenant.md.
--
-- 이 마이그레이션 배포 시점엔 전원 'public'이라 사용자 체감 변화 없음(순수 인프라 준비).
--
-- 설계 노트:
--   * 소속의 단일 진실 = users.tenant_id. 클라는 tenant를 주장 못 하고 서버가 device_id로만 판정.
--   * 랭킹(리더보드/월간우승/RP)은 users.tenant_id로 파티션 → 디바이스는 현재 테넌트 보드에만 등장(carry).
--   * device_medals는 손대지 않는다 — 테넌트 무관 '평생 개인 집계'(D11: 전환해도 메달 유지).
--     교차노출차단은 leaderboard 함수가 '명예의전당(monthly_winners)'만 테넌트 필터하는 것으로 달성(P1 배선).
--   * 콘텐츠(게시판/쪽지/길드)는 row에 tenant_id 스탬프 — 여기선 컬럼만 준비, 필터/스탬프는 Edge Function(P1).
--   * 길드 하위 로직(뷰/finalize/이름 유니크)의 테넌트화는 guild Edge Function 배선과 함께 별도 마이그레이션.
--     여기선 guilds/guild_monthly_winners에 tenant_id 컬럼만 추가(전원 public이라 기존 로직 그대로 정상).
--   * 이메일 원장 테이블 없음(D8) — tenant_otp는 휘발성, email 컬럼조차 없다.

-- ===========================================================================
-- 1) 레지스트리 — tenants + 테넌트↔도메인(1:N)
-- ===========================================================================
CREATE TABLE tenants (
    slug         TEXT PRIMARY KEY,               -- 'public' | 'skax' | …
    display_name TEXT NOT NULL,
    join_policy  TEXT NOT NULL DEFAULT 'open'    -- 'open' | 'email_domain' | 'admin_only'
                 CHECK (join_policy IN ('open','email_domain','admin_only')),
    is_default   BOOLEAN NOT NULL DEFAULT FALSE, -- 신규 디바이스 기본 소속 (정확히 1개 TRUE)
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- is_default = TRUE 는 정확히 하나만 (partial unique).
CREATE UNIQUE INDEX tenants_default_uniq ON tenants (is_default) WHERE is_default;

-- 테넌트 ↔ 허용 이메일 도메인 = 1:N (D9). domain PK = 전역 유니크 → 한 도메인은 한 테넌트로만 매핑.
-- 도메인 추가/숨김은 이 테이블 row 조작만(재배포 불필요). is_active=false 는 신규 인증만 막고 기존 소속은 유지.
CREATE TABLE tenant_email_domains (
    domain      TEXT PRIMARY KEY,               -- 정규화 lowercase (예: 'sk.com')
    tenant_slug TEXT NOT NULL REFERENCES tenants(slug) ON DELETE CASCADE,
    label       TEXT,                           -- 드롭다운 표시 override(선택). NULL이면 domain 그대로
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX tenant_email_domains_tenant ON tenant_email_domains (tenant_slug) WHERE is_active;

INSERT INTO tenants (slug, display_name, join_policy, is_default) VALUES
    ('public', '외부',  'open',         TRUE),
    ('skax',   'SKAX',  'email_domain', FALSE);
INSERT INTO tenant_email_domains (domain, tenant_slug) VALUES
    ('sk.com', 'skax');
    -- 계열사 확장 예: INSERT ('sktelecom.com','skax'), ('sk.co.kr','skax') … (마이그레이션/재배포 불필요)

-- ===========================================================================
-- 2) OTP (휘발성) — 이메일 주소는 저장하지 않는다(D8). 발송 때만 쓰고 버린다.
-- ===========================================================================
CREATE TABLE tenant_otp (
    id           BIGSERIAL PRIMARY KEY,
    device_id    UUID NOT NULL,                 -- FK 없음: 미등록 상태 대비 (register는 선행)
    tenant_slug  TEXT NOT NULL REFERENCES tenants(slug),
    code_hash    TEXT NOT NULL,                 -- SHA-256 hex of 6-digit code
    expires_at   TIMESTAMPTZ NOT NULL,
    attempts     SMALLINT NOT NULL DEFAULT 0,
    consumed_at  TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX tenant_otp_device_recent ON tenant_otp (device_id, created_at DESC);

-- ===========================================================================
-- 3) 테넌트 전용 공지 (전역 announcements와 분리 — 버전 무관, 멤버 대상). D7.
-- ===========================================================================
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

-- ===========================================================================
-- 4) 앵커 — users.tenant_id (기존 유저 전원 public 백필)
-- ===========================================================================
ALTER TABLE users ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
-- 리더보드 정렬 — 테넌트별 active·total_coins 내림차순 (기존 users_active_coins의 테넌트 파티션판).
CREATE INDEX users_tenant_coins ON users (tenant_id, total_coins DESC, registered_at ASC)
    WHERE status = 'active';

-- ===========================================================================
-- 5) 콘텐츠/랭킹 테이블 tenant_id 스탬프 컬럼 (기존 row = 'public')
--    쓰기 스탬프/읽기 필터는 Edge Function(P1). 여기선 컬럼·인덱스만 준비.
-- ===========================================================================
ALTER TABLE board_posts               ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE board_post_likes          ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE board_post_comments       ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE board_post_comment_likes  ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE direct_messages           ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE guilds                    ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE guild_monthly_winners     ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE monthly_winners           ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);
ALTER TABLE rp_rewards                ADD COLUMN tenant_id TEXT NOT NULL DEFAULT 'public' REFERENCES tenants(slug);

CREATE INDEX board_posts_tenant_time    ON board_posts (tenant_id, created_at DESC);
CREATE INDEX direct_messages_tenant_idx ON direct_messages (tenant_id, recipient_device, created_at DESC);

-- ===========================================================================
-- 6) 코어 랭킹 테넌트화 (리더보드 / 월간우승 / RP)
-- ===========================================================================

-- 6-a) monthly_leaderboard — 테넌트별 순위. ROW_NUMBER를 tenant로 파티션.
--   include-zero-vp(LEFT JOIN + COALESCE) 로직 유지. tenant_id 컬럼 추가 위해 DROP+CREATE.
DROP VIEW IF EXISTS monthly_leaderboard;
CREATE VIEW monthly_leaderboard AS
WITH period_start AS (
    SELECT (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul' AS start_at
),
monthly AS (
    SELECT
        s.device_id,
        SUM(s.accepted_coins)::BIGINT AS monthly_coins
    FROM submissions s, period_start
    WHERE s.accepted = TRUE
      AND s.submitted_at >= period_start.start_at
    GROUP BY s.device_id
)
SELECT
    u.device_id,
    u.tenant_id,
    u.nickname,
    u.github_login,
    u.profile_json,
    COALESCE(m.monthly_coins, 0)::BIGINT AS monthly_coins,
    ROW_NUMBER() OVER (
        PARTITION BY u.tenant_id
        ORDER BY COALESCE(m.monthly_coins, 0) DESC, u.registered_at ASC
    ) AS rank
FROM users u
LEFT JOIN monthly m ON m.device_id = u.device_id
WHERE u.status = 'active';

-- 6-b) monthly_winners 유니크 스왑 (period,rank) → (tenant_id,period,rank).
--   finalize의 ON CONFLICT과 원자적으로 함께 바꿔야 하므로 아래 함수 재정의와 한 마이그레이션에 둔다.
--   전원 public이라 (public,period,rank) 유니크는 기존 (period,rank)와 동치 — 데이터 충돌 없음.
DROP INDEX monthly_winners_period_rank;
CREATE UNIQUE INDEX monthly_winners_tenant_period_rank ON monthly_winners (tenant_id, period, rank);

-- finalize_previous_month_if_needed — 테넌트별 Top 3. 날짜 계산은 fix_monthly_finalize_tz 수정본 유지.
--   한 period를 전 테넌트 한 INSERT로 원자 처리하므로 EXISTS 가드는 period만 검사해도 정확.
CREATE OR REPLACE FUNCTION finalize_previous_month_if_needed() RETURNS VOID AS $$
DECLARE
    this_month_start TIMESTAMPTZ;
    prev_month_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    this_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month') AT TIME ZONE 'Asia/Seoul';
    prev_period := to_char(date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month', 'YYYY-MM');

    IF EXISTS (SELECT 1 FROM monthly_winners WHERE period = prev_period LIMIT 1) THEN
        RETURN;
    END IF;

    -- 테넌트별 상위 3명 (rank를 tenant로 파티션). 보상: 1등 10,000 / 2등 5,000 / 3등 2,500 coin.
    INSERT INTO monthly_winners
        (period, tenant_id, device_id, rank, final_score, nickname_snapshot, profile_json_snapshot, reward_coins)
    SELECT
        prev_period,
        ranked.tenant_id,
        ranked.device_id,
        ranked.rank,
        ranked.monthly_total,
        ranked.nickname,
        ranked.profile_json,
        CASE ranked.rank WHEN 1 THEN 10000 WHEN 2 THEN 5000 WHEN 3 THEN 2500 END
    FROM (
        SELECT
            u.tenant_id,
            m.device_id,
            m.monthly_total,
            u.nickname,
            u.profile_json,
            ROW_NUMBER() OVER (
                PARTITION BY u.tenant_id ORDER BY m.monthly_total DESC, u.registered_at ASC
            ) AS rank
        FROM (
            SELECT s.device_id, SUM(s.accepted_coins)::BIGINT AS monthly_total
            FROM submissions s
            WHERE s.accepted = TRUE
              AND s.submitted_at >= prev_month_start
              AND s.submitted_at <  this_month_start
            GROUP BY s.device_id
            HAVING SUM(s.accepted_coins) > 0
        ) m
        JOIN users u ON u.device_id = m.device_id
        WHERE u.status = 'active'
    ) ranked
    WHERE ranked.rank <= 3
    ON CONFLICT (tenant_id, period, rank) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- 6-c) RP finalize — 테넌트별 순위/총원. rp_rewards 유니크(period_type,period,device_id)는 device당
--   1행이라 스왑 불필요 (device는 한 테넌트 소속). rank/total_ranked만 tenant로 파티션 + tenant_id 스탬프.
CREATE OR REPLACE FUNCTION finalize_monthly_rp_if_needed() RETURNS VOID AS $$
DECLARE
    this_month_start TIMESTAMPTZ;
    prev_month_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    this_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month') AT TIME ZONE 'Asia/Seoul';
    prev_period := to_char(date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month', 'YYYY-MM');

    IF EXISTS (SELECT 1 FROM rp_rewards WHERE period_type = 'monthly' AND period = prev_period LIMIT 1) THEN
        RETURN;
    END IF;

    INSERT INTO rp_rewards (period, period_type, tenant_id, device_id, rank, rp_amount)
    SELECT
        prev_period, 'monthly', ranked.tenant_id, ranked.device_id, ranked.rank,
        CASE
            WHEN ranked.rank = 1 THEN 1000
            WHEN ranked.rank = 2 THEN 600
            WHEN ranked.rank = 3 THEN 400
            WHEN ranked.rank <= 10 THEN 200
            WHEN ranked.rank <= 50 THEN 80
            WHEN ranked.rank <= GREATEST(50, ROUND(ranked.total_ranked * 0.1)) THEN 40   -- 상위 10%
            WHEN ranked.rank <= GREATEST(50, ROUND(ranked.total_ranked * 0.5)) THEN 25   -- 상위 50%
            ELSE 20                                                                       -- 참여
        END
    FROM (
        SELECT
            u.tenant_id,
            m.device_id,
            ROW_NUMBER() OVER (PARTITION BY u.tenant_id ORDER BY m.monthly_total DESC, u.registered_at ASC) AS rank,
            COUNT(*) OVER (PARTITION BY u.tenant_id) AS total_ranked
        FROM (
            SELECT s.device_id, SUM(s.accepted_coins)::BIGINT AS monthly_total
            FROM submissions s
            WHERE s.accepted = TRUE
              AND s.submitted_at >= prev_month_start
              AND s.submitted_at <  this_month_start
            GROUP BY s.device_id
            HAVING SUM(s.accepted_coins) > 0
        ) m
        JOIN users u ON u.device_id = m.device_id
        WHERE u.status = 'active'
    ) ranked
    ON CONFLICT (period_type, period, device_id) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION finalize_weekly_rp_if_needed() RETURNS VOID AS $$
DECLARE
    this_week_start TIMESTAMPTZ;
    prev_week_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    this_week_start := (date_trunc('week', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_week_start := this_week_start - INTERVAL '7 days';
    prev_period := to_char(prev_week_start AT TIME ZONE 'Asia/Seoul', 'IYYY-"W"IW');

    IF EXISTS (SELECT 1 FROM rp_rewards WHERE period_type = 'weekly' AND period = prev_period LIMIT 1) THEN
        RETURN;
    END IF;

    INSERT INTO rp_rewards (period, period_type, tenant_id, device_id, rank, rp_amount)
    SELECT
        prev_period, 'weekly', ranked.tenant_id, ranked.device_id, ranked.rank,
        CASE
            WHEN ranked.rank = 1 THEN 250
            WHEN ranked.rank = 2 THEN 150
            WHEN ranked.rank = 3 THEN 100
            WHEN ranked.rank <= 10 THEN 60
            WHEN ranked.rank <= 50 THEN 25
            WHEN ranked.rank <= GREATEST(50, ROUND(ranked.total_ranked * 0.1)) THEN 12   -- 상위 10%
            WHEN ranked.rank <= GREATEST(50, ROUND(ranked.total_ranked * 0.5)) THEN 8    -- 상위 50%
            ELSE 5                                                                        -- 참여
        END
    FROM (
        SELECT
            u.tenant_id,
            m.device_id,
            ROW_NUMBER() OVER (PARTITION BY u.tenant_id ORDER BY m.weekly_total DESC, u.registered_at ASC) AS rank,
            COUNT(*) OVER (PARTITION BY u.tenant_id) AS total_ranked
        FROM (
            SELECT s.device_id, SUM(s.accepted_coins)::BIGINT AS weekly_total
            FROM submissions s
            WHERE s.accepted = TRUE
              AND s.submitted_at >= prev_week_start
              AND s.submitted_at <  this_week_start
            GROUP BY s.device_id
            HAVING SUM(s.accepted_coins) > 0
        ) m
        JOIN users u ON u.device_id = m.device_id
        WHERE u.status = 'active'
    ) ranked
    ON CONFLICT (period_type, period, device_id) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- ===========================================================================
-- 7) RLS — 신규 테이블 전부 anon 차단 (Edge Function service_role 경유만). 기존 테이블과 동일.
-- ===========================================================================
ALTER TABLE tenants               ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_email_domains  ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_otp            ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_announcements  ENABLE ROW LEVEL SECURITY;
