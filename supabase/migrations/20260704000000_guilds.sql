-- 길드 시스템 (P1) — docs/plans/guild.md §3.
--
-- 디자인 노트:
--   * guild_members.device_id UNIQUE = 1인 1길드를 DB가 보장.
--   * guilds.leader_device_id는 의도적으로 FK 없음 — users 삭제 시 guild_members CASCADE →
--     아래 AFTER DELETE 트리거가 승계/해체를 처리하므로, FK가 있으면 users 삭제 문장과
--     트리거의 guilds 갱신이 제약 검사 타이밍에 얽힌다. 일관성은 트리거가 책임진다.
--   * 월간 점수 = 멤버별 이번 달 VP 상위 5명 합산 (뷰의 rn <= 5 — 정책 상수는
--     _shared/guild_policy.ts의 TOP_CONTRIBUTORS와 쌍으로 유지할 것).
--   * guild_furniture / floor_theme / wall_theme는 P2b(사무실 꾸미기) 선행 스키마 —
--     P1 함수는 건드리지 않는다.
--   * RLS enable + 정책 없음 → anon 전면 거부, Edge Function(service_role) 경유만.

-- ===========================================================================
-- guilds — 1 row per guild
-- ===========================================================================
CREATE TABLE guilds (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name             TEXT NOT NULL,
    name_normalized  TEXT NOT NULL,              -- LOWER(name), case-insensitive unique
    invite_code      TEXT NOT NULL,              -- 8자 영숫자 (혼동 문자 제외), 길드장이 재발급 가능
    leader_device_id UUID NOT NULL,              -- FK 없음 (헤더 노트 참조)
    floor_theme      SMALLINT NOT NULL DEFAULT 0, -- P2b: 바닥재 (길드장만 변경)
    wall_theme       SMALLINT NOT NULL DEFAULT 0, -- P2b: 벽지
    -- 가구 재배치 (길드장) — 바닥 가구 세트의 포지션 순열. layout[포지션 i] = 가구 세트 id.
    -- 포지션(장소 이름·벽 장식·office_slot 의미)은 고정, 가구만 이동. 검증은 guild-manage.
    office_layout    SMALLINT[] NOT NULL DEFAULT '{0,1,2,3,4,5,6,7,8,9,10,11}',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT guild_name_length CHECK (CHAR_LENGTH(name) BETWEEN 2 AND 24)
);

CREATE UNIQUE INDEX guilds_name_normalized_uniq ON guilds (name_normalized);
CREATE UNIQUE INDEX guilds_invite_code_uniq ON guilds (invite_code);

-- ===========================================================================
-- guild_members — 멤버십 (1인 1길드)
-- ===========================================================================
CREATE TABLE guild_members (
    guild_id    UUID NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
    device_id   UUID NOT NULL UNIQUE REFERENCES users(device_id) ON DELETE CASCADE,
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    office_slot SMALLINT CHECK (office_slot >= 0 AND office_slot <= 11), -- NULL = 미배치
    PRIMARY KEY (guild_id, device_id)
);

-- 사무실 스팟 선착순 점유 — 같은 길드에서 슬롯 중복 불가 (NULL 미배치는 여러 명 허용).
CREATE UNIQUE INDEX guild_members_office_slot_uniq ON guild_members (guild_id, office_slot)
    WHERE office_slot IS NOT NULL;
-- 승계(최고참) 조회.
CREATE INDEX guild_members_guild_joined ON guild_members (guild_id, joined_at ASC);

-- ===========================================================================
-- guild_join_cooldowns — 탈퇴/추방 후 재가입 쿨다운 (7일, guild_policy.ts SSOT)
-- ===========================================================================
CREATE TABLE guild_join_cooldowns (
    device_id UUID PRIMARY KEY REFERENCES users(device_id) ON DELETE CASCADE,
    until     TIMESTAMPTZ NOT NULL
);

-- ===========================================================================
-- guild_create_attempts — 길드 생성 IP rate-limit (register_attempts 패턴)
-- ===========================================================================
CREATE TABLE guild_create_attempts (
    id           BIGSERIAL PRIMARY KEY,
    ip           TEXT NOT NULL,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX guild_create_attempts_ip_time ON guild_create_attempts (ip, attempted_at DESC);

-- ===========================================================================
-- guild_furniture — P2b 데코 기부 (P1에서는 테이블만 준비)
-- ===========================================================================
CREATE TABLE guild_furniture (
    guild_id     UUID NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
    slot_id      SMALLINT NOT NULL CHECK (slot_id >= 0 AND slot_id <= 9), -- 벽 0~4, 바닥 5~9
    item_kind    TEXT NOT NULL,               -- 클라이언트 카탈로그 식별자
    purchased_by UUID REFERENCES users(device_id) ON DELETE SET NULL, -- 기부자 명판 (탈퇴해도 가구는 유지)
    purchased_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (guild_id, slot_id)           -- 슬롯당 1개, 교체 = UPSERT
);

-- ===========================================================================
-- 길드장 승계/빈 길드 해체 트리거
--   guild-leave / guild-manage(kick) / 계정 삭제 CASCADE 어느 경로든 멤버 row 삭제 시
--   자동으로 일관성 유지: 리더 이탈 → 최고참 승계, 마지막 멤버 이탈 → 길드 삭제.
--   disband(guilds 삭제)의 CASCADE로 재진입해도 guilds row가 이미 없어 no-op.
-- ===========================================================================
CREATE FUNCTION guild_member_exit_fixup() RETURNS TRIGGER AS $$
DECLARE
    next_leader UUID;
BEGIN
    IF EXISTS (
        SELECT 1 FROM guilds g
        WHERE g.id = OLD.guild_id AND g.leader_device_id = OLD.device_id
    ) THEN
        SELECT gm.device_id INTO next_leader
        FROM guild_members gm
        WHERE gm.guild_id = OLD.guild_id
        ORDER BY gm.joined_at ASC
        LIMIT 1;
        IF next_leader IS NULL THEN
            DELETE FROM guilds WHERE id = OLD.guild_id;
        ELSE
            UPDATE guilds SET leader_device_id = next_leader WHERE id = OLD.guild_id;
        END IF;
    ELSIF NOT EXISTS (SELECT 1 FROM guild_members WHERE guild_id = OLD.guild_id) THEN
        -- 방어적 정리 — 정상 경로에서는 리더가 항상 멤버라 도달하지 않음.
        DELETE FROM guilds WHERE id = OLD.guild_id;
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER guild_member_exit_fixup_trigger
    AFTER DELETE ON guild_members
    FOR EACH ROW EXECUTE FUNCTION guild_member_exit_fixup();

-- ===========================================================================
-- 월간 뷰 — monthly_leaderboard와 동일한 KST 월 경계.
--   guild_member_monthly_vp: 멤버별 이번 달 VP + 길드 내 기여 순위(rn).
--     guild-info가 멤버 리스트(★ 상위 5명 표시)에 사용.
--   guild_monthly_scores: 길드별 상위 5명 합산 점수 + 전체 순위.
--     guild-leaderboard / guild-info가 사용.
--   shadow_banned/banned 멤버는 점수 집계에서 제외 (u.status = 'active' 필터) —
--   개인 monthly_leaderboard와 동일한 취급.
-- ===========================================================================
CREATE VIEW guild_member_monthly_vp AS
WITH period_start AS (
    SELECT (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul' AS start_at
),
member_vp AS (
    SELECT
        gm.guild_id,
        gm.device_id,
        COALESCE(SUM(s.accepted_coins), 0)::BIGINT AS monthly_vp
    FROM guild_members gm
    JOIN users u ON u.device_id = gm.device_id AND u.status = 'active'
    CROSS JOIN period_start ps
    LEFT JOIN submissions s ON s.device_id = gm.device_id
        AND s.accepted = TRUE
        AND s.submitted_at >= ps.start_at    -- 조인 조건에서 필터 — 이번 달 분만 스캔
    GROUP BY gm.guild_id, gm.device_id
)
SELECT
    guild_id,
    device_id,
    monthly_vp,
    ROW_NUMBER() OVER (
        PARTITION BY guild_id ORDER BY monthly_vp DESC, device_id ASC
    ) AS rn
FROM member_vp;

CREATE VIEW guild_monthly_scores AS
SELECT
    g.id AS guild_id,
    g.name,
    g.created_at,
    COALESCE(s.score, 0)::BIGINT AS score,
    COALESCE(mc.member_count, 0)::INT AS member_count,   -- 전체 멤버 수 (status 무관 — 표시용)
    ROW_NUMBER() OVER (ORDER BY COALESCE(s.score, 0) DESC, g.created_at ASC) AS rank
FROM guilds g
LEFT JOIN (
    SELECT
        guild_id,
        SUM(monthly_vp) FILTER (WHERE rn <= 5) AS score  -- TOP_CONTRIBUTORS = 5
    FROM guild_member_monthly_vp
    GROUP BY guild_id
) s ON s.guild_id = g.id
LEFT JOIN (
    SELECT guild_id, COUNT(*) AS member_count
    FROM guild_members
    GROUP BY guild_id
) mc ON mc.guild_id = g.id;

-- ===========================================================================
-- RLS — 전 테이블 anon 차단 (Edge Function service_role만)
-- ===========================================================================
ALTER TABLE guilds                ENABLE ROW LEVEL SECURITY;
ALTER TABLE guild_members         ENABLE ROW LEVEL SECURITY;
ALTER TABLE guild_join_cooldowns  ENABLE ROW LEVEL SECURITY;
ALTER TABLE guild_create_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE guild_furniture       ENABLE ROW LEVEL SECURITY;
