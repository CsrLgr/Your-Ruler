-- ============================================================
-- Legion Commander transfer — table, RLS, and RPCs
-- ============================================================
-- Run this in the Supabase SQL Editor.
--
-- "Commander" isn't a stored role — it's just clans.owner_id (see
-- getLegionTitle() in index.html: owner_id match = Commander, paid
-- non-owner = Warlord, everyone else = plain member). Transferring
-- command is therefore just moving owner_id to someone else — but
-- clans_update_owner (0001_rls_policies.sql) deliberately requires
-- WITH CHECK (owner_id = auth.uid()), which blocks a client-side
-- UPDATE from ever setting owner_id to a DIFFERENT user. That's
-- correct as a general safety rail, so the transfer flow goes through
-- three SECURITY DEFINER RPCs instead of a raw client UPDATE, same
-- pattern as merge_ruler_blocks()/find_clan_by_invite_code(): each
-- one does its own auth.uid()-based authorization check internally,
-- then bypasses the restrictive base RLS deliberately to do the one
-- specific, narrow thing it's meant to do.
--
-- No expiry by default (expires_at nullable, NULL = never expires);
-- the client can optionally pass one when initiating. Expiry is
-- checked lazily at accept-time (accept_legion_transfer below) rather
-- than swept by a background job — there's no cron/edge-function
-- infrastructure in this project to run one, and a request nobody
-- ever tries to accept doesn't need to actively transition state on
-- its own; it just needs to correctly refuse acceptance once expired.
-- ============================================================

create table if not exists legion_transfer_requests (
  id uuid primary key default gen_random_uuid(),
  clan_id uuid not null references clans(id) on delete cascade,
  from_user_id uuid not null references auth.users(id) on delete cascade,
  to_user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','rejected','cancelled','expired')),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists legion_transfer_requests_clan_status_idx
  on legion_transfer_requests(clan_id, status);
create index if not exists legion_transfer_requests_to_user_status_idx
  on legion_transfer_requests(to_user_id, status);

alter table legion_transfer_requests enable row level security;

-- Read-only for the two parties involved — every write (create,
-- accept, reject, cancel) goes through an RPC below instead, so
-- there's no client-facing INSERT/UPDATE/DELETE policy at all, same
-- "no client write policy, all writes via SECURITY DEFINER" shape
-- profiles already uses for its own row (see 0001's note on
-- handle_new_user()).
drop policy if exists "legion_transfer_requests_select_party" on legion_transfer_requests;
create policy "legion_transfer_requests_select_party"
  on legion_transfer_requests for select
  using (from_user_id = auth.uid() or to_user_id = auth.uid());

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'legion_transfer_requests'
  ) then
    alter publication supabase_realtime add table legion_transfer_requests;
  end if;
end $$;

-- ---- initiate_legion_transfer ----
-- Caller must be the clan's current owner; target must be a paid-tier
-- member of the SAME clan, not the caller themselves; and there must
-- be no other pending request for this clan already (one at a time —
-- the commander cancels or waits out the existing one before starting
-- another, rather than silently superseding it).
create or replace function public.initiate_legion_transfer(p_clan_id uuid, p_to_user_id uuid, p_expires_at timestamptz default null)
 returns legion_transfer_requests
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  result legion_transfer_requests;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM clans WHERE id = p_clan_id AND owner_id = auth.uid()) THEN
    RAISE EXCEPTION 'Only the Legion Commander can initiate a command transfer';
  END IF;

  IF p_to_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot transfer command to yourself';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM clan_members cm
    JOIN profiles p ON p.id = cm.user_id
    WHERE cm.clan_id = p_clan_id AND cm.user_id = p_to_user_id AND p.is_paid = true
  ) THEN
    RAISE EXCEPTION 'Command can only be transferred to a paid-tier Legion member';
  END IF;

  IF EXISTS (SELECT 1 FROM legion_transfer_requests WHERE clan_id = p_clan_id AND status = 'pending') THEN
    RAISE EXCEPTION 'A command transfer is already pending for this Legion';
  END IF;

  INSERT INTO legion_transfer_requests (clan_id, from_user_id, to_user_id, expires_at)
  VALUES (p_clan_id, auth.uid(), p_to_user_id, p_expires_at)
  RETURNING * INTO result;

  RETURN result;
END;
$function$;

-- ---- accept_legion_transfer ----
-- Only the named recipient, only while still pending and unexpired,
-- and only if they're STILL a paid-tier member of the clan right now
-- (re-checked at accept-time, not trusted from initiate-time — tier
-- status or membership could have changed in between). FOR UPDATE
-- locks the row for the duration of this check-then-act so two
-- concurrent accept attempts on the same request can't both succeed.
create or replace function public.accept_legion_transfer(p_request_id uuid)
 returns boolean
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  req legion_transfer_requests;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO req FROM legion_transfer_requests WHERE id = p_request_id FOR UPDATE;

  IF req IS NULL THEN
    RAISE EXCEPTION 'Transfer request not found';
  END IF;
  IF req.to_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Not authorized to accept this transfer';
  END IF;
  IF req.status <> 'pending' THEN
    RAISE EXCEPTION 'This transfer request is no longer pending';
  END IF;
  IF req.expires_at IS NOT NULL AND req.expires_at < now() THEN
    UPDATE legion_transfer_requests SET status = 'expired', resolved_at = now() WHERE id = p_request_id;
    RAISE EXCEPTION 'This transfer request has expired';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM clan_members cm
    JOIN profiles p ON p.id = cm.user_id
    WHERE cm.clan_id = req.clan_id AND cm.user_id = auth.uid() AND p.is_paid = true
  ) THEN
    RAISE EXCEPTION 'You must be a paid-tier member of this Legion to accept command';
  END IF;

  UPDATE clans SET owner_id = auth.uid() WHERE id = req.clan_id;
  UPDATE legion_transfer_requests SET status = 'accepted', resolved_at = now() WHERE id = p_request_id;

  RETURN true;
END;
$function$;

-- ---- reject_legion_transfer ----
-- Only the named recipient, only while still pending. Rejecting an
-- already-expired request is still allowed (harmless either way,
-- gives the recipient a clean way to dismiss it from their own view).
create or replace function public.reject_legion_transfer(p_request_id uuid)
 returns boolean
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  req legion_transfer_requests;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO req FROM legion_transfer_requests WHERE id = p_request_id FOR UPDATE;

  IF req IS NULL THEN
    RAISE EXCEPTION 'Transfer request not found';
  END IF;
  IF req.to_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Not authorized to reject this transfer';
  END IF;
  IF req.status <> 'pending' THEN
    RAISE EXCEPTION 'This transfer request is no longer pending';
  END IF;

  UPDATE legion_transfer_requests SET status = 'rejected', resolved_at = now() WHERE id = p_request_id;
  RETURN true;
END;
$function$;

-- ---- cancel_legion_transfer ----
-- Lets the ORIGINATING commander back out of their own still-pending
-- request (e.g. picked the wrong person) without waiting for the
-- target to act — otherwise the one-pending-per-clan rule in
-- initiate_legion_transfer would leave them stuck until it's accepted
-- or rejected by someone else's choice.
create or replace function public.cancel_legion_transfer(p_request_id uuid)
 returns boolean
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  req legion_transfer_requests;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO req FROM legion_transfer_requests WHERE id = p_request_id FOR UPDATE;

  IF req IS NULL THEN
    RAISE EXCEPTION 'Transfer request not found';
  END IF;
  IF req.from_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Not authorized to cancel this transfer';
  END IF;
  IF req.status <> 'pending' THEN
    RAISE EXCEPTION 'This transfer request is no longer pending';
  END IF;

  UPDATE legion_transfer_requests SET status = 'cancelled', resolved_at = now() WHERE id = p_request_id;
  RETURN true;
END;
$function$;
