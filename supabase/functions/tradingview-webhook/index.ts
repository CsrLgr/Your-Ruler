// TradingView webhook receiver.
//
// Deploy with the Supabase CLI from the repo root:
//   supabase functions deploy tradingview-webhook
//
// Needs the service role key available as a Function secret (NOT the
// same thing as it being an env var in your local shell — Edge
// Functions read their own secrets store):
//   supabase secrets set SUPABASE_SERVICE_ROLE_KEY=<your service role key>
// SUPABASE_URL is provided automatically by the Edge Functions runtime,
// no need to set it yourself.
//
// The service role key is safe HERE specifically because this is a
// real server that only Supabase runs, with no client ever able to
// read its source or environment — the same reasoning SECURITY.md
// documents for why it could never live in index.html. Do not put it
// anywhere else.
//
// ---- What to give TradingView ----
// Webhook URL (find your project ref in the Supabase dashboard):
//   https://<project-ref>.supabase.co/functions/v1/tradingview-webhook?uid=<your user id>
// (the app's TradingView settings modal shows this pre-filled with
// your actual user id once you're logged in)
//
// Alert "Message" field, exactly this JSON shape:
//   Open:  {"secret":"<your webhook secret>","action":"open","pair":"{{ticker}}","side":"long","price":{{close}}}
//   Close: {"secret":"<your webhook secret>","action":"close","pair":"{{ticker}}","side":"long","price":{{close}},"pnl":{{strategy.order.contracts}}}
// (side/pnl are optional; pair, action, price, secret are required.
// TradingView's {{...}} placeholders get filled in by TradingView
// itself before it sends the request — this function just receives
// plain JSON, it has no idea those are template variables.)
//
// ---- Requests this function accepts ----
// GET  -> 200 "ok", no auth, no database access. Purely a
//         reachability check for the app's "Test Connectivity" button.
// POST -> validates uid + secret against webhook_secrets, inserts one
//         row into trade_alerts, responds 200 "ok" or an error status.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
};

// Plain `!==` on strings short-circuits at the first differing byte —
// a textbook timing side-channel on secret comparison (an attacker
// measuring response latency across many requests can in principle
// recover the secret one byte at a time). Compares every byte
// unconditionally via a single OR-accumulator, no early exit.
// Length mismatch is checked separately and isn't a meaningful leak
// here: generateWebhookSecret() in index.html always produces a
// fixed 32-character secret, so length never varies with a correct
// guess the way byte-position would.
function timingSafeEqual(a: string, b: string): boolean {
  const aBytes = new TextEncoder().encode(a);
  const bBytes = new TextEncoder().encode(b);
  if (aBytes.length !== bBytes.length) return false;
  let diff = 0;
  for (let i = 0; i < aBytes.length; i++) {
    diff |= aBytes[i] ^ bBytes[i];
  }
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: CORS_HEADERS });
  }

  // Reachability check only — never touches the database, so it
  // needs no secret and can't leak or insert anything.
  if (req.method === 'GET') {
    return new Response('ok', { status: 200, headers: CORS_HEADERS });
  }

  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
  }

  const uid = new URL(req.url).searchParams.get('uid');
  if (!uid) {
    return new Response('Missing uid query param', { status: 400, headers: CORS_HEADERS });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return new Response('Invalid JSON body', { status: 400, headers: CORS_HEADERS });
  }

  const secret = payload.secret;
  const action = payload.action;
  const pair = payload.pair;
  const side = payload.side;
  const price = payload.price;
  const pnl = payload.pnl;
  const time = payload.time;

  if (!secret || !action || !pair) {
    return new Response('Missing required fields: secret, action, pair', { status: 400, headers: CORS_HEADERS });
  }
  if (action !== 'open' && action !== 'close') {
    return new Response('action must be "open" or "close"', { status: 400, headers: CORS_HEADERS });
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Validate the shared secret before writing anything — the uid in
  // the URL is just a public identifier (visible to anyone who sees
  // the webhook URL), it proves nothing on its own.
  const { data: secretRow, error: secretErr } = await admin
    .from('webhook_secrets')
    .select('tradingview_secret')
    .eq('user_id', uid)
    .maybeSingle();

  if (secretErr) {
    return new Response('Lookup failed: ' + secretErr.message, { status: 500, headers: CORS_HEADERS });
  }
  if (!secretRow || typeof secret !== 'string' || !timingSafeEqual(secretRow.tradingview_secret, secret)) {
    return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  }

  // The secret already did its job (auth check above) — it has no
  // reason to also live on inside every alert row forever. Strip it
  // before archiving the rest of the payload verbatim, so this
  // credential has exactly one place it's stored (webhook_secrets),
  // not two.
  const { secret: _secret, ...rawWithoutSecret } = payload;

  const { error: insertErr } = await admin.from('trade_alerts').insert({
    user_id: uid,
    action,
    pair: String(pair),
    side: side ? String(side) : null,
    price: typeof price === 'number' ? price : null,
    pnl: typeof pnl === 'number' ? pnl : null,
    alert_time: typeof time === 'string' ? time : null,
    raw: rawWithoutSecret
  });

  if (insertErr) {
    return new Response('Insert failed: ' + insertErr.message, { status: 500, headers: CORS_HEADERS });
  }

  return new Response('ok', { status: 200, headers: CORS_HEADERS });
});
