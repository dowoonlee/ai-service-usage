-- 게시판 1분 이내 삭제 기능 도입에 따른 cooldown 어뷰징 방어.
--
-- 기존: post Edge Function이 board_posts.created_at 기준으로 cooldown 체크 →
--       사용자가 1분 안에 글 삭제하면 cooldown row 자체가 사라져 다음 글을 즉시 작성 가능 →
--       사실상 600초 cooldown이 60초로 단축되는 어뷰징 가능.
--
-- 해결: users.last_post_at 컬럼을 별도로 두고 작성 시 갱신, 삭제로는 영향 없음.
--       cooldown 체크는 이 값 기준. 삭제 후에도 cooldown은 그대로 유지.
--
-- 기존 사용자는 NULL → 첫 post 시 NOW()로 채워짐 (cooldown 가드는 NULL인 경우 통과).

ALTER TABLE users ADD COLUMN last_post_at TIMESTAMPTZ;
