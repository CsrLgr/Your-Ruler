-- ============================================================
-- Ledgers: Legion-scoped entry sharing + entry-to-DM sending
-- ============================================================
-- Run this in the Supabase SQL Editor, same as prior migrations.
-- Idempotent.
--
-- Two new tables:
--   1. journal_entries  — a synced copy of each local Journal entry,
--      so a specific Legion (not "any Legion-mate everywhere," which
--      is all the existing shared_sections/is_shared model supports)
--      can be granted read access via shared_legion_ids. Entries stay
--      local-first (localStorage remains the source of truth for the
--      owner's own device); this table only exists so OTHER people's
--      clients have something to read.
--   2. entry_messages   — one row per (sender, recipient) DM of a
--      Journal entry's content. Sending "to a Legion" fans out to one
--      row per member client-side; there is no broadcast/group-row
--      concept here, matching every other table in this app.
-- ============================================================

-- ============================================================
-- journal_entries  (id, user_id, date, created_at, text, category,
--                    score, shared_legion_ids, updated_at)
-- ============================================================
create table if not exists journal_entries (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  entry_date text not null,
  entry_created_at timestamptz not null,
  text text not null,
  category text,
  score numeric,
  shared_legion_ids uuid[] not null default '{}',
  updated_at timestamptz not null default now()
);
alter table journal_entries enable row level security;

drop policy if exists "journal_entries_select_own_or_shared" on journal_entries;
create policy "journal_entries_select_own_or_shared"
  on journal_entries for select
  using (
    user_id = auth.uid()
    or (
      array_length(shared_legion_ids, 1) > 0
      and exists (
        select 1 from clan_members cm
        where cm.user_id = auth.uid()
          and cm.clan_id = any(shared_legion_ids)
      )
    )
  );

drop policy if exists "journal_entries_insert_own" on journal_entries;
create policy "journal_entries_insert_own"
  on journal_entries for insert
  with check (user_id = auth.uid());

drop policy if exists "journal_entries_update_own" on journal_entries;
create policy "journal_entries_update_own"
  on journal_entries for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "journal_entries_delete_own" on journal_entries;
create policy "journal_entries_delete_own"
  on journal_entries for delete
  using (user_id = auth.uid());

-- ============================================================
-- entry_messages  (id, sender_id, recipient_id, sender_name,
--                   entry_date, entry_category, entry_text,
--                   created_at, read)
-- ============================================================
-- sender_name is denormalized (copied from profiles.display_name at
-- send time) so the recipient's inbox can show who it's from without
-- needing its own SELECT policy on the sender's profile beyond what
-- profiles_select_own_or_legion (0001) already grants — which it does,
-- since sender/recipient are Legion-mates by the INSERT check below —
-- but denormalizing avoids an extra round-trip per inbox row.
create table if not exists entry_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  sender_name text not null,
  entry_date text,
  entry_category text,
  entry_text text not null,
  created_at timestamptz not null default now(),
  read boolean not null default false
);
alter table entry_messages enable row level security;

drop policy if exists "entry_messages_select_recipient_or_sender" on entry_messages;
create policy "entry_messages_select_recipient_or_sender"
  on entry_messages for select
  using (
    recipient_id = auth.uid()
    or sender_id = auth.uid()
  );

-- A DM can only be sent to someone you actually share a Legion with —
-- reuses the same is_legion_mate() helper from 0001 that already backs
-- shared_sections/shared_rulers.
drop policy if exists "entry_messages_insert_legion_mate" on entry_messages;
create policy "entry_messages_insert_legion_mate"
  on entry_messages for insert
  with check (
    sender_id = auth.uid()
    and is_legion_mate(recipient_id)
  );

-- Recipient can mark their own inbox rows read; nothing else is
-- editable (message content isn't meant to change after sending).
drop policy if exists "entry_messages_update_recipient_read" on entry_messages;
create policy "entry_messages_update_recipient_read"
  on entry_messages for update
  using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

drop policy if exists "entry_messages_delete_recipient" on entry_messages;
create policy "entry_messages_delete_recipient"
  on entry_messages for delete
  using (recipient_id = auth.uid());
