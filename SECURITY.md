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
- **Content-Security-Policy** — a `<meta>` tag in `index.html`.
  `frame-ancestors 'none'` covers clickjacking. `script-src`/
  `style-src` include `'unsafe-inline'` as a known, deliberate
  trade-off — the whole app is one inline `<script>`/`<style>` block
  with no build step, so nonce/hash-based CSP isn't achievable
  without a much larger refactor. `connect-src` is scoped to this
  project's exact Supabase origin (https + wss) plus Sentry, not a
  wildcard.
- **Session handling** — `persistSession`/`autoRefreshToken`/
  `detectSessionInUrl` are now explicit in `createClient()` (were
  previously relying on SDK defaults, which happen to be the same
  values — this just makes it auditable). `onAuthStateChange` already
  fully clears `currentUser`/paid-status/UI state on sign-out.
- **Crypto helper utility** — AES-256-GCM + PBKDF2 via the browser's
  native Web Crypto API (no external library). **Not wired into
  journal save/load yet.** Journal entry *text* never reaches
  Supabase today regardless (only journal images and the whiteboard
  sync there) — this is about encrypting data at rest in
  localStorage, and the open question is key management (derived
  from the session? a separate passphrase? what's the recovery
  story?), which is a product decision, not a crypto one. The entry
  data model already carries an `encrypted` flag (always `false`
  today) so wiring this in later doesn't require another migration.
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

1. **Run the RLS migration** in the Supabase SQL Editor — read its
   header comment first.
2. **Flip Pages source to "GitHub Actions"**: repo Settings > Pages >
   Build and deployment > Source. Until this changes, Pages keeps
   serving `main` directly and the new workflow's output, while it
   builds successfully, isn't what gets published.
3. **Add a `SENTRY_DSN` repo secret** (Settings > Secrets and
   variables > Actions) once a Sentry project exists — optional; the
   site works without it, just without error reporting.
4. **Enable passkeys in Supabase Auth** (dashboard toggle). The
   client currently loads `supabase-js@2` unpinned from jsdelivr;
   passkey/WebAuthn support needs verifying against whatever version
   that resolves to, and the client code needs the actual sign-in
   call added once the provider's on — that wasn't built this pass
   since it depends on the dashboard state first.
5. **Cloudflare**, once the domain routes through it:
   - Full (strict) SSL/TLS mode, "Always Use HTTPS" on.
   - Security headers via Transform Rules or a Worker — this is where
     HSTS, `X-Content-Type-Options`, and `Referrer-Policy` actually
     get set as real HTTP headers (the meta-tag CSP in `index.html`
     cannot set any of these). If Cloudflare also sets its own CSP,
     decide which one wins — a page with two conflicting CSPs doesn't
     merge cleanly, it can just break unexpectedly. Simplest path:
     leave CSP as this repo's meta tag and use Cloudflare only for
     the headers a meta tag can't set.
   - WAF managed rules + rate limiting, particularly on the auth
     endpoints (`signInWithOtp`, `signInWithPassword`) and Legion
     join-by-code, since both are realistic brute-force/abuse targets.
6. **Decide the journal-encryption key story** before wiring
   `encryptText`/`decryptText` into `saveEntries()`/`loadEntries()`.

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
