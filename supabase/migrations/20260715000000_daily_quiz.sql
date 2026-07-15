-- 오늘의 AI 뉴스 퀴즈 — usage 독립 반복 수급.
--
-- 배경: 코인 수급이 사실상 "실제 AI 사용량"에만 묶여 있어, 저사용자/사용 없는 날엔 가챠 코인
--       가뭄이 생긴다. fortune(오늘의 개발 운세)과 동일하게 서버가 매일 콘텐츠를 배포하되,
--       퀴즈는 정답 채점 → reward_grants 지급으로 코인을 준다. 사용량 스트릭(StreakLedger)이
--       "AI 쓰는 사람"을 커버한다면, 퀴즈는 저사용자 포함 전원을 커버.
--
-- 비용/공정성 설계: **전역 1세트/일**. 하루 1행만 생성(KST 날짜 PK)해 전원이 같은 문제를 풀고,
--       OpenAI 호출은 하루 1회로 고정된다(fortune은 device별인데도 운영 중 → 전역이면 훨씬 저렴).
--       랭킹 점수(VP)와 완전 분리 — 지식 퀴즈라 사용량 비례가 아니므로 reward_grants(코인)만 건드림.
--
-- 정답 보호: `questions`(문제+보기)만 클라에 내려가고 `answers`(정답 인덱스)는 서버 DB에만 둔다.
--       채점도 서버(daily-quiz Edge Function)에서 하므로 클라가 정답을 알 수 없어 조작 불가.

-- 하루 1세트 캐시. quiz_date(KST)가 PK → 같은 날 두 번째 호출은 OpenAI 비호출.
CREATE TABLE daily_quiz (
    quiz_date    DATE PRIMARY KEY,
    -- 출처 표기(저작권) — RSS의 제목/요약만 사용, 원문 크롤 X. 링크는 클라에 노출.
    source_title TEXT NOT NULL,
    source_url   TEXT NOT NULL,
    source_name  TEXT NOT NULL DEFAULT '',
    -- "오늘의 AI 근황" 2-3문장 브리핑. 문제를 풀기 전 읽는 교육 콘텐츠.
    brief        TEXT NOT NULL DEFAULT '',
    -- 클라 전송용: [{ question, choices: [4] }] — 정답 제외.
    questions    JSONB NOT NULL,
    -- 서버 전용: [정답 index, ...] — 클라에 절대 전송 안 함. 채점 기준.
    answers      JSONB NOT NULL,
    model_label  TEXT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 사용자별 제출 1회 기록. 하루 1회 dedup + 재조회 시 결과(맞은 수/받은 코인) 표시용.
-- 실제 코인 지급은 reward_grants(grant_key='quiz-<date>')의 UNIQUE(device_id, grant_key)가
-- 이중지급을 막지만, 이 테이블은 "이미 풀었다 + 몇 개 맞췄다"를 클라에 되돌려주는 UX 소스.
CREATE TABLE daily_quiz_submissions (
    device_id     UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    quiz_date     DATE NOT NULL,
    correct_count INT  NOT NULL CHECK (correct_count >= 0),
    reward_coins  INT  NOT NULL DEFAULT 0 CHECK (reward_coins >= 0),
    -- 사용자가 제출한 답 (감사/표시용). [선택 index, ...].
    submitted     JSONB NOT NULL,
    submitted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (device_id, quiz_date)
);

-- RLS — anon 전면 차단, Edge Function(service_role)만. (reward_grants/guild 테이블과 동일 정책.)
ALTER TABLE daily_quiz ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_quiz_submissions ENABLE ROW LEVEL SECURITY;
