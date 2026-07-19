-- ============================================================
-- Legions — bump free-tier join cap from 2 to 3
-- ============================================================
-- Run this in the Supabase SQL Editor. Idempotent — drops and
-- recreates the same policy 0001_rls_policies.sql defined, just with
-- the count threshold raised from < 2 to < 3, matching the tier spec:
-- free tier can join up to 3 Legions total, still cannot create one
-- (clans_insert_paid_owner, unchanged, already paid-only). Paid tier
-- stays unlimited either way — the `is_paid` branch of the OR was
-- already uncapped, only the free-tier branch's number changes.
-- ============================================================

drop policy if exists "clan_members_insert_self_capped" on clan_members;
create policy "clan_members_insert_self_capped"
  on clan_members for insert
  with check (
    user_id = auth.uid()
    and (
      exists (select 1 from profiles p where p.id = auth.uid() and p.is_paid = true)
      or (select count(*) from clan_members cm where cm.user_id = auth.uid()) < 3
    )
  );
