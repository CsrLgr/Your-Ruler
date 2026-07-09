# Command Center

**For Dangerous Humans.**

A single-page personal command center for tracking time, energy, decisions, and progress — no backend framework, no build step, just one `index.html` and a Supabase project for cross-device sync and squad sharing.

Live: https://csrlgr.github.io/Your-Ruler/

## What it does

- **Ruler** — a fixed 120-minute block clock anchored to sunrise, with per-block energy capture (1–3), notes, and a real Sleep/Wake log independent of block scheduling.
- **Vision** — a rolling 7-day Weekly Visualization (3 days of history, today, 3 days to plan ahead), a date-bound Yearly Visualization pulling from real weekly records, and the Musts & In-Between / Accomplish trackers.
- **Ledgers** — dated journal entries and a tab-based data export (CSV, PDF, or both) across every section.
- **Legions** — join or lead a squad, see teammates' local time and Ruler alignment at a glance, and control exactly what each of your own sections shares.
- **Alpha** — a Performance Score, day-over-day and sleep/energy correlation, weekly focus themes, and editable weekly summaries, all read from the same unified data archive the rest of the app writes to.

## Architecture

Everything lives in `index.html`: markup, styles, and vanilla JS in one file. Data is local-first (`localStorage`), with Supabase used only for cross-device sync and Legion (squad) sharing — the app works fully offline otherwise, backed by a network-first service worker (`sw.js`).

All historical data — scores, missions, energy, musts, journal counts — flows through one unified Daily/Weekly Archive rather than siloed per-feature storage, so Alpha, exports, and the Yearly Visualization all read from the same source of truth.

## Deploying

Push to `main` — GitHub Pages serves directly from the repo root.
