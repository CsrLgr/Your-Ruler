-- ============================================================
-- Alpha (Output/Input measurement tracking) — tables + RLS
-- ============================================================
-- Run this in the Supabase SQL Editor, same as 0001/0002. Idempotent.
--
-- Unlike the TradingView webhook tables (0002), both tables here are
-- written by a normal, authenticated client session (the user filling
-- out the Output questionnaire, or logging an Input entry) — there is
-- always a real auth.uid() to check, so plain RLS-protected client
-- inserts/updates work fine. No service_role, no Edge Function needed.
--
-- Strictly own-row-only on both tables, same reasoning as
-- webhook_secrets in 0002: this is personal measurement data, not
-- something with an established "Legion can see it" precedent like
-- profiles/shared_sections, so it defaults private rather than
-- exposed. Revisit if/when Legion-sharing for Alpha is ever asked for.
-- ============================================================

-- ---- alpha_profiles ----
-- One row per measurement profile a user builds via the Output
-- questionnaire (category + subject + goal + how they want to track
-- it). id is generated CLIENT-SIDE (crypto.randomUUID()) rather than
-- left to the column default, so the same profile object can be
-- upserted consistently across localStorage and Supabase without a
-- round-trip to learn the server-assigned id first.
create table if not exists alpha_profiles (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('mind', 'body', 'spirit')),
  subject text not null,
  goal text not null,
  metric_type text not null check (metric_type in ('rating', 'number', 'yesno', 'text')),
  metric_unit text,
  name text not null,
  created_at timestamptz not null default now()
);
alter table alpha_profiles enable row level security;

drop policy if exists "alpha_profiles_own_only" on alpha_profiles;
create policy "alpha_profiles_own_only"
  on alpha_profiles for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---- alpha_entries ----
-- One row per logged data point against a profile, from the Input
-- tab's generated form. entry_date is the LOCAL calendar day (see
-- todayLocalDateString() in index.html) the entry was logged on, not
-- a UTC day — consistent with the rest of the app's day-boundary
-- rewrite. value_text holds whatever the profile's metric_type
-- produced, already formatted as a display string (a rating "7", a
-- number+unit "12 lbs", "Yes"/"No", or free text) — simplest schema
-- that doesn't need a different column per metric type.
create table if not exists alpha_entries (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  profile_id uuid not null references alpha_profiles(id) on delete cascade,
  entry_date date not null,
  value_text text not null,
  created_at timestamptz not null default now()
);
alter table alpha_entries enable row level security;

drop policy if exists "alpha_entries_own_only" on alpha_entries;
create policy "alpha_entries_own_only"
  on alpha_entries for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create index if not exists alpha_entries_profile_id_idx on alpha_entries(profile_id);
