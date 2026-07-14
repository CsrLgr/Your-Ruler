-- ============================================================
-- Alpha rebuild — multi-profile taxonomy + encryption-ready schema
-- ============================================================
-- Run this in the Supabase SQL Editor, same as 0001-0004. Supersedes
-- 0003_alpha_profiles.sql's alpha_profiles/alpha_entries entirely —
-- drops and recreates both rather than ALTERing them, since the
-- Alpha tab was only just introduced and (per the app's own "hold
-- everything back until it's deployed" pattern this whole project has
-- followed) almost certainly has zero real rows in production yet.
-- If that's wrong for your environment, back up alpha_profiles/
-- alpha_entries before running this — it is NOT idempotent in the
-- sense of preserving old data, only in the sense of being safe to
-- re-run (DROP ... IF EXISTS / CREATE ... IF NOT EXISTS throughout).
--
-- ============================================================
-- ENCRYPTION STATUS — UPDATED: this is now real, not stubbed.
-- alphaEncryptString/alphaDecryptString (profile_name) and
-- alphaEncryptPayload/alphaDecryptPayload (encrypted_data) in
-- index.html call real WebCrypto AES-256-GCM. The key is a
-- device-bound, non-extractable CryptoKey (alphaGetOrCreateDeviceKey()
-- in index.html) generated once per (device, signed-in user) and
-- stored in IndexedDB — no passphrase, unlocks automatically on first
-- Alpha use after sign-in. Deliberately NOT derived from the Supabase
-- session/access token: a key derivable from something the auth
-- server itself issues would be recoverable by the server too, which
-- would defeat the point. See SECURITY.md and the header comment
-- above the Alpha JS block for the full model, including the
-- device-bound tradeoff (no cross-device access without a future
-- export/import path). Voice memo audio (alpha_entries via the
-- Relationships module) is encrypted the same way, at the byte level,
-- before it ever reaches Storage — see 0006_alpha_voice_notes_bucket.sql.
--
-- WHAT'S PLAINTEXT ON PURPOSE, EVEN WITH REAL ENCRYPTION LIVE:
--   - category, subcategory: the fixed taxonomy path (e.g.
--     'health' / 'mental.focus'). These are structural labels from a
--     small enum this app defines, not user-authored content, and
--     are needed server-side for RLS scoping and for the client to
--     query "give me profiles under this taxonomy leaf" without
--     downloading and decrypting every profile the user has. This is
--     a deliberate, accepted metadata leak: the server can always see
--     WHAT KINDS of things a user tracks (e.g. "has a Physical Health
--     profile"), never the actual profile name or content.
--   - entry_date: a day-bucket key, same reasoning as every other
--     date-keyed table in this app (see the local-timezone rewrite) —
--     needed for day-indexed queries, carries no content itself.
--   - updated_at / created_at: real timestamps, not content.
--
-- WHAT MUST BE ENCRYPTED (client-side, before it ever reaches
-- Supabase) ONCE REAL ENCRYPTION IS WIRED IN:
--   - profile_name: user-authored (e.g. "Gym Routine", or something
--     far more sensitive under Relationships/Custom). Stored as
--     ciphertext text, not jsonb — it's just an encrypted string, not
--     a structured object.
--   - encrypted_data: everything else about the profile — Output
--     questionnaire setup/baseline/goal, and for alpha_entries, the
--     logged value(s) themselves. jsonb-shaped ciphertext envelope
--     (the app will store something like {iv, ciphertext} in here
--     once wired up, not raw plaintext jsonb).
-- ============================================================

drop table if exists alpha_entries;
drop table if exists alpha_profiles;

-- ---- alpha_profiles ----
-- One row per measurement profile. subcategory encodes everything
-- below category as a dot-joined taxonomy path, since Health goes
-- one level deeper (category/subcategory/dimension) than
-- Relationships and Finances (category/subcategory only) — rather
-- than add a third taxonomy column that's null for 2 of 3
-- categories, the full remaining path lives in one text field, e.g.
-- 'mental.focus', 'physical.motion', 'intimate', 'custom',
-- 'increaseIncome'. See ALPHA_TAXONOMY in index.html for the
-- authoritative tree this encodes paths against.
create table if not exists alpha_profiles (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('health', 'relationships', 'finances')),
  subcategory text not null,
  profile_name text not null,
  encrypted_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table alpha_profiles enable row level security;

drop policy if exists "alpha_profiles_own_only" on alpha_profiles;
create policy "alpha_profiles_own_only"
  on alpha_profiles for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create index if not exists alpha_profiles_category_subcategory_idx
  on alpha_profiles(user_id, category, subcategory);

-- ---- alpha_entries ----
-- One row per logged data point against a profile, from that
-- profile's Input tab (not built yet — this table is schema-ready,
-- not wired to any UI in this pass).
create table if not exists alpha_entries (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  profile_id uuid not null references alpha_profiles(id) on delete cascade,
  entry_date date not null,
  encrypted_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table alpha_entries enable row level security;

drop policy if exists "alpha_entries_own_only" on alpha_entries;
create policy "alpha_entries_own_only"
  on alpha_entries for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create index if not exists alpha_entries_profile_id_idx on alpha_entries(profile_id);
