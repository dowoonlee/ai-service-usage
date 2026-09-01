-- 길드 시상대에 3위가 영영 안 뜨던 문제 — 표시(시상대)와 보상(RP)의 가드를 분리.
--
-- 배경: 20260707010000의 경쟁 가드 `LEAST(3, qual_count - 1)`가 시상대 동결과 RP 지급에
--   똑같이 걸려 있었다. 자격 길드가 3개면 pay_max_rank = 2 → 3위(=꼴찌)는 시상대에도
--   못 오른다. 길드가 3개뿐인 지금 보드에선 "3위 칸이 영구히 빈 채로 렌더"되어 화면이
--   잘린 것처럼 보였다(2026-08 skax: 성심당·AI혁신팀만 동결, @deprecated 2427VP 누락).
--
-- 가드의 목적은 "무경쟁 무임 지급 방지"이지 명예의 전당에서 지우는 것이 아니다. 그래서:
--   - 시상대 동결(guild_monthly_winners): Top3 전부 → 순위는 있는 그대로 보인다.
--   - RP 지급(rp_rewards): 경쟁 가드 유지 → 꼴찌 무임승차는 그대로 차단.
-- 다른 로직(정산 로그 가드, 자격 판정, 테넌트 파티션)은 20260818000000판 그대로다.

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

    IF EXISTS (SELECT 1 FROM guild_settlement_log WHERE period = prev_period) THEN
        RETURN;
    END IF;

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

    -- 1) 시상대 동결 — Top3 전부(경쟁 가드 없음). 순위 표시는 보상과 무관하다.
    INSERT INTO guild_monthly_winners
        (period, tenant_id, rank, guild_id, name_snapshot, score, member_count,
         leader_nickname_snapshot, leader_profile_json_snapshot)
    SELECT
        prev_period, t.tenant_id, t.rank, g.id, g.name, t.score,
        (SELECT COUNT(*) FROM guild_members m WHERE m.guild_id = g.id),
        lu.nickname,
        CASE WHEN jsonb_typeof(lu.profile_json) = 'object'
             THEN lu.profile_json - 'backup'
             ELSE lu.profile_json
        END
    FROM _guild_prev_ranked t
    JOIN guilds g ON g.id = t.guild_id
    LEFT JOIN users lu ON lu.device_id = g.leader_device_id
    WHERE t.rank <= 3
    ON CONFLICT (tenant_id, period, rank) DO NOTHING;

    -- 2) RP 지급 — 경쟁 가드 유지. 자기 아래 최소 1개 길드가 있어야 지급(꼴찌 무임승차 차단).
    INSERT INTO rp_rewards (period, period_type, tenant_id, device_id, rank, rp_amount)
    SELECT
        prev_period, 'guild-monthly', t.tenant_id, v.device_id, t.rank,
        CASE t.rank WHEN 1 THEN 500 WHEN 2 THEN 300 ELSE 200 END
    FROM _guild_prev_ranked t
    JOIN _guild_prev_vp v ON v.guild_id = t.guild_id
    WHERE t.rank <= LEAST(3, t.qual_count - 1) AND v.monthly_vp > 0
    ON CONFLICT (period_type, period, device_id) DO NOTHING;

    INSERT INTO guild_settlement_log (period) VALUES (prev_period)
    ON CONFLICT (period) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION finalize_monthly_guild_rp_if_needed() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION finalize_monthly_guild_rp_if_needed() TO service_role;

-- ===========================================================================
-- 백필 — 이미 정산이 끝난 달에서 가드에 잘린 순위를 채운다 (시상대 표시 전용).
-- ===========================================================================
-- 정산 로그 가드 때문에 지난 달은 함수가 다시 돌지 않으므로 여기서 한 번 채운다.
-- rp_rewards는 건드리지 않는다 — 당시 가드대로 지급이 끝난 건이고, 표시만 복원한다.
-- 재계산은 '현재' 멤버십/프로필 기준이라 과거 스냅샷과 다를 수 있으므로
--   (a) 이미 동결된 (tenant, period, rank)는 ON CONFLICT로 보존하고
--   (b) 그 달에 이미 등재된 길드는 다른 등수로 중복 등장하지 않게 제외한다.
WITH periods AS (
    SELECT DISTINCT
        period,
        (to_date(period || '-01', 'YYYY-MM-DD')::TIMESTAMP) AT TIME ZONE 'Asia/Seoul' AS m_start,
        (to_date(period || '-01', 'YYYY-MM-DD')::TIMESTAMP + INTERVAL '1 month') AT TIME ZONE 'Asia/Seoul' AS m_end
    FROM guild_monthly_winners
),
vp AS (
    SELECT p.period, gm.guild_id, gm.device_id,
           COALESCE(SUM(s.accepted_coins), 0)::BIGINT AS monthly_vp
    FROM periods p
    CROSS JOIN guild_members gm
    JOIN users u ON u.device_id = gm.device_id AND u.status = 'active'
    LEFT JOIN submissions s ON s.device_id = gm.device_id
        AND s.accepted = TRUE
        AND s.submitted_at >= p.m_start
        AND s.submitted_at <  p.m_end
    GROUP BY p.period, gm.guild_id, gm.device_id
),
ranked AS (
    SELECT period, guild_id, tenant_id, score, rank FROM (
        SELECT
            v.period,
            v.guild_id,
            g.tenant_id,
            SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5)::BIGINT AS score,
            ROW_NUMBER() OVER (
                PARTITION BY v.period, g.tenant_id
                ORDER BY SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5) DESC, MIN(g.created_at) ASC
            ) AS rank
        FROM (
            SELECT period, guild_id, device_id, monthly_vp,
                   ROW_NUMBER() OVER (PARTITION BY period, guild_id ORDER BY monthly_vp DESC, device_id ASC) AS rn
            FROM vp
        ) v
        JOIN guilds g ON g.id = v.guild_id
        GROUP BY v.period, v.guild_id, g.tenant_id
        HAVING SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5) > 0
    ) r
)
INSERT INTO guild_monthly_winners
    (period, tenant_id, rank, guild_id, name_snapshot, score, member_count,
     leader_nickname_snapshot, leader_profile_json_snapshot)
SELECT
    r.period, r.tenant_id, r.rank, g.id, g.name, r.score,
    (SELECT COUNT(*) FROM guild_members m WHERE m.guild_id = g.id),
    lu.nickname,
    CASE WHEN jsonb_typeof(lu.profile_json) = 'object'
         THEN lu.profile_json - 'backup'
         ELSE lu.profile_json
    END
FROM ranked r
JOIN guilds g ON g.id = r.guild_id
LEFT JOIN users lu ON lu.device_id = g.leader_device_id
WHERE r.rank <= 3
  AND NOT EXISTS (
      SELECT 1 FROM guild_monthly_winners w
       WHERE w.tenant_id = r.tenant_id AND w.period = r.period AND w.guild_id = g.id
  )
ON CONFLICT (tenant_id, period, rank) DO NOTHING;
