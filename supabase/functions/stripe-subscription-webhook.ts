// Supabase Edge Function: stripe-subscription-webhook
//
// Called directly by Stripe (not the browser) — the authoritative
// confirmation of a subscription's state, independent of whether the
// payer's browser ever makes it back to the site after checkout.
// Separate from stripe-webhook (that one is donations/event tickets —
// unrelated, do not touch it).
//
// Deploy with JWT verification OFF (Stripe calls this, not your app):
//   supabase functions deploy stripe-subscription-webhook --no-verify-jwt
// (Dashboard: there's a "Verify JWT" toggle for this function — off.)
//
// Uses the SAME secrets stripe-subscription already has:
//   STRIPE_SECRET_KEY, plus its own STRIPE_SUBSCRIPTION_WEBHOOK_SECRET
//   (the whsec_... shown once when you create this endpoint in Stripe
//   → Developers → Webhooks, subscribed to:
//     checkout.session.completed
//     customer.subscription.updated
//     customer.subscription.deleted
//     invoice.payment_failed

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";

serve(async (req) => {
  const signature = req.headers.get('stripe-signature');
  const body = await req.text();

  const stripeSecretKey = Deno.env.get('STRIPE_SECRET_KEY');
  const webhookSecret = Deno.env.get('STRIPE_SUBSCRIPTION_WEBHOOK_SECRET');

  if (!stripeSecretKey || !webhookSecret) {
    return new Response('Webhook not configured', { status: 500 });
  }

  const stripe = new Stripe(stripeSecretKey, {
    apiVersion: '2023-10-16',
    httpClient: Stripe.createFetchHttpClient(),
  });

  let event;
  try {
    // constructEventAsync (not the sync version) -- Deno's runtime
    // doesn't have Node's crypto module, so the async/SubtleCrypto
    // variant is the one that actually works in an Edge Function.
    event = await stripe.webhooks.constructEventAsync(body, signature, webhookSecret);
  } catch (err) {
    return new Response('Signature verification failed: ' + err.message, { status: 400 });
  }

  const supabaseAdmin = createClient(
    Deno.env.get('SUPABASE_URL'),
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  );

  async function syncFromSubscription(sub) {
    const churchId = sub.metadata && sub.metadata.church_id;
    const plan = sub.metadata && sub.metadata.plan;
    if (!churchId) {
      console.warn('[stripe-subscription-webhook] subscription has no church_id metadata, skipping:', sub.id);
      return;
    }
    // A cancelled/expired subscription drops the church back to Free
    // rather than leaving it stamped with a stale paid plan_type.
    const isActive = sub.status === 'active' || sub.status === 'trialing' || sub.status === 'past_due';
    // Newer Stripe API versions (this account's webhook payloads are
    // pinned to one) moved current_period_end off the top-level
    // Subscription object onto each subscription item instead -- read
    // whichever shape is actually present rather than assuming the
    // old one, and fall back to null instead of crashing if neither is.
    const periodEndUnix = sub.current_period_end || (sub.items && sub.items.data[0] && sub.items.data[0].current_period_end);
    const { error: updateError } = await supabaseAdmin.from('churches').update({
      plan_type: isActive ? (plan || 'free') : 'free',
      stripe_customer_id: typeof sub.customer === 'string' ? sub.customer : sub.customer.id,
      stripe_subscription_id: sub.id,
      subscription_status: sub.status,
      current_period_end: periodEndUnix ? new Date(periodEndUnix * 1000).toISOString() : null,
      // Reflects a pending downgrade-to-Free (cancel_subscription
      // action) so the Billing panel can say "ending on <date>"
      // instead of just looking like a normal active plan. Once the
      // subscription is actually gone (this same event fires as
      // customer.subscription.deleted, isActive false), this is
      // meaningless either way, so just clear it.
      cancel_at_period_end: isActive ? !!sub.cancel_at_period_end : false,
    }).eq('id', churchId);
    // Confirmed as a real, live bug: a check-constraint violation (or
    // any other Postgres rejection) from this update was previously
    // swallowed completely -- supabase-js returns { data, error }
    // rather than throwing, and this call never looked at `error` at
    // all, so the function kept reporting 200 success back to Stripe
    // while silently writing nothing. Throwing here instead makes the
    // outer handler return 500, which tells Stripe to retry (correct
    // for a real failure) and puts the actual reason in the logs
    // instead of nowhere.
    if (updateError) {
      throw new Error('churches update failed for ' + churchId + ': ' + updateError.message);
    }
  }

  try {
    if (event.type === 'checkout.session.completed') {
      const session = event.data.object;
      if (session.mode === 'subscription' && session.subscription) {
        const sub = await stripe.subscriptions.retrieve(session.subscription);
        await syncFromSubscription(sub);
      }
    } else if (event.type === 'customer.subscription.updated' || event.type === 'customer.subscription.deleted') {
      await syncFromSubscription(event.data.object);
    } else if (event.type === 'invoice.payment_failed') {
      const invoice = event.data.object;
      if (invoice.subscription) {
        const sub = await stripe.subscriptions.retrieve(invoice.subscription);
        await syncFromSubscription(sub);
      }
    }
    return new Response(JSON.stringify({ received: true }), {
      headers: { 'Content-Type': 'application/json' }
    });
  } catch (err) {
    console.error('[stripe-subscription-webhook] handler error:', err);
    // Non-2xx tells Stripe to retry with backoff.
    return new Response('Handler error: ' + err.message, { status: 500 });
  }
});
