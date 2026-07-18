-- ============================================================
-- find_clan_by_invite_code() — capture an existing live function
-- ============================================================
-- Run this in the Supabase SQL Editor. Idempotent (CREATE OR REPLACE).
--
-- 0001_rls_policies.sql's header deliberately left this function
-- undocumented/untouched, since at the time it could only be
-- confirmed to exist live, not read verbatim (no DB connection
-- available from that environment). It has since been read directly
-- via pg_get_functiondef and confirmed, during an audit of the
-- invite-code join flow, to be exactly what the client's join button
-- needs: a plain exact-match lookup, SECURITY DEFINER so a
-- non-member can look up a clan by code despite clans_select_member
-- otherwise restricting SELECT to owner/members only.
--
-- Capturing it here doesn't change its behavior at all (verbatim
-- copy, CREATE OR REPLACE) — it just closes the same gap
-- 0013_merge_ruler_blocks.sql closed: without this file, restoring
-- the schema from migrations alone would silently break the "Join"
-- button, since nothing else in this repo defines it.
-- ============================================================

CREATE OR REPLACE FUNCTION public.find_clan_by_invite_code(code text)
 RETURNS TABLE(id uuid, name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  select clans.id, clans.name
  from clans
  where clans.invite_code = code;
$function$
