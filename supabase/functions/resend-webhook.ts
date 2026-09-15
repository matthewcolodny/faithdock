// Supabase Edge Function: resend-webhook
//
// Receives delivery/open/click/bounce event callbacks from Resend and
// records them against message_log (see migration
// 028_message_delivery_tracking.sql) so the church owner's Messages
// dashboard page can show real delivery/open/bounce stats for each past
// send, instead of the previous fire-and-forget "we called Resend, no
// idea what happened after that."
//
// This is a NEW function — unlike smooth-action.ts, there is no existing
// live version to fetch from the dashboard first. It still needs the same
// "paste into the Edge Functions dashboard, redeploy, keep this backup in
// sync" treatment once it's live, per this repo's dashboard-only deploy
// workflow (see smooth-action.ts's header comment). NOT YET DEPLOYED as
// of this file being written — this is the proposed source to paste in,
// not a confirmation that it's live.
//
// Required one-time setup (cannot be done from code — see the accompanying
// prompt notes for the exact steps):
//   1. Create a webhook in the Resend dashboard pointing at this
//      function's URL, subscribed to: email.sent, email.delivered,
//      email.opened, email.clicked, email.bounced, email.complained.
//      Resend gives you a signing secret when you create it — save that
//      as this function's RESEND_WEBHOOK_SECRET environment variable/
//      secret in Supabase.
//   2. In the Supabase dashboard, this function's own settings must have
//      "Verify JWT" turned OFF. Resend calls this URL directly and will
//      never send a Supabase-issued JWT, so with JWT verification on,
//      every single event would be rejected with 401 before this code
//      ever runs.
//
// Signature verification uses the Svix library (Resend's webhooks are
// Svix-formatted under the hood — same svix-id / svix-timestamp /
// svix-signature headers, same HMAC scheme). This is deliberately NOT
// folded into smooth-action.ts: that function is invoked by our own
// client code with a Supabase user JWT (verify_jwt on); this one is
// called by Resend with no Supabase auth at all (verify_jwt off) — mixing
// the two into one function would mean either weakening smooth-action's
// auth or fighting Supabase's per-function JWT setting for one shared
// function. Two functions, two trust boundaries.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { Webhook } from "npm:svix@1.15.0";

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  const webhookSecret = Deno.env.get('RESEND_WEBHOOK_SECRET');
  if (!webhookSecret) {
    console.error('RESEND_WEBHOOK_SECRET is not configured.');
    return new Response('Not configured', { status: 500 });
  }

  // Signature verification needs the exact raw body string — parse it as
  // JSON only after it verifies, never before.
  const rawBody = await req.text();
  const svixId = req.headers.get('svix-id');
  const svixTimestamp = req.headers.get('svix-timestamp');
  const svixSignature = req.headers.get('svix-signature');

  if (!svixId || !svixTimestamp || !svixSignature) {
    return new Response('Missing signature headers', { status: 400 });
  }

  let event;
  try {
    const wh = new Webhook(webhookSecret);
    event = wh.verify(rawBody, {
      'svix-id': svixId,
      'svix-timestamp': svixTimestamp,
      'svix-signature': svixSignature,
    });
  } catch (err) {
    console.error('Resend webhook signature verification failed:', err.message);
    return new Response('Invalid signature', { status: 400 });
  }

  const eventType = event && event.type;
  const emailId = event && event.data && event.data.email_id;
  // Resend's own event timestamp when present, otherwise "now" is close
  // enough — this only feeds display fields (first_opened_at etc.), not
  // anything that gates access or billing.
  const eventAt = (event && event.created_at) ? event.created_at : new Date().toISOString();

  const trackedTypes = ['email.sent', 'email.delivered', 'email.opened', 'email.clicked', 'email.bounced', 'email.complained'];
  if (emailId && trackedTypes.indexOf(eventType) !== -1) {
    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    const { error } = await supabaseAdmin.rpc('apply_resend_webhook_event', {
      p_resend_email_id: emailId,
      p_event_type: eventType,
      p_event_at: eventAt,
    });
    // Logging only — an email_id with no matching message_log row is
    // expected and fine (e.g. a webhook event for one of the emails this
    // feature doesn't log at all: welcome_email, staff invites,
    // ownership_handoff, etc., which aren't sent through the tracked
    // mass_email path). Never turn that into a failure response; Resend
    // retries non-2xx responses, and there's nothing to retry here.
    if (error) console.error('apply_resend_webhook_event error:', error.message);
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
});
