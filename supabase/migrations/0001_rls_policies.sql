-- ============================================================
-- Command Center — Row Level Security baseline
-- ============================================================
-- Run this in the Supabase SQL Editor (Database > SQL Editor).
-- Idempotent: safe to re-run — every policy is dropped and
-- recreated rather than assuming a clean slate.
--
-- IMPORTANT: this was written from the CLIENT CODE's query
-- patterns (index.html), not from reading your live schema — there
-- is no database connection available from the environment that
-- wrote this. Before running, especially check:
--   - Any existing paid-tier / free-tier-limit logic on
--     clans/clan_members — this migration re-defines equivalent
--     behavior from scratch, matching the error strings the
--     client already handles ("Free tier is limited to 2 clans",
--     a row-level-security violation on clan creation for free
--     users). If you already enforce these some other way (a
--     trigger, say), you may end up with the same rule checked
--     twice, which is redundant but not harmful.
--
-- find_clan_by_invite_code() was checked against the live database
-- and deliberately left untouched — see the note near the "clans"
-- section below for why.
-- ============================================================

-- ---- Helper: are these two users in a Legion (clan) together? ----
-- SECURITY DEFINER so policies can call it without a circular RLS
-- check on clan_members referencing itself.
create or replace function is_legion_mate(target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from clan_members cm1
    join clan_members cm2 on cm1.clan_id = cm2.clan_id
    where cm1.user_id = auth.uid()
      and cm2.user_id = target_user_id
  );
$$;

-- ============================================================
-- profiles  (id, display_name, timezone, is_paid)
-- ============================================================
alter table profiles enable row level security;

drop policy if exists "profiles_select_own_or_legion" on profiles;
create policy "profiles_select_own_or_legion"
  on profiles for select
  using (
    id = auth.uid()
    or is_legion_mate(id)
  );

-- Users can update their own display_name/timezone, but NOT their
-- own is_paid flag: the WITH CHECK requires the submitted is_paid
-- to equal whatever is already stored, so a client-side attempt to
-- flip it is rejected. is_paid changes only via the Supabase
-- dashboard, or a future admin/billing flow with its own privileges.
drop policy if exists "profiles_update_own_not_billing" on profiles;
create policy "profiles_update_own_not_billing"
  on profiles for update
  using (id = auth.uid())
  with check (
    id = auth.uid()
    and is_paid is not distinct from (select p.is_paid from profiles p where p.id = auth.uid())
  );

-- No client-facing INSERT/DELETE policy on purpose: profile rows are
-- created by handle_new_user(), a SECURITY DEFINER trigger on
-- auth.users — confirmed 2026-07 against the live definition, so it
-- bypasses RLS regardless of these policies and needs no INSERT
-- policy of its own. Account deletion is a separate, deliberate
-- flow, not a client DELETE policy.

-- ============================================================
-- clans  (id, name, owner_id, invite_code)
-- ============================================================
alter table clans enable row level security;

drop policy if exists "clans_select_member" on clans;
create policy "clans_select_member"
  on clans for select
  using (
    owner_id = auth.uid()
    or exists (
      select 1 from clan_members cm
      where cm.clan_id = clans.id and cm.user_id = auth.uid()
    )
  );

-- Paid-tier only, matching the client's existing "Creating Legions
-- is a paid feature" error handling on the 42501 / row-level-security
-- error path.
drop policy if exists "clans_insert_paid_owner" on clans;
create policy "clans_insert_paid_owner"
  on clans for insert
  with check (
    owner_id = auth.uid()
    and exists (select 1 from profiles p where p.id = auth.uid() and p.is_paid = true)
  );

drop policy if exists "clans_update_owner" on clans;
create policy "clans_update_owner"
  on clans for update
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

drop policy if exists "clans_delete_owner" on clans;
create policy "clans_delete_owner"
  on clans for delete
  using (owner_id = auth.uid());

-- find_clan_by_invite_code() already exists in production and is
-- LEFT ALONE ON PURPOSE — confirmed 2026-07 against the live
-- definition: SECURITY DEFINER (so the member-only SELECT policy
-- above doesn't break non-member lookups by code) with the same
-- exact-match logic this migration would otherwise write. There is
-- nothing to fix and no reason to touch it, so this migration
-- doesn't redefine it.

-- ============================================================
-- clan_members  (clan_id, user_id)
-- ============================================================
alter table clan_members enable row level security;

drop policy if exists "clan_members_select_own_or_fellow" on clan_members;
create policy "clan_members_select_own_or_fellow"
  on clan_members for select
  using (
    user_id = auth.uid()
    or exists (
      select 1 from clan_members cm2
      where cm2.clan_id = clan_members.clan_id and cm2.user_id = auth.uid()
    )
  );

-- Free tier capped at 2 Legions, matching the client's existing
-- "Free tier is limited to 2 clans" error handling. Paid tier
-- unlimited.
drop policy if exists "clan_members_insert_self_capped" on clan_members;
create policy "clan_members_insert_self_capped"
  on clan_members for insert
  with check (
    user_id = auth.uid()
    and (
      exists (select 1 from profiles p where p.id = auth.uid() and p.is_paid = true)
      or (select count(*) from clan_members cm where cm.user_id = auth.uid()) < 2
    )
  );

drop policy if exists "clan_members_delete_own" on clan_members;
create policy "clan_members_delete_own"
  on clan_members for delete
  using (user_id = auth.uid());

-- ============================================================
-- daily_snapshots  (user_id, snapshot_date, blocks) — fully
-- private, never read by anyone but the owner. No Legion sharing
-- path exists for this table at all.
-- ============================================================
alter table daily_snapshots enable row level security;

drop policy if exists "daily_snapshots_own_only" on daily_snapshots;
create policy "daily_snapshots_own_only"
  on daily_snapshots for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ============================================================
-- shared_rulers  (user_id, blocks)
-- ============================================================
-- SELECT is gated on the SAME is_shared flag the client already
-- uses to decide whether to *display* this data (shared_sections,
-- section = 'ruler') — this closes the gap where a Legion co-member
-- could otherwise read blocks via the API directly even with
-- sharing toggled off, since the client-side check alone doesn't
-- stop a direct API call.
alter table shared_rulers enable row level security;

drop policy if exists "shared_rulers_select_own_or_shared" on shared_rulers;
create policy "shared_rulers_select_own_or_shared"
  on shared_rulers for select
  using (
    user_id = auth.uid()
    or (
      is_legion_mate(user_id)
      and exists (
        select 1 from shared_sections ss
        where ss.user_id = shared_rulers.user_id
          and ss.section = 'ruler'
          and ss.is_shared = true
      )
    )
  );

drop policy if exists "shared_rulers_insert_own" on shared_rulers;
create policy "shared_rulers_insert_own"
  on shared_rulers for insert
  with check (user_id = auth.uid());

drop policy if exists "shared_rulers_update_own" on shared_rulers;
create policy "shared_rulers_update_own"
  on shared_rulers for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "shared_rulers_delete_own" on shared_rulers;
create policy "shared_rulers_delete_own"
  on shared_rulers for delete
  using (user_id = auth.uid());

-- ============================================================
-- shared_sections  (user_id, section, data, is_shared, updated_at)
-- Covers musts / weekly / yearly / accomplish / whiteboard / ruler
-- (the ruler row is a placeholder flag only — real blocks data is
-- shared_rulers above), gated per-row by that row's own is_shared.
-- ============================================================
alter table shared_sections enable row level security;

drop policy if exists "shared_sections_select_own_or_shared" on shared_sections;
create policy "shared_sections_select_own_or_shared"
  on shared_sections for select
  using (
    user_id = auth.uid()
    or (is_legion_mate(user_id) and is_shared = true)
  );

drop policy if exists "shared_sections_insert_own" on shared_sections;
create policy "shared_sections_insert_own"
  on shared_sections for insert
  with check (user_id = auth.uid());

drop policy if exists "shared_sections_update_own" on shared_sections;
create policy "shared_sections_update_own"
  on shared_sections for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "shared_sections_delete_own" on shared_sections;
create policy "shared_sections_delete_own"
  on shared_sections for delete
  using (user_id = auth.uid());

-- ============================================================
-- Storage: journal-images bucket
-- Path convention (from the client): "<user_id>/<timestamp>-<rand>.<ext>"
-- Never shared with Legion-mates — journal images are private, read
-- only via short-lived signed URLs the owner requests.
-- Storage RLS is enabled on storage.objects by Supabase by default;
-- this only adds the bucket-scoped policy.
-- ============================================================
drop policy if exists "journal_images_owner_all" on storage.objects;
create policy "journal_images_owner_all"
  on storage.objects for all
  using (
    bucket_id = 'journal-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'journal-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
