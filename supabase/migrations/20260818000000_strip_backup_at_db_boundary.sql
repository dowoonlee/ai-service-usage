-- profile_json.backup 을 DB 경계에서 떨군다 — Egress 절감 + 누출 표면 축소.
--
-- 배경 (2026-08-18 실측):
--   무료 플랜 Egress 한도는 5GB/월인데 ~48MB/일을 쓰고 있었고, 그 대부분이 리더보드 조회였다.
--   monthly_leaderboard 한 번 조회 = 보드 22행 × profile_json 평균 9.8KB = 212KB이고,
--   그 중 **91%가 profile_json.backup**(본인 디바이스 복구 전용 페이로드)이다.
--   Edge Function은 이걸 전부 받아온 뒤 stripBackup()으로 버리고 응답에는 싣지 않는다.
--   즉 버릴 데이터를 DB→함수 구간에서 하루 1,316회 실어 나르고 있었다.
--
--   이 비용은 사용자 수에 **제곱으로** 는다 — 조회 횟수 ∝ 활성 사용자 수,
--   조회 1회당 크기 ∝ 보드 사용자 수. 활성 사용자가 2배면 Egress는 4배다.
--   (측정 시점 활성 ~14명 / 보드 22명 기준 월 1.5GB = 한도의 30%.)
--
-- 이 마이그레이션이 하는 일:
--   1) monthly_leaderboard 뷰가 backup 없는 profile_json을 노출
--   2) 시상대 동결(finalize)이 backup을 스냅샷에 저장하지 않게
--   3) 이미 backup을 품고 저장된 스냅샷을 백필
--
-- ⚠️ API 응답은 바이트 단위로 **동일하다**. 어차피 stripBackup()이 떨구던 키를 더 이른
--    단계에서 떨굴 뿐이라 클라이언트가 보는 JSON은 변하지 않는다. 따라서 이 마이그레이션은
--    Edge Function 재배포 없이 단독으로 적용해도 안전하다(구버전 함수와도 호환).
--    Edge Function 쪽 stripBackup() 호출은 심층 방어로 그대로 둔다 — 이제 no-op이지만,
--    profile_json을 응답에 싣는 새 경로가 users 테이블을 직접 읽을 수 있으므로 유지한다.


-- ===========================================================================
-- 1) monthly_leaderboard — 뷰 단계에서 backup 제거
-- ===========================================================================
-- 20260716000000_security_invoker_views.sql 의 경고를 지킨다:
--   "향후 뷰를 DROP+CREATE로 재정의하면 reloption이 초기화되므로,
--    재정의하는 마이그레이션은 반드시 security_invoker + REVOKE를 함께 복원할 것."
-- CREATE OR REPLACE 는 reloption을 보존하지만, 의도를 문서화하고 DROP+CREATE로 바뀌는
-- 실수에 대비해 아래에서 둘 다 재확인한다(멱등).
CREATE OR REPLACE VIEW monthly_leaderboard AS
 WITH period_start AS (
         SELECT (date_trunc('month'::text, (now() AT TIME ZONE 'Asia/Seoul'::text)) AT TIME ZONE 'Asia/Seoul'::text) AS start_at
        ), monthly AS (
         SELECT s.device_id,
            sum(s.accepted_coins) AS monthly_coins
           FROM submissions s,
            period_start
          WHERE s.accepted = true AND s.submitted_at >= period_start.start_at
          GROUP BY s.device_id
        )
 SELECT u.device_id,
    u.tenant_id,
    u.nickname,
    u.github_login,
    -- ★ 유일한 변경점. jsonb_typeof 가드는 Edge Function stripBackup()과 같은 의미다
    --   (객체가 아니면 손대지 않는다). `jsonb - text`는 스칼라에 적용하면
    --   "cannot delete from scalar"로 에러라 가드 없이는 뷰 전체가 깨질 수 있다.
    CASE WHEN jsonb_typeof(u.profile_json) = 'object'
         THEN u.profile_json - 'backup'
         ELSE u.profile_json
    END AS profile_json,
    COALESCE(m.monthly_coins, 0::bigint) AS monthly_coins,
    row_number() OVER (PARTITION BY u.tenant_id ORDER BY (COALESCE(m.monthly_coins, 0::bigint)) DESC, u.registered_at) AS rank
   FROM users u
     LEFT JOIN monthly m ON m.device_id = u.device_id
  WHERE u.status = 'active'::text;

ALTER VIEW monthly_leaderboard SET (security_invoker = true);
REVOKE SELECT ON monthly_leaderboard FROM anon, authenticated;


-- ===========================================================================
-- 2) finalize — 시상대 스냅샷에 backup을 저장하지 않는다
-- ===========================================================================
-- 스냅샷은 매달 3행씩 영구히 쌓이고, 저장된 backup은 읽는 쪽에서 전부 stripBackup()으로
-- 버려진다(_shared/leaderboard_query.ts). 저장할 이유가 없는데 저장하면
--   - 리더보드 조회마다 3행분 backup이 또 DB→함수로 흐르고
--   - 남의 복구 페이로드가 만료 없이 영구 보관된다
-- 두 가지가 같이 생긴다. 본인 복구 경로(recover-by-code / recover-by-github)는
-- users.profile_json 을 직접 읽으므로 이 변경의 영향을 받지 않는다.

-- 아래 두 함수 본문은 배포된 정의(pg_get_functiondef)를 그대로 옮기고 스냅샷 컬럼에
-- 들어가는 표현식 한 줄씩만 바꾼 것이다. 로직 변경은 없다.

CREATE OR REPLACE FUNCTION finalize_previous_month_if_needed() RETURNS VOID
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
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
            -- ★ 변경점 — 스냅샷에는 backup을 담지 않는다.
            CASE WHEN jsonb_typeof(u.profile_json) = 'object'
                 THEN u.profile_json - 'backup'
                 ELSE u.profile_json
            END AS profile_json,
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
$$;

CREATE OR REPLACE FUNCTION finalize_monthly_guild_rp_if_needed() RETURNS VOID
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
    this_month_start TIMESTAMPTZ;
    prev_month_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    this_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month') AT TIME ZONE 'Asia/Seoul';
    prev_period := to_char(date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month', 'YYYY-MM');

    -- 이미 정산됐으면 no-op — 승자/보상 유무와 무관하게 로그로 판정(빈 정산 재실행 방지).
    -- 한 period를 전 테넌트 한 번에 처리하므로 로그는 period 단위로 충분.
    IF EXISTS (SELECT 1 FROM guild_settlement_log WHERE period = prev_period) THEN
        RETURN;
    END IF;

    -- 직전 달 멤버별 VP(현재 멤버 기준).
    CREATE TEMP TABLE _guild_prev_vp ON COMMIT DROP AS
    SELECT
        gm.guild_id,
        gm.device_id,
        COALESCE(SUM(s.accepted_coins), 0)::BIGINT AS monthly_vp
    FROM guild_members gm
    JOIN users u ON u.device_id = gm.device_id AND u.status = 'active'
    LEFT JOIN submissions s ON s.device_id = gm.device_id
        AND s.accepted = TRUE
        AND s.submitted_at >= prev_month_start
        AND s.submitted_at <  this_month_start
    GROUP BY gm.guild_id, gm.device_id;

    -- 자격 길드(상위 5명 합산 VP > 0)를 **테넌트별로** 랭킹 + 테넌트별 자격 길드 수(qual_count).
    -- 윈도우 함수는 HAVING 이후 rows(자격 길드)에 대해 계산되므로 qual_count는 테넌트별 자격 길드 수.
    CREATE TEMP TABLE _guild_prev_ranked ON COMMIT DROP AS
    SELECT guild_id, tenant_id, score, rank, qual_count FROM (
        SELECT
            v.guild_id,
            g.tenant_id,
            SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5)::BIGINT AS score,
            ROW_NUMBER() OVER (
                PARTITION BY g.tenant_id
                ORDER BY SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5) DESC, MIN(g.created_at) ASC
            ) AS rank,
            COUNT(*) OVER (PARTITION BY g.tenant_id) AS qual_count
        FROM (
            SELECT guild_id, device_id, monthly_vp,
                   ROW_NUMBER() OVER (PARTITION BY guild_id ORDER BY monthly_vp DESC, device_id ASC) AS rn
            FROM _guild_prev_vp
        ) v
        JOIN guilds g ON g.id = v.guild_id
        GROUP BY v.guild_id, g.tenant_id
        HAVING SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5) > 0
    ) ranked;

    -- 1) 시상대 동결 — 테넌트별 경쟁 가드(rank ≤ LEAST(3, qual_count-1)), 길드장 스냅샷 포함.
    INSERT INTO guild_monthly_winners
        (period, tenant_id, rank, guild_id, name_snapshot, score, member_count,
         leader_nickname_snapshot, leader_profile_json_snapshot)
    SELECT
        prev_period, t.tenant_id, t.rank, g.id, g.name, t.score,
        (SELECT COUNT(*) FROM guild_members m WHERE m.guild_id = g.id),
        lu.nickname,
        -- ★ 변경점 — 길드장 스냅샷에도 backup을 담지 않는다.
        CASE WHEN jsonb_typeof(lu.profile_json) = 'object'
             THEN lu.profile_json - 'backup'
             ELSE lu.profile_json
        END
    FROM _guild_prev_ranked t
    JOIN guilds g ON g.id = t.guild_id
    LEFT JOIN users lu ON lu.device_id = g.leader_device_id
    WHERE t.rank <= LEAST(3, t.qual_count - 1)
    ON CONFLICT (tenant_id, period, rank) DO NOTHING;

    -- 2) RP 지급 — 경쟁 가드 + 자격 멤버(해당 월 VP > 0). rank = 테넌트 내 길드 순위.
    INSERT INTO rp_rewards (period, period_type, tenant_id, device_id, rank, rp_amount)
    SELECT
        prev_period, 'guild-monthly', t.tenant_id, v.device_id, t.rank,
        CASE t.rank WHEN 1 THEN 500 WHEN 2 THEN 300 ELSE 200 END
    FROM _guild_prev_ranked t
    JOIN _guild_prev_vp v ON v.guild_id = t.guild_id
    WHERE t.rank <= LEAST(3, t.qual_count - 1) AND v.monthly_vp > 0
    ON CONFLICT (period_type, period, device_id) DO NOTHING;

    -- 3) 정산 완료 마킹 — 승자 유무와 무관하게 항상.
    INSERT INTO guild_settlement_log (period) VALUES (prev_period)
    ON CONFLICT (period) DO NOTHING;
END;
$$;


-- ===========================================================================
-- 3) 백필 — 이미 저장된 스냅샷에서 backup 제거
-- ===========================================================================
-- 읽는 쪽이 전부 stripBackup()을 거치므로 이 데이터를 쓰는 곳은 없다(응답 불변).
UPDATE monthly_winners
   SET profile_json_snapshot = profile_json_snapshot - 'backup'
 WHERE jsonb_typeof(profile_json_snapshot) = 'object'
   AND profile_json_snapshot ? 'backup';

UPDATE guild_monthly_winners
   SET leader_profile_json_snapshot = leader_profile_json_snapshot - 'backup'
 WHERE jsonb_typeof(leader_profile_json_snapshot) = 'object'
   AND leader_profile_json_snapshot ? 'backup';
