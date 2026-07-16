-- ============================================================
-- Ledgers: carry edited/history/image_paths server-side too
-- ============================================================
-- Run this in the Supabase SQL Editor, same as prior migrations.
-- Idempotent.
--
-- journal_entries (0007_journal_dm.sql) only ever stored
-- text/category/score/date/shared_legion_ids — enough for Legion
-- sharing/DMs, but not enough to fully restore a local entry after
-- it's cleared from the device: an entry's edit history and any
-- attached journal-image paths existed ONLY in localStorage, never
-- synced. That's fine as long as localStorage is never wiped, but it
-- becomes real, permanent data loss the moment a "clear all local
-- data on logout, re-fetch on login" flow exists (see index.html's
-- pullAllUserDataFromSupabase()) — every entry would silently lose
-- its history and images on the very next login.
--
-- These three columns close that gap so journal_entries becomes a
-- COMPLETE mirror of a local entry, not a partial one.
-- ============================================================

alter table journal_entries
  add column if not exists edited boolean not null default false,
  add column if not exists history jsonb not null default '[]'::jsonb,
  add column if not exists image_paths text[] not null default '{}';
