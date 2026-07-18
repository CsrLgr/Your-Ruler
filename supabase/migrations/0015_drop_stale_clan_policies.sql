-- ============================================================
-- Drop stale pre-0001 policies on clans/clan_members
-- ============================================================
-- Run this in the Supabase SQL Editor. Idempotent: safe to re-run if
-- a policy was already dropped or never existed under this name.
--
-- Found during an audit of the invite-code join flow: five policies
-- from before 0001_rls_policies.sql were still active on clans/
-- clan_members, none of which 0004_fix_rls_policy_bypasses.sql
-- targeted (that migration only covers profiles/clan_members/
-- shared_rulers, by 4 specific names — none of these five). Postgres
-- OR's multiple permissive policies together, so any of these being
-- BROADER than their 0001 replacement would have silently undone it,
-- exactly like the bugs 0004 fixed.
--
-- Checked each one's actual qual/with_check against its 0001
-- replacement (confirmed live, 2026-07-17) — all five turned out to
-- be functionally IDENTICAL duplicates, not bypasses:
--   1. "Users can leave a clan (delete their own membership)"
--      (clan_members, DELETE) — qual (user_id = auth.uid()), same as
--      clan_members_delete_own.
--   2. "Clan members can view their clans" (clans, SELECT) — qual
--      (owner_id = auth.uid()) OR is_clan_member(id), where
--      is_clan_member() is confirmed to just be a membership EXISTS
--      check identical in effect to clans_select_member's inline
--      EXISTS subquery.
--   3. "Only paid users can create clans" (clans, INSERT) —
--      with_check byte-for-byte identical to clans_insert_paid_owner.
--   4. "Owner can delete their clan" (clans, DELETE) — qual
--      (owner_id = auth.uid()), same as clans_delete_owner.
--   5. "Owner can update their clan" (clans, UPDATE) — qual
--      (owner_id = auth.uid()), with_check null (Postgres reuses
--      USING as the check when omitted, same effective restriction
--      as clans_update_owner's explicit WITH CHECK).
--
-- Dropped anyway, even though harmless today: exact duplicates under
-- a different name are exactly what let the real 0004 bugs go
-- unnoticed for as long as they did — a reviewer checking "the new
-- policy" has no reason to also check for an old one hiding under an
-- unrelated name. One policy per command per table, going forward.
-- ============================================================

drop policy if exists "Users can leave a clan (delete their own membership)" on clan_members;
drop policy if exists "Clan members can view their clans" on clans;
drop policy if exists "Only paid users can create clans" on clans;
drop policy if exists "Owner can delete their clan" on clans;
drop policy if exists "Owner can update their clan" on clans;
