-- 길드 가입신청 (pull 방식 가입) — docs/plans/guild.md.
--
-- 초대장(guild_invites, 길드장이 발송 → 유저 수락)의 대칭 흐름. 유저가 길드 리스트를 보고
-- 가입을 신청 → 길드장이 수락/거절한다. 기존 초대 코드 가입(guild-join)·푸시 초대와 병행.
--
-- 설계 노트 (guild_invites와 동일한 규약):
--   * requester_device_id는 users FK(CASCADE) — 신청자 탈퇴 시 신청도 사라진다.
--   * tenant_id 컬럼 없음 — "한 길드 = 한 테넌트"라 격리는 길드의 tenant_id로 판정
--     (guild-request create·guild-manage approve 시 guild.tenant_id == user.tenant_id 검사).
--   * 만료는 status flip 없이 조회 시 expires_at > now()로 판정(크론 불필요).
--   * (guild_id, requester) pending 유니크 → 같은 유저가 같은 길드에 대기중 신청 1건.
--   * 거절 후 재신청 쿨다운은 responded_at 기준으로 애플리케이션(guild_policy)이 검사.
--   * RLS 활성 + 정책 없음 = service_role(Edge Function) 전용 (다른 guild_* 테이블과 동일).
CREATE TABLE guild_join_requests (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    guild_id            UUID NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
    requester_device_id UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    status              TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ NOT NULL,
    responded_at        TIMESTAMPTZ
);

-- 대기중 신청은 (길드, 신청자) 당 1건.
CREATE UNIQUE INDEX guild_join_requests_pending_uniq
    ON guild_join_requests (guild_id, requester_device_id) WHERE status = 'pending';

-- 신청자의 보낸 신청 조회 인덱스 ("내 가입신청" 리스트).
CREATE INDEX guild_join_requests_requester_pending_idx
    ON guild_join_requests (requester_device_id) WHERE status = 'pending';

-- 길드장의 받은 신청 조회 인덱스 (수신함).
CREATE INDEX guild_join_requests_guild_pending_idx
    ON guild_join_requests (guild_id) WHERE status = 'pending';

-- 거절 재신청 쿨다운 조회용 (guild, requester, responded_at DESC).
CREATE INDEX guild_join_requests_declined_idx
    ON guild_join_requests (guild_id, requester_device_id, responded_at) WHERE status = 'declined';

ALTER TABLE guild_join_requests ENABLE ROW LEVEL SECURITY;
