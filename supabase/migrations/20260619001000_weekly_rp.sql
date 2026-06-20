-- 주간 RP 정산 — 월간(finalize_monthly_rp_if_needed)과 평행 구조. 직전 ISO 주(월요일 00:00 KST 시작)의
-- 전체 순위에 RP를 계단식으로 지급한다. 주간 풀은 월간의 약 1/4로 둬서 "주간=잔잔, 월간=한 방" 성격을
-- 구분한다. rp_rewards 테이블은 20260619000000_rp_rewards.sql에서 생성. cf. docs/DESIGN_RP_ECONOMY.md

CREATE OR REPLACE FUNCTION finalize_weekly_rp_if_needed() RETURNS VOID AS $$
DECLARE
    this_week_start TIMESTAMPTZ;
    prev_week_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    -- date_trunc('week')는 월요일 시작 (ISO). KST 기준 직전 주 구간.
    this_week_start := (date_trunc('week', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_week_start := this_week_start - INTERVAL '7 days';
    -- ISO year + ISO week, 예: "2026-W25".
    prev_period := to_char(prev_week_start AT TIME ZONE 'Asia/Seoul', 'IYYY-"W"IW');

    IF EXISTS (SELECT 1 FROM rp_rewards WHERE period_type = 'weekly' AND period = prev_period LIMIT 1) THEN
        RETURN;
    END IF;

    INSERT INTO rp_rewards (period, period_type, device_id, rank, rp_amount)
    SELECT
        prev_period, 'weekly', ranked.device_id, ranked.rank,
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
            m.device_id,
            ROW_NUMBER() OVER (ORDER BY m.weekly_total DESC, u.registered_at ASC) AS rank,
            COUNT(*) OVER () AS total_ranked
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
