-- ============================================================
-- Scheduling — schedule_events (Plans tab "+ Schedule Event")
-- ============================================================
-- Run this in the Supabase SQL Editor, same as prior migrations.
-- Idempotent.
--
-- ENCRYPTION: title/date/time/duration/category/reminder settings are
-- PLAINTEXT on purpose — this is the "what and when" data every
-- signed-in device needs to actually function as a calendar. Only
-- free-text description/notes are sensitive enough to encrypt, so
-- those two are folded into ONE encrypted_data jsonb envelope via the
-- EXISTING journal device key (journalEncryptionKey/
-- journalEncryptPayload/journalDecryptPayload in index.html — see
-- SECURITY.md). No new key is introduced for this feature.
--
-- That key is device-bound and non-extractable (same tradeoff
-- SECURITY.md already documents for Journal encryption) — an event's
-- description/notes encrypted on one device will not decrypt on
-- another signed-in device. This is a deliberate, accepted limitation
-- scoped to just those two fields; title/date/time/duration/category
-- stay plaintext specifically so the calendar itself still works
-- correctly cross-device even though those two fields don't.
--
-- NEVER SHARED TO A LEGION: unlike journal_entries/shared_sections,
-- this table has no is_shared/shared_legion_ids concept at all — RLS
-- below is plain own-row-only, matching alpha_profiles/alpha_entries
-- exactly (0005_alpha_taxonomy_encryption_ready.sql).
--
-- REALTIME: deliberately NOT added to the supabase_realtime
-- publication (contrast 0008_clan_messages.sql/
-- 0014_entry_messages_realtime.sql, both added because a DIFFERENT
-- user's client needs to see changes live). schedule_events only ever
-- needs to reach the SAME user's other devices, and pull-on-login via
-- pullAllUserDataFromSupabase() is sufficient for that, same as Ruler
-- blocks already work without Realtime.
-- ============================================================

create table if not exists schedule_events (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  event_date text not null,
  start_time text not null,
  duration_minutes integer not null default 60,
  title text not null,
  category text not null default 'Other',
  reminder_offset_minutes integer,
  reminder_shown boolean not null default false,
  encrypted_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table schedule_events enable row level security;

drop policy if exists "schedule_events_own_only" on schedule_events;
create policy "schedule_events_own_only"
  on schedule_events for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create index if not exists schedule_events_user_date_idx
  on schedule_events(user_id, event_date);
