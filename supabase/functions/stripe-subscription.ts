// Supabase Edge Function: stripe-subscription
// Handles FaithDock's own subscription billing — a church paying
// FaithDock $19/$39/$79 a month. This is a completely separate Stripe
// flow from stripe-create-checkout (donor giving, via Connect) and
// stripe-connect-onboarding (a church's own Connect account setup).
// This function uses FaithDock's OWN Stripe secret key — the same
// account, not a connected account.
//
// Secrets to set in Supabase (Edge Functions -> Secrets):
//   STRIPE_SECRET_KEY        — FaithDock's own Stripe secret key
//                               (reuse the same one stripe-create-checkout
//                               already uses, if that's on the same account)
//   STRIPE_PRICE_STARTER     — Price ID for the $19/mo recurring Price
//   STRIPE_PRICE_STANDARD    — Price ID for the $39/mo recurring Price
//   STRIPE_PRICE_PREMIUM     — Price ID for the $79/mo recurring Price
// (Multi-Church has no self-serve checkout — its pricing card is a
// mailto: "Contact Sales" link, index.html:3131 — nothing to add here.)
//
// Requires the cancel_at_period_end column (see the migration handed
// over alongside this file) and the corresponding read in
// loadBillingPanel() / write in stripe-subscription-webhook.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const PRICE_ENV_BY_PLAN = {
  starter: 'STRIPE_PRICE_STARTER',
  standard: 'STRIPE_PRICE_STANDARD',
  premium: 'STRIPE_PRICE_PREMIUM',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const stripeSecretKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeSecretKey) {
      return new Response(JSON.stringify({ error: 'Billing is not configured yet.' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }
    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });
    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

    // Who's actually calling this? Every action below operates on a
    // specific church, and only that church's owner may touch its
    // billing — without this, any signed-in user could pass a
    // different church's id and either start a checkout that
    // overwrites that church's stripe_customer_id, or (worse) open a
    // billing portal session for a church that already has a real
    // Stripe customer, exposing its payment methods/subscription to
    // someone who doesn't own it.
    const authHeader = req.headers.get('Authorization') ?? '';
    const supabaseAsCaller = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_ANON_KEY'), {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await supabaseAsCaller.auth.getUser();
    if (!user) {
      return new Response(JSON.stringify({ error: 'Not signed in.' }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }
    async function requireOwnedChurch(churchId) {
      const { data: church } = await supabaseAdmin
        .from('churches').select('id, name, owner_id, stripe_customer_id, stripe_subscription_id').eq('id', churchId).maybeSingle();
      if (!church || church.owner_id !== user.id) return null;
      return church;
    }

    if (body.action === 'start_checkout') {
      const { churchId, plan, successUrl, cancelUrl } = body;
      if (!churchId || !plan || !PRICE_ENV_BY_PLAN[plan]) {
        return new Response(JSON.stringify({ error: 'Missing or invalid plan.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
      const priceId = Deno.env.get(PRICE_ENV_BY_PLAN[plan]);
      if (!priceId) {
        return new Response(JSON.stringify({ error: `No Price ID configured for the ${plan} plan.` }), {
          status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      const churchRow = await requireOwnedChurch(churchId);
      if (!churchRow) {
        return new Response(JSON.stringify({ error: 'You do not have access to this church.' }), {
          status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      // Cancel any existing active subscription before starting a new
      // one. Without this, switching plans left a church with two (or
      // three) simultaneously-active Stripe subscriptions, each
      // firing its own webhook events on renewal/update — every event
      // blindly overwrote churches.plan_type with whatever plan it
      // carried, so whichever subscription's webhook happened to land
      // last silently "won." Confirmed live: this is what produced
      // the plan flickering between tiers on a plain page refresh.
      if (churchRow.stripe_subscription_id) {
        try {
          const existingSub = await stripe.subscriptions.retrieve(churchRow.stripe_subscription_id);
          if (existingSub && existingSub.status !== 'canceled') {
            await stripe.subscriptions.cancel(churchRow.stripe_subscription_id);
          }
        } catch (e) {
          // Already gone, or never a real subscription id — fine,
          // nothing to cancel. Don't block starting the new one over it.
          console.warn('[stripe-subscription] could not cancel existing subscription:', e.message);
        }
      }

      // Reuse the existing Stripe Customer if this church already has
      // one (e.g. downgraded once, upgrading again) instead of
      // creating duplicates on every checkout attempt.
      let customerId = churchRow.stripe_customer_id;
      if (!customerId) {
        const { data: ownerData } = await supabaseAdmin.auth.admin.getUserById(churchRow.owner_id);
        const customer = await stripe.customers.create({
          name: churchRow.name,
          email: ownerData && ownerData.user ? ownerData.user.email : undefined,
          metadata: { church_id: churchId },
        });
        customerId = customer.id;
        await supabaseAdmin.from('churches').update({ stripe_customer_id: customerId }).eq('id', churchId);
      }

      const session = await stripe.checkout.sessions.create({
        customer: customerId,
        mode: 'subscription',
        line_items: [{ price: priceId, quantity: 1 }],
        success_url: successUrl,
        cancel_url: cancelUrl,
        metadata: { church_id: churchId, plan: plan },
        subscription_data: { metadata: { church_id: churchId, plan: plan } },
      });

      return new Response(JSON.stringify({ url: session.url }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    if (body.action === 'create_portal_session') {
      const { churchId, returnUrl } = body;
      const churchRow = await requireOwnedChurch(churchId);
      if (!churchRow) {
        return new Response(JSON.stringify({ error: 'You do not have access to this church.' }), {
          status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
      if (!churchRow.stripe_customer_id) {
        return new Response(JSON.stringify({ error: 'No billing account on file for this church yet.' }), {
          status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
      const portalSession = await stripe.billingPortal.sessions.create({
        customer: churchRow.stripe_customer_id,
        return_url: returnUrl,
      });
      return new Response(JSON.stringify({ url: portalSession.url }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    if (body.action === 'cancel_subscription') {
      // Downgrade to Free. Schedules cancellation at the end of the
      // already-paid billing period (cancel_at_period_end) rather
      // than cutting the church off immediately — they keep whatever
      // they already paid for until it actually runs out. The actual
      // flip to plan_type='free' happens later, automatically, via
      // stripe-subscription-webhook's customer.subscription.deleted
      // handler once the period genuinely ends.
      const { churchId } = body;
      const churchRow = await requireOwnedChurch(churchId);
      if (!churchRow) {
        return new Response(JSON.stringify({ error: 'You do not have access to this church.' }), {
          status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
      if (!churchRow.stripe_subscription_id) {
        return new Response(JSON.stringify({ error: 'No active paid plan to cancel.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
      const sub = await stripe.subscriptions.update(churchRow.stripe_subscription_id, { cancel_at_period_end: true });
      await supabaseAdmin.from('churches').update({ cancel_at_period_end: true }).eq('id', churchId);
      return new Response(JSON.stringify({ success: true, current_period_end: new Date(sub.current_period_end * 1000).toISOString() }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    if (body.action === 'confirm_subscription') {
      // Fallback for the redirect-back moment, in case the webhook
      // hasn't landed yet — mirrors how stripe-create-checkout
      // confirms a donation on return rather than only trusting the
      // webhook's timing.
      const { sessionId } = body;
      const session = await stripe.checkout.sessions.retrieve(sessionId, { expand: ['subscription'] });
      if (session.payment_status !== 'paid' && session.status !== 'complete') {
        return new Response(JSON.stringify({ success: false }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
      }
      const churchId = session.metadata && session.metadata.church_id;
      const plan = session.metadata && session.metadata.plan;
      // The church id came from Stripe's own session metadata, which
      // only start_checkout above (now ownership-gated) ever sets —
      // this re-check is cheap defense in depth against someone
      // passing an arbitrary real sessionId they don't own.
      const churchRow = churchId ? await requireOwnedChurch(churchId) : null;
      if (churchRow && plan && session.subscription) {
        const sub = session.subscription;
        const periodEndUnix = sub.current_period_end || (sub.items && sub.items.data[0] && sub.items.data[0].current_period_end);
        const { error: updateError } = await supabaseAdmin.from('churches').update({
          plan_type: plan,
          stripe_subscription_id: sub.id,
          subscription_status: sub.status,
          current_period_end: periodEndUnix ? new Date(periodEndUnix * 1000).toISOString() : null,
          cancel_at_period_end: false,
        }).eq('id', churchId);
        // Confirmed as a real, live bug: a check-constraint violation
        // here was previously swallowed silently -- this call never
        // looked at the returned `error`, so the client got back
        // { success: true } while nothing actually changed. Surface
        // it instead.
        if (updateError) {
          return new Response(JSON.stringify({ error: 'Could not update plan: ' + updateError.message }), {
            status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
          });
        }
      }
      return new Response(JSON.stringify({ success: true }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    return new Response(JSON.stringify({ error: 'Unknown action.' }), {
      status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }
});
