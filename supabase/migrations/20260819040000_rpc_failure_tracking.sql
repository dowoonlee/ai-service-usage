-- best-effort RPC 실패를 DB에 남긴다 (#243).
--
-- 왜 로그로 안 되나: 무료 플랜은 로그 보존이 24시간뿐이다. PR #242 의 아레나 시즌 정산 실패는
-- 19일간 이어졌지만, 그걸 확정한 근거는 로그가 아니라 "reward_grants 0건 / pvp_seasons 마커
-- 부재"라는 DB 상태였다. 관측 창을 놓치면 사라지는 신호는 신호가 아니다.
--
-- 왜 실패만 쓰나: 이 RPC 들의 호출부는 leaderboard/sync 처럼 호출량이 많은 경로다. 성공할
-- 때마다 쓰면 정상 트래픽에 쓰기가 하나씩 붙는다. 현재 프로젝트 병목이 Egress 라 정상 경로에는
-- 아무 비용도 추가하지 않는 게 중요하다. 실패는 드물므로 이 테이블의 쓰기량은 사실상 0이다.
--
-- 판정은 **최근성**으로 한다: 정산 함수는 한 번 성공하면 EXISTS 가드로 즉시 return 하므로
-- 성공이 행을 지우지 않는다. 과거에 고쳐진 장애의 행이 그대로 남으니, 조회는
--     select * from rpc_failures where last_error_at > now() - interval '2 days';
-- 처럼 최근 창으로 볼 것. first_error_at 은 장애가 언제부터였는지(#242 는 19일)를 남긴다.
create table if not exists rpc_failures (
  fn_name         text        primary key,
  last_error      text        not null,
  last_error_at   timestamptz not null default now(),
  first_error_at  timestamptz not null default now(),
  fail_count      integer     not null default 1
);

-- 이 저장소 관행 — RLS 활성 + 정책 0개 = service_role(Edge Function) 전용.
alter table rpc_failures enable row level security;
revoke all on rpc_failures from anon, authenticated;

/**
 * 실패 1건을 기록한다. 같은 함수의 반복 실패는 카운트만 올리고 first_error_at 은 보존한다.
 *
 * read-modify-write 를 피해 단일 INSERT ... ON CONFLICT DO UPDATE 로 처리한다(CLAUDE.md 규칙).
 * ON CONFLICT 의 UPDATE 는 독립 UPDATE 문이 아니므로 safeupdate 가드 대상이 아니다 —
 * 하필 이 함수가 #242 와 같은 이유로 죽으면 실패를 기록할 수단 자체가 사라진다.
 */
create or replace function record_rpc_failure(p_fn text, p_error text) returns void
language sql
security invoker
set search_path = public
as $$
  insert into rpc_failures (fn_name, last_error)
  values (p_fn, left(coalesce(p_error, ''), 500))
  on conflict (fn_name) do update
    set last_error    = excluded.last_error,
        last_error_at = now(),
        fail_count    = rpc_failures.fail_count + 1;
$$;

revoke all on function record_rpc_failure(text, text) from public, anon, authenticated;
grant execute on function record_rpc_failure(text, text) to service_role;
