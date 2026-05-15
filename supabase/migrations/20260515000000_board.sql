-- 미니 게시판 (100자 텍스트 + 좋아요).
--
-- 디자인 노트:
--   * board_posts는 append-only — 삭제 불가 (DELETE policy 없음, Edge Function도 DELETE 안 함).
--     DDL 차원 영구 보관.
--   * nickname_snapshot은 작성/좋아요 시점 동결. 사용자가 닉변경해도 과거 글의 작성자 표시는
--     그대로 — 채팅 history로서의 일관성 우선.
--   * board_post_likes의 PK가 (post_id, device_id) 복합 → 같은 사용자가 한 글에 좋아요 2번 불가.
--     toggle은 INSERT … ON CONFLICT DO NOTHING → rowCount=0이면 DELETE.
--   * RLS 활성 + 정책 없음 → anon은 직접 접근 불가. 모든 read/write는 Edge Function (service_role).

-- ===========================================================================
-- board_posts — append-only 게시글
-- ===========================================================================
CREATE TABLE board_posts (
    id                BIGSERIAL PRIMARY KEY,
    device_id         UUID REFERENCES users(device_id) ON DELETE SET NULL,
    nickname_snapshot TEXT NOT NULL,                         -- 작성 시점 닉네임 동결
    content           TEXT NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT board_posts_content_length CHECK (CHAR_LENGTH(content) BETWEEN 1 AND 100)
);

-- 시간순 조회 hot path (최신 100개 LIMIT).
CREATE INDEX board_posts_created_at ON board_posts (created_at DESC);
-- rate limit 체크용 (본인의 마지막 post 시각).
CREATE INDEX board_posts_device_time ON board_posts (device_id, created_at DESC);

-- ===========================================================================
-- board_post_likes — 1인 1글 1좋아요 (PK 복합)
-- ===========================================================================
CREATE TABLE board_post_likes (
    post_id           BIGINT NOT NULL REFERENCES board_posts(id) ON DELETE CASCADE,
    device_id         UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    nickname_snapshot TEXT NOT NULL,                         -- 좋아요 시점 닉네임 동결
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (post_id, device_id)
);

-- post_id별 좋아요 시간순 (popover에서 누른 사람 시간순 표시).
CREATE INDEX board_post_likes_post_time ON board_post_likes (post_id, created_at ASC);

-- ===========================================================================
-- RLS — Edge Function (service_role) 경유만 허용
-- ===========================================================================
ALTER TABLE board_posts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE board_post_likes ENABLE ROW LEVEL SECURITY;
-- 명시적 정책 없음 → anon은 모든 작업 거부.
