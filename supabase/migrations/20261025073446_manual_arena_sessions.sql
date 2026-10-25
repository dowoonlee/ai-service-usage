-- Interactive battles are independent of ATB ratings, currencies and season settlement.
-- Verified ownership must be populated only from an audited server-side ownership source.
-- Never backfill this table directly from pvp_teams (client-asserted kind/variant).
CREATE TABLE public.manual_verified_pets (
    device_id uuid NOT NULL REFERENCES public.users(device_id) ON DELETE CASCADE,
    kind text NOT NULL,
    variant integer NOT NULL CHECK (variant BETWEEN 0 AND 4),
    progress_units double precision NOT NULL DEFAULT 0 CHECK (progress_units BETWEEN 0 AND 8),
    verified_at timestamptz NOT NULL DEFAULT now(),
    evidence text NOT NULL CHECK (length(evidence) > 0),
    PRIMARY KEY (device_id, kind)
);

CREATE TABLE public.manual_arena_sessions (
    id uuid PRIMARY KEY,
    device_id uuid NOT NULL REFERENCES public.users(device_id) ON DELETE CASCADE,
    tenant_id text NOT NULL REFERENCES public.tenants(slug),
    start_request_id uuid NOT NULL,
    start_fingerprint text NOT NULL,
    revision integer NOT NULL DEFAULT 0 CHECK (revision >= 0),
    state_json jsonb NOT NULL,
    eligible_kinds text[] NOT NULL DEFAULT '{}',
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'finished', 'expired')),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL DEFAULT now() + interval '24 hours',
    UNIQUE (device_id, start_request_id)
);
CREATE UNIQUE INDEX manual_arena_one_active ON public.manual_arena_sessions(device_id) WHERE status = 'active';
CREATE INDEX manual_arena_owner_time ON public.manual_arena_sessions(device_id, created_at DESC);
CREATE INDEX manual_arena_tenant ON public.manual_arena_sessions(tenant_id);

CREATE TABLE public.manual_arena_requests (
    battle_id uuid NOT NULL REFERENCES public.manual_arena_sessions(id) ON DELETE CASCADE,
    request_id uuid NOT NULL,
    fingerprint text NOT NULL,
    response jsonb NOT NULL,
    PRIMARY KEY (battle_id, request_id)
);

CREATE TABLE public.manual_pet_mastery (
    device_id uuid NOT NULL REFERENCES public.users(device_id) ON DELETE CASCADE,
    kind text NOT NULL,
    wins integer NOT NULL DEFAULT 0 CHECK (wins >= 0),
    original_wins integer NOT NULL DEFAULT 0 CHECK (original_wins >= 0),
    alternate_wins integer NOT NULL DEFAULT 0 CHECK (alternate_wins >= 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, kind)
);
CREATE TABLE public.manual_mastery_awards (
    battle_id uuid NOT NULL REFERENCES public.manual_arena_sessions(id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES public.users(device_id) ON DELETE CASCADE,
    kind text NOT NULL,
    branch text CHECK (branch IN ('original', 'alternate')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (battle_id, kind)
);
CREATE INDEX manual_mastery_awards_owner ON public.manual_mastery_awards(device_id, kind);

ALTER TABLE public.manual_verified_pets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manual_arena_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manual_arena_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manual_pet_mastery ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manual_mastery_awards ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.manual_verified_pets, public.manual_arena_sessions, public.manual_arena_requests,
    public.manual_pet_mastery, public.manual_mastery_awards FROM anon, authenticated;
GRANT ALL ON public.manual_verified_pets, public.manual_arena_sessions, public.manual_arena_requests,
    public.manual_pet_mastery, public.manual_mastery_awards TO service_role;

-- Called only by the authenticated Edge Function; no SECURITY DEFINER privilege escalation.
CREATE FUNCTION public.manual_arena_start(p_id uuid, p_device uuid, p_tenant text,
    p_request uuid, p_fingerprint text, p_state jsonb, p_eligible text[])
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE prior public.manual_arena_sessions%ROWTYPE; active_session uuid;
BEGIN
    PERFORM 1 FROM public.users WHERE device_id = p_device AND tenant_id = p_tenant AND status <> 'banned' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'not_authorized'; END IF;
    SELECT * INTO prior FROM public.manual_arena_sessions WHERE device_id = p_device AND start_request_id = p_request;
    IF FOUND THEN
        IF prior.start_fingerprint <> p_fingerprint THEN RAISE EXCEPTION 'request_conflict'; END IF;
        RETURN to_jsonb(prior);
    END IF;
    UPDATE public.manual_arena_sessions SET status = 'expired' WHERE device_id = p_device AND status = 'active'
        AND (expires_at <= now() OR tenant_id <> p_tenant);
    SELECT id INTO active_session FROM public.manual_arena_sessions WHERE device_id = p_device AND status = 'active';
    IF FOUND THEN RAISE EXCEPTION 'active_battle'; END IF;
    IF (SELECT count(*) FROM public.manual_arena_sessions WHERE device_id = p_device
        AND created_at >= (date_trunc('day', now() AT TIME ZONE 'Asia/Seoul') AT TIME ZONE 'Asia/Seoul')) >= 10 THEN
        RAISE EXCEPTION 'daily_limit';
    END IF;
    INSERT INTO public.manual_arena_sessions(id, device_id, tenant_id, start_request_id, start_fingerprint, state_json, eligible_kinds)
        VALUES (p_id, p_device, p_tenant, p_request, p_fingerprint, p_state, p_eligible)
        RETURNING * INTO prior;
    RETURN to_jsonb(prior);
END $$;

CREATE FUNCTION public.manual_arena_commit(p_id uuid, p_device uuid, p_tenant text,
    p_request uuid, p_fingerprint text, p_revision integer, p_state jsonb, p_response jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE session public.manual_arena_sessions%ROWTYPE; cached public.manual_arena_requests%ROWTYPE;
    fighter jsonb; pet_kind text; chosen_branch text;
BEGIN
    SELECT * INTO session FROM public.manual_arena_sessions WHERE id = p_id AND device_id = p_device AND tenant_id = p_tenant FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'battle_not_found'; END IF;
    SELECT * INTO cached FROM public.manual_arena_requests WHERE battle_id = p_id AND request_id = p_request;
    IF FOUND THEN
        IF cached.fingerprint <> p_fingerprint THEN RAISE EXCEPTION 'request_conflict'; END IF;
        RETURN cached.response;
    END IF;
    IF session.status <> 'active' OR session.expires_at <= now() THEN RAISE EXCEPTION 'battle_closed'; END IF;
    IF session.revision <> p_revision THEN RAISE EXCEPTION 'revision_conflict'; END IF;
    IF (p_state->>'revision')::integer <> p_revision + 1 OR p_state->>'id' <> p_id::text
        OR (p_state->>'rulesVersion')::integer <> 1 THEN RAISE EXCEPTION 'invalid_state'; END IF;
    UPDATE public.manual_arena_sessions SET state_json = p_state, revision = p_revision + 1,
        status = CASE WHEN p_state->'outcome' IS NOT NULL AND p_state->'outcome' <> 'null'::jsonb THEN 'finished' ELSE 'active' END
        WHERE id = p_id;
    IF p_state#>>'{outcome,winner}' = '0' AND p_state#>>'{outcome,reason}' = 'knockout' THEN
        FOR fighter IN SELECT value FROM jsonb_array_elements(p_state#>'{teams,0,fighters}') LOOP
            pet_kind := fighter#>>'{pet,kind}';
            IF pet_kind = ANY(session.eligible_kinds) AND (fighter#>>'{pet,variant}')::integer = 4
                AND (fighter->>'participated')::boolean THEN
                chosen_branch := CASE WHEN (fighter->>'ultimateUsed')::boolean THEN fighter->>'branch' ELSE NULL END;
                INSERT INTO public.manual_mastery_awards(battle_id, device_id, kind, branch)
                    VALUES(p_id, p_device, pet_kind, chosen_branch) ON CONFLICT DO NOTHING;
                IF FOUND THEN
                    INSERT INTO public.manual_pet_mastery(device_id, kind, wins, original_wins, alternate_wins)
                        VALUES(p_device, pet_kind, 1, CASE WHEN chosen_branch = 'original' THEN 1 ELSE 0 END,
                            CASE WHEN chosen_branch = 'alternate' THEN 1 ELSE 0 END)
                        ON CONFLICT(device_id, kind) DO UPDATE SET wins = public.manual_pet_mastery.wins + 1,
                            original_wins = public.manual_pet_mastery.original_wins + EXCLUDED.original_wins,
                            alternate_wins = public.manual_pet_mastery.alternate_wins + EXCLUDED.alternate_wins, updated_at = now();
                END IF;
            END IF;
        END LOOP;
    END IF;
    INSERT INTO public.manual_arena_requests(battle_id, request_id, fingerprint, response)
        VALUES(p_id, p_request, p_fingerprint, p_response);
    RETURN p_response;
END $$;

REVOKE ALL ON FUNCTION public.manual_arena_start(uuid, uuid, text, uuid, text, jsonb, text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manual_arena_commit(uuid, uuid, text, uuid, text, integer, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.manual_arena_start(uuid, uuid, text, uuid, text, jsonb, text[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.manual_arena_commit(uuid, uuid, text, uuid, text, integer, jsonb, jsonb) TO service_role;
