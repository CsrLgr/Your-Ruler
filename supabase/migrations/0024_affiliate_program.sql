-- ============================================================
-- Affiliate program — Phase 2
-- ============================================================
-- Run this in the Supabase SQL Editor.
--
-- Deliberately lean on profiles rather than a separate affiliate_
-- accounts table (unlike the Stripe-Connect-oriented Phase 2 this
-- superseded, back when the payment provider was still Stripe) — an
-- affiliate here just needs a referral code and a payout wallet
-- address, both single values, no onboarding-flow state to track.
--
-- referred_by_user_id: set ONCE, by record_referral() below, first
-- attribution wins (a person can only ever have one referrer). Plain
-- column instead of a separate referrals table for the same
-- lean-on-profiles reasoning above.
--
-- wallet_address_encrypted: same device-bound AES-256-GCM model
-- Ledgers already uses (journalEncryptionKey/journalEncryptPayload in
-- index.html) — jsonb {iv, ciphertext} envelope, not plaintext.
-- Encryption happens client-side before this column is ever written;
-- Postgres/Supabase only ever sees ciphertext. Combined with
-- connect-src being HTTPS-only (see the CSP meta tag), that's
-- "encrypted at rest" (this column) and "encrypted in transit"
-- (TLS) — the address is never plaintext outside the browser that
-- owns the device key.
alter table profiles
  add column if not exists affiliate_enabled boolean not null default false,
  add column if not exists referral_code text,
  add column if not exists wallet_address_encrypted jsonb,
  add column if not exists referred_by_user_id uuid references auth.users(id);

create unique index if not exists profiles_referral_code_idx
  on profiles(referral_code) where referral_code is not null;

-- ============================================================
-- affiliate_commissions — what's owed to a referrer, one row per
-- converted payment (first payment AND every renewal, same
-- "every successful payment is an opportunity" reasoning
-- nowpayments-webhook's invoice.paid handler already uses for
-- is_paid itself).
-- ============================================================
-- status is 'pending' for everything right now — there is no payout
-- automation yet (a wallet address is captured so that step has
-- somewhere to send to, later), so every row just accumulates as
-- "owed" until a real payout mechanism exists. This table is already
-- shaped to support that later without a schema change: a payout run
-- would just flip matching rows to 'paid' and stamp when.
create table if not exists affiliate_commissions (
  id uuid primary key default gen_random_uuid(),
  referrer_user_id uuid not null references auth.users(id) on delete cascade,
  referred_user_id uuid not null references auth.users(id) on delete cascade,
  payment_reference text not null,
  amount numeric,
  currency text not null default 'USD',
  status text not null default 'pending' check (status in ('pending', 'paid')),
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

-- Idempotency: the webhook's own event-level gate
-- (payment_webhook_events_processed) already stops a duplicate
-- 'finished'/invoice.paid delivery from reaching this far twice, but
-- this is cheap, real defense-in-depth against ever double-crediting
-- a referrer for the same payment specifically — same "belt and
-- suspenders" reasoning profiles_update_own_not_billing's own
-- redundant-looking check already models elsewhere in this schema.
create unique index if not exists affiliate_commissions_payment_reference_idx
  on affiliate_commissions(payment_reference);

create index if not exists affiliate_commissions_referrer_idx
  on affiliate_commissions(referrer_user_id);

alter table affiliate_commissions enable row level security;

-- A referrer can see their own earned commissions. Deliberately NOT
-- visible to the referred_user_id side — the person who signed up
-- doesn't need to see what commission their own payment generated
-- for someone else.
drop policy if exists "affiliate_commissions_select_referrer" on affiliate_commissions;
create policy "affiliate_commissions_select_referrer"
  on affiliate_commissions for select
  using (referrer_user_id = auth.uid());

-- No client-facing INSERT/UPDATE/DELETE at all — every row is
-- created by nowpayments-webhook (service_role), same "no client
-- write policy, all writes via a controlled path" shape this schema
-- already uses for payment_webhook_events_processed.

-- ---- enable_affiliate_program ----
-- Paid-tier check happens here too (not just in the Settings UI),
-- and code generation + uniqueness both happen server-side so a
-- client never needs write access to referral_code directly, and a
-- collision is retried automatically rather than surfacing as an
-- error the UI would have to handle.
create or replace function public.enable_affiliate_program()
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  is_caller_paid boolean;
  existing_code text;
  new_code text;
  attempt int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT is_paid, referral_code INTO is_caller_paid, existing_code
  FROM profiles WHERE id = auth.uid();

  IF NOT COALESCE(is_caller_paid, false) THEN
    RAISE EXCEPTION 'The affiliate program is a paid feature';
  END IF;

  IF existing_code IS NOT NULL THEN
    UPDATE profiles SET affiliate_enabled = true WHERE id = auth.uid();
    RETURN existing_code;
  END IF;

  LOOP
    attempt := attempt + 1;
    new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    BEGIN
      UPDATE profiles SET affiliate_enabled = true, referral_code = new_code WHERE id = auth.uid();
      RETURN new_code;
    EXCEPTION WHEN unique_violation THEN
      IF attempt >= 5 THEN
        RAISE EXCEPTION 'Could not generate a unique referral code, try again';
      END IF;
      -- loop and retry with a fresh random code
    END;
  END LOOP;
END;
$function$;

-- ---- record_referral ----
-- Called once, client-side, the first time a signed-in session with a
-- pending ?ref= code runs (see index.html). SECURITY DEFINER because
-- looking up "who owns this code" needs to read a stranger's profile
-- row, which profiles_select_own_or_legion (0001) correctly doesn't
-- allow directly — same reasoning find_clan_by_invite_code already
-- established for invite codes. First-attribution-wins (the WHERE
-- referred_by_user_id IS NULL guard) and self-referral is rejected.
create or replace function public.record_referral(p_referral_code text)
 returns boolean
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  referrer_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;

  SELECT id INTO referrer_id
  FROM profiles
  WHERE referral_code = p_referral_code AND affiliate_enabled = true;

  IF referrer_id IS NULL OR referrer_id = auth.uid() THEN
    RETURN false;
  END IF;

  UPDATE profiles
  SET referred_by_user_id = referrer_id
  WHERE id = auth.uid() AND referred_by_user_id IS NULL;

  RETURN FOUND;
END;
$function$;
