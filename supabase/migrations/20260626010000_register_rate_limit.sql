-- register 어뷰징 방어: IP별 등록 시도 로그 (rolling window rate-limit 평가용).
--
-- 배경: device_id를 클라이언트가 UUID로 자유 생성하므로, 한 명이 무한히 새 계정을 등록할 수
-- 있다. initialCoins 폐기로 farming 이득(점수 한방 주입)은 사라졌지만, 닉네임 스쿼팅·DB 오염
-- 같은 스팸 가입은 여전히 가능. 같은 IP의 성공 등록 횟수를 rolling window로 제한해 완화한다.
--
-- IP는 완벽한 식별자가 아님(VPN/CGNAT/공용망 공유) — 1차 방어선일 뿐. 임계는 정상 사용자
-- (보통 1회/생애)를 막지 않도록 넉넉히 둔다. 보관기간이 지난 행은 운영자/별도 잡이 정리.
CREATE TABLE register_attempts (
    id            BIGSERIAL PRIMARY KEY,
    ip            TEXT NOT NULL,
    attempted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- (ip, 최근순) — window 카운트 쿼리용.
CREATE INDEX register_attempts_ip_time ON register_attempts (ip, attempted_at DESC);
-- 오래된 행 정리(예: 일일 cron으로 DELETE WHERE attempted_at < now()-interval '7 days')용.
CREATE INDEX register_attempts_time ON register_attempts (attempted_at);

-- RLS: anon 전면 차단. Edge Function(service_role)만 접근. init_ranking.sql과 동일 정책.
ALTER TABLE register_attempts ENABLE ROW LEVEL SECURITY;
-- 명시적 정책 없음 → anon은 SELECT/INSERT/UPDATE/DELETE 모두 거부.
