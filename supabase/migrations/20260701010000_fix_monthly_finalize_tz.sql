-- 월간 finalize(명예의 전당 + 월간 RP)의 직전 달 계산 버그 수정.
--
-- 버그: prev_month_start := this_month_start - INTERVAL '1 month' 에서 this_month_start가
-- timestamptz다. KST 자정(예: 7/1 00:00)은 UTC로 전월 말일 15:00(6/30 15:00)이라, timestamptz에서
-- 달력 한 달을 빼면 5/30 15:00 → prev_period="2026-05"로 한 달 밀린다. 이미 5월이 finalized돼
-- 있으니 EXISTS 가드에 걸려 no-op → 6월이 영영 정산 안 됨. (말일 clamping이 우연히 가려주는 달
-- 경계에선 정상 동작해 5월까진 문제 없었다.)
--
-- 수정: 달(달력) 빼기를 naive Seoul timestamp(= date_trunc 결과, tz 없음)에서 수행한 뒤 timestamptz로
-- 변환한다. 주간 finalize는 '- INTERVAL 7 days'(고정 일수)라 이 문제가 없어 손대지 않는다.

CREATE OR REPLACE FUNCTION finalize_previous_month_if_needed() RETURNS VOID AS $$
DECLARE
    this_month_start TIMESTAMPTZ;
    prev_month_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    -- KST 기준 이번 달 / 직전 달 시작. 달 빼기는 naive Seoul timestamp에서 수행(아래 버그 주석 참고).
    this_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month') AT TIME ZONE 'Asia/Seoul';
    prev_period := to_char(date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month', 'YYYY-MM');

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

CREATE OR REPLACE FUNCTION finalize_monthly_rp_if_needed() RETURNS VOID AS $$
DECLARE
    this_month_start TIMESTAMPTZ;
    prev_month_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    this_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month') AT TIME ZONE 'Asia/Seoul';
    prev_period := to_char(date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month', 'YYYY-MM');

    -- 이미 정산됐으면 비싼 aggregation 회피.
    IF EXISTS (SELECT 1 FROM rp_rewards WHERE period_type = 'monthly' AND period = prev_period LIMIT 1) THEN
        RETURN;
    END IF;

    -- 직전 달 submissions 합산 → active 사용자 전체 순위 → 계단식 RP.
    -- 절대순위(1~50)를 백분위보다 먼저 적용하고, GREATEST(50, ...)로 소규모 모집단에서 백분위 구간이
    -- 50위 절대구간에 묻혀 역전되지 않도록 한다.
    INSERT INTO rp_rewards (period, period_type, device_id, rank, rp_amount)
    SELECT
        prev_period, 'monthly', ranked.device_id, ranked.rank,
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
            m.device_id,
            ROW_NUMBER() OVER (ORDER BY m.monthly_total DESC, u.registered_at ASC) AS rank,
            COUNT(*) OVER () AS total_ranked
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
