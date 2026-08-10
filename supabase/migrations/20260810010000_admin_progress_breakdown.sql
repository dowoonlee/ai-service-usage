-- 진척도 세분화 — 펫 해금 / 이로치 해금 / 관장 격파를 각각 독립 지표로 분리.
--
-- 배경: admin_user_progress의 `variants_unlocked`는 unlockedVariants 배열 길이의 합이라
--       기본 변종(0)까지 센다. 171종을 보유하면 이로치가 하나도 없어도 171이 나와서
--       "이로치 해금 진척"으로 못 쓴다. 관장(뱃지)도 총계만 있고 tier 분해가 없어
--       "localhost는 다 깼는데 production이 막혔다" 같은 판단이 불가능했다.
--
-- 변종 번호 규약 (PetOwnership):
--   0 = 기본, 1~3 = 이로치(중복 5/15/40회 또는 사용시간 4/8/12일로 해금), 4 = 레인보우(prestige).
--   따라서 이로치 해금 수 = 배열에서 1·2·3만 카운트. 레인보우는 별도 축으로 둔다.
--
-- 뱃지 키 규약 (BadgeRegistry): "category.tier" — tier는 localhost < dev < staging < production.
--   19 카테고리 × 4 tier = 76개가 만점(클라 stats.badgesTotal과 일치).
--
-- ⚠ admin_user_progress를 DROP+CREATE로 재정의하므로 security_invoker와 REVOKE를 반드시
--   함께 복원한다 (20260716000000 주석의 경고 — reloption·권한은 재정의 시 초기화된다).

DROP VIEW IF EXISTS admin_user_progress;

CREATE VIEW admin_user_progress AS
SELECT
    u.device_id,
    u.nickname,
    u.status,
    u.tenant_id,
    u.app_version,
    u.os_version,
    u.registered_at,
    u.last_submitted_at,
    u.github_login IS NOT NULL                                          AS github_linked,
    u.uses_zero_baseline,
    u.total_coins                                                       AS server_total_coins,
    NULLIF(u.profile_json #>> '{stats,totalSeconds}', '')::BIGINT        AS play_seconds,
    NULLIF(u.profile_json #>> '{stats,totalPulls}', '')::INT             AS total_pulls,
    NULLIF(u.profile_json #>> '{stats,badgesCleared}', '')::INT          AS badges_cleared,
    NULLIF(u.profile_json #>> '{stats,badgesTotal}', '')::INT            AS badges_total,
    NULLIF(u.profile_json #>> '{stats,collectionsComplete}', '')::INT    AS collections_complete,
    NULLIF(u.profile_json #>> '{stats,collectionsTotal}', '')::INT       AS collections_total,
    NULLIF(u.profile_json #>> '{stats,coinsTotalEarned}', '')::BIGINT    AS client_coins_earned,
    NULLIF(u.profile_json #>> '{backup,coins}', '')::BIGINT              AS coin_balance,
    NULLIF(u.profile_json #>> '{backup,gachaTickets}', '')::INT          AS gacha_tickets,
    NULLIF(u.profile_json #>> '{backup,premiumTickets}', '')::INT        AS premium_tickets,
    -- 펫 해금.
    COALESCE(pets.pets_owned, 0)                                        AS pets_owned,
    COALESCE(pets.dupes_total, 0)                                       AS pulls_accounted,
    -- 이로치 해금 — variant 1~3만. 기본(0)·레인보우(4) 제외.
    COALESCE(pets.shiny_unlocked, 0)                                    AS shiny_unlocked,
    -- 이로치 만렙(3종 전부 해금)인 펫 수 — 상위 진척 판별용.
    COALESCE(pets.shiny_maxed, 0)                                       AS shiny_maxed,
    COALESCE(pets.prestige_pets, 0)                                     AS prestige_pets,
    -- 하위호환 — 기존 컬럼명 유지(기본 변종 포함 총합).
    COALESCE(pets.variants_unlocked, 0)                                 AS variants_unlocked,
    -- 관장 격파 tier 분해.
    COALESCE(badges.t_localhost, 0)                                     AS badges_localhost,
    COALESCE(badges.t_dev, 0)                                           AS badges_dev,
    COALESCE(badges.t_staging, 0)                                       AS badges_staging,
    COALESCE(badges.t_production, 0)                                    AS badges_production,
    CASE WHEN jsonb_typeof(u.profile_json #> '{backup,masteredRegions}') = 'array'
         THEN jsonb_array_length(u.profile_json #> '{backup,masteredRegions}') END AS regions_mastered,
    CASE WHEN jsonb_typeof(u.profile_json #> '{backup,ownedTitles}') = 'array'
         THEN jsonb_array_length(u.profile_json #> '{backup,ownedTitles}') END     AS titles_owned,
    CASE WHEN jsonb_typeof(u.profile_json -> 'clearedBadges') = 'array'
         THEN jsonb_array_length(u.profile_json -> 'clearedBadges') END            AS badges_in_profile,
    (u.profile_json->>'integrityViolation')::BOOLEAN                    AS integrity_violation,
    NULLIF(u.profile_json->>'guildName', '')                            AS guild_name,
    COALESCE(subs.submissions_total, 0)                                 AS submissions_total,
    COALESCE(subs.submissions_rejected, 0)                              AS submissions_rejected,
    COALESCE(subs.submissions_capped, 0)                                AS submissions_capped,
    COALESCE(flags.flag_count, 0)                                       AS flag_count,
    COALESCE(flags.flag_unreviewed, 0)                                  AS flag_unreviewed
FROM users u
LEFT JOIN LATERAL (
    SELECT
        COUNT(*)                                                            AS pets_owned,
        SUM(CASE WHEN jsonb_typeof(p.value->'unlockedVariants') = 'array'
                 THEN jsonb_array_length(p.value->'unlockedVariants') ELSE 0 END)::BIGINT
                                                                            AS variants_unlocked,
        -- 이로치 = 1·2·3. 배열이 아니거나 값이 이상하면 0으로 흡수.
        SUM(CASE WHEN jsonb_typeof(p.value->'unlockedVariants') = 'array' THEN (
                SELECT COUNT(*) FROM jsonb_array_elements_text(p.value->'unlockedVariants') v
                WHERE v IN ('1', '2', '3')
            ) ELSE 0 END)::BIGINT                                           AS shiny_unlocked,
        COUNT(*) FILTER (
            WHERE p.value->'unlockedVariants' @> '[1,2,3]'::JSONB
        )                                                                   AS shiny_maxed,
        COUNT(*) FILTER (WHERE p.value->'unlockedVariants' @> '[4]'::JSONB)  AS prestige_pets,
        SUM(COALESCE(NULLIF(p.value->>'count', '')::INT, 0))::BIGINT         AS dupes_total
    FROM jsonb_each(admin_owned_pets(u.profile_json)) p
) pets ON TRUE
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) FILTER (WHERE split_part(b, '.', 2) = 'localhost')   AS t_localhost,
        COUNT(*) FILTER (WHERE split_part(b, '.', 2) = 'dev')         AS t_dev,
        COUNT(*) FILTER (WHERE split_part(b, '.', 2) = 'staging')     AS t_staging,
        COUNT(*) FILTER (WHERE split_part(b, '.', 2) = 'production')  AS t_production
    FROM jsonb_array_elements_text(
        CASE WHEN jsonb_typeof(u.profile_json -> 'clearedBadges') = 'array'
             THEN u.profile_json -> 'clearedBadges' ELSE '[]'::JSONB END) b
) badges ON TRUE
LEFT JOIN LATERAL (
    SELECT
        COUNT(*)                                        AS submissions_total,
        COUNT(*) FILTER (WHERE NOT s.accepted)          AS submissions_rejected,
        COUNT(*) FILTER (WHERE s.cap_applied)           AS submissions_capped
    FROM submissions s WHERE s.device_id = u.device_id
) subs ON TRUE
LEFT JOIN LATERAL (
    SELECT
        COUNT(*)                                          AS flag_count,
        COUNT(*) FILTER (WHERE f.reviewed_at IS NULL)     AS flag_unreviewed
    FROM abuse_flags f WHERE f.device_id = u.device_id
) flags ON TRUE;

-- ===========================================================================
-- admin_badge_progress — 관장(뱃지)별 격파 인원. 난이도 곡선 점검용.
-- ===========================================================================
-- "어느 tier에서 사람들이 막히는가"를 본다. 클라가 보낸 clearedBadges 기준이라
-- 한 번도 아무에게도 격파되지 않은 관장은 행 자체가 없다(sparse) — 대시보드가
-- 카테고리×tier 격자를 채우는 쪽이 여기서 generate_series로 만드는 것보다 단순하다.
CREATE VIEW admin_badge_progress AS
SELECT
    b                                   AS badge_key,
    split_part(b, '.', 1)               AS category,
    split_part(b, '.', 2)               AS tier,
    COUNT(*)                            AS cleared_by,
    ROUND(
        COUNT(*)::NUMERIC
        / NULLIF((SELECT COUNT(*) FROM users WHERE status = 'active'), 0) * 100, 1
    )                                   AS cleared_pct
FROM users u
CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(u.profile_json -> 'clearedBadges') = 'array'
         THEN u.profile_json -> 'clearedBadges' ELSE '[]'::JSONB END) b
WHERE u.status = 'active'
GROUP BY 1, 2, 3;

-- ===========================================================================
-- 보안 복원 — DROP+CREATE로 초기화된 reloption·권한을 되돌린다.
-- ===========================================================================
ALTER VIEW admin_user_progress  SET (security_invoker = true);
ALTER VIEW admin_badge_progress SET (security_invoker = true);

REVOKE ALL ON admin_user_progress, admin_badge_progress FROM anon, authenticated;

GRANT SELECT ON admin_user_progress, admin_badge_progress TO service_role;
