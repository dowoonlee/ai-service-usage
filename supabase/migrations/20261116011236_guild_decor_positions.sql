-- Preserve existing slots, donations and purchases; NULL coordinates use the legacy slot position.
ALTER TABLE public.guild_furniture
    ADD COLUMN position_x integer,
    ADD COLUMN position_y integer,
    ADD COLUMN position_version uuid NOT NULL DEFAULT gen_random_uuid(),
    ADD CONSTRAINT guild_decor_position_bounds CHECK (
        (position_x IS NULL AND position_y IS NULL) OR
        (position_x IS NOT NULL AND position_y IS NOT NULL AND position_x BETWEEN 8 AND 272 AND position_y BETWEEN 16 AND 140)
    );

CREATE FUNCTION public.guild_decor_position_version()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
    NEW.position_version := gen_random_uuid();
    -- Old clients can still replace a slot. A new purchase must start at the slot's default position.
    IF NEW.item_kind IS DISTINCT FROM OLD.item_kind OR NEW.purchased_at IS DISTINCT FROM OLD.purchased_at THEN
        NEW.position_x := NULL;
        NEW.position_y := NULL;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER guild_decor_position_version BEFORE UPDATE ON public.guild_furniture
    FOR EACH ROW EXECUTE FUNCTION public.guild_decor_position_version();

CREATE FUNCTION public.move_guild_decor(p_device uuid, p_guild uuid, p_slot integer,
    p_version uuid, p_x integer, p_y integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE item public.guild_furniture%ROWTYPE; is_wall boolean; half_width integer;
BEGIN
    PERFORM 1 FROM public.guild_members m JOIN public.users u ON u.device_id = m.device_id
        WHERE m.device_id = p_device AND m.guild_id = p_guild AND u.status <> 'banned' FOR SHARE OF m;
    IF NOT FOUND THEN RAISE EXCEPTION 'not_in_guild'; END IF;
    SELECT * INTO item FROM public.guild_furniture
        WHERE guild_id = p_guild AND slot_id = p_slot FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'decor_not_found'; END IF;
    IF p_version IS NULL OR item.position_version <> p_version THEN RAISE EXCEPTION 'decor_changed'; END IF;
    is_wall := item.item_kind IN ('SMALL_PAINTING', 'SMALL_PAINTING_2', 'LARGE_PAINTING', 'HANGING_PLANT',
        'XMAS_LIGHTS', 'XMAS_BANNER', 'XMAS_WREATH');
    IF NOT is_wall AND item.item_kind NOT IN ('PLANT', 'PLANT_2', 'CACTUS', 'POT', 'BIN', 'COFFEE_TABLE',
        'CHRISTMAS_TREE', 'SNOWMAN', 'GIFT_BOXES') THEN RAISE EXCEPTION 'invalid_decor_kind'; END IF;
    half_width := CASE WHEN item.item_kind IN ('LARGE_PAINTING','COFFEE_TABLE','XMAS_LIGHTS','XMAS_BANNER') THEN 16
        WHEN item.item_kind = 'SNOWMAN' THEN 10 ELSE 8 END;
    IF p_x IS NULL OR p_y IS NULL OR p_x < half_width OR p_x > 280 - half_width
        OR (is_wall AND p_y NOT BETWEEN 32 AND 60)
        OR (NOT is_wall AND p_y NOT IN (84,112,140)) THEN RAISE EXCEPTION 'invalid_decor_position'; END IF;
    UPDATE public.guild_furniture SET position_x = p_x, position_y = p_y
        WHERE guild_id = p_guild AND slot_id = p_slot RETURNING * INTO item;
    RETURN jsonb_build_object('x', item.position_x, 'y', item.position_y, 'version', item.position_version);
END $$;

REVOKE ALL ON FUNCTION public.guild_decor_position_version(),
    public.move_guild_decor(uuid,uuid,integer,uuid,integer,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guild_decor_position_version(),
    public.move_guild_decor(uuid,uuid,integer,uuid,integer,integer) TO service_role;
