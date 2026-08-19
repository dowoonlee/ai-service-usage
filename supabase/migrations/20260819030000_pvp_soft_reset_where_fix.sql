-- 아레나 시즌 정산이 2026-08-01 이후 한 번도 성공한 적 없던 버그 수정.
--
-- 20260723000000 이 추가한 소프트 리셋에 WHERE 가 없었다:
--     UPDATE pvp_ratings SET rating = GREATEST(0, ROUND(1000 + (rating-1000)/2.0)::int);
-- Supabase 는 `authenticator` 롤에 session_preload_libraries = 'supautils, safeupdate' 를
-- 걸어 둔다(pg_db_role_setting 실측). Edge Function 의 db.rpc() 는 PostgREST →
-- authenticator → SET ROLE service_role 경로라 이 가드가 그대로 적용되고, WHERE 없는
-- UPDATE 는 SQLSTATE 21000 "UPDATE requires a WHERE clause" 로 무조건 거부된다.
-- plpgsql 함수는 한 트랜잭션이므로 앞서 실행된 reward_grants/enhance_items INSERT 까지
-- 통째로 롤백된다 — reward_grants 에 'pvp-season-%' 가 0건이었던 이유다.
--
-- 6월 정산(2026-07-20 06:18)은 소프트 리셋이 추가되기 전이라 통과했고 참가자도 0명이었다.
-- 즉 이 함수는 **정산 대상이 실제로 생긴 첫 순간부터** 계속 죽고 있었다. pvp_seasons 에
-- 마커가 안 남으니 아레나 진입마다 재시도 → 재실패(24h 로그 10회). 호출부
-- pvp-leaderboard/index.ts:51 이 finErr 를 로그만 남기고 무시해 19일간 무증상이었다.
--
-- 수정: rating = 1000 인 행은 리셋해도 값이 그대로이므로(1000 + 0/2 = 1000) 이를 WHERE 로
-- 세운다. 가드를 통과하면서 대상 집합도 정확히 "값이 바뀌는 행"이 된다.
--
-- ⚠ CREATE OR REPLACE FUNCTION 은 proconfig 를 새 정의로 갈아치우므로 20260819000000 이
--   걸어 둔 SET search_path = public 이 사라진다. 정의에 인라인으로 다시 명시한다.
--   ACL 은 REPLACE 시 보존되지만, 20260819010000 의 회수 상태를 명시적으로 재확인해 둔다.
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
    -- WHERE rating <> 1000 은 safeupdate 가드 통과용이자 실제 변경 대상 집합과 정확히 일치한다.
    UPDATE pvp_ratings
        SET rating = GREATEST(0, ROUND(1000 + (rating - 1000) / 2.0)::int)
      WHERE rating <> 1000;
    -- 매칭 후보·랭킹에 쓰이는 캐시 미러 동기화 (진실은 pvp_ratings).
    UPDATE pvp_teams t SET rating = r.rating FROM pvp_ratings r WHERE r.device_id = t.device_id;

    INSERT INTO pvp_seasons (period) VALUES (prev_period) ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql SET search_path = public;

REVOKE ALL ON FUNCTION finalize_previous_month_pvp_if_needed() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION finalize_previous_month_pvp_if_needed() TO service_role;
