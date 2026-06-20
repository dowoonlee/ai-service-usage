-- RP(Rank Point) 보상 원장 — 랭킹 순위 정산으로 적립되는 화폐. coins(monthly_winners)와 수급처가
-- 분리된 경제다 (coins=사용량/진행, RP=순위/과시). monthly_winners와 동일하게 leaderboard endpoint가
-- 첫 호출 시 lazy trigger로 정산하며 pg_cron은 쓰지 않는다. cf. docs/DESIGN_RP_ECONOMY.md

CREATE TABLE rp_rewards (
    id           BIGSERIAL PRIMARY KEY,
    period       TEXT NOT NULL,                                    -- 월간 "YYYY-MM" / 주간 "IYYY-Www" (KST)
    period_type  TEXT NOT NULL CHECK (period_type IN ('monthly', 'weekly')),
    device_id    UUID REFERENCES users(device_id) ON DELETE SET NULL,
    rank         INTEGER NOT NULL,
    rp_amount    INTEGER NOT NULL,
    finalized_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    claimed_at   TIMESTAMPTZ                                       -- NULL = 미수령
);

-- 한 (기간 타입·기간·device)당 한 행 — race 자동 차단 + 재정산 멱등.
CREATE UNIQUE INDEX rp_rewards_periodtype_period_device ON rp_rewards(period_type, period, device_id);
-- 본인의 미수령 보상 조회 hot path (monthly_winners_device_unclaimed 패턴).
CREATE INDEX rp_rewards_device_unclaimed ON rp_rewards(device_id, claimed_at) WHERE claimed_at IS NULL;

-- anon 직접 접근 차단 — service_role(Edge Function)만 읽고 쓴다 (monthly_winners와 동일).
ALTER TABLE rp_rewards ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- finalize_monthly_rp_if_needed()
-- ============================================================================
-- 직전 KST 월의 **전체 순위**에 RP를 계단식으로 1회 INSERT. 이미 정산됐으면 no-op.
-- coins 정산(finalize_previous_month_if_needed)이 Top3만 다루는 것과 달리, RP는 참여자 전원에게
-- 순위 비례로 지급해 "꼴찌도 0이 아닌" 분배를 만든다. leaderboard Edge Function 시작부에서 호출.

CREATE OR REPLACE FUNCTION finalize_monthly_rp_if_needed() RETURNS VOID AS $$
DECLARE
    this_month_start TIMESTAMPTZ;
    prev_month_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    this_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_month_start := this_month_start - INTERVAL '1 month';
    prev_period := to_char(prev_month_start AT TIME ZONE 'Asia/Seoul', 'YYYY-MM');

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
