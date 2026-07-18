-- ============================================================
-- merge_ruler_blocks() — capture an existing live function
-- ============================================================
-- Run this in the Supabase SQL Editor. Idempotent (CREATE OR REPLACE).
--
-- This function already exists in production — confirmed via
-- `select pg_get_functiondef(oid) from pg_proc where proname =
-- 'merge_ruler_blocks';` against the live database — but had no
-- migration file in this repo, unlike find_clan_by_invite_code()
-- (see 0001's header), which got the same "exists live, deliberately
-- undocumented" treatment on purpose. This one wasn't a deliberate
-- omission, just a gap: the client (pushMyRulerToSupabase() in
-- index.html) calls it for Legion Ruler-block sync, and without this
-- file, restoring the schema from migrations alone would silently
-- break that feature. The body below is copied verbatim from the
-- live definition, not rewritten.
--
-- What it does: merges an incoming shared_rulers.blocks array against
-- the stored one, position by position, keeping whichever side has
-- the newer block_updated_at timestamp (or the existing block if the
-- incoming one has no usable timestamp). This is why shared Ruler
-- blocks are deliberately left unencrypted (see SECURITY.md) — a
-- field-by-field server-side merge like this can't operate on
-- ciphertext.
-- ============================================================

create or replace function public.merge_ruler_blocks(p_user_id uuid, p_blocks jsonb)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  existing_blocks jsonb;
  merged jsonb;
  i int;
  block_count int;
  existing_block jsonb;
  incoming_block jsonb;
  existing_ts timestamptz;
  incoming_ts timestamptz;
BEGIN
  -- Refuse to merge into anyone else's row. auth.uid() is the
  -- Supabase-authenticated caller's own id; p_user_id must match it.
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'Not authorized to update this ruler';
  END IF;

  SELECT blocks INTO existing_blocks
  FROM shared_rulers
  WHERE user_id = p_user_id;

  -- No row yet for this user — nothing to merge against, so just
  -- insert the incoming array as the starting state.
  IF existing_blocks IS NULL THEN
    INSERT INTO shared_rulers (user_id, blocks, updated_at)
    VALUES (p_user_id, p_blocks, now())
    ON CONFLICT (user_id) DO UPDATE
      SET blocks = EXCLUDED.blocks, updated_at = now();
    RETURN;
  END IF;

  merged := existing_blocks;
  block_count := LEAST(
    COALESCE(jsonb_array_length(p_blocks), 0),
    COALESCE(jsonb_array_length(existing_blocks), 0)
  );

  -- Merge each position that exists in both arrays.
  FOR i IN 0 .. block_count - 1 LOOP
    incoming_block := p_blocks -> i;
    existing_block := existing_blocks -> i;

    -- Defensive parse: a malformed/missing timestamp on either side
    -- is treated as NULL rather than raising, so one bad timestamp
    -- can't fail the whole merge.
    BEGIN
      incoming_ts := (incoming_block ->> 'block_updated_at')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      incoming_ts := NULL;
    END;
    BEGIN
      existing_ts := (existing_block ->> 'block_updated_at')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      existing_ts := NULL;
    END;

    IF existing_ts IS NULL OR (incoming_ts IS NOT NULL AND incoming_ts > existing_ts) THEN
      merged := jsonb_set(merged, ARRAY[i::text], incoming_block);
    END IF;
    -- else: keep the existing block at this position (incoming was
    -- older, or had no timestamp to justify overwriting a stamped one)
  END LOOP;

  -- If the incoming array is LONGER than the existing one (e.g. the
  -- block count ever changes in the future), append the extra
  -- incoming blocks rather than silently dropping them.
  IF jsonb_array_length(p_blocks) > block_count THEN
    FOR i IN block_count .. jsonb_array_length(p_blocks) - 1 LOOP
      merged := merged || jsonb_build_array(p_blocks -> i);
    END LOOP;
  END IF;

  UPDATE shared_rulers
  SET blocks = merged, updated_at = now()
  WHERE user_id = p_user_id;
END;
$function$
