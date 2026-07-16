-- ============================================================
-- shared_sections: widen the section CHECK constraint for 5 new
-- personal-settings sections (Quick Links, Sunrise location, Daily
-- Score Weights, Affiliate Link, Journal categories)
-- ============================================================
-- Run this in the Supabase SQL Editor, same as prior migrations.
-- Idempotent (drops and recreates the constraint rather than
-- assuming its current definition — supersedes 0010's version of
-- this same constraint).
--
-- These 5 settings previously had no Supabase sync at all — pure
-- localStorage, wiped on logout with no way to get them back (see
-- pullAllUserDataFromSupabase() in index.html). None of them are
-- security-sensitive (unlike the Telegram bot token, which stays
-- local-only on purpose — see SECURITY.md), so there's no reason not
-- to back them up the same way Musts/Whiteboard/Yearly/etc. already
-- are. is_shared is always false for all 5 (sectionShareState has no
-- entry for them) — these are personal settings, never shown to
-- Legion-mates.
-- ============================================================

alter table shared_sections drop constraint if exists shared_sections_section_check;
alter table shared_sections add constraint shared_sections_section_check
  check (section in (
    'musts', 'whiteboard', 'weekly', 'yearly', 'monthlyFocus',
    'themeYear', 'accomplishMonth', 'ruler', 'accomplish',
    'dailyArchiveFull', 'weeklyArchiveFull',
    'quickLinks', 'sunriseLocation', 'dailyScoreWeights',
    'affiliateLink', 'journalCategories'
  ));
