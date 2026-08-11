-- 외부 PR 기여자 서버 캐시
--
-- 기존엔 클라이언트가 각자 GitHub `/pulls?state=closed&per_page=100`을 직접 호출했다.
-- 두 가지가 깨졌다:
--   1) 비인증 GitHub API는 **IP 단위** 60req/h다. 사내망 NAT이면 전 사용자가 한 IP를
--      공유해 금세 소진된다(관측: remaining 0).
--   2) 더 치명적으로, /pulls는 생성 역순 100개만 준다. 리포 PR이 215개까지 늘면서
--      외부 기여자 PR(#3·#8·#45·#59)이 조회 창(#95~#215) 밖으로 밀려 목록이 조용히 비었다.
--
-- 그래서 서버가 한 곳에서 Search API로 긁어 DB에 담고, 클라는 이 테이블만 읽는다.
-- 갱신은 pg_cron 없이 lazy 트리거 — finalize_monthly_guild_rp_if_needed와 같은 패턴이다.

create table if not exists contributors (
  login             text primary key,
  avatar_url        text,
  -- [{number, title, mergedAt}] — 최신 머지순. 클라가 그대로 렌더한다.
  prs               jsonb       not null default '[]'::jsonb,
  pr_count          integer     not null default 0,
  latest_merged_at  timestamptz,
  updated_at        timestamptz not null default now()
);

-- 정렬(PR 많은 순 → 최근 머지순)은 서버가 하지만, 행이 늘어도 싸게 훑도록 인덱스를 둔다.
create index if not exists contributors_rank_idx
  on contributors (pr_count desc, latest_merged_at desc);

-- 동기화 메타 — 항상 1행(id=1).
create table if not exists contributors_sync (
  id               integer primary key default 1,
  -- 마지막 **성공** 시각. TTL 판정 기준.
  last_success_at  timestamptz,
  -- 마지막 **시도** 시각. 실패가 이어질 때 매 요청마다 GitHub을 두드리지 않도록 하는 쿨다운.
  last_attempt_at  timestamptz,
  last_error       text,
  constraint contributors_sync_singleton check (id = 1)
);

insert into contributors_sync (id) values (1) on conflict (id) do nothing;

/**
 * 동기화 슬롯을 원자적으로 선점한다.
 *
 * 여러 클라이언트가 동시에 만료를 관측해도 UPDATE ... WHERE 조건을 통과하는 건 한 트랜잭션뿐이라,
 * GitHub 호출도 한 번만 나간다(중복 호출로 rate limit을 태우는 것을 막는다).
 *
 * @param ttl_seconds       성공 후 이만큼 지나야 다시 갱신한다.
 * @param retry_seconds     실패했을 때의 재시도 간격. TTL보다 훨씬 짧게 둬서
 *                          "24시간 동안 빈 목록" 상태에 갇히지 않게 한다.
 * @returns true면 호출자가 갱신을 수행해야 한다.
 */
create or replace function claim_contributors_sync(
  ttl_seconds     integer,
  retry_seconds   integer
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  claimed boolean;
begin
  update contributors_sync
     set last_attempt_at = now()
   where id = 1
     and (last_attempt_at is null or last_attempt_at < now() - make_interval(secs => retry_seconds))
     and (last_success_at is null or last_success_at < now() - make_interval(secs => ttl_seconds))
  returning true into claimed;
  return coalesce(claimed, false);
end;
$$;
