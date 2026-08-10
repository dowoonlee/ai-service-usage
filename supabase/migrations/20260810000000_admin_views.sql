-- 운영 대시보드용 admin_* 뷰 — 사용량 / 유저별 해금 진척 / abuse 트리아지.
--
-- 배경: 지금까지 운영 조회는 매번 즉석 SQL이었다. 쿼리 로직(특히 profile_json JSONB 파싱)이
--       어디에도 남지 않아 재현이 안 되고, 매번 손으로 다시 쓴다. 집계 로직을 뷰로 고정해
--       repo에서 버전관리하고, 로컬 대시보드(admin/)와 Studio가 같은 정의를 공유하게 한다.
--
-- 보안 — 20260716000000_security_invoker_views.sql 의 결론을 그대로 적용한다:
--   * 전 뷰 security_invoker = true. 뷰는 기본적으로 소유자(postgres) 권한으로 실행되어
--     하부 테이블 RLS를 우회하므로, 이 설정 없이는 anon 키만으로 전 사용자 진척/백업이 샌다.
--   * anon/authenticated 로부터 SELECT 회수 (심층 방어). service_role만 읽는다.
--   * 이 뷰들을 DROP+CREATE로 재정의하는 마이그레이션은 security_invoker + REVOKE를
--     반드시 함께 복원할 것 — reloption과 권한은 재정의 시 초기화된다.
--
-- profile_json 스키마 노트 (Swift `ProfileState`가 기본 JSONEncoder로 직렬화 → 키는 camelCase):
--   stats.{totalSeconds,coinsTotalEarned,totalPulls,badgesCleared,badgesTotal,
--          collectionsComplete,collectionsTotal}
--   backup.ownedPets = { "<PetKind rawValue>": { count, unlockedVariants:[Int] } }
--   backup.{coins,gachaTickets,premiumTickets,petUsageSeconds,ownedTitles,...}
--   integrityViolation (Bool?) — 클라 자가 무결성 탐지 결과.
-- 클라가 보낸 blob을 서버가 그대로 저장하는 opaque 필드라 스키마 보증이 없다. 모든 파싱은
-- 방어적으로 — 키 부재/타입 불일치에도 뷰가 죽지 않게 jsonb_typeof 가드 + NULLIF를 쓴다.

-- ===========================================================================
-- 공통 헬퍼 — ownedPets 집계
-- ===========================================================================
-- jsonb_each는 인자가 object가 아니면 에러라 타입 가드 필수. 옛 클라(backup 미전송)나
-- 손상된 blob에서도 0행으로 흡수되어야 LEFT JOIN LATERAL이 NULL로 떨어진다.
CREATE OR REPLACE FUNCTION admin_owned_pets(p_profile JSONB)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
    SELECT CASE
        WHEN jsonb_typeof(p_profile #> '{backup,ownedPets}') = 'object'
            THEN p_profile #> '{backup,ownedPets}'
        ELSE '{}'::JSONB
    END;
$$;

-- ===========================================================================
-- admin_overview — 단일 행 KPI. 대시보드 상단 타일.
-- ===========================================================================
CREATE VIEW admin_overview AS
SELECT
    (SELECT COUNT(*) FROM users)                                            AS users_total,
    (SELECT COUNT(*) FROM users WHERE status = 'active')                    AS users_active,
    (SELECT COUNT(*) FROM users WHERE status = 'banned')                    AS users_banned,
    (SELECT COUNT(*) FROM users WHERE status = 'shadow_banned')             AS users_shadow_banned,
    -- 활성도는 last_submitted_at 기준 (submissions 스캔보다 싸고, 폴링이 곧 활성 신호).
    (SELECT COUNT(*) FROM users WHERE last_submitted_at >= NOW() - INTERVAL '24 hours')  AS active_24h,
    (SELECT COUNT(*) FROM users WHERE last_submitted_at >= NOW() - INTERVAL '7 days')    AS active_7d,
    (SELECT COUNT(*) FROM users WHERE last_submitted_at >= NOW() - INTERVAL '30 days')   AS active_30d,
    -- 신규 유입.
    (SELECT COUNT(*) FROM users WHERE registered_at >= NOW() - INTERVAL '7 days')        AS new_7d,
    (SELECT COUNT(*) FROM users WHERE registered_at >= NOW() - INTERVAL '30 days')       AS new_30d,
    -- 오늘(KST) 제출.
    (SELECT COUNT(*) FROM submissions
       WHERE (submitted_at AT TIME ZONE 'Asia/Seoul')::DATE
             = (NOW() AT TIME ZONE 'Asia/Seoul')::DATE)                     AS submissions_today,
    (SELECT COALESCE(SUM(accepted_coins), 0) FROM submissions
       WHERE accepted AND (submitted_at AT TIME ZONE 'Asia/Seoul')::DATE
             = (NOW() AT TIME ZONE 'Asia/Seoul')::DATE)                     AS coins_today,
    -- 트리아지 큐.
    (SELECT COUNT(*) FROM abuse_flags WHERE reviewed_at IS NULL)            AS flags_unreviewed,
    (SELECT COUNT(*) FROM abuse_flags
       WHERE reviewed_at IS NULL AND flagged_at >= NOW() - INTERVAL '7 days') AS flags_unreviewed_7d,
    (SELECT COUNT(*) FROM users
       WHERE (profile_json->>'integrityViolation')::BOOLEAN IS TRUE)        AS integrity_violations,
    -- 미수령 보상 (지급했는데 클라가 아직 못 받아간 건 = 배포/폴링 문제 신호).
    (SELECT COUNT(*) FROM reward_grants WHERE claimed_at IS NULL)           AS grants_pending,
    (SELECT COUNT(*) FROM rp_rewards WHERE claimed_at IS NULL)              AS rp_rewards_pending,
    -- 소셜 활동.
    (SELECT COUNT(*) FROM guilds)                                           AS guilds_total,
    (SELECT COUNT(*) FROM board_posts WHERE created_at >= NOW() - INTERVAL '7 days') AS posts_7d,
    (SELECT COUNT(*) FROM pvp_matches WHERE created_at >= NOW() - INTERVAL '7 days') AS pvp_matches_7d;

-- ===========================================================================
-- admin_user_progress — device별 해금 진척 + 경제 상태 1행.
-- ===========================================================================
-- profile_json의 stats는 클라가 계산해 보낸 값(자가 신고)이고, total_coins/submissions는
-- 서버 권위 값이다. 둘이 크게 어긋나면 조작 신호 — 그 비교를 위해 양쪽을 나란히 둔다.
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
    -- 서버 권위 값.
    u.total_coins                                                       AS server_total_coins,
    -- 클라 자가 신고 진척 (profile_json.stats).
    NULLIF(u.profile_json #>> '{stats,totalSeconds}', '')::BIGINT        AS play_seconds,
    NULLIF(u.profile_json #>> '{stats,totalPulls}', '')::INT             AS total_pulls,
    NULLIF(u.profile_json #>> '{stats,badgesCleared}', '')::INT          AS badges_cleared,
    NULLIF(u.profile_json #>> '{stats,badgesTotal}', '')::INT            AS badges_total,
    NULLIF(u.profile_json #>> '{stats,collectionsComplete}', '')::INT    AS collections_complete,
    NULLIF(u.profile_json #>> '{stats,collectionsTotal}', '')::INT       AS collections_total,
    NULLIF(u.profile_json #>> '{stats,coinsTotalEarned}', '')::BIGINT    AS client_coins_earned,
    -- 경제 잔액 (backup).
    NULLIF(u.profile_json #>> '{backup,coins}', '')::BIGINT              AS coin_balance,
    NULLIF(u.profile_json #>> '{backup,gachaTickets}', '')::INT          AS gacha_tickets,
    NULLIF(u.profile_json #>> '{backup,premiumTickets}', '')::INT        AS premium_tickets,
    -- 펫 인벤토리 집계.
    COALESCE(pets.pets_owned, 0)                                        AS pets_owned,
    COALESCE(pets.variants_unlocked, 0)                                 AS variants_unlocked,
    COALESCE(pets.prestige_pets, 0)                                     AS prestige_pets,
    COALESCE(pets.dupes_total, 0)                                       AS pulls_accounted,
    -- 칭호 / 컬렉션 인벤토리 크기.
    CASE WHEN jsonb_typeof(u.profile_json #> '{backup,ownedTitles}') = 'array'
         THEN jsonb_array_length(u.profile_json #> '{backup,ownedTitles}') END AS titles_owned,
    CASE WHEN jsonb_typeof(u.profile_json -> 'clearedBadges') = 'array'
         THEN jsonb_array_length(u.profile_json -> 'clearedBadges') END       AS badges_in_profile,
    -- 무결성 / 소속.
    (u.profile_json->>'integrityViolation')::BOOLEAN                    AS integrity_violation,
    NULLIF(u.profile_json->>'guildName', '')                            AS guild_name,
    -- 서버측 제출 요약 (권위 값 — 자가 신고와 대조용).
    COALESCE(subs.submissions_total, 0)                                 AS submissions_total,
    COALESCE(subs.submissions_rejected, 0)                              AS submissions_rejected,
    COALESCE(subs.submissions_capped, 0)                                AS submissions_capped,
    COALESCE(flags.flag_count, 0)                                       AS flag_count,
    COALESCE(flags.flag_unreviewed, 0)                                  AS flag_unreviewed
FROM users u
LEFT JOIN LATERAL (
    SELECT
        COUNT(*)                                                            AS pets_owned,
        -- unlockedVariants가 배열이 아닌 이상 데이터는 0으로 흡수.
        SUM(CASE WHEN jsonb_typeof(p.value->'unlockedVariants') = 'array'
                 THEN jsonb_array_length(p.value->'unlockedVariants') ELSE 0 END)::BIGINT
                                                                            AS variants_unlocked,
        -- prestigeVariant = 4 (PetOwnership.prestigeVariant) — 레인보우 해금 보유 수.
        COUNT(*) FILTER (WHERE p.value->'unlockedVariants' @> '[4]'::JSONB)  AS prestige_pets,
        -- 펫별 누적 획득 횟수 합 = 실제 가챠로 얻은 총량 (stats.totalPulls와 대조).
        SUM(COALESCE(NULLIF(p.value->>'count', '')::INT, 0))::BIGINT         AS dupes_total
    FROM jsonb_each(admin_owned_pets(u.profile_json)) p
) pets ON TRUE
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
-- admin_daily_activity — 일자별(KST) 사용량 시계열. 최근 90일.
-- ===========================================================================
-- 제출이 0건인 날은 행이 없다(sparse). 대시보드가 날짜 축을 채우는 쪽이 뷰에서
-- generate_series로 조인하는 것보다 단순해서 의도적으로 sparse하게 둔다.
CREATE VIEW admin_daily_activity AS
SELECT
    (s.submitted_at AT TIME ZONE 'Asia/Seoul')::DATE            AS day_kst,
    COUNT(DISTINCT s.device_id)                                 AS active_devices,
    COUNT(*)                                                    AS submissions,
    COUNT(*) FILTER (WHERE s.accepted)                          AS accepted,
    COUNT(*) FILTER (WHERE NOT s.accepted)                      AS rejected,
    COUNT(*) FILTER (WHERE s.cap_applied)                       AS capped,
    COALESCE(SUM(s.accepted_coins), 0)::BIGINT                  AS accepted_coins,
    COALESCE(SUM(s.delta_coins), 0)::BIGINT                     AS reported_coins,
    -- 신고량 대비 반영량 — 캡이 얼마나 물리는지. 1.0에서 멀어질수록 캡/거부가 많다는 뜻.
    ROUND(
        COALESCE(SUM(s.accepted_coins), 0)::NUMERIC
        / NULLIF(SUM(s.delta_coins), 0)::NUMERIC, 3
    )                                                           AS accept_ratio
FROM submissions s
WHERE s.submitted_at >= NOW() - INTERVAL '90 days'
GROUP BY 1;

-- ===========================================================================
-- admin_abuse_queue — 플래그 + 판단에 필요한 컨텍스트를 한 행에.
-- ===========================================================================
-- abuse_flags 단독으로는 판정이 안 된다(reason/details만 있음). 해당 device의 최근 제출
-- 패턴·계정 나이·무결성 플래그를 조인해 "열지 않고도 판단 가능한" 트리아지 행을 만든다.
CREATE VIEW admin_abuse_queue AS
SELECT
    f.id                                                AS flag_id,
    f.device_id,
    u.nickname,
    u.status,
    u.tenant_id,
    u.app_version,
    f.reason,
    f.flagged_at,
    f.details,
    f.reviewed_at,
    f.review_note,
    f.reviewed_at IS NULL                               AS unreviewed,
    u.registered_at,
    -- 계정 나이 — 갓 만든 계정의 대량 적립은 강한 신호.
    ROUND(EXTRACT(EPOCH FROM (f.flagged_at - u.registered_at)) / 86400.0, 1)
                                                        AS account_age_days_at_flag,
    u.total_coins                                       AS server_total_coins,
    (u.profile_json->>'integrityViolation')::BOOLEAN    AS integrity_violation,
    NULLIF(u.profile_json #>> '{stats,totalPulls}', '')::INT AS total_pulls,
    -- 플래그 전후 7일 제출 패턴.
    COALESCE(w.submissions_7d, 0)                       AS submissions_7d,
    COALESCE(w.capped_7d, 0)                            AS capped_7d,
    COALESCE(w.rejected_7d, 0)                          AS rejected_7d,
    COALESCE(w.max_delta_7d, 0)                         AS max_delta_7d,
    COALESCE(w.accepted_coins_7d, 0)                    AS accepted_coins_7d,
    -- 같은 device의 누적 플래그 수 — 반복범인지 1회성인지.
    COALESCE(tot.flag_count, 0)                         AS device_flag_count
FROM abuse_flags f
LEFT JOIN users u ON u.device_id = f.device_id
LEFT JOIN LATERAL (
    SELECT
        COUNT(*)                                        AS submissions_7d,
        COUNT(*) FILTER (WHERE s.cap_applied)           AS capped_7d,
        COUNT(*) FILTER (WHERE NOT s.accepted)          AS rejected_7d,
        MAX(s.delta_coins)                              AS max_delta_7d,
        COALESCE(SUM(s.accepted_coins), 0)::BIGINT      AS accepted_coins_7d
    FROM submissions s
    WHERE s.device_id = f.device_id
      AND s.submitted_at BETWEEN f.flagged_at - INTERVAL '7 days' AND f.flagged_at
) w ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*) AS flag_count FROM abuse_flags f2 WHERE f2.device_id = f.device_id
) tot ON TRUE;

-- ===========================================================================
-- admin_version_spread — app_version 분포. 클라 게이트/강제 업데이트 판단용.
-- ===========================================================================
-- v0.17.11 미만 게이트(#201) 같은 결정은 "구버전이 몇 명 남았나"에 달려 있다.
CREATE VIEW admin_version_spread AS
SELECT
    COALESCE(u.app_version, '(unknown)')                                AS app_version,
    COUNT(*)                                                            AS users,
    COUNT(*) FILTER (WHERE u.last_submitted_at >= NOW() - INTERVAL '7 days')  AS active_7d,
    COUNT(*) FILTER (WHERE u.last_submitted_at >= NOW() - INTERVAL '30 days') AS active_30d,
    MAX(u.last_submitted_at)                                            AS last_seen,
    COUNT(DISTINCT u.os_version)                                        AS os_variants
FROM users u
WHERE u.status <> 'banned'
GROUP BY 1;

-- ===========================================================================
-- admin_pet_popularity — 펫별 보유 분포. 가챠 밸런스/해금 진척 분석용.
-- ===========================================================================
-- rarity는 클라 상수(Gacha.pool)라 서버가 모른다 — 대시보드가 필요하면 클라 정의를
-- 복제해 붙이고, 여기서는 관측값(보유자 수/획득 총량)만 낸다.
CREATE VIEW admin_pet_popularity AS
SELECT
    p.key                                                               AS pet_kind,
    COUNT(*)                                                            AS owners,
    SUM(COALESCE(NULLIF(p.value->>'count', '')::INT, 0))::BIGINT        AS acquisitions_total,
    COUNT(*) FILTER (WHERE p.value->'unlockedVariants' @> '[4]'::JSONB) AS prestige_owners,
    ROUND(AVG(CASE WHEN jsonb_typeof(p.value->'unlockedVariants') = 'array'
                   THEN jsonb_array_length(p.value->'unlockedVariants') ELSE 0 END), 2)
                                                                        AS avg_variants,
    -- 이 펫을 대표 펫으로 장착한 사람 수 (Claude/Cursor 슬롯 합).
    COUNT(*) FILTER (WHERE u.profile_json #>> '{backup,petClaudeKind}' = p.key)  AS equipped_claude,
    COUNT(*) FILTER (WHERE u.profile_json #>> '{backup,petCursorKind}' = p.key)  AS equipped_cursor
FROM users u
CROSS JOIN LATERAL jsonb_each(admin_owned_pets(u.profile_json)) p
WHERE u.status = 'active'
GROUP BY 1;

-- ===========================================================================
-- 보안 마감 — invoker 전환 + anon/authenticated 회수.
-- ===========================================================================
ALTER VIEW admin_overview        SET (security_invoker = true);
ALTER VIEW admin_user_progress   SET (security_invoker = true);
ALTER VIEW admin_daily_activity  SET (security_invoker = true);
ALTER VIEW admin_abuse_queue     SET (security_invoker = true);
ALTER VIEW admin_version_spread  SET (security_invoker = true);
ALTER VIEW admin_pet_popularity  SET (security_invoker = true);

REVOKE ALL ON admin_overview, admin_user_progress, admin_daily_activity,
              admin_abuse_queue, admin_version_spread, admin_pet_popularity
    FROM anon, authenticated;

REVOKE ALL ON FUNCTION admin_owned_pets(JSONB) FROM anon, authenticated;

GRANT SELECT ON admin_overview, admin_user_progress, admin_daily_activity,
                admin_abuse_queue, admin_version_spread, admin_pet_popularity
    TO service_role;
