#!/usr/bin/env bash
# Disposable database, no network, no linked Supabase writes.
set -euo pipefail
cd "$(dirname "$0")/.."
recap_container="aiusage-recap-test-$$"
recap_test_dir=$(mktemp -d /tmp/aiusage-recap-db.XXXXXX)
cleanup() {
    docker rm -fv "$recap_container" >/dev/null 2>&1 || true
    rm -rf "$recap_test_dir"
}
trap cleanup EXIT
docker run -d --pull=never --name "$recap_container" --network none -e POSTGRES_HOST_AUTH_METHOD=trust \
    -v "$(pwd)/supabase/migrations:/workspace/supabase/migrations:ro" \
    -v "$(pwd)/supabase/tests:/workspace/supabase/tests:ro" "${POSTGRES_TEST_IMAGE:-postgres:17.6-alpine}" >/dev/null
ready=false
for _ in {1..60}; do
    if docker exec "$recap_container" sh -c 'test "$(cat /proc/1/comm)" = postgres && pg_isready -U postgres' >/dev/null 2>&1; then ready=true; break; fi
    sleep 0.5
done
if [ "$ready" != true ]; then docker logs "$recap_container"; exit 1; fi
db_psql() { docker exec -i -w /workspace "$recap_container" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
db_psql >/dev/null <<'SQL'
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role BYPASSRLS;
CREATE TABLE public.users(device_id uuid PRIMARY KEY, status text NOT NULL DEFAULT 'active');
GRANT SELECT, UPDATE ON public.users TO service_role;
INSERT INTO public.users(device_id) VALUES ('00000000-0000-0000-0000-000000000001');
SQL
db_psql -f supabase/migrations/20261113102047_recap_narrations.sql >/dev/null
db_psql -f supabase/tests/recap_narrations.sql
db_psql -c "INSERT INTO public.users(device_id) VALUES ('00000000-0000-0000-0000-000000000002')" >/dev/null
for i in 1 2; do
    db_psql -At -c "SET ROLE service_role; SELECT public.claim_recap_narration('00000000-0000-0000-0000-000000000002',2026,'fox','{}',gen_random_uuid(),'v1')->>'status'" >"$recap_test_dir/race$i.log" &
    if [ "$i" -eq 1 ]; then pid1=$!; else pid2=$!; fi
done
wait "$pid1"
wait "$pid2"
python3 - "$recap_test_dir" <<'PY'
import pathlib, sys
results = [p.read_text().strip().splitlines()[-1] for p in pathlib.Path(sys.argv[1]).glob('race*.log')]
assert sorted(results) == ['generate', 'pending'], results
print('Recap concurrent claim: exactly one generation')
PY
