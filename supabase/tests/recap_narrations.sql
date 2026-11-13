DO $$ BEGIN
    ASSERT NOT has_table_privilege('anon', 'public.recap_narrations', 'SELECT');
    ASSERT NOT has_table_privilege('authenticated', 'public.recap_narrations', 'INSERT');
    ASSERT NOT has_function_privilege('anon', 'public.claim_recap_narration(uuid,integer,text,jsonb,uuid,text)', 'EXECUTE');
    ASSERT NOT has_function_privilege('authenticated', 'public.finish_recap_narration(uuid,integer,text,uuid,jsonb,text)', 'EXECUTE');
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.recap_narrations'::regclass);
END $$;
SET ROLE service_role;
DO $$
DECLARE d uuid := '00000000-0000-0000-0000-000000000001';
    token uuid := gen_random_uuid(); other_token uuid := gen_random_uuid(); r jsonb;
BEGIN
    r := public.claim_recap_narration(d, 2026, 'fox', '{"activeDays":10}', token, 'recap-v1');
    ASSERT r->>'status' = 'generate';
    r := public.claim_recap_narration(d, 2026, 'fox', '{"activeDays":20}', other_token, 'recap-v1');
    ASSERT r->>'status' = 'pending', 'same key cannot generate twice';
    r := public.claim_recap_narration(d, 2026, 'bear', '{}', other_token, 'recap-v1');
    ASSERT r->>'status' = 'pending', 'different pets cannot generate concurrently for one account';
    ASSERT NOT public.finish_recap_narration(d, 2026, 'fox', other_token, '{"persona":"fox","lines":{}}', 'model');
    ASSERT public.finish_recap_narration(d, 2026, 'fox', token, '{"persona":"fox","lines":{"boot":"saved"}}', 'model');
    r := public.claim_recap_narration(d, 2026, 'fox', '{"activeDays":999}', other_token, 'recap-v2');
    ASSERT r->>'status' = 'ready';
    ASSERT r->'row'->'facts_json' = '{"activeDays":10}'::jsonb, 'first snapshot stays immutable';
    ASSERT r->'row'->'narration'->'lines'->>'boot' = 'saved';
    ASSERT NOT (r->'row' ? 'lease_token'), 'cache responses never expose the lease token';
    PERFORM public.fail_recap_narration(d, 2026, 'fox', token);
    ASSERT (SELECT status = 'ready' FROM public.recap_narrations WHERE device_id=d AND pet_kind='fox');

    r := public.claim_recap_narration(d, 2026, 'bear', '{}', token, 'recap-v1');
    ASSERT r->>'status' = 'generate', 'new pet gets its own narration';
    UPDATE public.recap_narrations SET lease_until = now() - interval '1 second' WHERE device_id=d AND pet_kind='bear';
    r := public.claim_recap_narration(d, 2026, 'bear', '{"changed":1}', other_token, 'recap-v1');
    ASSERT r->>'status' = 'generate';
    ASSERT r->'facts' = '{}'::jsonb, 'lease recovery preserves the original snapshot';
    ASSERT NOT public.finish_recap_narration(d, 2026, 'bear', token, '{"persona":"stale","lines":{}}', 'model');
    PERFORM public.fail_recap_narration(d, 2026, 'bear', other_token);
    r := public.claim_recap_narration(d, 2026, 'bear', '{}', token, 'recap-v1');
    ASSERT r->>'status' = 'failed', 'failure cooldown prevents a paid retry loop';
    UPDATE public.recap_narrations SET lease_until = now() - interval '1 second' WHERE device_id=d AND pet_kind='bear';
    r := public.claim_recap_narration(d, 2026, 'bear', '{}', token, 'recap-v1');
    ASSERT r->>'status' = 'generate';
    UPDATE public.recap_narrations SET lease_until = now() - interval '1 second' WHERE device_id=d AND pet_kind='bear';
    r := public.claim_recap_narration(d, 2026, 'bear', '{}', other_token, 'recap-v1');
    ASSERT r->>'status' = 'failed' AND (r->>'retryAfter')::int = 0, 'three attempts maximum';

    BEGIN
        PERFORM public.claim_recap_narration(gen_random_uuid(), 2026, 'fox', '{}', token, 'v1');
        RAISE EXCEPTION 'missing owner guard';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM = 'not_authorized'; END;
    BEGIN
        PERFORM public.claim_recap_narration(d, 2027, 'fox', '{}', token, 'v1');
        RAISE EXCEPTION 'missing year guard';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM = 'invalid_recap_request'; END;
END $$;
RESET ROLE;
-- Ownership recovery reuses device_id; account deletion cascades through the FK.
DELETE FROM public.users WHERE device_id='00000000-0000-0000-0000-000000000001';
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM public.recap_narrations); END $$;
