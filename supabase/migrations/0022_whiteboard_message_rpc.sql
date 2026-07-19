-- ============================================================
-- append_member_whiteboard_message() — fix the broken cross-user
-- whiteboard write
-- ============================================================
-- Run this in the Supabase SQL Editor.
--
-- Found during a security/functionality sweep: the member-detail
-- modal's "Leave a message on their whiteboard" feature (paid tier
-- only) has never actually worked. appendToMemberWhiteboard() in
-- index.html did a direct client-side UPDATE on shared_sections WHERE
-- user_id = <the OTHER person's id> — but shared_sections_update_own
-- (0001_rls_policies.sql) only allows user_id = auth.uid(). The
-- UPDATE silently matched zero rows (no error, no exception — RLS
-- just filters which rows are visible to the statement), so the
-- client showed success and cleared the input while nothing was ever
-- written. A second, compounding bug: even with permission, the
-- client used a bare UPDATE, not an upsert — a member who'd never
-- touched their own whiteboard yet has no shared_sections row at all,
-- so the write would still have matched nothing.
--
-- This RPC does the whole operation server-side: validates the caller
-- is paid tier and a Legion-mate of the target (via is_legion_mate(),
-- 0001), then INSERT ... ON CONFLICT DO UPDATE so it works whether or
-- not the target already has a whiteboard row. is_shared is only set
-- on the INSERT branch (a fresh row defaults to private, matching the
-- app's existing convention) — the ON CONFLICT branch deliberately
-- never touches is_shared, so a sender can never flip the target's
-- own sharing preference just by leaving a message.
-- ============================================================

create or replace function public.append_member_whiteboard_message(p_target_user_id uuid, p_message text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  is_caller_paid boolean;
  existing_data jsonb;
  existing_tasks jsonb;
  new_task jsonb;
  combined jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF p_target_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot send a whiteboard message to yourself';
  END IF;

  IF p_message IS NULL OR btrim(p_message) = '' THEN
    RAISE EXCEPTION 'Message cannot be empty';
  END IF;

  SELECT is_paid INTO is_caller_paid FROM profiles WHERE id = auth.uid();
  IF NOT COALESCE(is_caller_paid, false) THEN
    RAISE EXCEPTION 'Leaving whiteboard messages is a paid feature';
  END IF;

  IF NOT is_legion_mate(p_target_user_id) THEN
    RAISE EXCEPTION 'You can only message a Legion-mate''s whiteboard';
  END IF;

  SELECT data INTO existing_data
  FROM shared_sections
  WHERE user_id = p_target_user_id AND section = 'whiteboard';

  existing_tasks := COALESCE(existing_data -> 'tasks', '[]'::jsonb);
  new_task := jsonb_build_object('text', p_message, 'done', false);
  combined := existing_tasks || jsonb_build_array(new_task);

  INSERT INTO shared_sections (user_id, section, data, is_shared, updated_at)
  VALUES (p_target_user_id, 'whiteboard', jsonb_build_object('tasks', combined), false, now())
  ON CONFLICT (user_id, section) DO UPDATE
    SET data = jsonb_build_object('tasks', combined), updated_at = now();

  RETURN jsonb_build_object('tasks', combined);
END;
$function$;
