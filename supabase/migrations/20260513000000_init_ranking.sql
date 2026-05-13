-- 랭킹 시스템 초기 schema.
--
-- 디자인 노트:
--   * users.device_id가 PK — 디바이스 단위로 row 1개. 재설치 시 새 device_id가 같은 user의
--     hmac_key/recovery_code를 받아 매핑(서버측에서 update). 같은 GitHub login으로 두 디바이스
--     동시 사용은 의도적으로 불허 — github_user_id에 UNIQUE 제약.
--   * users.total_coins는 캐시. 진실은 SUM(delta_coins WHERE accepted) FROM submissions.
--     submit 트랜잭션 내에서 동기 갱신.
--   * submissions는 append-only time-series. 운영자 audit + 기간별 통계 슬라이싱용. ban 평가 시
--     이상치 점수도 여기서 계산.
--   * RLS는 모든 anon 직접 접근 차단. 클라이언트는 Edge Functions 경유만. Edge Functions는
--     service_role로 접근하여 RLS bypass.

-- ===========================================================================
-- users — 1 row per device (registered identity)
-- ===========================================================================
CREATE TABLE users (
    device_id            UUID PRIMARY KEY,
    nickname             TEXT NOT NULL,
    nickname_normalized  TEXT NOT NULL,             -- LOWER(nickname), case-insensitive unique
    github_login         TEXT,                       -- 사용자가 GitHub 연동 시
    github_user_id       BIGINT,                     -- login 변경 안전한 ID
    hmac_key_b64         TEXT NOT NULL,              -- per-install 32바이트 base64
    recovery_code_hash   TEXT NOT NULL,              -- SHA-256 hex of recovery code
    total_coins          BIGINT NOT NULL DEFAULT 0,  -- accepted submissions 합계 캐시
    status               TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'banned', 'shadow_banned')),
    registered_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_submitted_at    TIMESTAMPTZ,
    CONSTRAINT nickname_length CHECK (CHAR_LENGTH(nickname) BETWEEN 3 AND 24)
);

-- case-insensitive unique
CREATE UNIQUE INDEX users_nickname_normalized_uniq ON users (nickname_normalized);
-- github_user_id는 nullable + 있을 땐 unique (한 GitHub 계정에 한 user)
CREATE UNIQUE INDEX users_github_user_id_uniq ON users (github_user_id) WHERE github_user_id IS NOT NULL;
-- 리더보드 정렬 — active만, total_coins 내림차순
CREATE INDEX users_active_coins ON users (total_coins DESC, registered_at ASC) WHERE status = 'active';

-- ===========================================================================
-- submissions — append-only time-series log
-- ===========================================================================
CREATE TABLE submissions (
    id                BIGSERIAL PRIMARY KEY,
    device_id         UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    delta_coins       INTEGER NOT NULL,             -- 클라이언트가 보고한 raw delta
    accepted_coins    INTEGER NOT NULL,             -- 캡 적용 후 실제 반영된 양 (<= delta_coins)
    elapsed_seconds   INTEGER NOT NULL,             -- 직전 제출 후 경과 (클라 시각). 0 = 첫 제출
    submitted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    client_ts         BIGINT,                       -- 클라이언트 epoch (replay 방지 보조)
    accepted          BOOLEAN NOT NULL,
    cap_applied       BOOLEAN NOT NULL DEFAULT FALSE,
    reject_reason     TEXT
);

CREATE INDEX submissions_device_time ON submissions (device_id, submitted_at DESC);
CREATE INDEX submissions_time ON submissions (submitted_at DESC);
CREATE INDEX submissions_accepted_time ON submissions (submitted_at DESC) WHERE accepted = TRUE;

-- ===========================================================================
-- abuse_flags — 이상치 누적 점수 (수동 큐레이션 보조)
-- ===========================================================================
CREATE TABLE abuse_flags (
    id          BIGSERIAL PRIMARY KEY,
    device_id   UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    reason      TEXT NOT NULL,
    flagged_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    details     JSONB
);
CREATE INDEX abuse_flags_device ON abuse_flags (device_id);
CREATE INDEX abuse_flags_recent ON abuse_flags (flagged_at DESC);

-- ===========================================================================
-- public_leaderboard — anon 가능한 조회 view
-- ===========================================================================
-- ROW_NUMBER로 동점자는 등록일 빠른 쪽이 상위 → 결정적 순서.
-- shadow_banned/banned는 자동 제외. total_coins > 0만 표시 (옵트인만 했고 적립 0인 사용자 가림).
CREATE VIEW public_leaderboard AS
SELECT
    device_id,
    nickname,
    github_login,
    total_coins,
    ROW_NUMBER() OVER (ORDER BY total_coins DESC, registered_at ASC) AS rank
FROM users
WHERE status = 'active' AND total_coins > 0;

-- ===========================================================================
-- RLS — anon은 직접 테이블 접근 차단. 모든 access는 Edge Functions 경유.
-- service_role은 RLS bypass라 Edge Functions 내부 쿼리는 영향 없음.
-- ===========================================================================
ALTER TABLE users        ENABLE ROW LEVEL SECURITY;
ALTER TABLE submissions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE abuse_flags  ENABLE ROW LEVEL SECURITY;

-- 명시적 정책 없음 → anon은 SELECT/INSERT/UPDATE/DELETE 모두 거부.
-- 만약 leaderboard view를 anon에 노출하려면 아래 GRANT 활성화:
-- GRANT SELECT ON public_leaderboard TO anon;
-- (현재는 leaderboard Edge Function이 service_role로 조회해서 응답하므로 불필요)
