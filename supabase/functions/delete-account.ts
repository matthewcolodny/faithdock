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
// BACKED UP 2026-09-18, unchanged. Read before changing anything here.
//
// KNOWN GAP, not fixed in this backup: this function does NOT check
// whether the caller still owns a church. index.html checks twice --
// loadProfilePage hides the button, and the confirm handler re-queries
// `churches` before calling -- but both checks are in the browser, and
// this endpoint is reachable with nothing but a valid session.
//
// What that costs depends on the ON DELETE rule of churches.owner_id,
// which predates this repo's migrations and is not recorded anywhere:
//   * CASCADE  -- deleting the user destroys their churches and
//                 everything under them, and any live Stripe
//                 subscription keeps billing with nothing left pointing
//                 at it (the same failure the church-delete path was
//                 just fixed for; see GOTCHAS.md)
//   * SET NULL -- the churches survive with no owner
//   * RESTRICT -- the delete fails with a foreign key error, which is
//                 the safe outcome and would make this a non-issue
//
// Confirm which, before deciding whether this needs a server-side
// guard:
//
//   select conname, confdeltype
//     from pg_constraint
//    where conrelid = 'churches'::regclass
//      and confrelid = 'auth.users'::regclass;
//
//   -- confdeltype: a = NO ACTION, r = RESTRICT, c = CASCADE,
//   --              n = SET NULL, d = SET DEFAULT
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
