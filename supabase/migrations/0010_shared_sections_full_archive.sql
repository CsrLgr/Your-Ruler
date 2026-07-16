-- ============================================================
-- shared_sections: widen the section CHECK constraint for the two
-- new full-archive sections (dailyArchiveFull, weeklyArchiveFull)
-- ============================================================
-- Run this in the Supabase SQL Editor, same as prior migrations.
-- Idempotent (drops and recreates the constraint rather than
-- assuming its current definition).
--
-- shared_sections.section already has a CHECK constraint enumerating
-- every value the app can write (added in an earlier ad-hoc fix, not
-- itself tracked as a migration file — this one supersedes it).
-- Without this, saveDailyArchive()/saveWeeklyArchive() pushing
-- 'dailyArchiveFull'/'weeklyArchiveFull' will fail with a 23514
-- check-constraint violation, the same error class fixed previously
-- for the other section values.
--
-- Why two NEW sections instead of reusing 'weekly': the existing
-- 'weekly' section already carries a DERIVED rolling-window snapshot
-- (buildRollingWindowSnapshot() — last few days only, summary shape)
-- that Legion-mates' clients read for display. Overloading it with
-- the full raw Daily/Weekly Archive would break that existing reader
-- and conflate "what I show teammates" with "my actual local backup"
-- — two different shapes, two different purposes, so two different
-- section rows.
-- ============================================================

alter table shared_sections drop constraint if exists shared_sections_section_check;
alter table shared_sections add constraint shared_sections_section_check
  check (section in (
    'musts', 'whiteboard', 'weekly', 'yearly', 'monthlyFocus',
    'themeYear', 'accomplishMonth', 'ruler', 'accomplish',
    'dailyArchiveFull', 'weeklyArchiveFull'
  ));
