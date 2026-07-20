// Creates a NOWPayments subscription for the signed-in caller and
// returns the URL they pay at. The client redirects the browser
// there directly — nothing NOWPayments-related loads client-side.
// See NOWPAYMENTS_SETUP.md.
//
// Deploy with the Supabase CLI from the repo root:
//   supabase functions deploy create-payment
//
// Called by an authenticated app user (via
// supabaseClient.functions.invoke('create-payment'), which attaches
// the caller's real Supabase access token automatically) — verify_jwt
// stays at its default (true), unlike nowpayments-webhook. The
// Authorization header the platform gateway already validated is
// reused below to resolve exactly who's asking, same pattern
// create-checkout-session used for Stripe.
//
// Required secrets (see NOWPAYMENTS_SETUP.md for where each comes
// from):
//   supabase secrets set NOWPAYMENTS_API_KEY=...
//   supabase secrets set NOWPAYMENTS_PLAN_ID=...
// The Plan itself (amount, interval, currency) is created ONCE ahead
// of time — see the setup guide — not by this function on every
// click; this just subscribes the caller to that existing plan.
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are
// auto-injected by the platform, same as every other function here.
//
// ---- A real behavioral difference from the Stripe version this
// replaced, worth knowing ----
// Crypto has no equivalent of "keep a card on file and auto-charge it
// next month" — there's no stored payment instrument NOWPayments (or
// anyone) can silently re-charge. Their "subscription" is a recurring
// INVOICE: NOWPayments emails the subscriber a fresh payment link
// each billing interval, and they have to actively go pay it again,
// the same way the very first payment worked. is_paid tracks whether
// the most recent cycle was actually paid — it is NOT a guarantee of
// uninterrupted access the way a Stripe subscription's silent
// auto-renewal was.
//
// ---- One thing to verify once this is actually deployed ----
// NOWPayments' exact POST /v1/subscriptions response shape (which
// field holds the URL to redirect the customer to — e.g. an
// invoice_url on the created subscription/payment object) is taken
// from their published docs/examples, not confirmed against a live
// call from this environment. If the redirect comes back empty on a
// real test click, log the raw response and adjust the extraction
// below — the rest of the flow (auth, plan lookup, saving the
// subscription id) doesn't depend on getting that one field name
// exactly right on the first try.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SERVICE_ROLE_KEY')!;
const NOWPAYMENTS_API_KEY = Deno.env.get('NOWPAYMENTS_API_KEY')!;
const NOWPAYMENTS_PLAN_ID = Deno.env.get('NOWPAYMENTS_PLAN_ID')!;
const NOWPAYMENTS_API_BASE = 'https://api.nowpayments.io/v1';
// Where NOWPayments sends the browser back to, and where it POSTs IPN
// callbacks. Both default to the production domain/function URL but
// can be overridden while testing (e.g. via the Stripe CLI-equivalent
// local tunnel) with `supabase secrets set APP_URL=...` /
// `supabase secrets set NOWPAYMENTS_IPN_URL=...`.
const APP_URL = Deno.env.get('APP_URL') ?? 'https://mycommandcenterapp.com/';
const IPN_CALLBACK_URL = Deno.env.get('NOWPAYMENTS_IPN_URL')
  ?? (SUPABASE_URL.replace('.supabase.co', '.supabase.co/functions/v1/nowpayments-webhook'));

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
  }

  const authHeader = req.headers.get('Authorization') ?? '';
  const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } }
  });
  const { data: userData, error: userErr } = await callerClient.auth.getUser();
  if (userErr || !userData?.user) {
    return new Response('Not authenticated', { status: 401, headers: CORS_HEADERS });
  }
  const user = userData.user;

  const subscriptionRes = await fetch(NOWPAYMENTS_API_BASE + '/subscriptions', {
    method: 'POST',
    headers: {
      'x-api-key': NOWPAYMENTS_API_KEY,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      subscription_plan_id: NOWPAYMENTS_PLAN_ID,
      email: user.email,
      ipn_callback_url: IPN_CALLBACK_URL,
      success_url: APP_URL + '?checkout=success',
      cancel_url: APP_URL + '?checkout=cancelled'
    })
  });

  if (!subscriptionRes.ok) {
    const errText = await subscriptionRes.text();
    return new Response('NOWPayments subscription creation failed: ' + errText, { status: 502, headers: CORS_HEADERS });
  }

  const subscription = await subscriptionRes.json();
  // See the header comment above — verify this against the real
  // response once deployed and adjust if the field name differs.
  const paymentUrl = subscription.invoice_url
    ?? subscription?.result?.[0]?.invoice_url
    ?? subscription.pay_url;
  const subscriptionId = subscription.id ?? subscription.subscription_id ?? subscription?.result?.[0]?.id;

  if (!paymentUrl || !subscriptionId) {
    return new Response('Unexpected NOWPayments response shape: ' + JSON.stringify(subscription), { status: 502, headers: CORS_HEADERS });
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { error: saveErr } = await admin
    .from('profiles')
    .update({ nowpayments_subscription_id: String(subscriptionId) })
    .eq('id', user.id);
  if (saveErr) {
    return new Response('Could not save subscription id: ' + saveErr.message, { status: 500, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ url: paymentUrl }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' }
  });
});
