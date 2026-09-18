// Supabase Edge Function: delete-account
// This runs server-side — deleting a user from auth.users requires
// the admin API, which the client SDK can't call directly. This
// function only ever deletes the account of whoever is actually
// making the authenticated request — never an arbitrary user ID
// passed in from the client.
//
// Deploy via Supabase dashboard: Edge Functions → Create a new
// function → name it exactly "delete-account" → paste this code →
// Deploy. No new secrets needed — uses the built-in service role key.
//
// ============================================================
// Backed up 2026-09-18 and CHANGED the same day -- the deployed copy
// must be replaced with this one. Read before changing anything here.
//
// FIXED 2026-09-18: this function now refuses to delete an account
// that still owns a church. It previously did not, and index.html's
// two checks -- loadProfilePage hiding the button, and the confirm
// handler re-querying `churches` -- are both in the browser, while this
// endpoint is reachable with nothing but a valid session.
//
// The answer turned out to be the one nobody expects: there is NO
// foreign key on churches.owner_id at all. Not CASCADE, not SET NULL,
// not RESTRICT -- nothing. So deleting a user left the church row in
// place holding the id of somebody who no longer exists:
//
//   * nobody can sign in to manage it, because its owner is gone
//   * it is not claimable either -- review_church_claim only assigns
//     churches whose owner_id is NULL, and a dead id is not null
//   * it stays in the public directory, run by no one
//   * and if it was on a paid plan, Stripe keeps charging a card that
//     nobody can now reach the portal to stop
//
// A database-level constraint would be the deeper fix and is not this
// function's to make. Refusing here is the cheap, correct one, and it
// would still be worth doing under RESTRICT -- the alternative there
// is a raw foreign key error shown to somebody closing their account.
// ============================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const authHeader = req.headers.get('Authorization');

    // Request-scoped client — used only to verify who's actually
    // calling this, never to perform the deletion itself.
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    });
    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) {
      return new Response(JSON.stringify({ error: 'Not authenticated.' }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    const supabaseAdmin = createClient(supabaseUrl, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

    // Refuse while they still own a church. The browser checks this
    // too; that is not a reason to skip it here, because the browser is
    // not what enforces anything.
    //
    // Read with the ADMIN client, not the caller's. RLS decides what
    // the caller can see, and a church they can somehow no longer read
    // is still a church that would be left ownerless -- a guard that
    // can be made to return nothing is not a guard.
    const { data: ownedChurches, error: ownedError } = await supabaseAdmin
      .from('churches').select('id, name').eq('owner_id', userData.user.id).limit(5);
    if (ownedError) {
      // Fail closed. If we cannot establish that they own nothing, we
      // do not delete -- the damage is one-directional.
      return new Response(JSON.stringify({ error: 'Could not check your churches, so nothing was deleted. Please try again.' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }
    if (ownedChurches && ownedChurches.length) {
      const names = ownedChurches.map((c) => c.name).join(', ');
      return new Response(JSON.stringify({
        error: 'You still own ' + (ownedChurches.length === 1 ? 'a church' : ownedChurches.length + ' churches')
             + ' (' + names + '). Transfer or delete '
             + (ownedChurches.length === 1 ? 'it' : 'them')
             + ' first — an account cannot be closed while a church would be left with nobody to run it.'
      }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    const { error: deleteError } = await supabaseAdmin.auth.admin.deleteUser(userData.user.id);
    if (deleteError) {
      return new Response(JSON.stringify({ error: deleteError.message }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }
});
