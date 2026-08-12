-- 랭크전 일일 제한 · 레이팅의 원자적 갱신.
--
-- pvp-challenge는 두 카운터를 모두 read-modify-write(select → upsert)로 갱신했다:
--   * pvp_daily_counts — 동시 요청이 같은 count를 읽어 전부 제한을 통과하고 카운트는 1만 올랐다.
--     클라이언트가 요청을 병렬로 쏘면 일일 제한이 사실상 무력화된다(레이팅 펌핑 경로).
--   * pvp_ratings — 동시 매치의 나중 쓰기가 앞 매치 결과를 통째로 덮어써 rating·전적이 유실됐다.
--     본인이 아니라 "같은 상대에게 동시에 도전당한 제3자"가 피해를 본다.
--
-- 두 갱신을 단일 INSERT ... ON CONFLICT DO UPDATE로 옮겨 DB가 직렬화하게 한다.
-- (submit/claim-reward의 조건부 UPDATE + 재시도와 같은 목적이지만, 여기선 순수 증분이라
--  재시도 루프 없이 RPC 한 번으로 끝난다.)

-- 오늘치 도전 1회를 원자적으로 선점한다.
-- 반환: 선점 후 누적 도전 수. 이미 한도에 도달했으면 NULL — 호출부가 409 daily_limit으로 매핑.
create or replace function pvp_claim_daily(
  p_device uuid,
  p_date   date,
  p_limit  integer
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if p_limit <= 0 then
    return null;
  end if;
  insert into pvp_daily_counts (device_id, kst_date, count)
  values (p_device, p_date, 1)
  on conflict (device_id, kst_date) do update
     set count = pvp_daily_counts.count + 1
   where pvp_daily_counts.count < p_limit
  returning pvp_daily_counts.count into v_count;
  -- ON CONFLICT의 WHERE에 걸리면 반환 행이 없어 v_count가 NULL로 남는다(= 한도 도달).
  return v_count;
end;
$$;

-- 레이팅 delta를 원자적으로 적용한다(행이 없으면 1000 기준으로 생성).
-- 반환: 실제 반영된 rating. Elo 제로섬 클램프는 호출부가 계산하지만, 동시 매치로 상대 레이팅이
-- 그 사이 변했을 수 있으므로 0 바닥을 DB 측에서도 방어한다.
create or replace function pvp_apply_rating(
  p_device uuid,
  p_tenant text,
  p_delta  integer,
  p_win    integer,
  p_loss   integer
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rating integer;
begin
  insert into pvp_ratings (device_id, tenant_id, rating, wins, losses, updated_at)
  values (p_device, p_tenant, greatest(0, 1000 + p_delta), p_win, p_loss, now())
  on conflict (device_id) do update
     set rating     = greatest(0, pvp_ratings.rating + p_delta),
         wins       = pvp_ratings.wins + p_win,
         losses     = pvp_ratings.losses + p_loss,
         tenant_id  = excluded.tenant_id,
         updated_at = now()
  returning rating into v_rating;
  return v_rating;
end;
$$;

-- ⚠️ security definer 함수는 생성 시 PUBLIC에 EXECUTE가 붙는다. anon key는 앱 번들에 그대로
-- 들어있는 공개값이라, 이대로 두면 누구나 pvp_apply_rating(임의 device, +99999)로 레이팅을
-- 조작할 수 있다. Edge Function(service_role)만 호출하도록 명시적으로 좁힌다.
revoke all on function pvp_claim_daily(uuid, date, integer) from public, anon, authenticated;
revoke all on function pvp_apply_rating(uuid, text, integer, integer, integer) from public, anon, authenticated;
grant execute on function pvp_claim_daily(uuid, date, integer) to service_role;
grant execute on function pvp_apply_rating(uuid, text, integer, integer, integer) to service_role;
