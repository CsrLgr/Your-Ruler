-- ============================================================
-- Scheduling — scope-based redesign (drop + recreate schedule_events)
-- ============================================================
-- Run this in the Supabase SQL Editor. NOT idempotent in the
-- data-preserving sense — this DROPS the existing table. Confirmed
-- with the user before writing this: no real events exist yet, only
-- already-deleted test events from the previous day's build, so a
-- clean drop-and-recreate is the right call here (same precedent
-- 0005_alpha_taxonomy_encryption_ready.sql set when Track Alpha's own
-- taxonomy changed shape — see that file's header for the same
-- reasoning applied there).
--
-- WHAT CHANGED: the original 0017 shape (event_date/start_time/
-- duration_minutes) assumed every event was a fixed-length slot on a
-- single day. The redesigned Scheduling UI lets a user drill through
-- a Track Alpha-style scope hub (Hour/Day/Week/Month/Longer) to pick
-- the event's TIMEFRAME directly — a "Week" event covers a real
-- calendar week, a "Month" event covers a real month, etc. Every
-- event now normalizes to one inclusive [start_date, end_date] day
-- range regardless of scope (start_hour adds precision only when
-- scope = 'hour'), which is what lets every consumer (Ruler-widget
-- annotation, Upcoming list, "does this event touch date X" checks)
-- use one uniform date-range comparison instead of scope-specific
-- branching. See index.html's scheduleComputeRange()-equivalent
-- logic for exactly how each scope's range is derived at save time.
--
-- ENCRYPTION IS UNCHANGED from 0017: only description/notes are
-- encrypted, in one encrypted_data envelope via the existing journal
-- device key (journalEncryptPayload/journalDecryptPayload — see
-- SECURITY.md). title/scope/start_date/end_date/start_hour/category/
-- reminder settings stay plaintext, same reasoning as before — the
-- "what and when" every signed-in device needs for the feature to
-- actually function as a calendar, cross-device.
-- ============================================================

drop table if exists schedule_events;

create table schedule_events (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  scope text not null check (scope in ('hour','day','week','month','longer')),
  start_date text not null,   -- YYYY-MM-DD, inclusive
  end_date text not null,     -- YYYY-MM-DD, inclusive, >= start_date
  start_hour integer,         -- 0-23, only meaningful when scope = 'hour'
  title text not null,
  category text not null default 'Other',
  reminder_offset_minutes integer,
  reminder_shown boolean not null default false,
  encrypted_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint schedule_events_date_order check (end_date >= start_date)
);
alter table schedule_events enable row level security;

create policy "schedule_events_own_only"
  on schedule_events for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create index schedule_events_user_range_idx
  on schedule_events(user_id, start_date, end_date);
