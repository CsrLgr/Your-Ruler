-- ============================================================
-- TradingView webhook integration — tables + RLS
-- ============================================================
-- Run this in the Supabase SQL Editor, same as 0001. Idempotent.
--
-- Also requires:
--   1. Deploying supabase/functions/tradingview-webhook (this
--      migration only creates the tables it reads/writes).
--   2. Setting the Edge Function's SUPABASE_SERVICE_ROLE_KEY — see
--      that function's own header comment for exact steps.
-- ============================================================

-- ---- webhook_secrets ----
-- One shared secret per user, used to validate inbound TradingView
-- payloads. Deliberately its OWN table, not a column on `profiles`:
-- profiles rows are readable by Legion-mates (profiles_select_own_or_legion
-- in 0001), and leaking this secret would let a teammate forge trade
-- alerts against your ledger. This table has no cross-user visibility
-- at all — own row only, full stop.
create table if not exists webhook_secrets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  tradingview_secret text not null,
  updated_at timestamptz not null default now()
);
alter table webhook_secrets enable row level security;

drop policy if exists "webhook_secrets_own_only" on webhook_secrets;
create policy "webhook_secrets_own_only"
  on webhook_secrets for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---- trade_alerts ----
-- One row per TradingView alert fire (open or close). Inserted
-- exclusively by the tradingview-webhook Edge Function using the
-- service_role key — there is no "logged in user" context on an
-- inbound webhook POST from TradingView's servers, so RLS can't be
-- satisfied by a normal client insert. Deliberately no INSERT policy
-- below: a client trying to write its own fake row is correctly
-- rejected, since only service_role bypasses RLS entirely.
create table if not exists trade_alerts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null check (action in ('open', 'close')),
  pair text not null,
  side text,
  price numeric,
  pnl numeric,
  alert_time timestamptz,
  raw jsonb,
  processed boolean not null default false,
  created_at timestamptz not null default now()
);
alter table trade_alerts enable row level security;

drop policy if exists "trade_alerts_select_own" on trade_alerts;
create policy "trade_alerts_select_own"
  on trade_alerts for select
  using (user_id = auth.uid());

-- Client sets processed = true after turning a row into a Ledgers
-- entry, so the next catch-up query doesn't re-process it.
drop policy if exists "trade_alerts_update_own" on trade_alerts;
create policy "trade_alerts_update_own"
  on trade_alerts for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "trade_alerts_delete_own" on trade_alerts;
create policy "trade_alerts_delete_own"
  on trade_alerts for delete
  using (user_id = auth.uid());

-- Deliberately not enabling Realtime on this table: the client only
-- does an on-load/on-login catch-up query (see processTradeAlerts()
-- in index.html), not a live subscription. Alerts fired while the
-- app is closed are still captured — they just get processed the
-- next time it's opened, not instantly. A live-while-open
-- subscription is a reasonable follow-up if that gap matters to you.
