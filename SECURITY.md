# Security posture

This documents what's actually implemented, what's a deliberate scope
decision, and what still needs a manual step outside this codebase
(dashboards/accounts this environment has no access to).

## Implemented in code

- **Row Level Security** — `supabase/migrations/0001_rls_policies.sql`.
  Strict per-table policies: own data always, Legion (clan)-shared
  data only where the owner's `is_shared` flag is on. Includes two
  fixes found while writing this, not just a baseline:
  - `shared_rulers` SELECT is now gated on the *same* `is_shared`
    flag the client already uses to decide whether to display a
    teammate's Ruler — previously that flag was only a client-side
    display decision, so a direct API call could read it regardless.
  - `profiles.is_paid` can no longer be changed by the owning user's
    own UPDATE — the policy's `WITH CHECK` requires the submitted
    value to match what's already stored. Without this, a user could
    set their own paid flag via the client SDK.
  - **This was written from the client code's query patterns, not
    from reading the live database** (no DB connection is available
    from this environment) — read the file's header comment before
    running it, especially around `find_clan_by_invite_code()` if
    that RPC already exists in some form.
  - **A third generation of stale pre-0001 policies, found during a
    later audit of the invite-code join flow** —
    `0015_drop_stale_clan_policies.sql`. Five policies on
    `clans`/`clan_members` that `0004` (below) never touched (it only
    targets 4 specific names on `profiles`/`clan_members`/
    `shared_rulers`). Checked each one's actual `qual`/`with_check`
    against its `0001` replacement before deciding to drop rather than
    assuming: all five turned out to be functionally identical
    duplicates (including a helper, `is_clan_member()`, confirmed to
    just be an ordinary membership `EXISTS` check), not bypasses like
    the ones `0004` fixed. Dropped anyway — an exact duplicate under
    an unrelated name is precisely what let `0004`'s real bugs go
    unnoticed for as long as they did.
- **Content-Security-Policy** — a `<meta>` tag in `index.html`.
  `script-src`/`style-src` include `'unsafe-inline'` as a known,
  deliberate trade-off — the whole app is one inline `<script>`/
  `<style>` block with no build step, so nonce/hash-based CSP isn't
  achievable without a much larger refactor. `connect-src` is scoped
  to exact origins only (Supabase https+wss, Sentry, `api.telegram.org`
  for the GM/GN feature below, plus `cdnjs.cloudflare.com` and
  `browser.sentry-cdn.com` so DevTools can fetch jsPDF's/Sentry's
  `.map` sourcemaps without a console warning — both origins already
  execute full JS via `script-src`, so allowing a plain `.map` GET from
  the same origin adds no new capability) — never a wildcard.
  **CORRECTION:** this previously claimed `frame-ancestors 'none'`
  covered clickjacking. It didn't — confirmed via a live browser
  console warning ("The Content Security Policy directive
  'frame-ancestors' is ignored when delivered via a `<meta>` element"),
  which matches the CSP3 spec: `frame-ancestors` is HTTP-header-only,
  never honored from a meta tag. The directive has been removed from
  the policy (it did nothing but log that warning on every page load).
  **This app currently has no clickjacking protection** — see the
  Cloudflare manual-step item below, which is the only way to actually
  get one (a real response header, which needs something in front of
  GitHub Pages to set it).
- **Telegram GM/GN broadcast** — each user enters their *own* bot
  token + chat IDs + message templates in a local settings modal;
  all of it lives in `localStorage` only, keyed to that device, never
  synced to Supabase or committed anywhere. This is a deliberate,
  necessary exception to "no secrets in the client": there is no
  server for a bot token to live on safely (same constraint as
  `service_role` — see below), so the only honest options were "each
  user's own token, local to their own device" or "don't build this
  feature." The token only ever leaves the device in a direct request
  to `api.telegram.org`; this app has no backend that could see or
  log it even if it wanted to.
- **TradingView webhook integration** — `supabase/functions/tradingview-webhook`
  + `supabase/migrations/0002_trade_alerts.sql`. This is the first
  piece of this project with an actual server, which changes the
  `service_role` story from "there's nowhere safe to put it" to
  "here is specifically where it belongs" — the Edge Function is the
  one place a webhook receiver could exist at all (TradingView needs
  something always-on and publicly reachable to POST to; a static
  site can't receive inbound requests), and only Supabase runs it, so
  the key is never exposed to a browser. Two tables: `webhook_secrets`
  (strictly own-row-only, no Legion sharing at all — unlike
  `profiles`, which teammates can read, this must never leak or
  anyone could forge trade alerts against your ledger) and
  `trade_alerts` (client can read/update its own rows via normal RLS;
  INSERT is deliberately not permitted to the client at all — only
  the Edge Function, via `service_role`, can create rows, since a
  webhook POST has no "logged in user" for RLS to check against).
  The client-side secret is stored the same way as the Telegram
  token — localStorage only — but is *also* pushed to
  `webhook_secrets` (through the normal RLS-protected client), since
  the Edge Function needs a copy server-side to validate incoming
  requests against.
  **Fixed (found during a security audit pass):** the Edge Function
  compared the incoming secret with plain `!==`, a textbook
  timing-safe-comparison bug (string equality short-circuits at the
  first differing byte, in principle letting an attacker recover the
  secret one byte at a time via response-latency measurements). Now
  uses a constant-time `timingSafeEqual()` (single OR-accumulator over
  every byte, no early exit) defined directly in the function — no new
  dependency. It also used to store the *entire* inbound payload,
  secret included, into `trade_alerts.raw` on every single alert,
  duplicating a credential this file elsewhere calls "must never
  leak" into every row ever received; the secret is now stripped
  before that insert.
- **Alpha (multi-profile measurement system)** —
  `supabase/migrations/0005_alpha_taxonomy_encryption_ready.sql`
  supersedes `0003_alpha_profiles.sql` entirely (drops and recreates
  `alpha_profiles`/`alpha_entries` — the tab was rebuilt around a
  Health/Relationships/Finances taxonomy with E2E encryption as a
  stated design goal, not an afterthought). Both tables are still
  written by a normal authenticated client session (plain
  RLS-protected inserts, own-row-only, no service_role) and row `id`s
  are still client-generated (`crypto.randomUUID()`) for the same
  local/Supabase upsert-consistency reason as before.
  **Encryption status: real, not stubbed.** `alphaEncryptString`/
  `alphaDecryptString` (for `profile_name`) and `alphaEncryptPayload`/
  `alphaDecryptPayload` (for `encrypted_data`) call real WebCrypto
  AES-256-GCM — no server-visible plaintext leaves the device.
  **Key model (revised — no longer a passphrase):** the key is a
  **device-bound, non-extractable CryptoKey**
  (`crypto.subtle.generateKey(..., extractable: false, ...)`),
  generated once per (device, signed-in user) pair on first Alpha use
  and stored in IndexedDB — `alphaGetOrCreateDeviceKey()` in
  index.html. `extractable: false` means the raw key bytes can never
  be read back out via JS, by this app's own code or anyone else's,
  even with direct access to IndexedDB's storage.
  This deliberately does **not** derive the key from anything the
  Supabase auth session issues (access token, refresh token, etc.) —
  a key derivable from something the auth server itself mints is a
  key the server (or anyone with `service_role`/admin access, who can
  mint a valid session for any user) could also derive, which would
  make "the server never sees plaintext" false. A locally-generated,
  never-transmitted key is what keeps that claim actually true.
  Real consequences of this choice:
  - **No passphrase, no prompt** — unlocks automatically the moment
    a signed-in user first opens Alpha on a given device. This was a
    direct, explicit tradeoff request: friction removed in exchange
    for the key being device-bound rather than portable.
  - **The key is DEVICE-BOUND, not account-wide.** Data encrypted on
    one browser/device is not decryptable on another — each device
    generates its own independent key on first use. There's currently
    no export/import or cross-device recovery path for this key.
  - Keyed by `user_id` inside IndexedDB (`alphaDeviceKey:<user_id>`),
    so two different accounts signing in on the same shared device
    never share or overwrite each other's key — `onAuthStateChange`
    resets `alphaEncryptionKey` whenever the signed-in user actually
    changes (not on routine token refreshes for the same user).
  - Local storage is still plaintext regardless — encryption only
    applies to what leaves the device (profile/entry data via
    `alphaEncryptPayload`, voice memo audio via `alphaEncryptBlob`,
    both below).
  Voice memos (Relationships session logs) are encrypted the same
  way: `alphaEncryptBlob`/`alphaDecryptBlob` run the identical
  AES-GCM key over raw audio bytes instead of a UTF-8 string, and the
  ciphertext — never plaintext audio — is what reaches
  `supabase/migrations/0006_alpha_voice_notes_bucket.sql`'s
  `alpha-voice-notes` Storage bucket (private, owner-only RLS,
  mirroring the existing `journal-images` bucket pattern exactly).
  `category`/`subcategory` are still sent **and stay** plaintext on
  purpose even with real encryption now live — they're a fixed
  taxonomy enum this file defines, not user content, needed
  server-side for RLS scoping and so the client can query "profiles
  under this leaf" without decrypting everything. That's an accepted,
  documented metadata leak (the server always knows *what kind* of
  thing you track, never the name, notes, or voice content) — see the
  header comment above the Alpha JS block and each migration file's
  own comment for the full reasoning.
- **Session handling** — `persistSession`/`autoRefreshToken`/
  `detectSessionInUrl` are now explicit in `createClient()` (were
  previously relying on SDK defaults, which happen to be the same
  values — this just makes it auditable). `onAuthStateChange` already
  fully clears `currentUser`/paid-status/UI state on sign-out.
- **Journal encryption (Plans/Today/Ledgers-own-entries) — now wired
  in.** Second, independent device-bound key (`journalEncryptionKey`,
  `keyPrefix: 'journalDeviceKey'`) via the same `getOrCreateDeviceKey()`
  infrastructure Track Alpha uses — same IndexedDB database/store,
  different record, so the two keys are fully independent (losing or
  compromising one says nothing about the other). Covers:
  - `shared_sections` rows with no live "Share with Legion" path
    (`dailyArchiveFull`/`weeklyArchiveFull`/`plansWeeks`/`themeYear`/
    `monthlyFocus`) — always encrypted.
  - `shared_sections` rows that DO have a live share checkbox
    (`musts`/`whiteboard`/`weekly`/`yearly`/`accomplishMonth`) —
    encrypted only while `is_shared` is currently false. The moment
    sharing is turned on, that section pushes in plaintext instead
    (a Legion-mate's client has no way to decrypt something encrypted
    with *your* device key), and encrypts again the next time it's
    edited after sharing is turned back off.
  - `journal_entries.text`/`.history` — encrypted only for entries
    with an empty `shared_legion_ids` (same reasoning: a shared
    entry's Legion-mate recipients can't decrypt your device key's
    output, so shared entries stay plaintext, matching exactly what
    `journal_entries_select_own_or_shared` actually grants them).
  - **Deliberately NOT covered, left plaintext:** live Ruler blocks
    (`shared_rulers`, via the `merge_ruler_blocks` RPC) — that RPC
    merges block-by-block server-side using each block's own
    `block_updated_at` timestamp to resolve cross-device conflicts,
    which requires reading individual block fields; ciphertext would
    make that merge impossible without a much larger redesign. Also
    not covered: `entry_messages` (DMs) and `clan_messages` (Legion
    group chat) — both need Legion-visible encryption (per-recipient
    key exchange for DMs, a per-Legion shared key for chat), which is
    separate, larger, and explicitly deferred, not part of this pass.
  - **Legacy data handles itself, no migration needed.** Every decrypt
    path (`journalDecryptString`/`journalDecryptPayload`) detects
    whether a stored value looks like this app's `{iv, ciphertext}`
    envelope; anything that doesn't (every row written before this
    feature existed, and anything currently plaintext-by-design per
    the sharing rules above) is returned unchanged rather than treated
    as an error. The `data`/`text`/`history` columns involved were
    already `jsonb`/`text` with no shape constraint, so no schema
    change was needed either.
- **Scheduling (Plans tab "+ Schedule Event")** —
  `supabase/migrations/0017_schedule_events.sql`. A new `schedule_events`
  table, own-row-only RLS (`for all using/with check (user_id =
  auth.uid())`, matching `alpha_profiles`/`alpha_entries` — never
  shared to a Legion, no `is_shared` concept at all). Deliberately a
  **split** encryption model, not all-or-nothing: `title`/`event_date`/
  `start_time`/`duration_minutes`/`category`/reminder settings are
  plaintext on purpose — that's the "what and when" every signed-in
  device needs for the calendar to actually work cross-device. Only
  `description`/`notes` (the genuinely sensitive freeform content) are
  encrypted, folded into one `encrypted_data` envelope via the
  **existing** journal device key (`journalEncryptionKey`/
  `journalEncryptPayload`/`journalDecryptPayload`) — no new key for
  this feature. That key is device-bound and non-extractable (same
  tradeoff already documented above for Journal), so those two fields
  specifically won't decrypt on a device other than the one that wrote
  them — the client detects this (`journalDecryptPayload` already
  self-catches and returns the ciphertext envelope unchanged on
  failure) and shows "unavailable on this device" rather than raw
  ciphertext. **Save-side data-loss guard:** editing an event whose
  description/notes are currently unavailable, and leaving both fields
  blank, preserves the original ciphertext untouched rather than
  silently overwriting it with two freshly-"encrypted" empty strings —
  only actually typing new content on that device replaces it (see
  `pushScheduleEventToSupabase()`'s `detailsUnavailable`/
  `encryptedDataRaw` handling). Reminders are in-app only (no push
  infrastructure exists anywhere in this app — `sw.js` is pure
  offline-cache); the client-side reminder scan piggybacks on the
  existing 1s clock tick rather than adding a new timer. Integrates
  with the Ruler tab's rolling 7-day widget read-only/additively
  (`renderScheduleAnnotationInto`) — never touches `blocks[]`/
  `stampBlock`/`merge_ruler_blocks`, which stay exactly as they were.
- **Per-user localStorage namespacing** — every local key (Journal
  entries, Ruler blocks, Track Alpha's local cache, the Telegram bot
  token, the TradingView webhook secret, etc.) is wrapped through
  `scopedKey()` (`index.html`, right after `currentUser` is declared),
  which prefixes the key with the signed-in user's id (or a `guest`
  bucket while signed out). Previously every key was a bare global
  string, so a second Supabase account signing in on the same
  shared/borrowed device inherited whatever the first account had
  cached — including the two literal credentials above. A handful of
  one-time legacy-migration source keys are deliberately left
  unscoped (see the comment above `scopedKey()`) since they only ever
  read pre-existing data from before this scheme existed.
  `ensureCorrectUserScope()` forces a full page reload whenever the
  signed-in identity actually changes (guarded by a sessionStorage
  marker so it can't loop), since every piece of local state is loaded
  synchronously at script start, before Supabase's async session check
  can possibly resolve — reload is what guarantees everything re-loads
  from the correct bucket rather than requiring ~30 separate pieces of
  state to be manually re-synced in place.
  **Fixed (found while adding Scheduling's own storage key to this
  list):** the sign-out wipe list (`getAllScopedStorageKeys()`, was a
  plain `var ALL_SCOPED_STORAGE_KEYS = [...]` array literal) had
  silently contained `undefined` in place of
  `ALPHA_PROFILES_KEY`/`ALPHA_ENTRIES_KEY`/`ALPHA_GENDER_KEY` since
  those three are assigned thousands of lines further down this same
  script — `var` hoisting means the array literal captured each
  identifier's value (still unassigned at that point) at construction
  time, not live. Track Alpha's local cache has therefore never
  actually been cleared on sign-out, contradicting this section's own
  "nothing survives past sign-out" guarantee. Fixed by converting it
  to a function, evaluated only when `wipeAllLocalUserData()` actually
  runs — by then every key is guaranteed assigned, regardless of
  declaration order.
- **Subresource Integrity on all 5 externally-loaded scripts**
  (`supabase-js`, `jspdf`, `jspdf-autotable`, `jszip`, Sentry) — each
  `<script>` tag now carries an `integrity="sha384-…"` hash computed
  directly against that exact file's bytes, plus `crossorigin="anonymous"`.
  CSP's `script-src` already restricted *which hosts* could serve
  script; this closes the gap where one of those hosts (or a
  compromised CDN edge) could still serve tampered bytes and have them
  execute anyway. `supabase-js` is also now pinned to an exact version
  (`2.110.7`) instead of the previous unpinned `@2`, so what's hashed
  here is deterministic rather than whatever jsdelivr resolves `@2` to
  on a given day. **If any of these libraries are intentionally
  upgraded, the new file's hash must be recomputed and the `src`/
  `integrity` updated together — the browser will otherwise refuse to
  load it.**
- **Sentry** — SDK loads via CDN, `Sentry.init()` is guarded against
  an unreplaced DSN placeholder so local dev never breaks or reports
  against a fake project. Session replay is off on purpose — this app
  handles personal daily data (journal text, mission notes), so error
  reports should carry stack traces, not screen contents.
- **Secret injection via GitHub Actions** — `.github/workflows/deploy.yml`
  substitutes the Sentry DSN from a repo secret at build time; the
  source `index.html` only ever contains a placeholder string. Note
  `SUPABASE_ANON_KEY` is intentionally *not* treated as a secret here
  — see below.

## Corrected assumptions

- **The Supabase anon key is not a secret.** It's a publishable
  client identifier (comparable to a Stripe publishable key) —
  Supabase's own docs are explicit that it's safe to ship in frontend
  code. Access control is entirely RLS, enforced by Postgres
  regardless of what the client sends. There is nothing to "hide"
  here, and treating it as one wouldn't add real protection.
- **There is no server.** This app is a static `index.html` on GitHub
  Pages — no build step (until this change), no environment variable
  injection, nowhere for a `service_role` key to live. Nothing in the
  client touches it, and nothing should until (if) a real backend
  exists — at which point this becomes a concrete, different task.

## Manual steps still needed (outside this codebase)

1. **Run the RLS migration(s)** in the Supabase SQL Editor —
   `0001_rls_policies.sql`, `0002_trade_alerts.sql`,
   `0005_alpha_taxonomy_encryption_ready.sql`, and
   `0006_alpha_voice_notes_bucket.sql`. Read each header comment
   first. `0005` supersedes `0003_alpha_profiles.sql` (drops and
   recreates its tables) — only run `0003` if you need the old Alpha
   schema for some reason; otherwise skip straight to `0005`. `0006`
   creates the `alpha-voice-notes` Storage bucket the Relationships
   voice-memo feature needs — nothing in that feature works without
   it. Also run `0004_fix_rls_policy_bypasses.sql` if it hasn't been
   applied yet — it closes live, actively-exploitable RLS gaps
   (stale pre-`0001` policies OR'd with the correct ones), not a
   routine migration.
   **This list previously stopped at `0006` and was never updated as
   later migrations were added — that's a doc gap, not evidence they
   weren't run.** `0007_journal_dm.sql` through `0013_merge_ruler_blocks.sql`
   are now **all confirmed applied live, as of 2026-07-17**:
   `clan_messages`, `entry_messages`, `clans`, and `clan_members` all
   exist and `clan_messages` is in the `supabase_realtime` publication
   (`0007`/`0008`); `journal_entries` has `edited`/`history`/`image_paths`
   (`0009`); `shared_sections_section_check` matches `0012`'s full list
   including `plansWeeks`, meaning `0010`/`0011`/`0012` are all applied
   in order; and `merge_ruler_blocks` exists (`0013`). Any *new*
   migration added after this point should get the same live check
   before being assumed to have run.
   **`0014_entry_messages_realtime.sql` — confirmed applied live, as
   of 2026-07-17.** Adds `entry_messages` to the `supabase_realtime`
   publication so DMs push live (`subscribeToInboxRealtime()` in
   `index.html`), matching how `clan_messages` chat already works.
   **`0015_drop_stale_clan_policies.sql` — needs to be run.** Drops 5
   duplicate pre-0001 policies on `clans`/`clan_members` found during
   an audit of the invite-code join flow; confirmed harmless (see
   "Implemented in code" above) but should still be dropped. Verify
   with the same `pg_policies` query used to find them:
   `select policyname from pg_policies where tablename in
   ('clans','clan_members') and policyname in ('Users can leave a
   clan (delete their own membership)','Clan members can view their
   clans','Only paid users can create clans','Owner can delete their
   clan','Owner can update their clan');` — should return zero rows
   once applied.
   **`0016_find_clan_by_invite_code.sql` — resolved, no live check
   needed.** Captures the already-live `find_clan_by_invite_code()`
   verbatim (it was working correctly before this file existed and
   still is — `CREATE OR REPLACE` against its exact current
   definition changes nothing). Optional to run; only matters for
   restoring the schema from migrations alone in the future.
   **`0017_schedule_events.sql` — needs to be run.** New table for the
   Scheduling feature (Plans tab). Verify with:
   `select column_name from information_schema.columns where
   table_name = 'schedule_events';` — should return `id`, `user_id`,
   `event_date`, `start_time`, `duration_minutes`, `title`,
   `category`, `reminder_offset_minutes`, `reminder_shown`,
   `encrypted_data`, `created_at`, `updated_at`.
2. **Flip Pages source to "GitHub Actions"**: repo Settings > Pages >
   Build and deployment > Source. Until this changes, Pages keeps
   serving `main` directly and the new workflow's output, while it
   builds successfully, isn't what gets published.
3. **Add a `SENTRY_DSN` repo secret** (Settings > Secrets and
   variables > Actions) once a Sentry project exists — optional; the
   site works without it, just without error reporting.
4. **Enable passkeys in Supabase Auth** (dashboard toggle). The
   client now loads `supabase-js@2.110.7` pinned (was unpinned `@2`
   from jsdelivr — see the Subresource Integrity item below);
   passkey/WebAuthn support needs verifying against that exact
   version, and the client code needs the actual sign-in call added
   once the provider's on — that wasn't built this pass since it
   depends on the dashboard state first.
5. **Verify `0004_fix_rls_policy_bypasses.sql` is actually applied** —
   flagged during a security audit pass as unverifiable from this
   environment (no DB connection). Run in the SQL Editor:
   `select policyname from pg_policies where tablename in
   ('profiles','clan_members','shared_rulers');` — if any of the four
   stale policy names named in that migration's header are still
   present, run the migration now; it's idempotent.
6. **`merge_ruler_blocks` — resolved.** Confirmed live via
   `pg_get_functiondef`; the body is now captured verbatim in
   `0013_merge_ruler_blocks.sql` (previously existed only in the
   Supabase project, nowhere in git). Running `0013` is optional and
   harmless — it's `CREATE OR REPLACE` against the exact existing
   definition — but do it once so the DB and repo agree.
7. **Cloudflare**, once the domain routes through it:
   - Full (strict) SSL/TLS mode, "Always Use HTTPS" on.
   - Security headers via Transform Rules or a Worker — this is where
     HSTS, `X-Content-Type-Options`, `Referrer-Policy`, and
     `X-Frame-Options` (or a header-delivered `frame-ancestors`)
     actually get set as real HTTP headers (the meta-tag CSP in
     `index.html` cannot set any of these — `frame-ancestors`
     specifically is silently ignored via `<meta>`, so clickjacking
     protection does not exist until this step is done). If Cloudflare
     also sets its own CSP,
     decide which one wins — a page with two conflicting CSPs doesn't
     merge cleanly, it can just break unexpectedly. Simplest path:
     leave CSP as this repo's meta tag and use Cloudflare only for
     the headers a meta tag can't set.
   - WAF managed rules + rate limiting, particularly on the auth
     endpoints (`signInWithOtp`, `signInWithPassword`) and Legion
     join-by-code, since both are realistic brute-force/abuse targets.

## Explicitly out of scope right now

Matches the original ask — not overlooked, just not this pass:

- App shielding / reverse-engineering protection (PWAs are inherently
  readable; not a real defense against anything that matters here).
- Blanket end-to-end encryption of everything (conflicts with Legion
  sharing and any future server-side analytics — selective encryption
  of personal notes is the actual target, once the key story exists).
- Audit logging, per-endpoint rate limiting, HSMs/managed key
  services, RASP, custom WAF rules — all Phase 2, gated on paid tier
  and an actual attack surface existing yet.
