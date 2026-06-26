-- 랭킹 응답 진단 캡처 컬럼 추가 (#56 — #54류 랭킹 디코딩 실패 디버깅 사각지대 해소).
--
-- 배경: 버그리포트 진단은 Claude·Cursor·Codex 사용량 응답만 비공개 적재해, 랭킹
-- (leaderboard/board) 응답 디코딩이 깨지는 케이스(#54)는 페이로드가 전혀 안 잡혔다.
-- 이제 클라(RankingAPI.execute)가 디코딩 실패 *순간* 의 응답을 PII 마스킹(닉네임·deviceId·
-- coins·복구코드 등 값 제거, 타입은 보존)·용량 캡 후 버그리포트에 함께 첨부하면 여기 적재한다.
--
-- 마스킹은 클라에서 끝내고 서버는 저장만 — 사용량 서브트리(claude_usage 등)와 동일한 패턴.

ALTER TABLE codex_usage_samples
    ADD COLUMN ranking_response     JSONB,  -- 마스킹된 실패 응답 (객체 JSON 또는 truncated 문자열)
    ADD COLUMN ranking_decode_error TEXT;   -- 캡처 컨텍스트: "path=… status=… err=…"

-- RLS 변경 없음 — 기존과 동일하게 anon 직접 거부, service_role(Edge Function) 경유만.
