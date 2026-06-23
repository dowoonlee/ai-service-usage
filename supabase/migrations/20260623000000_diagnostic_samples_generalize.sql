-- codex_usage_samples 일반화 — 버그리포트 진단 데이터 공용 저장소로 확장 (이슈 #36 후속).
--
-- 배경: 사용량 버그는 디버그 로그보다 응답 원본(rate_limit 등) 구조가 진단에 결정적인데,
-- 버그리포트는 GitHub 공개 이슈로 가므로 raw·PII를 본문에 실을 수 없다. 그래서 raw는 이
-- 비공개 테이블에 적재하고, GitHub 이슈에는 row의 UUID만 적어 개발자가 역참조하게 한다.
--
-- 그 UUID 참조를 위해 PK를 BIGSERIAL → uuid 로 전환한다(순번 노출 = enumeration 차단).
-- USING gen_random_uuid() 는 기존 row(현재 codex_voluntary 자발 제출 소수)의 id 를 새 uuid 로
-- 재발급한다 — 이 id 를 참조하는 곳(FK·이슈 링크)이 아직 없어 무해하고, rate_limit/parsed 등
-- 데이터는 그대로 보존된다. 클라이언트가 생성한 UUID를 insert 하되, 누락 시 DEFAULT 로 채운다
-- (pg17 코어 내장). origin 컬럼은 NOT NULL DEFAULT 라 기존 row 가 'codex_voluntary' 로 채워진다.
--
-- 두 모집단을 origin 으로 구분한다:
--   'codex_voluntary' — 기존 Codex 섹션 "진단 제출" 버튼 (정상 사용자도 자발 제출, 익명 집계)
--   'bug_report'      — 버그리포트 "사용량 이슈" 템플릿 (특정 인시던트 + 로그 + 다중 소스 raw)
--
-- 테이블/Edge Function 이름은 유지한다(변경 최소화). 의미상 범용이지만 codex-sample 함수가
-- 유일한 참조라 rename 대비 호환 리스크가 없을 때까지 미룬다.

-- 1) PK 를 uuid 로 전환 (기존 row 의 id 는 새 uuid 로 재발급, 데이터는 보존) ----------
ALTER TABLE codex_usage_samples ALTER COLUMN id DROP DEFAULT;
DROP SEQUENCE IF EXISTS codex_usage_samples_id_seq;
ALTER TABLE codex_usage_samples
    ALTER COLUMN id TYPE uuid USING gen_random_uuid();
ALTER TABLE codex_usage_samples ALTER COLUMN id SET DEFAULT gen_random_uuid();

-- 2) 범용 진단 컬럼 추가 -------------------------------------------------------
ALTER TABLE codex_usage_samples
    ADD COLUMN origin       TEXT NOT NULL DEFAULT 'codex_voluntary'
        CHECK (origin IN ('codex_voluntary', 'bug_report')),
    ADD COLUMN category     TEXT,    -- bug_report 세분류 (예: 'usage') — 자유 텍스트, 서버에서 cap
    ADD COLUMN os_version   TEXT,    -- 버그리포트 환경정보 (macOS 버전)
    ADD COLUMN claude_usage JSONB,   -- Claude usage 응답의 PII-free 사용률 서브트리 (org uuid 제외)
    ADD COLUMN cursor_usage JSONB,   -- Cursor usage 응답의 PII-free 사용률 서브트리 (모델별 cost 제외)
    ADD COLUMN log_tail     TEXT;    -- 디버그 로그 마지막 N줄 (버그리포트에서 사용자가 첨부 동의 시)

-- RLS 는 init 마이그레이션에서 이미 ENABLE + 정책 없음 → anon 직접 거부, service_role(Edge
-- Function) 경유만. uuid PK 라 추측 조회도 불가. 별도 정책 변경 없음.
