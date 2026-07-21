-- 아레나 시즌 소프트 리셋 — 정산 직후 레이팅을 1000 기준으로 편차 절반 압축.
--
-- 문제: pvp_ratings.rating 이 리셋 없이 평생 누적 → 실질적으로 "누적 판수/출석일 = 레이팅"이 되어
-- 월간 백분위 보상이 시즌 성과가 아니라 초기 선점자 고착으로 변질된다. 일일 제한(10판)은 상승
-- 속도만 늦출 뿐 상한을 만들지 못한다(느려진 만큼 후발주자 추격만 더 어려워짐).
-- 소프트 리셋으로 스펙 우위는 다음 시즌 다시 입증하되, 누적 판수 프리미엄은 매달 상각한다.
--
-- 20260722 의 finalize_previous_month_pvp_if_needed 를 CREATE OR REPLACE — 함수 말미에 리셋 추가.
-- 리셋은 RP·챔피언 grant(직전 시즌 레이팅 기준) 계산 이후에 실행해야 순위가 보존된다.
-- 멱등 마커(pvp_seasons) 가드 내부라 시즌당 정확히 1회. pvp_teams.rating(매칭·랭킹 캐시 미러)도 동기화.

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

    -- 시즌 소프트 리셋: rating' = 1000 + (rating - 1000)/2 (정수 반올림, 하한 0).
    -- 편차를 1000 기준으로 절반 압축 → 무한 상승·초기 선점 고착 방지. 반드시 위 grant 산정 이후.
    UPDATE pvp_ratings
        SET rating = GREATEST(0, ROUND(1000 + (rating - 1000) / 2.0)::int);
    -- 매칭 후보·랭킹에 쓰이는 캐시 미러 동기화 (진실은 pvp_ratings).
    UPDATE pvp_teams t SET rating = r.rating FROM pvp_ratings r WHERE r.device_id = t.device_id;

    INSERT INTO pvp_seasons (period) VALUES (prev_period) ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;
