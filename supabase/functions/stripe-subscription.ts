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
//
// ============================================================
// 2026-09-18 — three changes. See GOTCHAS.md.
//
// 1. A Stripe Customer now records WHO it belongs to, in its own
//    metadata (`owner_id`). Ownership of a church can move;
//    a saved card cannot. Without this, transferring a church handed
//    the new owner a billing portal for the PREVIOUS owner's Customer
//    — their card's last4, their billing address, their invoice
//    history — because requireOwnedChurch only ever asked who owns the
//    church today.
//
//    The marker lives in Stripe metadata rather than a column on
//    `churches` on purpose: `authenticated` holds table-wide UPDATE on
//    that table and the pin trigger deliberately lets the owner
//    through, so a column would be writable by the very person it is
//    meant to check.
//
// 2. `list_invoices` — the church's own plan invoices, read straight
//    from Stripe. Nothing is copied into our database.
//
// 3. `start_checkout` no longer reuses a Customer that belongs to
//    somebody else. It used to reuse whatever id was on the church
//    row, which after a transfer would have put the NEW owner's
//    subscription on the PREVIOUS owner's card.
// ============================================================

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

    function jsonError(message, status) {
      return new Response(JSON.stringify({ error: message }), {
        status: status, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // Who does this Stripe Customer belong to? Returns the user id in
    // its metadata, backfilling it from the church's current owner when
    // it is absent.
    //
    // The backfill is safe for exactly one reason, and it is worth
    // stating: ownership transfer never actually worked until migration
    // 061 (051's trigger silently reverted it), so every Customer
    // created before today belongs to whoever owns that church now.
    // It also self-heals — the first time anyone touches billing, the
    // marker is written and later checks are exact rather than assumed.
    async function customerOwnerId(customerId, churchOwnerId) {
      let customer;
      try {
        customer = await stripe.customers.retrieve(customerId);
      } catch (e) {
        // A customer that no longer exists in Stripe is not somebody
        // else's, it is nobody's.
        console.warn('[stripe-subscription] customer retrieve failed:', e.message);
        return null;
      }
      if (!customer || customer.deleted) return null;
      const marked = customer.metadata && customer.metadata.owner_id;
      if (marked) return marked;
      try {
        await stripe.customers.update(customerId, {
          metadata: { ...(customer.metadata || {}), owner_id: churchOwnerId },
        });
      } catch (e) {
        console.warn('[stripe-subscription] could not backfill owner_id:', e.message);
      }
      return churchOwnerId;
    }

    // Shared by create_portal_session and list_invoices. Both expose
    // one person's payment details, so both answer the same question:
    // is the caller the person this Customer belongs to?
    //
    // Deliberately NOT "does the caller own the church". After a
    // transfer those are different people, and each needs a different
    // outcome:
    //   * the previous owner still has a live subscription on their own
    //     card and must be able to reach the portal to cancel it, even
    //     though the church is no longer theirs
    //   * the new owner must NOT see it, and is told why
    async function resolveBillingAccess(churchId) {
      const { data: church } = await supabaseAdmin
        .from('churches').select('id, name, owner_id, stripe_customer_id, stripe_subscription_id').eq('id', churchId).maybeSingle();
      if (!church) return { error: 'This church no longer exists.', status: 404 };
      if (!church.stripe_customer_id) {
        if (church.owner_id !== user.id) return { error: 'You do not have access to this church.', status: 403 };
        return { error: 'No billing account on file for this church yet.', status: 404 };
      }
      const ownsCustomer = await customerOwnerId(church.stripe_customer_id, church.owner_id);
      if (ownsCustomer === user.id) return { church: church };
      if (church.owner_id === user.id) {
        // The caller owns the church but not the card paying for it.
        return {
          error: 'This church\'s plan is still being paid for by its previous owner, on their own card. '
               + 'They need to cancel it from their account. Start your own plan here to take over billing.',
          status: 403
        };
      }
      return { error: 'You do not have access to this church.', status: 403 };
    }

    if (body.action === 'start_checkout') {
      const { churchId, plan, successUrl, cancelUrl } = body;
      if (!churchId || !plan || !PRICE_ENV_BY_PLAN[plan]) {
        return jsonError('Missing or invalid plan.', 400);
      }
      const priceId = Deno.env.get(PRICE_ENV_BY_PLAN[plan]);
      if (!priceId) {
        return jsonError(`No Price ID configured for the ${plan} plan.`, 500);
      }

      const churchRow = await requireOwnedChurch(churchId);
      if (!churchRow) {
        return jsonError('You do not have access to this church.', 403);
      }

      // Reuse the existing Stripe Customer if this church already has
      // one (e.g. downgraded once, upgrading again) instead of
      // creating duplicates on every checkout attempt -- but ONLY if
      // it belongs to the person checking out. After a transfer it
      // does not, and reusing it would charge the previous owner's
      // card for the new owner's subscription.
      let customerId = churchRow.stripe_customer_id;
      let reusingOwnCustomer = false;
      if (customerId) {
        const ownsCustomer = await customerOwnerId(customerId, churchRow.owner_id);
        reusingOwnCustomer = (ownsCustomer === user.id);
        if (!reusingOwnCustomer) customerId = null;
      }

      // Cancel any existing active subscription before starting a new
      // one. Without this, switching plans left a church with two (or
      // three) simultaneously-active Stripe subscriptions, each
      // firing its own webhook events on renewal/update — every event
      // blindly overwrote churches.plan_type with whatever plan it
      // carried, so whichever subscription's webhook happened to land
      // last silently "won." Confirmed live: this is what produced
      // the plan flickering between tiers on a plain page refresh.
      //
      // Only cancels a subscription on the caller's OWN customer. A
      // subscription belonging to a previous owner is theirs to cancel;
      // this function must not end someone else's paid plan on their
      // behalf, and the portal path above is how they do it.
      if (churchRow.stripe_subscription_id && reusingOwnCustomer) {
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

      if (!customerId) {
        const { data: ownerData } = await supabaseAdmin.auth.admin.getUserById(churchRow.owner_id);
        const customer = await stripe.customers.create({
          name: churchRow.name,
          email: ownerData && ownerData.user ? ownerData.user.email : undefined,
          // owner_id is the marker every check above relies on.
          metadata: { church_id: churchId, owner_id: churchRow.owner_id },
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
      const access = await resolveBillingAccess(churchId);
      if (access.error) return jsonError(access.error, access.status);

      const portalSession = await stripe.billingPortal.sessions.create({
        customer: access.church.stripe_customer_id,
        return_url: returnUrl,
      });
      return new Response(JSON.stringify({ url: portalSession.url }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    if (body.action === 'list_invoices') {
      // The church's own plan invoices. Stripe generates and stores
      // these; nothing is copied into our database, so there is no
      // second copy to drift, no webhook to miss one, and no money
      // data of ours to keep in sync.
      const { churchId } = body;
      const access = await resolveBillingAccess(churchId);
      // "No billing account on file" is not an error worth shouting
      // about here -- a church that has never paid simply has no
      // invoices, and the page should say that rather than turn red.
      if (access.error) {
        if (access.status === 404) {
          return new Response(JSON.stringify({ invoices: [] }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
        }
        return jsonError(access.error, access.status);
      }

      const list = await stripe.invoices.list({
        customer: access.church.stripe_customer_id,
        limit: Math.min(Math.max(parseInt(body.limit, 10) || 12, 1), 24),
      });
      // Only the fields the page renders. An invoice object carries a
      // great deal more, and shipping all of it to the browser would
      // be handing over data nothing asked for.
      const invoices = (list.data || []).map((inv) => ({
        id: inv.id,
        number: inv.number,
        created: inv.created ? new Date(inv.created * 1000).toISOString() : null,
        amount_paid: inv.amount_paid,
        amount_due: inv.amount_due,
        currency: inv.currency,
        status: inv.status,
        hosted_invoice_url: inv.hosted_invoice_url,
        invoice_pdf: inv.invoice_pdf,
      }));
      return new Response(JSON.stringify({ invoices: invoices }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
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
      // Same access rule as the portal: the person paying is the person
      // who may cancel, which after a transfer is not the church's
      // owner.
      const access = await resolveBillingAccess(churchId);
      if (access.error) return jsonError(access.error, access.status);
      const churchRow = access.church;
      if (!churchRow.stripe_subscription_id) {
        return jsonError('No active paid plan to cancel.', 400);
      }
      const sub = await stripe.subscriptions.update(churchRow.stripe_subscription_id, { cancel_at_period_end: true });
      await supabaseAdmin.from('churches').update({ cancel_at_period_end: true }).eq('id', churchId);
      return new Response(JSON.stringify({ success: true, current_period_end: new Date(sub.current_period_end * 1000).toISOString() }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    if (body.action === 'cancel_subscription_now') {
      // Ends the subscription IMMEDIATELY, unlike cancel_subscription
      // which schedules it for the end of the paid period. The only
      // caller is deleting a church, and the two cases genuinely
      // differ: a downgrade keeps serving what was paid for, whereas a
      // deleted church has nothing left to serve.
      //
      // This exists because deleting a church used to be a plain row
      // delete. The row was destroyed along with its
      // stripe_subscription_id, Stripe carried on charging the card
      // every month, and the webhook's `update ... .eq('id', churchId)`
      // then matched zero rows and returned 200 -- so nothing anywhere
      // reported that a customer was paying for something that no
      // longer existed. Cancel first, delete second, and refuse to
      // delete if the cancel fails: the row is the only thing that
      // still points at the subscription.
      const { churchId } = body;
      const access = await resolveBillingAccess(churchId);
      // A church with no billing account is the ordinary case -- most
      // are on Free. Nothing to cancel is a success, not an error, or
      // deleting a free church would be blocked by its own safeguard.
      if (access.error) {
        if (access.status === 404) {
          return new Response(JSON.stringify({ success: true, cancelled: false }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
        }
        return jsonError(access.error, access.status);
      }
      const churchRow = access.church;
      if (!churchRow.stripe_subscription_id) {
        return new Response(JSON.stringify({ success: true, cancelled: false }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
      }
      try {
        const existing = await stripe.subscriptions.retrieve(churchRow.stripe_subscription_id);
        if (existing && existing.status !== 'canceled') {
          await stripe.subscriptions.cancel(churchRow.stripe_subscription_id);
        }
      } catch (e) {
        // Deliberately NOT swallowed. Every other cancel path in this
        // file logs and carries on, because there the worst case is a
        // stale id. Here the caller deletes the church the moment this
        // returns success, and a false success means somebody is billed
        // forever for a church that no longer exists.
        return jsonError('Could not cancel the subscription, so the church was not deleted: ' + e.message, 502);
      }
      // Cleared rather than left pointing at a cancelled subscription,
      // for the case where the cancel succeeds and the delete does not.
      await supabaseAdmin.from('churches').update({
        plan_type: 'free', subscription_status: 'canceled',
        stripe_subscription_id: null, cancel_at_period_end: false,
      }).eq('id', churchId);
      return new Response(JSON.stringify({ success: true, cancelled: true }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
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
          return jsonError('Could not update plan: ' + updateError.message, 500);
        }
      }
      return new Response(JSON.stringify({ success: true }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    return jsonError('Unknown action.', 400);
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }
});
