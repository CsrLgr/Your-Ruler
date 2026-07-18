-- ============================================================
-- Live DM delivery — add entry_messages to supabase_realtime
-- ============================================================
-- Run this in the Supabase SQL Editor, same as prior migrations.
-- Idempotent — guarded the same way 0008_clan_messages.sql adds
-- clan_messages to this same publication.
--
-- Without this, DMs only ever show up on login or when the Legions
-- tab is opened (renderInbox()/refreshInboxUnreadCount() re-query on
-- those events) — the RLS/INSERT/SELECT path already works, this
-- just makes an already-open Inbox update live instead of on next
-- poll. See subscribeToInboxRealtime() in index.html.
-- ============================================================

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'entry_messages'
  ) then
    alter publication supabase_realtime add table entry_messages;
  end if;
end $$;
