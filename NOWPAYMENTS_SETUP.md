# NOWPayments setup — USDC subscription payments

Manual steps to do in the NOWPayments dashboard (and Supabase) before
the Membership section in Settings can actually take a payment.
Nothing here is automated — it's a checklist. Test everything against
NOWPayments' **sandbox** environment first if you can; if you go
straight to production, do one small real payment yourself before
telling anyone else about the feature.

## 1. Account (no business registration needed)

Sign up at [nowpayments.io](https://nowpayments.io) with a personal
email. Registering with a personal (non-corporate) email prompts you
to just describe your activity in a few words — there's no business
registration step and no KYB/KYC required to open the account or
accept crypto-only payments. KYC only becomes relevant if you later
turn on fiat conversion/payout (converting received USDC to a bank
transfer) — if you're keeping everything on-chain, you can skip that
entirely.

**Dominican Republic**: NOWPayments' public policy is broad
availability with an explicit carve-out only for sanctioned/restricted
jurisdictions — DR isn't one of those, and nothing in their published
docs singles it out. I couldn't find a DR-specific confirmation
either way, though, so verify this yourself during signup (or ask
support@nowpayments.io directly) before relying on it — don't take my
research as a substitute for their own confirmation on your specific
situation.

## 2. Get your API key

Dashboard → **Settings → API keys** → generate one. This is
`NOWPAYMENTS_API_KEY` below — server-side only, never in the client.

## 3. Generate the IPN secret

Dashboard → **Settings → Payment settings** (or wherever your
dashboard version places it) → generate an **IPN Secret Key**. This
is `NOWPAYMENTS_IPN_SECRET` below — it's what proves an incoming
webhook actually came from NOWPayments (HMAC-SHA512 over the
callback body, verified in `nowpayments-webhook`), never in the client.

## 4. Create the subscription Plan

`POST https://api.nowpayments.io/v1/subscriptions/plans` (via curl,
Postman, or their dashboard if it exposes plan creation directly),
with your `NOWPAYMENTS_API_KEY` in the `x-api-key` header:

```json
{
  "title": "Command Center — Paid Tier",
  "interval_day": 30,
  "amount": 9.99,
  "currency": "usd"
}
```

- `interval_day`: how often it re-invoices. **Must match**
  `NOWPAYMENTS_INTERVAL_DAYS` below exactly — that number is also
  used server-side to compute when a paid period actually expires.
- `currency`: check NOWPayments' current supported-currency list for
  the exact ticker if you want the price itself denominated in USDC
  rather than USD-with-USDC-as-a-payment-option — their coin list uses
  network-specific tickers (e.g. distinct codes for USDC on different
  chains), confirm the exact one you want before creating the plan.

Copy the returned plan **id** — that's `NOWPAYMENTS_PLAN_ID` below.

## 5. Register the IPN callback URL

Set on the Plan itself (or per-subscription — `create-payment`
already sends it on every subscription it creates, so this step is
really just making sure the URL is right, not a separate manual
registration): `https://<your-project-ref>.supabase.co/functions/v1/nowpayments-webhook`
(find `<your-project-ref>` in the Supabase dashboard's project
settings — the same one your app's `SUPABASE_URL` already uses).

## 6. Every key/secret, and exactly where it goes

None of these ever go in `index.html` or anywhere else in the
client — they're Supabase Edge Function secrets only, set via the
CLI, the same way `SERVICE_ROLE_KEY` already works for the
TradingView webhook function.

| Name | Where to find it | Where it goes |
|---|---|---|
| `NOWPAYMENTS_API_KEY` | Step 2 above | Edge Function secret |
| `NOWPAYMENTS_IPN_SECRET` | Step 3 above | Edge Function secret |
| `NOWPAYMENTS_PLAN_ID` | Step 4 above | Edge Function secret |
| `NOWPAYMENTS_INTERVAL_DAYS` | Same number as the Plan's `interval_day` | Edge Function secret |
| `AFFILIATE_COMMISSION_PERCENT` | Your choice, e.g. `20` for 20% (optional — defaults to 20) | Edge Function secret |

Set them from the repo root once the functions exist:
```
supabase secrets set NOWPAYMENTS_API_KEY=...
supabase secrets set NOWPAYMENTS_IPN_SECRET=...
supabase secrets set NOWPAYMENTS_PLAN_ID=...
supabase secrets set NOWPAYMENTS_INTERVAL_DAYS=30
supabase secrets set AFFILIATE_COMMISSION_PERCENT=20
```

## Affiliate program (Phase 2)

No separate account/dashboard setup needed — the referral code,
wallet address, and commission tracking are entirely this app's own
schema (`0024_affiliate_program.sql`), not a NOWPayments feature.
`affiliate_commissions` rows are created automatically whenever a
referred user's payment comes through `nowpayments-webhook`, but
there's no payout automation yet — a wallet address is captured
(client-side encrypted) so a real payout mechanism has somewhere to
send to once one exists. Until then, commissions just accumulate as
"owed" (`status = 'pending'`) for manual payout however you already
handle that outside the app.

Notably **absent**: any client-side key. The app never loads a
NOWPayments SDK — `create-payment` builds the subscription entirely
server-side and the client just redirects to the URL it returns.

## 7. One real behavioral difference from a card subscription

There's no stored payment instrument for NOWPayments (or anyone) to
silently re-charge — crypto doesn't work that way. Their
"subscription" is a recurring **invoice**: they email the subscriber
a fresh payment link each `interval_day`, and the subscriber has to
actively go pay it again, same as the first time. `is_paid` reflects
whether the most recent cycle was actually paid, not a guarantee of
uninterrupted access — see `expire_stale_subscription()`
(`0023_nowpayments_subscriptions.sql`) for how a lapsed renewal
actually gets noticed without needing a cron job.

## 8. Verify against the real API once deployed

Two spots in the code are marked with a comment flagging them as
"taken from NOWPayments' published docs, not confirmed against a live
call from this environment" — the exact field name for the payment
URL in `create-payment`'s subscription-creation response, and the
exact field name for the subscription id on the webhook's callback
payload. Both are defensive (they check a couple of plausible names),
but the very first real test click is what actually confirms which
one NOWPayments uses. If either comes back wrong, the error response
includes the raw payload — paste it back and I'll fix the one line
that needs it.

## 9. Testing

- Use NOWPayments' sandbox/testnet options if your account tier has
  them; otherwise, a real payment of a small amount is the only way
  to see the full flow (there's no equivalent of Stripe's fully
  free testnet-asset flow across the board — confirm what test
  tooling your specific account has access to).
- Watch the Edge Function logs (`supabase functions logs
  nowpayments-webhook`) during your first real test — that's where
  you'll see the raw callback payload if anything in step 8 needs
  adjusting.
