-- 월간 명예의 전당 + 보상 시스템.
-- 매월 1일 00:00 KST에 직전 달 Top 3가 동결되어 reward 지급 대상이 됨.
-- finalize는 cron 대신 leaderboard endpoint가 첫 호출 시 lazy trigger (UNIQUE로 race 차단).

CREATE TABLE monthly_winners (
    id                    BIGSERIAL PRIMARY KEY,
    period                TEXT NOT NULL,                          -- "YYYY-MM" (KST 기준)
    device_id             UUID REFERENCES users(device_id) ON DELETE SET NULL,
    rank                  INTEGER NOT NULL CHECK (rank BETWEEN 1 AND 3),
    final_score           BIGINT NOT NULL,
    nickname_snapshot     TEXT NOT NULL,                          -- finalize 시점 닉네임 동결
    profile_json_snapshot JSONB,                                  -- 트레이너 카드 표시용
    reward_coins          INTEGER NOT NULL,
    finalized_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    reward_claimed_at     TIMESTAMPTZ                             -- NULL = 미수령
);

-- 한 period당 같은 rank는 하나뿐 — race 자동 차단.
CREATE UNIQUE INDEX monthly_winners_period_rank ON monthly_winners(period, rank);
-- 본인의 미수령 reward 조회 hot path.
CREATE INDEX monthly_winners_device_unclaimed
    ON monthly_winners(device_id, reward_claimed_at)
    WHERE reward_claimed_at IS NULL;
-- 기간별 조회 (명예의 전당 섹션).
CREATE INDEX monthly_winners_period ON monthly_winners(period);

-- ============================================================================
-- finalize_previous_month_if_needed()
-- ============================================================================
-- 직전 KST 월의 Top 3를 1회 INSERT. 이미 finalized면 no-op.
-- leaderboard Edge Function의 시작부에서 호출.

CREATE OR REPLACE FUNCTION finalize_previous_month_if_needed() RETURNS VOID AS $$
DECLARE
    this_month_start TIMESTAMPTZ;
    prev_month_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    -- KST 기준 이번 달 / 직전 달 시작 시각.
    this_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_month_start := this_month_start - INTERVAL '1 month';
    prev_period := to_char(prev_month_start AT TIME ZONE 'Asia/Seoul', 'YYYY-MM');

    -- 이미 finalized 검사 — UNIQUE constraint가 있어도 비싼 aggregation 회피.
    IF EXISTS (SELECT 1 FROM monthly_winners WHERE period = prev_period LIMIT 1) THEN
        RETURN;
    END IF;

    -- 직전 달 submissions 합산 → active 사용자 Top 3 → INSERT.
    -- 보상: 1등 10,000 / 2등 5,000 / 3등 2,500 coin.
    INSERT INTO monthly_winners
        (period, device_id, rank, final_score, nickname_snapshot, profile_json_snapshot, reward_coins)
    SELECT
        prev_period,
        u.device_id,
        ranked.rank,
        ranked.monthly_total,
        u.nickname,
        u.profile_json,
        CASE ranked.rank
            WHEN 1 THEN 10000
            WHEN 2 THEN 5000
            WHEN 3 THEN 2500
        END
    FROM (
        SELECT
            m.device_id,
            m.monthly_total,
            ROW_NUMBER() OVER (ORDER BY m.monthly_total DESC, u.registered_at ASC) AS rank
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
    JOIN users u ON u.device_id = ranked.device_id
    WHERE ranked.rank <= 3
    ON CONFLICT (period, rank) DO NOTHING;
END;
$$ LANGUAGE plpgsql;
