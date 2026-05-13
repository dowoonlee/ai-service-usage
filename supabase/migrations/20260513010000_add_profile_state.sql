-- 트레이너 카드 + stats를 보드에 노출하기 위한 확장.
-- profile_json: 클라이언트가 직렬화한 ProfileState (TrainerCard + trainerID + stats + 뱃지/컬렉션).
-- 서버는 opaque 저장만, 렌더링은 수신측 클라이언트.

ALTER TABLE users
    ADD COLUMN profile_json JSONB;

-- public_leaderboard view 재정의 — profile_json 컬럼 노출.
DROP VIEW IF EXISTS public_leaderboard;
CREATE VIEW public_leaderboard AS
SELECT
    device_id,
    nickname,
    github_login,
    total_coins,
    profile_json,
    ROW_NUMBER() OVER (ORDER BY total_coins DESC, registered_at ASC) AS rank
FROM users
WHERE status = 'active' AND total_coins > 0;
