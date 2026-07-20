// NOWPayments IPN (Instant Payment Notification) receiver — the only
// place profiles.is_paid ever gets set to true. See
// NOWPAYMENTS_SETUP.md for exactly where to register this URL.
//
// Deploy with the Supabase CLI from the repo root:
//   supabase functions deploy nowpayments-webhook
//
// REQUIRES verify_jwt = false (see ../../config.toml) — NOWPayments
// calls this with no Supabase auth at all, same reasoning as
// tradingview-webhook. Authentication instead happens entirely via
// the x-nowpayments-sig header, verified below against
// NOWPAYMENTS_IPN_SECRET — that's the real access control here.
//
// Required secrets (see NOWPAYMENTS_SETUP.md):
//   supabase secrets set NOWPAYMENTS_IPN_SECRET=...
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected.
//
// ---- Signature verification ----
// NOWPayments signs a CANONICAL form of the body, not the raw bytes
// as received (unlike Stripe): the JSON object's keys — recursively,
// at every nesting level — are sorted alphabetically, re-serialized,
// then HMAC-SHA512'd with the IPN secret. The result must match the
// x-nowpayments-sig header exactly. sortKeysDeep()/hmacHex() below do
// that; compared timing-safely, same reasoning as
// tradingview-webhook's timingSafeEqual().
//
// ---- Idempotency ----
// NOWPayments' IPN fires once per STATUS CHANGE on a payment
// (waiting -> confirming -> confirmed -> finished, ...), not once per
// payment overall. event_id is `<payment_id>:<payment_status>`, so a
// redelivered "finished" callback for a payment is deduped while
// still letting each distinct status for that same payment_id
// through as its own row. If the handler throws after the dedupe
// insert succeeds, that row is deleted before returning an error —
// otherwise a legitimately failed callback would look "already
// processed" on redelivery and never actually take effect.
//
// ---- What actually flips is_paid ----
// Only payment_status === 'finished' — NOWPayments' own guidance is
// explicit that "confirming"/"confirmed" are not yet safe to treat as
// fulfilled (funds haven't actually settled). Every other status is
// acknowledged and ignored.
//
// ---- One thing to verify once this is actually deployed ----
// Which field on the callback payload ties a payment back to the
// subscription created in create-payment (subscription_id, sub_id,
// or similar — taken from NOWPayments' documented examples, not
// confirmed against a live payload from this environment). If
// real-world testing shows a different field name, that's the one
// line to adjust — everything else (signature check, idempotency,
// the is_paid update itself) doesn't depend on it.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SERVICE_ROLE_KEY')!;
const NOWPAYMENTS_IPN_SECRET = Deno.env.get('NOWPAYMENTS_IPN_SECRET')!;
// Must match the Plan's own interval_day (see NOWPAYMENTS_SETUP.md) —
// there's no field on the callback payload that reliably reports it
// back, so it's kept as its own secret, single source of truth
// alongside NOWPAYMENTS_PLAN_ID in create-payment.
const NOWPAYMENTS_INTERVAL_DAYS = Number(Deno.env.get('NOWPAYMENTS_INTERVAL_DAYS') ?? '30');

function sortKeysDeep(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeysDeep);
  if (value && typeof value === 'object') {
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      sorted[key] = sortKeysDeep((value as Record<string, unknown>)[key]);
    }
    return sorted;
  }
  return value;
}

async function hmacSha512Hex(message: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-512' },
    false,
    ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(signature)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Same constant-time comparison reasoning as tradingview-webhook's
// timingSafeEqual — both hex digests are fixed-length here (SHA-512
// always produces 128 hex chars), so length alone reveals nothing.
function timingSafeEqual(a: string, b: string): boolean {
  const aBytes = new TextEncoder().encode(a);
  const bBytes = new TextEncoder().encode(b);
  if (aBytes.length !== bBytes.length) return false;
  let diff = 0;
  for (let i = 0; i < aBytes.length; i++) diff |= aBytes[i] ^ bBytes[i];
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  const signatureHeader = req.headers.get('x-nowpayments-sig');
  if (!signatureHeader) {
    return new Response('Missing x-nowpayments-sig header', { status: 400 });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return new Response('Invalid JSON body', { status: 400 });
  }

  const canonical = JSON.stringify(sortKeysDeep(payload));
  const expectedSig = await hmacSha512Hex(canonical, NOWPAYMENTS_IPN_SECRET);
  if (!timingSafeEqual(expectedSig, signatureHeader)) {
    return new Response('Signature verification failed', { status: 400 });
  }

  const paymentId = payload.payment_id ?? payload.id;
  const paymentStatus = payload.payment_status ?? payload.status;
  if (!paymentId || !paymentStatus) {
    return new Response('Missing payment_id/payment_status in payload', { status: 400 });
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const eventId = String(paymentId) + ':' + String(paymentStatus);
  const { error: dedupeErr } = await admin
    .from('payment_webhook_events_processed')
    .insert({ event_id: eventId });
  if (dedupeErr) {
    if (dedupeErr.code === '23505') {
      return new Response('Already processed', { status: 200 });
    }
    return new Response('Dedupe check failed: ' + dedupeErr.message, { status: 500 });
  }

  try {
    if (paymentStatus === 'finished') {
      const subscriptionId = payload.subscription_id ?? payload.sub_id;
      if (!subscriptionId) {
        throw new Error('No subscription id on a finished payment payload: ' + JSON.stringify(payload));
      }
      const periodEnd = new Date(Date.now() + NOWPAYMENTS_INTERVAL_DAYS * 24 * 60 * 60 * 1000).toISOString();
      const { error } = await admin
        .from('profiles')
        .update({ is_paid: true, nowpayments_period_end: periodEnd })
        .eq('nowpayments_subscription_id', String(subscriptionId));
      if (error) throw error;
    }
    // Every other status (waiting/confirming/confirmed/partially_paid/
    // failed/expired/refunded) is acknowledged and otherwise ignored —
    // is_paid is only ever SET true here. Downgrade isn't an event
    // this webhook ever sees (see the header comment on why crypto
    // has no "cancelled" signal) — it happens lazily, client-side, via
    // expire_stale_subscription() once nowpayments_period_end passes.
  } catch (err) {
    await admin.from('payment_webhook_events_processed').delete().eq('event_id', eventId);
    return new Response('Handler failed: ' + (err as Error).message, { status: 500 });
  }

  return new Response('ok', { status: 200 });
});
