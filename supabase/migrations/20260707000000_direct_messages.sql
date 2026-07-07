-- 1:1 쪽지 (E2EE) + 통합 인박스 — docs/plans/direct-messages.md.
--
-- 본문은 종단간 암호화(HPKE)라 서버는 암호문만 저장하고 읽지 못한다. 서버는 자격(존재·키·차단·
-- 수신설정·레이트리밋)만 검사한다. 신원 공개키는 user_keys, 메시지는 direct_messages.
--
-- 설계 노트:
--   * sender_device는 FK 없음 — 발신자 탈퇴 후에도 스레드 유지 (guild_invites inviter 패턴).
--   * 만료·purge는 조회 시 처리하거나 후속 크론 — v1은 무기한 + 양측 tombstone.
--   * RLS 활성 + 정책 없음 = service_role(Edge Function) 전용 (guild_* 테이블과 동일).

-- 신원 공개키 (device 1:1). 개인키는 클라 Keychain에만, 서버엔 공개키만.
CREATE TABLE user_keys (
    device_id  UUID PRIMARY KEY REFERENCES users(device_id) ON DELETE CASCADE,
    x25519_pub TEXT NOT NULL,                       -- base64 raw 32B
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()   -- rotate(기기 변경) 시 갱신
);

-- 암호화 메시지. ciphertext = base64(version || encapsulatedKey || ct). 서버 불투명.
CREATE TABLE direct_messages (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_device    UUID NOT NULL,                 -- FK 없음 (탈퇴 후 스레드 유지)
    recipient_device UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    ciphertext       TEXT NOT NULL,                 -- ≤ 6KB (dm_policy DM_CIPHERTEXT_MAX)
    sender_id_pub    TEXT NOT NULL,                 -- 발신 당시 발신자 공개키 스냅샷 (수신자 open/TOFU)
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    read_at          TIMESTAMPTZ,
    del_sender       BOOLEAN NOT NULL DEFAULT false, -- 양측 tombstone (둘 다 true면 물리 삭제 대상)
    del_recipient    BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX direct_messages_inbox_idx  ON direct_messages (recipient_device, created_at DESC);
CREATE INDEX direct_messages_thread_idx ON direct_messages (sender_device, recipient_device, created_at);

-- 차단 (blocker가 blocked의 발신을 거부).
CREATE TABLE dm_blocks (
    blocker_device UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    blocked_device UUID NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker_device, blocked_device)
);
CREATE INDEX dm_blocks_blocked_idx ON dm_blocks (blocked_device);

-- 수신 정책 (누가 나에게 쪽지 가능한가).
CREATE TABLE dm_settings (
    device_id  UUID PRIMARY KEY REFERENCES users(device_id) ON DELETE CASCADE,
    allow_from TEXT NOT NULL DEFAULT 'anyone' CHECK (allow_from IN ('anyone', 'guild', 'none')),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE user_keys       ENABLE ROW LEVEL SECURITY;
ALTER TABLE direct_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE dm_blocks       ENABLE ROW LEVEL SECURITY;
ALTER TABLE dm_settings     ENABLE ROW LEVEL SECURITY;
