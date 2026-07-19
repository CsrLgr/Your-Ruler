-- ============================================================
-- Scheduling — streamlined 2-question flow (drop + recreate
-- schedule_events again)
-- ============================================================
-- Run this in the Supabase SQL Editor. NOT idempotent in the
-- data-preserving sense — this DROPS the existing table. Confirmed
-- with the user before writing this (again): still just their own
-- test events from verifying the previous scope-hub round, nothing
-- real to preserve.
--
-- WHAT CHANGED FROM 0018: the create flow collapsed from a 5-scope
-- hub (Hour/Day/Week/Month/Longer) with Year->Month->Day tile
-- drilling down to 2 questions — "Hour, Day, or Multiple Days?" then
-- "When?" (a direct date input, no more tile navigation) — so:
--   - scope narrows to just ('hour','day','multi'); Week/Month/Longer
--     were really all "a multi-day range" wearing different labels,
--     so there's no need to track which named preset an event was
--     created through — just the actual dates.
--   - end_hour is new: Hour-scoped events previously had no explicit
--     end (just "at this hour"); the streamlined flow lets the user
--     pick an hour RANGE within the day (start hour, then end hour),
--     giving real duration control that didn't exist before.
--
-- ENCRYPTION IS UNCHANGED from 0017/0018: only description/notes are
-- encrypted, in one encrypted_data envelope via the existing journal
-- device key. Everything else stays plaintext for the same
-- cross-device reason already documented in SECURITY.md.
-- ============================================================

drop table if exists schedule_events;

create table schedule_events (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  scope text not null check (scope in ('hour','day','multi')),
  start_date text not null,   -- YYYY-MM-DD, inclusive
  end_date text not null,     -- YYYY-MM-DD, inclusive, >= start_date
  start_hour integer,         -- 0-23, only meaningful when scope = 'hour'
  end_hour integer,           -- 0-23, only meaningful when scope = 'hour', > start_hour
  title text not null,
  category text not null default 'Other',
  reminder_offset_minutes integer,
  reminder_shown boolean not null default false,
  encrypted_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint schedule_events_date_order check (end_date >= start_date),
  constraint schedule_events_hour_order check (end_hour is null or start_hour is null or end_hour > start_hour)
);
alter table schedule_events enable row level security;

create policy "schedule_events_own_only"
  on schedule_events for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create index schedule_events_user_range_idx
  on schedule_events(user_id, start_date, end_date);
