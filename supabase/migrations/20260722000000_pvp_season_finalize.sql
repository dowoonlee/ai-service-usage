-- 아레나 시즌(월간) 정산 — 직전 달 레이팅 상위에게 RP 지급 (기획 §2-8 / T6).
--
-- rp_rewards 의 finalize_monthly_rp_if_needed 패턴을 미러: leaderboard(pvp-leaderboard) 조회 시
-- lazy 트리거. 멱등(pvp_seasons 마커). RP는 reward_grants(currency='rp')에 INSERT → 클라의
-- 기존 pendingGrant/claim-reward 파이프라인이 자동 수령(신규 수령 코드 불필요).
-- 챔피언(테넌트 1위)에겐 확정 강화권 1장도 지급(§2-9 확정권 재원 = 시즌 보상).

-- 시즌 정산 완료 마커(멱등).
CREATE TABLE pvp_seasons (
    period       TEXT PRIMARY KEY,                 -- "YYYY-MM" (KST)
    finalized_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE pvp_seasons ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION finalize_previous_month_pvp_if_needed() RETURNS VOID AS $$
DECLARE
    prev_period TEXT;
BEGIN
    prev_period := to_char(
        date_trunc('month', (NOW() AT TIME ZONE 'Asia/Seoul')) - interval '1 month', 'YYYY-MM');

    -- 이미 정산됨 → skip (멱등).
    IF EXISTS (SELECT 1 FROM pvp_seasons WHERE period = prev_period) THEN RETURN; END IF;

    -- 티어별 RP를 reward_grants 에 삽입 (테넌트별 백분위 랭킹, 참여자 = 1판 이상).
    -- grant_key 는 콜론 불가(CHECK) → 하이픈. UNIQUE(device_id, grant_key)로 이중지급 방지.
    INSERT INTO reward_grants (device_id, currency, amount, reason, grant_key)
    SELECT r.device_id, 'rp',
        CASE WHEN r.rk = 1 THEN 400
             WHEN r.rk <= GREATEST(1, CEIL(r.cnt * 0.1)) THEN 150
             WHEN r.rk <= CEIL(r.cnt * 0.5) THEN 40
             ELSE 15 END,
        'pvp season ' || prev_period || ' rank ' || r.rk,
        'pvp-season-' || prev_period || '-' || r.device_id::text
    FROM (
        SELECT device_id, tenant_id,
            ROW_NUMBER() OVER (PARTITION BY tenant_id ORDER BY rating DESC, updated_at ASC) AS rk,
            COUNT(*)     OVER (PARTITION BY tenant_id) AS cnt
        FROM pvp_ratings
        WHERE wins + losses > 0
    ) r
    ON CONFLICT (device_id, grant_key) DO NOTHING;

    -- 챔피언(테넌트 1위)에게 확정 강화권 1장.
    INSERT INTO enhance_items (device_id, guarantee_count)
    SELECT device_id, 1 FROM (
        SELECT device_id,
            ROW_NUMBER() OVER (PARTITION BY tenant_id ORDER BY rating DESC, updated_at ASC) AS rk
        FROM pvp_ratings WHERE wins + losses > 0
    ) c WHERE c.rk = 1
    ON CONFLICT (device_id) DO UPDATE
        SET guarantee_count = enhance_items.guarantee_count + 1, updated_at = NOW();

    INSERT INTO pvp_seasons (period) VALUES (prev_period) ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;
