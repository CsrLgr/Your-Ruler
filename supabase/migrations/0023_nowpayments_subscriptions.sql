-- ============================================================
-- Subscription payments — Phase 1 (checkout + is_paid lifecycle)
-- Provider: NOWPayments (USDC), not Stripe.
-- ============================================================
-- Run this in the Supabase SQL Editor. See NOWPAYMENTS_SETUP.md for
-- the Dashboard-side setup (Plan, IPN secret, API key) this schema
-- supports.
--
-- profiles.nowpayments_subscription_id: set by the nowpayments-
-- webhook Edge Function (service_role, bypasses RLS deliberately —
-- see profiles_update_own_not_billing in 0001_rls_policies.sql,
-- which already blocks a client from touching is_paid directly; this
-- column is equally not client-writable — nothing in index.html ever
-- sends it, it's populated exclusively by create-payment at
-- subscription-creation time and read back by the webhook to resolve
-- which profile a given payment belongs to).
--
-- Unlike Stripe, NOWPayments has no persistent "Customer" object to
-- link to (a subscription is created directly against an email each
-- time), so there's no equivalent of a customer-id column here — the
-- subscription id alone is enough to resolve a payment back to a user.
--
-- nowpayments_period_end: closes a real gap Stripe's model didn't
-- have. A Stripe subscription auto-charges a stored card and fires
-- customer.subscription.deleted the moment that stops working —
-- there's an authoritative "this is now cancelled" signal. Crypto has
-- no stored instrument to auto-charge; NOWPayments' "subscription" is
-- a recurring INVOICE the payer has to actively pay again each
-- interval. There is no "they stopped paying" webhook — the only
-- observable fact is "the next finished payment for this interval
-- never arrived." Rather than needing a cron job (this project has
-- no scheduled-task infrastructure) to notice that, nowpayments-
-- webhook stamps this column with "when the CURRENT paid period ends"
-- on every finished payment, and expire_stale_subscription() (below)
-- lazily self-heals it the next time the owning user's own session
-- checks their tier — see refreshCurrentUserPaidStatus() in
-- index.html, which now calls it before reading is_paid.
alter table profiles
  add column if not exists nowpayments_subscription_id text,
  add column if not exists nowpayments_period_end timestamptz;

create unique index if not exists profiles_nowpayments_subscription_id_idx
  on profiles(nowpayments_subscription_id) where nowpayments_subscription_id is not null;

-- ---- payment_webhook_events_processed ----
-- Generalized name (was written Stripe-specific, renamed — this
-- table was never applied under its old shape, so this is a clean
-- rewrite, not a migration-on-top-of-a-migration). Same idempotency
-- purpose as before: a payment gateway can redeliver the same
-- notification, and this table is checked/inserted into before any
-- handler runs so a duplicate delivery is a harmless no-op.
--
-- NOWPayments' IPN callback fires once per STATUS CHANGE on a
-- payment (waiting -> confirming -> confirmed -> finished, etc.), not
-- once per payment overall — so event_id is populated by the webhook
-- as `<payment_id>:<payment_status>`, not the bare payment_id alone.
-- That's what makes "this exact payment reaching this exact status"
-- the idempotency unit: a redelivered "finished" callback for a
-- payment is correctly deduped, while the earlier "confirming"/
-- "confirmed" callbacks for that SAME payment_id are still each their
-- own distinct, legitimate row.
--
-- No RLS policies at all (RLS enabled, zero grants) — no legitimate
-- client access whatsoever, read or write. Only the webhook function
-- (service_role, bypasses RLS entirely) ever touches it.
create table if not exists payment_webhook_events_processed (
  event_id text primary key,
  created_at timestamptz not null default now()
);
alter table payment_webhook_events_processed enable row level security;

-- ---- expire_stale_subscription ----
-- Safe to expose to any authenticated caller despite being SECURITY
-- DEFINER (which normally means "bypasses RLS, be careful") — it only
-- ever operates on auth.uid()'s OWN row (hardcoded, not a parameter,
-- so there's no way to target anyone else's), and it can only ever
-- move is_paid from true to false, never the other way. A malicious
-- or buggy caller can only hurt themselves by downgrading their own
-- access early, which is a no-op if they weren't paid anyway and
-- immediately fixable by a real payment if they were — the one thing
-- it can never do is grant paid status, so it doesn't need the same
-- scrutiny profiles_update_own_not_billing's RLS gives a real
-- self-upgrade attempt.
create or replace function public.expire_stale_subscription()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN;
  END IF;

  UPDATE profiles
  SET is_paid = false
  WHERE id = auth.uid()
    AND is_paid = true
    AND nowpayments_period_end IS NOT NULL
    AND nowpayments_period_end < now();
END;
$function$;
