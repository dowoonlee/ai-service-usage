-- abuse_flags 운영 검토 추적 — 운영자가 각 플래그를 확인했는지/언제/메모를 남긴다.
-- Edge Function은 abuse_flags에 INSERT만 하고(자동 탐지), 검토는 service_role로 수동 UPDATE.
-- reviewed_at IS NULL = 미확인, 값 있으면 그 시각에 확인함. review_note는 판정 메모
-- (예: "개발자 본인 dev 아티팩트", "false positive — 재설치 추정", "관찰 중").
--
-- 컬럼 추가만이라 기존 INSERT 경로(submit/index.ts 등)는 영향 없음 — 새 컬럼은 nullable.
ALTER TABLE abuse_flags
  ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS review_note TEXT;

-- 미확인 플래그만 빠르게 조회 (운영 트리아지 큐).
CREATE INDEX IF NOT EXISTS abuse_flags_unreviewed
  ON abuse_flags (flagged_at DESC) WHERE reviewed_at IS NULL;
