// Supabase Edge Function: stripe-event-checkout
// Per-registration event ticket payments, through the church's own
// Stripe Connect account — the exact same connected account already
// used for Giving (stripe-create-checkout), but a completely
// separate flow: this pays for a specific event registration, not a
// general donation.
//
// This is a BACKUP COPY tracked in the repo for reference, same
// dashboard-only deploy workflow as this repo's other edge functions:
// the live source of truth is the Edge Functions dashboard. To make a
// change: paste the dashboard's current source into the chat first
// (never guess at it), make the edit, paste the full updated file back
// into the dashboard's Code tab and redeploy, THEN update this file to
// match so the backup doesn't drift.
//
// FIRST TIME TRACKED IN THIS REPO 2026-09-15 -- pasted in by the user
// while chasing down the Stripe-checkout redirect bug fixed in
// stripe-create-checkout.ts (see that file's own header comment for
// the full explanation). This function builds its successUrl the
// exact same way (index.html's startPaidEventCheckout(), same
// `origin + pathname + hash` pattern as the giving flow's
// bindGiveSubmitBtn()) and had the identical bug, confirmed once the
// user actually pasted this source in -- not assumed.
//
// EDITED 2026-09-15, NOT YET CONFIRMED DEPLOYED: fixed success_url
// construction the same way as stripe-create-checkout.ts. The old code
// did:
//   success_url: successUrl + (successUrl.indexOf('?') === -1 ? '?' : '&') + 'event_session_id={CHECKOUT_SESSION_ID}'
// which appends the query param AFTER the "#" hash fragment that's
// always present in successUrl (this app is a hash-routed SPA) --
// browsers never parse anything after "#" as a query string, so
// window.location.search came back empty on redirect, meaning
// checkForCompletedEventTicket() in index.html never found
// event_session_id and never called confirm_registration. Same failure
// mode as the giving flow: the registration's own webhook-independent
// confirm step never ran, and the app's hash router tried to parse
// "<hash>?event_session_id=cs_..." as a route, found nothing, and fell
// through to the not-found redirect. buildSuccessUrl() below is the
// same fix as stripe-create-checkout.ts's, just parameterized for this
// function's own query param name (event_session_id, not session_id --
// the two intentionally never collide, per this file's own original
// comment on checkForCompletedEventTicket in index.html).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// FaithDock's cut of each ticket sale, in whole percent. Matches the
// same 0% pilot decision already made for Giving — raising this
// later is changing this one number in both places, not a rebuild.
const PLATFORM_FEE_PERCENT = 0;

// Inserts <paramName>={CHECKOUT_SESSION_ID} into the query string of a
// URL that may already carry a "#..." hash fragment -- see this file's
// header comment. Splitting on the first "#" and reassembling in the
// right order (query string before the fragment, per normal URL
// syntax) is what makes window.location.search actually contain the
// param once Stripe redirects back, instead of it silently becoming
// part of the hash.
function buildSuccessUrl(rawSuccessUrl: string, paramName: string): string {
  const hashIndex = rawSuccessUrl.indexOf('#');
  const base = hashIndex === -1 ? rawSuccessUrl : rawSuccessUrl.slice(0, hashIndex);
  const hash = hashIndex === -1 ? '' : rawSuccessUrl.slice(hashIndex);
  const sep = base.indexOf('?') === -1 ? '?' : '&';
  return base + sep + paramName + '={CHECKOUT_SESSION_ID}' + hash;
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

    if (body.action === 'confirm_registration') {
      // Fallback for the redirect-back moment, in case the webhook
      // hasn't landed yet — same reasoning as stripe-create-checkout's
      // confirm_donation. The webhook remains the authoritative
      // source of truth; this only closes that timing gap.
      const { sessionId } = body;
      const session = await stripe.checkout.sessions.retrieve(sessionId);
      if (session.payment_status === 'paid') {
        await supabaseAdmin.from('event_registrations').update({
          status: 'confirmed', payment_status: 'succeeded', amount_paid_cents: session.amount_total
        }).eq('stripe_checkout_session_id', sessionId);
        return new Response(JSON.stringify({ success: true }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
      return new Response(JSON.stringify({ success: false, status: session.payment_status }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // Default action: start a ticket checkout for a new registration.
    const { eventId, answers, discountCode, successUrl, cancelUrl } = body;

    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) {
      return new Response(JSON.stringify({ error: 'You need to sign up or log in first.' }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    const { data: eventRow } = await supabase.from('events').select('id, title, price_cents, max_participants, church_id, churches(name, stripe_account_id, stripe_onboarding_complete)').eq('id', eventId).single();
    if (!eventRow || !eventRow.price_cents || eventRow.price_cents <= 0) {
      return new Response(JSON.stringify({ error: 'This event does not have a ticket price set.' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }
    const church = eventRow.churches;
    if (!church || !church.stripe_account_id || !church.stripe_onboarding_complete) {
      return new Response(JSON.stringify({ error: 'This church has not finished setting up payments yet.' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // Best-effort capacity check, same as the free-registration path
    // — not perfectly race-proof, but worth doing server-side once
    // real money is involved rather than trusting the client alone.
    if (eventRow.max_participants) {
      const { count: currentCount } = await supabaseAdmin.from('event_registrations').select('id', { count: 'exact', head: true }).eq('event_id', eventId).eq('role', 'participant').eq('status', 'confirmed');
      if ((currentCount || 0) >= eventRow.max_participants) {
        return new Response(JSON.stringify({ error: 'This event is full.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
    }

    // Discount codes are always validated and priced server-side —
    // never trust a discounted amount computed by the client for a
    // real charge. A code applies to this specific event only.
    let discountCodeRow = null;
    let discountAmountCents = 0;
    let finalAmountCents = eventRow.price_cents;
    if (discountCode && String(discountCode).trim()) {
      const normalizedCode = String(discountCode).trim().toUpperCase();
      const { data: codeRow } = await supabase.from('event_discount_codes').select('id, code, discount_type, discount_value, max_uses, times_used').eq('event_id', eventId).eq('code', normalizedCode).eq('is_active', true).single();
      if (!codeRow) {
        return new Response(JSON.stringify({ error: 'That discount code isn\'t valid for this event.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
      if (codeRow.max_uses !== null && codeRow.times_used >= codeRow.max_uses) {
        return new Response(JSON.stringify({ error: 'That discount code has reached its limit.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
      discountCodeRow = codeRow;
      discountAmountCents = codeRow.discount_type === 'percent'
        ? Math.round(eventRow.price_cents * (codeRow.discount_value / 100))
        : codeRow.discount_value;
      finalAmountCents = Math.max(0, eventRow.price_cents - discountAmountCents);
    }

    // Pending, not confirmed — this is what keeps an abandoned
    // checkout from ever counting toward capacity or showing up as a
    // real attendee. Upsert so re-attempting a previously abandoned
    // checkout reuses the same row rather than erroring on a
    // duplicate.
    const { data: regRow, error: regError } = await supabaseAdmin.from('event_registrations').upsert({
      event_id: eventId, user_id: userData.user.id, status: 'pending', role: 'participant', payment_status: 'pending',
      discount_code_id: discountCodeRow ? discountCodeRow.id : null,
      discount_amount_cents: discountCodeRow ? discountAmountCents : null
    }, { onConflict: 'event_id,user_id' }).select().limit(1);
    if (regError || !regRow || !regRow.length) {
      return new Response(JSON.stringify({ error: regError ? regError.message : 'Could not start registration.' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }
    const registrationId = regRow[0].id;

    // Answers are saved now, before payment completes — the question
    // record doesn't depend on the registration's payment status, so
    // there's no reason to make someone re-answer if they retry a
    // failed payment.
    if (Array.isArray(answers) && answers.length) {
      const answerRows = answers.map((a) => ({
        registration_id: registrationId,
        question_id: a.question_id,
        answer_text: a.answer_text !== undefined ? a.answer_text : null,
        answer_bool: a.answer_bool !== undefined ? a.answer_bool : null,
      }));
      await supabaseAdmin.from('event_question_answers').upsert(answerRows, { onConflict: 'registration_id,question_id' });
    }

    // A code that discounts the event down to (effectively) free
    // skips Stripe entirely — Stripe Checkout can't process a
    // near-zero charge anyway, and forcing someone through a
    // payment screen to pay nothing is a bad experience for what a
    // 100%-off code is clearly meant to do. Redemption happens right
    // here, atomically, since there's no separate payment-confirmation
    // step to defer it to for this path.
    if (discountCodeRow && finalAmountCents < 50) {
      const { data: redeemed } = await supabaseAdmin.rpc('redeem_discount_code', { p_code_id: discountCodeRow.id });
      if (!redeemed) {
        return new Response(JSON.stringify({ error: 'That discount code was just used up — try again without it, or contact the organizer.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
      await supabaseAdmin.from('event_registrations').update({
        status: 'confirmed', payment_status: 'succeeded', amount_paid_cents: 0
      }).eq('id', registrationId);
      return new Response(JSON.stringify({ freeRegistration: true }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    const applicationFeeAmount = Math.round(finalAmountCents * (PLATFORM_FEE_PERCENT / 100));
    const productName = discountCodeRow
      ? eventRow.title + ' — ' + church.name + ' (code ' + discountCodeRow.code + ' applied)'
      : eventRow.title + ' — ' + church.name;

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [{
        price_data: {
          currency: 'usd',
          product_data: { name: productName },
          unit_amount: finalAmountCents,
        },
        quantity: 1,
      }],
      payment_intent_data: {
        application_fee_amount: applicationFeeAmount,
        transfer_data: { destination: church.stripe_account_id },
      },
      customer_email: userData.user.email || undefined,
      metadata: {
        type: 'event_ticket', event_id: eventId, registration_id: registrationId,
        discount_code_id: discountCodeRow ? discountCodeRow.id : ''
      },
      success_url: buildSuccessUrl(successUrl, 'event_session_id'),
      cancel_url: cancelUrl,
    });

    await supabaseAdmin.from('event_registrations').update({ stripe_checkout_session_id: session.id }).eq('id', registrationId);

    return new Response(JSON.stringify({ url: session.url }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }
});
