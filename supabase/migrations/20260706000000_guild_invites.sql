-- 길드 초대장 (푸시 초대) — docs/plans/guild.md.
--
-- 길드장이 가입 가능한 유저(무소속 + 재가입 쿨다운 없음)에게 초대를 발송하고, 받은 유저가
-- 수락하면 가입하는 흐름. 기존 초대 코드 가입(guild-join)과 병행한다.
--
-- 설계 노트:
--   * inviter_device_id는 의도적으로 FK 없음 — 길드장 교체/탈퇴(users CASCADE) 시에도 초대 유지.
--   * 만료는 별도 status로 flip하지 않고 조회 시 expires_at > now()로 판정(크론 불필요).
--   * (guild_id, invitee) pending 유니크 → 같은 길드가 같은 유저에게 대기중 초대 1건.
--   * 거절 후 재초대 쿨다운은 responded_at 기준으로 애플리케이션(guild_policy)이 검사.
--   * RLS 활성 + 정책 없음 = service_role(Edge Function) 전용 (다른 guild_* 테이블과 동일).
CREATE TABLE guild_invites (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    guild_id          UUID NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
    invitee_device_id UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    inviter_device_id UUID NOT NULL,
    status            TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at        TIMESTAMPTZ NOT NULL,
    responded_at      TIMESTAMPTZ
);

-- 대기중 초대는 (길드, 피초대자) 당 1건.
CREATE UNIQUE INDEX guild_invites_pending_uniq
    ON guild_invites (guild_id, invitee_device_id) WHERE status = 'pending';

-- 피초대자의 받은 초대 조회 인덱스.
CREATE INDEX guild_invites_invitee_pending_idx
    ON guild_invites (invitee_device_id) WHERE status = 'pending';

-- 거절 재초대 쿨다운 조회용 (guild, invitee, responded_at DESC).
CREATE INDEX guild_invites_declined_idx
    ON guild_invites (guild_id, invitee_device_id, responded_at) WHERE status = 'declined';

ALTER TABLE guild_invites ENABLE ROW LEVEL SECURITY;
