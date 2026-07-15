-- ============================================================
-- Legion group chat (clan_messages) + Realtime
-- ============================================================
-- Run this in the Supabase SQL Editor, same as prior migrations.
-- Idempotent.
--
-- One row per message, one shared room per Legion (clan_id) — every
-- current member can read the whole history and post to it. No
-- edit/delete policy: messages are immutable once sent, same
-- philosophy as trade_alerts/entry_messages.
-- ============================================================

create table if not exists clan_messages (
  id uuid primary key default gen_random_uuid(),
  clan_id uuid not null references clans(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  sender_name text not null,
  text text not null,
  created_at timestamptz not null default now()
);
alter table clan_messages enable row level security;

drop policy if exists "clan_messages_select_member" on clan_messages;
create policy "clan_messages_select_member"
  on clan_messages for select
  using (
    exists (
      select 1 from clan_members cm
      where cm.clan_id = clan_messages.clan_id and cm.user_id = auth.uid()
    )
  );

-- A message can only be posted by its own sender, and only into a
-- Legion that sender actually belongs to (not just any clan_id).
drop policy if exists "clan_messages_insert_member" on clan_messages;
create policy "clan_messages_insert_member"
  on clan_messages for insert
  with check (
    sender_id = auth.uid()
    and exists (
      select 1 from clan_members cm
      where cm.clan_id = clan_messages.clan_id and cm.user_id = auth.uid()
    )
  );

-- ---- Realtime ----
-- The client subscribes via postgres_changes (see selectClanForChat()
-- in index.html) — this table has to be added to the supabase_realtime
-- publication for that to fire. Guarded so re-running this migration
-- doesn't error if it's already been added.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'clan_messages'
  ) then
    alter publication supabase_realtime add table clan_messages;
  end if;
end $$;
