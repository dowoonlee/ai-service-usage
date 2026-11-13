-- One immutable successful narration per account/year/species. HMAC-authenticated Edge Function only.
CREATE TABLE public.recap_narrations (
    device_id uuid NOT NULL REFERENCES public.users(device_id) ON DELETE CASCADE,
    recap_year integer NOT NULL CHECK (recap_year BETWEEN 2026 AND 2100),
    pet_kind text NOT NULL CHECK (pet_kind ~ '^[A-Za-z][A-Za-z0-9]{0,63}$'),
    facts_json jsonb NOT NULL CHECK (jsonb_typeof(facts_json) = 'object'),
    status text NOT NULL CHECK (status IN ('pending', 'ready', 'failed')),
    lease_token uuid NOT NULL,
    lease_until timestamptz NOT NULL,
    attempts smallint NOT NULL DEFAULT 1 CHECK (attempts BETWEEN 1 AND 3),
    narration jsonb CHECK (jsonb_typeof(narration) = 'object'),
    model text,
    prompt_version text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    generated_at timestamptz,
    PRIMARY KEY (device_id, recap_year, pet_kind),
    CHECK (status <> 'ready' OR (narration IS NOT NULL AND model IS NOT NULL AND generated_at IS NOT NULL))
);
ALTER TABLE public.recap_narrations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.recap_narrations FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.recap_narrations TO service_role;

-- Serialize short claim transactions per account; never hold a DB lock during a Claude call.
-- A pending lease survives request disconnects. Only its token can publish the result.
CREATE FUNCTION public.claim_recap_narration(p_device uuid, p_year integer, p_pet text,
    p_facts jsonb, p_token uuid, p_prompt_version text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE prior public.recap_narrations%ROWTYPE;
BEGIN
    IF p_year IS NULL OR p_year <> 2026 OR p_pet IS NULL OR p_pet !~ '^[A-Za-z][A-Za-z0-9]{0,63}$'
        OR p_facts IS NULL OR jsonb_typeof(p_facts) <> 'object' OR octet_length(p_facts::text) > 16000
        OR p_token IS NULL OR p_prompt_version IS NULL OR length(p_prompt_version) NOT BETWEEN 1 AND 80 THEN
        RAISE EXCEPTION 'invalid_recap_request';
    END IF;
    PERFORM 1 FROM public.users WHERE device_id = p_device AND status <> 'banned' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'not_authorized'; END IF;

    SELECT * INTO prior FROM public.recap_narrations
        WHERE device_id = p_device AND recap_year = p_year AND pet_kind = p_pet;
    IF FOUND THEN
        IF prior.status = 'ready' THEN
            RETURN jsonb_build_object('status', 'ready', 'row', to_jsonb(prior) - 'lease_token' - 'lease_until');
        END IF;
        IF prior.lease_until > now() THEN
            RETURN jsonb_build_object('status', prior.status, 'retryAfter',
                CASE WHEN prior.status = 'pending' THEN 3 ELSE ceil(extract(epoch FROM prior.lease_until - now()))::integer END);
        END IF;
        IF prior.attempts >= 3 THEN
            RETURN jsonb_build_object('status', 'failed', 'retryAfter', 0);
        END IF;
    END IF;
    -- Switching pets must not start multiple paid generations simultaneously.
    IF EXISTS (SELECT 1 FROM public.recap_narrations WHERE device_id = p_device
        AND status = 'pending' AND lease_until > now()) THEN
        RETURN jsonb_build_object('status', 'pending', 'retryAfter', 5);
    END IF;

    INSERT INTO public.recap_narrations(device_id, recap_year, pet_kind, facts_json, status,
        lease_token, lease_until, prompt_version)
    VALUES(p_device, p_year, p_pet, p_facts, 'pending', p_token, now() + interval '3 minutes', p_prompt_version)
    ON CONFLICT (device_id, recap_year, pet_kind) DO UPDATE SET
        status = 'pending', lease_token = p_token, lease_until = now() + interval '3 minutes',
        attempts = recap_narrations.attempts + 1, prompt_version = p_prompt_version
    RETURNING * INTO prior;
    -- Retries reuse the first request's snapshot, even if the client sends newer numbers.
    RETURN jsonb_build_object('status', 'generate', 'facts', prior.facts_json);
END $$;

CREATE FUNCTION public.finish_recap_narration(p_device uuid, p_year integer, p_pet text,
    p_token uuid, p_narration jsonb, p_model text)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
    IF p_narration IS NULL OR jsonb_typeof(p_narration) <> 'object'
        OR jsonb_typeof(p_narration->'lines') IS DISTINCT FROM 'object'
        OR jsonb_typeof(p_narration->'persona') IS DISTINCT FROM 'string'
        OR octet_length(p_narration::text) > 20000 OR p_model IS NULL OR length(p_model) NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'invalid_narration';
    END IF;
    UPDATE public.recap_narrations SET status = 'ready', narration = p_narration,
        model = p_model, generated_at = now()
    WHERE device_id = p_device AND recap_year = p_year AND pet_kind = p_pet
        AND status = 'pending' AND lease_token = p_token AND lease_until > now();
    RETURN FOUND;
END $$;

CREATE FUNCTION public.fail_recap_narration(p_device uuid, p_year integer, p_pet text, p_token uuid)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$
    UPDATE public.recap_narrations SET status = 'failed', lease_until = now() + interval '15 minutes'
    WHERE device_id = p_device AND recap_year = p_year AND pet_kind = p_pet
        AND status = 'pending' AND lease_token = p_token;
$$;

REVOKE ALL ON FUNCTION public.claim_recap_narration(uuid,integer,text,jsonb,uuid,text),
    public.finish_recap_narration(uuid,integer,text,uuid,jsonb,text),
    public.fail_recap_narration(uuid,integer,text,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_recap_narration(uuid,integer,text,jsonb,uuid,text),
    public.finish_recap_narration(uuid,integer,text,uuid,jsonb,text),
    public.fail_recap_narration(uuid,integer,text,uuid) TO service_role;
