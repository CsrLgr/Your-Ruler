-- ============================================================
-- TRW University link (Settings + Track Alpha -> Finances -> Increase Income)
-- ============================================================
-- Run this in the Supabase SQL Editor.
--
-- Plain text, not encrypted — this is a link a user WANTS shared and
-- clicked (their own TRW affiliate link, or nobody's if they leave it
-- blank), not private content. No RLS change needed: the only UPDATE
-- policy on profiles (profiles_update_own_not_billing, extended most
-- recently by 0025_partner_program.sql) only pins is_paid/
-- partner_status/partner_started_at — every other column, this one
-- included, is already freely self-editable by its own row's owner.
-- ============================================================

alter table profiles
  add column if not exists trw_link text;
