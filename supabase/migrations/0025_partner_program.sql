-- ============================================================
-- Command Center Partner Program
-- ============================================================
-- Run this in the Supabase SQL Editor.
--
-- Mechanics: a free-tier user opts in and is IMMEDIATELY granted
-- is_paid = true for a 30-day trial (see enable_partner_program()) —
-- "keeps paid tier permanently" / "expires and drops back to free"
-- only makes sense if they're actually ON paid tier during the
-- window, not earning a bonus on top of something else. At the day-30
-- gate (evaluate_partner_program()): >= 3 of their recruits having
-- converted to paid makes it permanent; fewer revokes it.
--
-- A "recruit" is deliberately a NARROW definition, chosen specifically
-- to be hard to game: someone who (a) signed up via this partner's
-- own referral_code (referred_by_user_id, 0024_affiliate_program.sql)
-- AND (b) is a member of a Legion this partner owns, created on or
-- after they opted in. Both conditions matter — referral alone can be
-- spammed with signups that never actually join anything real;
-- Legion membership alone could just be existing contacts added to a
-- pre-existing Legion with no real recruitment involved. Requiring
-- both means a recruit is a real person who both used this partner's
-- link AND was organized into their Legion structure.
-- ============================================================

alter table profiles
  add column if not exists partner_status text check (partner_status in ('active', 'won', 'lost')),
  add column if not exists partner_started_at timestamptz;

-- ---- Lock down the new columns the same way is_paid already is ----
-- profiles_update_own_not_billing (0001_rls_policies.sql) only pinned
-- is_paid before this — without extending it here, a client could
-- directly UPDATE partner_started_at to 31 days in the past and
-- partner_status to 'active', then call evaluate_partner_program()
-- against that faked timeline. Re-created (not ALTERed — Postgres
-- policies aren't editable in place) with the same WITH CHECK shape,
-- now covering all three fields that gate is_paid. Every other
-- column on profiles remains freely self-editable, same as before.
drop policy if exists "profiles_update_own_not_billing" on profiles;
create policy "profiles_update_own_not_billing"
  on profiles for update
  using (id = auth.uid())
  with check (
    id = auth.uid()
    and is_paid is not distinct from (select p.is_paid from profiles p where p.id = auth.uid())
    and partner_status is not distinct from (select p.partner_status from profiles p where p.id = auth.uid())
    and partner_started_at is not distinct from (select p.partner_started_at from profiles p where p.id = auth.uid())
  );

-- ---- enable_partner_program ----
-- Free-tier only (a paid user has nothing to "win"). Grants the
-- 30-day trial immediately. Also ensures a referral_code exists and
-- affiliate_enabled is on — recruitment is tracked through the exact
-- same code the Affiliate Program uses, not a separate mechanism.
create or replace function public.enable_partner_program()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  is_caller_paid boolean;
  current_status text;
  existing_code text;
  new_code text;
  attempt int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT is_paid, partner_status, referral_code INTO is_caller_paid, current_status, existing_code
  FROM profiles WHERE id = auth.uid();

  IF COALESCE(is_caller_paid, false) THEN
    RAISE EXCEPTION 'The Partner Program is for free-tier members working toward paid access — you already have paid access';
  END IF;
  IF current_status = 'active' THEN
    RAISE EXCEPTION 'The Partner Program is already active on your account';
  END IF;

  new_code := existing_code;
  IF new_code IS NULL THEN
    LOOP
      attempt := attempt + 1;
      new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
      EXIT WHEN NOT EXISTS (SELECT 1 FROM profiles WHERE referral_code = new_code);
      IF attempt >= 5 THEN
        RAISE EXCEPTION 'Could not generate a unique referral code, try again';
      END IF;
    END LOOP;
  END IF;

  UPDATE profiles
  SET partner_status = 'active',
      partner_started_at = now(),
      is_paid = true,
      affiliate_enabled = true,
      referral_code = new_code
  WHERE id = auth.uid();
END;
$function$;

-- ---- One thing to verify once this is actually run ----
-- Both queries below assume clans has a `created_at timestamptz`
-- column (Supabase's Table Editor adds one by default to every new
-- table, and clans/clan_members/profiles were created that way per
-- 0001_rls_policies.sql's own note — but that migration never had to
-- read the column, so its presence hasn't actually been exercised by
-- any code in this project until now). If running this migration (or
-- the first real opt-in test) errors with something like "column
-- c.created_at does not exist", that's the one thing to fix: swap
-- `c.created_at` below for whatever the real creation-timestamp
-- column on clans is actually called, in both get_partner_progress()
-- and evaluate_partner_program() (the two conditions must always
-- match exactly, or the displayed numbers could stop matching what
-- actually gates the reward).
--
-- ---- get_partner_progress ----
-- Read-only. Computes recruit_count/conversion_count with the exact
-- same query shape evaluate_partner_program() uses to decide the
-- outcome, so what's displayed can never drift from what actually
-- gates the reward.
create or replace function public.get_partner_progress()
 returns jsonb
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
DECLARE
  started timestamptz;
  status text;
  recruits int;
  conversions int;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('status', null);
  END IF;

  SELECT partner_started_at, partner_status INTO started, status
  FROM profiles WHERE id = auth.uid();

  IF status IS NULL THEN
    RETURN jsonb_build_object('status', null);
  END IF;

  SELECT count(DISTINCT p.id) INTO recruits
  FROM profiles p
  JOIN clan_members cm ON cm.user_id = p.id
  JOIN clans c ON c.id = cm.clan_id
  WHERE p.referred_by_user_id = auth.uid()
    AND c.owner_id = auth.uid()
    AND c.created_at >= started;

  SELECT count(DISTINCT p.id) INTO conversions
  FROM profiles p
  JOIN clan_members cm ON cm.user_id = p.id
  JOIN clans c ON c.id = cm.clan_id
  WHERE p.referred_by_user_id = auth.uid()
    AND p.is_paid = true
    AND c.owner_id = auth.uid()
    AND c.created_at >= started;

  RETURN jsonb_build_object(
    'status', status,
    'started_at', started,
    'recruit_count', COALESCE(recruits, 0),
    'conversion_count', COALESCE(conversions, 0)
  );
END;
$function$;

-- ---- evaluate_partner_program ----
-- The day-30 gate. Lazily checked (no cron infrastructure exists in
-- this project — same reasoning expire_stale_subscription() already
-- established for subscription expiry), called from
-- refreshCurrentUserPaidStatus() on every session start alongside
-- that same function. A no-op unless partner_status is currently
-- 'active' AND at least 30 days have actually passed since
-- partner_started_at (both server-controlled facts a client cannot
-- forge, now that partner_started_at is RLS-locked above).
--
-- Losing does NOT unconditionally strip is_paid — it falls back to
-- whatever a real NOWPayments subscription would independently
-- justify, so a partner who also happens to be a genuine paying
-- subscriber never gets incorrectly cut off just for missing the
-- Partner Program's own target.
create or replace function public.evaluate_partner_program()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  started timestamptz;
  status text;
  conversions int;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN;
  END IF;

  SELECT partner_started_at, partner_status INTO started, status
  FROM profiles WHERE id = auth.uid();

  IF status IS DISTINCT FROM 'active' OR started IS NULL THEN
    RETURN;
  END IF;

  IF now() < started + interval '30 days' THEN
    RETURN;
  END IF;

  SELECT count(DISTINCT p.id) INTO conversions
  FROM profiles p
  JOIN clan_members cm ON cm.user_id = p.id
  JOIN clans c ON c.id = cm.clan_id
  WHERE p.referred_by_user_id = auth.uid()
    AND p.is_paid = true
    AND c.owner_id = auth.uid()
    AND c.created_at >= started;

  IF COALESCE(conversions, 0) >= 3 THEN
    -- Permanent: also clears nowpayments_period_end so
    -- expire_stale_subscription() can never later revoke this —
    -- they didn't pay for a subscription, they earned it outright.
    UPDATE profiles
    SET partner_status = 'won', is_paid = true, nowpayments_period_end = null
    WHERE id = auth.uid();
  ELSE
    UPDATE profiles
    SET partner_status = 'lost',
        is_paid = (nowpayments_period_end IS NOT NULL AND nowpayments_period_end > now())
    WHERE id = auth.uid();
  END IF;
END;
$function$;
