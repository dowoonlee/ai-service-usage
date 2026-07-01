-- 게시글 댓글 + 댓글 좋아요.
-- board_posts 아래 flat 댓글(대댓글 없음). 각 댓글에 좋아요(1인 1댓글 1좋아요).
-- board_posts/board_post_likes와 동일 스타일: nickname_snapshot 동결, RLS enable + 정책 없음
-- (anon 차단, Edge Function service_role만 접근). 삭제는 FK CASCADE로 연쇄 정리.

CREATE TABLE board_post_comments (
    id                BIGSERIAL PRIMARY KEY,
    post_id           BIGINT NOT NULL REFERENCES board_posts(id) ON DELETE CASCADE,
    device_id         UUID REFERENCES users(device_id) ON DELETE SET NULL,
    nickname_snapshot TEXT NOT NULL,                     -- 작성 시점 닉네임 동결
    content           TEXT NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT board_post_comments_content_length CHECK (CHAR_LENGTH(content) BETWEEN 1 AND 200)
);

-- 글별 댓글 시간순 조회 (핫 경로 — board 응답 조립).
CREATE INDEX board_post_comments_post_time ON board_post_comments (post_id, created_at ASC);
-- 사용자의 최근 댓글 체크 (rate limit용).
CREATE INDEX board_post_comments_device_time ON board_post_comments (device_id, created_at DESC);

CREATE TABLE board_post_comment_likes (
    comment_id        BIGINT NOT NULL REFERENCES board_post_comments(id) ON DELETE CASCADE,
    device_id         UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    nickname_snapshot TEXT NOT NULL,                     -- 좋아요 시점 닉네임 동결
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (comment_id, device_id)                  -- 1인 1댓글 1좋아요
);

-- 댓글별 좋아요 조회 (board 응답 조립에서 in절 일괄).
CREATE INDEX board_post_comment_likes_comment ON board_post_comment_likes (comment_id);

ALTER TABLE board_post_comments      ENABLE ROW LEVEL SECURITY;
ALTER TABLE board_post_comment_likes ENABLE ROW LEVEL SECURITY;
-- 명시적 정책 없음 → anon 전면 거부. 모든 접근은 Edge Function(service_role) 경유.
