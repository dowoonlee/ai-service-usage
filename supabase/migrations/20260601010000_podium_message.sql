-- 명예의 전당 시상대 한마디 — 월별 우승자(1·2·3위)가 podium에 남기는 커스텀 메시지.
-- 1회 등록 후 변경 불가(immutable): set-podium-message 함수가 podium_message IS NULL일 때만 set.
-- 길이 제한 50자(char_length = 코드포인트 기준, 한글 1자=1). 서버 함수도 동일 검증.

ALTER TABLE monthly_winners ADD COLUMN podium_message TEXT;

ALTER TABLE monthly_winners ADD CONSTRAINT podium_message_len
    CHECK (podium_message IS NULL OR char_length(podium_message) <= 50);
