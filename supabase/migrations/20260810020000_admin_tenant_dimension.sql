-- 운영 대시보드 테넌트 차원 — 모든 집계 뷰를 테넌트 단위로 쪼갠다.
--
-- 배경: 지표가 전 테넌트 합계라 "SKAX는 잘 쓰는데 외부는 안 쓴다" 같은 판단이 불가능했다.
--       사용량·진척·abuse 전부 테넌트를 나눠 봐야 의미가 생긴다.
--
-- 설계: 뷰는 테넌트별 행만 낸다. "전체"는 대시보드가 합산한다 — 모든 지표가 카운트/합계라
--       합산이 정확하고(한 유저는 한 테넌트에만 속한다), 뷰에 ALL 행을 UNION하면 클라가
--       매번 그 행을 걸러내야 해서 오히려 번거롭다. 단, 비율(accept_ratio·cleared_pct)은
--       합산할 수 없으므로 원시 분자·분모를 함께 내려 클라가 재계산한다.
--
-- 테넌트 컬럼이 있는 테이블(board_posts·guilds·pvp_matches)은 그대로 쓰고, device 단위
-- 테이블(submissions·abuse_flags·reward_grants·rp_rewards)은 users를 조인해 귀속시킨다.
--
-- ⚠ 전 뷰 DROP+CREATE — security_invoker와 REVOKE를 반드시 함께 복원한다(20260716000000).

-- ===========================================================================
-- admin_tenants — 대시보드 테넌트 셀렉터용 목록.
-- ===========================================================================
CREATE VIEW admin_tenants AS
SELECT
    t.slug,
    t.display_name,
    t.is_default,
    COUNT(u.device_id)                                                        AS users,
    COUNT(u.device_id) FILTER (WHERE u.last_submitted_at >= NOW() - INTERVAL '7 days') AS active_7d
FROM tenants t
LEFT JOIN users u ON u.tenant_id = t.slug
GROUP BY t.slug, t.display_name, t.is_default;

-- ===========================================================================
-- admin_overview — 테넌트별 KPI 1행. 대시보드가 "전체" 선택 시 합산한다.
-- ===========================================================================
DROP VIEW IF EXISTS admin_overview;

CREATE VIEW admin_overview AS
WITH base AS (
    SELECT slug AS tenant_id FROM tenants
),
u AS (
    SELECT
        tenant_id,
        COUNT(*)                                                          AS users_total,
        COUNT(*) FILTER (WHERE status = 'active')                         AS users_active,
        COUNT(*) FILTER (WHERE status = 'banned')                         AS users_banned,
        COUNT(*) FILTER (WHERE status = 'shadow_banned')                  AS users_shadow_banned,
        COUNT(*) FILTER (WHERE last_submitted_at >= NOW() - INTERVAL '24 hours') AS active_24h,
        COUNT(*) FILTER (WHERE last_submitted_at >= NOW() - INTERVAL '7 days')   AS active_7d,
        COUNT(*) FILTER (WHERE last_submitted_at >= NOW() - INTERVAL '30 days')  AS active_30d,
        COUNT(*) FILTER (WHERE registered_at >= NOW() - INTERVAL '7 days')       AS new_7d,
        COUNT(*) FILTER (WHERE registered_at >= NOW() - INTERVAL '30 days')      AS new_30d,
        COUNT(*) FILTER (WHERE (profile_json->>'integrityViolation')::BOOLEAN IS TRUE)
                                                                          AS integrity_violations
    FROM users GROUP BY tenant_id
),
subs AS (
    SELECT
        us.tenant_id,
        COUNT(*)                                                          AS submissions_today,
        COALESCE(SUM(s.accepted_coins) FILTER (WHERE s.accepted), 0)      AS coins_today
    FROM submissions s
    JOIN users us ON us.device_id = s.device_id
    WHERE (s.submitted_at AT TIME ZONE 'Asia/Seoul')::DATE
          = (NOW() AT TIME ZONE 'Asia/Seoul')::DATE
    GROUP BY 1
),
flags AS (
    SELECT
        us.tenant_id,
        COUNT(*) FILTER (WHERE f.reviewed_at IS NULL)                     AS flags_unreviewed,
        COUNT(*) FILTER (WHERE f.reviewed_at IS NULL
                           AND f.flagged_at >= NOW() - INTERVAL '7 days') AS flags_unreviewed_7d
    FROM abuse_flags f
    JOIN users us ON us.device_id = f.device_id
    GROUP BY 1
),
grants AS (
    SELECT us.tenant_id, COUNT(*) AS grants_pending
    FROM reward_grants g
    JOIN users us ON us.device_id = g.device_id
    WHERE g.claimed_at IS NULL
    GROUP BY 1
),
rp AS (
    -- rp_rewards에도 tenant_id가 있지만 users 귀속으로 통일한다 — device 삭제 시 남는
    -- 고아 행(device_id NULL)이 조인에서 자연히 빠져 "받을 사람이 있는" 건만 세어진다.
    SELECT us.tenant_id, COUNT(*) AS rp_rewards_pending
    FROM rp_rewards r
    JOIN users us ON us.device_id = r.device_id
    WHERE r.claimed_at IS NULL
    GROUP BY 1
),
g AS (
    SELECT tenant_id, COUNT(*) AS guilds_total FROM guilds GROUP BY 1
),
posts AS (
    SELECT tenant_id, COUNT(*) AS posts_7d FROM board_posts
    WHERE created_at >= NOW() - INTERVAL '7 days' GROUP BY 1
),
pvp AS (
    SELECT tenant_id, COUNT(*) AS pvp_matches_7d FROM pvp_matches
    WHERE created_at >= NOW() - INTERVAL '7 days' GROUP BY 1
)
SELECT
    base.tenant_id,
    COALESCE(u.users_total, 0)          AS users_total,
    COALESCE(u.users_active, 0)         AS users_active,
    COALESCE(u.users_banned, 0)         AS users_banned,
    COALESCE(u.users_shadow_banned, 0)  AS users_shadow_banned,
    COALESCE(u.active_24h, 0)           AS active_24h,
    COALESCE(u.active_7d, 0)            AS active_7d,
    COALESCE(u.active_30d, 0)           AS active_30d,
    COALESCE(u.new_7d, 0)               AS new_7d,
    COALESCE(u.new_30d, 0)              AS new_30d,
    COALESCE(subs.submissions_today, 0) AS submissions_today,
    COALESCE(subs.coins_today, 0)       AS coins_today,
    COALESCE(flags.flags_unreviewed, 0) AS flags_unreviewed,
    COALESCE(flags.flags_unreviewed_7d, 0) AS flags_unreviewed_7d,
    COALESCE(u.integrity_violations, 0) AS integrity_violations,
    COALESCE(grants.grants_pending, 0)  AS grants_pending,
    COALESCE(rp.rp_rewards_pending, 0)  AS rp_rewards_pending,
    COALESCE(g.guilds_total, 0)         AS guilds_total,
    COALESCE(posts.posts_7d, 0)         AS posts_7d,
    COALESCE(pvp.pvp_matches_7d, 0)     AS pvp_matches_7d
FROM base
LEFT JOIN u      ON u.tenant_id = base.tenant_id
LEFT JOIN subs   ON subs.tenant_id = base.tenant_id
LEFT JOIN flags  ON flags.tenant_id = base.tenant_id
LEFT JOIN grants ON grants.tenant_id = base.tenant_id
LEFT JOIN rp     ON rp.tenant_id = base.tenant_id
LEFT JOIN g      ON g.tenant_id = base.tenant_id
LEFT JOIN posts  ON posts.tenant_id = base.tenant_id
LEFT JOIN pvp    ON pvp.tenant_id = base.tenant_id;

-- ===========================================================================
-- admin_daily_activity — (일자, 테넌트) 단위.
-- ===========================================================================
DROP VIEW IF EXISTS admin_daily_activity;

CREATE VIEW admin_daily_activity AS
SELECT
    (s.submitted_at AT TIME ZONE 'Asia/Seoul')::DATE            AS day_kst,
    us.tenant_id,
    COUNT(DISTINCT s.device_id)                                 AS active_devices,
    COUNT(*)                                                    AS submissions,
    COUNT(*) FILTER (WHERE s.accepted)                          AS accepted,
    COUNT(*) FILTER (WHERE NOT s.accepted)                      AS rejected,
    COUNT(*) FILTER (WHERE s.cap_applied)                       AS capped,
    COALESCE(SUM(s.accepted_coins), 0)::BIGINT                  AS accepted_coins,
    COALESCE(SUM(s.delta_coins), 0)::BIGINT                     AS reported_coins,
    -- 비율은 합산할 수 없다 — 테넌트를 합칠 때 클라가 accepted/reported로 다시 낸다.
    ROUND(
        COALESCE(SUM(s.accepted_coins), 0)::NUMERIC
        / NULLIF(SUM(s.delta_coins), 0)::NUMERIC, 3
    )                                                           AS accept_ratio
FROM submissions s
JOIN users us ON us.device_id = s.device_id
WHERE s.submitted_at >= NOW() - INTERVAL '90 days'
GROUP BY 1, 2;

-- ===========================================================================
-- admin_version_spread — (버전, 테넌트) 단위.
-- ===========================================================================
DROP VIEW IF EXISTS admin_version_spread;

CREATE VIEW admin_version_spread AS
SELECT
    COALESCE(u.app_version, '(unknown)')                                AS app_version,
    u.tenant_id,
    COUNT(*)                                                            AS users,
    COUNT(*) FILTER (WHERE u.last_submitted_at >= NOW() - INTERVAL '7 days')  AS active_7d,
    COUNT(*) FILTER (WHERE u.last_submitted_at >= NOW() - INTERVAL '30 days') AS active_30d,
    MAX(u.last_submitted_at)                                            AS last_seen,
    COUNT(DISTINCT u.os_version)                                        AS os_variants
FROM users u
WHERE u.status <> 'banned'
GROUP BY 1, 2;

-- ===========================================================================
-- admin_pet_popularity — (펫, 테넌트) 단위.
-- ===========================================================================
DROP VIEW IF EXISTS admin_pet_popularity;

CREATE VIEW admin_pet_popularity AS
SELECT
    p.key                                                               AS pet_kind,
    u.tenant_id,
    COUNT(*)                                                            AS owners,
    SUM(COALESCE(NULLIF(p.value->>'count', '')::INT, 0))::BIGINT        AS acquisitions_total,
    COUNT(*) FILTER (WHERE p.value->'unlockedVariants' @> '[4]'::JSONB) AS prestige_owners,
    ROUND(AVG(CASE WHEN jsonb_typeof(p.value->'unlockedVariants') = 'array'
                   THEN jsonb_array_length(p.value->'unlockedVariants') ELSE 0 END), 2)
                                                                        AS avg_variants,
    COUNT(*) FILTER (WHERE u.profile_json #>> '{backup,petClaudeKind}' = p.key)  AS equipped_claude,
    COUNT(*) FILTER (WHERE u.profile_json #>> '{backup,petCursorKind}' = p.key)  AS equipped_cursor
FROM users u
CROSS JOIN LATERAL jsonb_each(admin_owned_pets(u.profile_json)) p
WHERE u.status = 'active'
GROUP BY 1, 2;

-- ===========================================================================
-- admin_badge_progress — (관장, 테넌트) 단위.
-- ===========================================================================
DROP VIEW IF EXISTS admin_badge_progress;

CREATE VIEW admin_badge_progress AS
SELECT
    b                                   AS badge_key,
    split_part(b, '.', 1)               AS category,
    split_part(b, '.', 2)               AS tier,
    u.tenant_id,
    COUNT(*)                            AS cleared_by,
    -- 분모는 같은 테넌트의 활성 유저. 테넌트를 합칠 때는 이 값이 아니라 cleared_by 합을
    -- 활성 유저 합으로 나눠야 한다(클라가 그렇게 한다).
    ROUND(
        COUNT(*)::NUMERIC / NULLIF(
            (SELECT COUNT(*) FROM users u2
             WHERE u2.status = 'active' AND u2.tenant_id = u.tenant_id), 0) * 100, 1
    )                                   AS cleared_pct
FROM users u
CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(u.profile_json -> 'clearedBadges') = 'array'
         THEN u.profile_json -> 'clearedBadges' ELSE '[]'::JSONB END) b
WHERE u.status = 'active'
GROUP BY 1, 2, 3, 4;

-- ===========================================================================
-- 보안 복원.
-- ===========================================================================
ALTER VIEW admin_tenants         SET (security_invoker = true);
ALTER VIEW admin_overview        SET (security_invoker = true);
ALTER VIEW admin_daily_activity  SET (security_invoker = true);
ALTER VIEW admin_version_spread  SET (security_invoker = true);
ALTER VIEW admin_pet_popularity  SET (security_invoker = true);
ALTER VIEW admin_badge_progress  SET (security_invoker = true);

REVOKE ALL ON admin_tenants, admin_overview, admin_daily_activity,
              admin_version_spread, admin_pet_popularity, admin_badge_progress
    FROM anon, authenticated;

GRANT SELECT ON admin_tenants, admin_overview, admin_daily_activity,
                admin_version_spread, admin_pet_popularity, admin_badge_progress
    TO service_role;
