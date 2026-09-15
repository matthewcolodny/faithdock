// Supabase Edge Function: stripe-create-checkout
// This runs server-side — the Stripe secret key never reaches the browser.
//
// This is a BACKUP COPY tracked in the repo for reference, same
// dashboard-only deploy workflow as smooth-action.ts/resend-webhook.ts:
// the live source of truth is the Edge Functions dashboard. To make a
// change: paste the dashboard's current source into the chat first
// (never guess at it), make the edit, paste the full updated file back
// into the dashboard's Code tab and redeploy, THEN update this file to
// match so the backup doesn't drift.
//
// FIRST TIME TRACKED IN THIS REPO 2026-09-15 -- pasted in by the user
// after a report ("after giving test, and completing Stripe payment, it
// redirected me to 'Churches near you', not sure if intentional... also
// the giving amount did not show up on 'Giving' insights") led to
// tracing the actual bug into this file. The version below is the
// user's live paste PLUS one targeted fix (see EDITED note just below)
// -- not yet confirmed deployed with that fix in place.
//
// EDITED 2026-09-15, NOT YET CONFIRMED DEPLOYED: fixed success_url
// construction. The old code did:
//   success_url: successUrl + (successUrl.indexOf('?') === -1 ? '?' : '&') + 'session_id={CHECKOUT_SESSION_ID}'
// successUrl from the client is always a hash-routed SPA URL with no
// query string of its own (e.g. "https://faithdock.com/#church/My%20Church"
// -- built in index.html's bindGiveSubmitBtn as
// `window.location.origin + window.location.pathname + window.location.hash`).
// Appending "?session_id=..." onto the END of that string puts the
// query string AFTER the "#" fragment -- which browsers never parse as
// a query string at all; it just becomes part of the hash. Two
// consequences, both reported as separate symptoms by the user but
// actually one root cause:
//   1. window.location.search is empty when Stripe redirects back, so
//      index.html's checkForCompletedDonation() never finds session_id,
//      never calls confirm_donation, and the donation row stays
//      status: 'pending' forever -- explaining the amount never
//      appearing on Giving Insights (not a staleness/refresh issue).
//   2. The app's hash router tries to parse "My Church?session_id=cs_..."
//      as the church name, finds no match, and falls through to
//      showRouteFromHash's not-found redirect (go('directory')) --
//      landing on a page titled "Churches near you" (the standalone
//      Directory page reuses that exact heading string), which is what
//      the user saw and correctly suspected wasn't intentional.
// Fixed by inserting the session_id param into the URL BEFORE the "#"
// fragment instead of blindly appending to the whole string -- see
// buildSuccessUrl() below. Confirmed via the user's own pasted RLS
// policy list (`churches are publicly readable`, qual = true) that
// is_hidden does NOT block a hidden church's direct row lookup --
// ruling that out as a contributing cause, matching what
// 018_church_is_hidden.sql's own header comment always promised.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// FaithDock's cut of each donation, in whole percent. Set to 0 for
// now per the pilot pricing decision — raising this later is just
// changing this one number, not a rebuild.
const PLATFORM_FEE_PERCENT = 0;

// Inserts session_id={CHECKOUT_SESSION_ID} into the query string of a
// URL that may already carry a "#..." hash fragment (this app is a
// single-page app with hash-based routing, so successUrl always has
// one) -- a plain string append would land the query string AFTER the
// fragment, where browsers never parse it as a query string at all.
// Splitting on the first "#" and reassembling in the right order (query
// string before the fragment, per normal URL syntax) is what makes
// window.location.search actually contain session_id once Stripe
// redirects back.
function buildSuccessUrl(rawSuccessUrl: string): string {
  const hashIndex = rawSuccessUrl.indexOf('#');
  const base = hashIndex === -1 ? rawSuccessUrl : rawSuccessUrl.slice(0, hashIndex);
  const hash = hashIndex === -1 ? '' : rawSuccessUrl.slice(hashIndex);
  const sep = base.indexOf('?') === -1 ? '?' : '&';
  return base + sep + 'session_id={CHECKOUT_SESSION_ID}' + hash;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const authHeader = req.headers.get('Authorization');
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    });
    const supabaseAdmin = createClient(supabaseUrl, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

    const stripeSecretKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeSecretKey) {
      return new Response(JSON.stringify({ error: 'Stripe not configured' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }
    const stripe = new Stripe(stripeSecretKey, { apiVersion: '2023-10-16' });

    const body = await req.json();

    if (body.action === 'confirm_donation') {
      const { sessionId } = body;
      const session = await stripe.checkout.sessions.retrieve(sessionId);

      if (session.payment_status === 'paid') {
        await supabaseAdmin.from('donations').update({
          status: 'succeeded',
          stripe_payment_intent_id: session.payment_intent
        }).eq('stripe_checkout_session_id', sessionId);
        return new Response(JSON.stringify({ success: true }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
      return new Response(JSON.stringify({ success: false, status: session.payment_status }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // Default action: create a checkout session for a new donation.
    const { churchId, amountCents, donorEmail, fundId, successUrl, cancelUrl } = body;

    if (!amountCents || amountCents < 100) {
      return new Response(JSON.stringify({ error: 'Donation amount must be at least $1.' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    const { data: churchRow } = await supabase.from('churches').select('id, name, stripe_account_id, stripe_onboarding_complete').eq('id', churchId).single();
    if (!churchRow || !churchRow.stripe_account_id || !churchRow.stripe_onboarding_complete) {
      return new Response(JSON.stringify({ error: 'This church has not finished setting up giving yet.' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // A fund, if one was picked, has to actually belong to this
    // church and be a real fund — not trusted blindly just because
    // the client sent an ID. Also doubles as the lookup for the
    // fund's display name on the Stripe checkout page.
    let fundName = null;
    let validatedFundId = null;
    if (fundId) {
      const { data: fundRow } = await supabase.from('giving_funds').select('id, name').eq('id', fundId).eq('church_id', churchId).eq('is_active', true).single();
      if (fundRow) {
        validatedFundId = fundRow.id;
        fundName = fundRow.name;
      }
    }

    // Donor doesn't have to be signed in — giving works for guests too.
    const { data: userData } = await supabase.auth.getUser();
    const donorId = userData.user ? userData.user.id : null;

    const applicationFeeAmount = Math.round(amountCents * (PLATFORM_FEE_PERCENT / 100));
    const productName = fundName ? `Donation to ${churchRow.name} — ${fundName}` : `Donation to ${churchRow.name}`;

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [{
        price_data: {
          currency: 'usd',
          product_data: { name: productName },
          unit_amount: amountCents,
        },
        quantity: 1,
      }],
      payment_intent_data: {
        application_fee_amount: applicationFeeAmount,
        transfer_data: { destination: churchRow.stripe_account_id },
      },
      customer_email: donorEmail || undefined,
      success_url: buildSuccessUrl(successUrl),
      cancel_url: cancelUrl,
    });

    // Record it as pending immediately — confirm_donation flips it to
    // succeeded once Stripe confirms the payment actually went through.
    await supabaseAdmin.from('donations').insert({
      church_id: churchId,
      donor_id: donorId,
      donor_email: donorEmail || null,
      amount_cents: amountCents,
      platform_fee_cents: applicationFeeAmount,
      fund_id: validatedFundId,
      stripe_checkout_session_id: session.id,
      status: 'pending'
    });

    return new Response(JSON.stringify({ url: session.url }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }
});
