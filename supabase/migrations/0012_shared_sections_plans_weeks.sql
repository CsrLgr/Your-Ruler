-- ============================================================
-- shared_sections: widen the section CHECK constraint for the new
-- 'plansWeeks' section (Plans tab's 4 renameable week goal-boxes +
-- their day boxes/notes — previously had no Supabase sync at all)
-- ============================================================
-- Run this in the Supabase SQL Editor, same as prior migrations.
-- Idempotent (drops and recreates the constraint — supersedes 0011's
-- version of this same constraint).
--
-- Found during a data-flow sweep: "weekly Plans" showing
-- inconsistently after refresh was traced to this data type having
-- literally no push or pull function anywhere in the code — any
-- wipe+repopulate cycle (see pullAllUserDataFromSupabase() in
-- index.html) deleted it with nothing to restore it. is_shared is
-- always false (sectionShareState has no entry for 'plansWeeks') —
-- this is personal planning data, never shown to Legion-mates.
-- ============================================================

alter table shared_sections drop constraint if exists shared_sections_section_check;
alter table shared_sections add constraint shared_sections_section_check
  check (section in (
    'musts', 'whiteboard', 'weekly', 'yearly', 'monthlyFocus',
    'themeYear', 'accomplishMonth', 'ruler', 'accomplish',
    'dailyArchiveFull', 'weeklyArchiveFull',
    'quickLinks', 'sunriseLocation', 'dailyScoreWeights',
    'affiliateLink', 'journalCategories',
    'plansWeeks'
  ));
