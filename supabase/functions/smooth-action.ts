// Supabase Edge Function: smooth-action (FINAL CONSOLIDATED VERSION +
// login link + ownership handoff + member invite + event contact notify)
// This runs server-side — the Resend API key never reaches the browser.
//
// This is a BACKUP COPY tracked in the repo for reference. Supabase Edge
// Functions are not deployed from this repo (no `supabase functions deploy`
// workflow exists here) — the live source of truth is the Edge Functions
// dashboard. To make a change: paste the dashboard's current source into
// the chat first (never guess at it), make the edit, paste the full
// updated file back into the dashboard's Code tab and redeploy, THEN
// update this file to match so the backup doesn't drift.
//
// Last CONFIRMED deployed and working: 2026-09-09, including the
// event_contact_notify feature and the member_invite fix documented in
// GOTCHAS.md.
//
// PASTED INTO THE DASHBOARD 2026-09-15 per the user's own confirmation
// (message_batches/message_log delivery tracking, migration
// 028_message_delivery_tracking.sql, the new resend-webhook.ts function)
// -- NOT independently re-verified from this environment (no dashboard
// access here), taken on the user's word.
//
// EDITED AGAIN 2026-09-15, NOT YET CONFIRMED DEPLOYED: mass_email's
// outbound payload now sets reply_to to the actual sender's own email
// (captured from the same JWT already used for senderId/created_by)
// instead of leaving it unset. Messages has no staff permission gate,
// so whoever clicked Send is frequently a staff member, not the owner --
// a hardcoded owner reply_to would misroute replies away from the
// person who actually needs to see them.
//
// EDITED A THIRD TIME 2026-09-14: the same reply_to-the-actual-sender
// fix extended to member_invite, event_contact_notify, and the default
// staff-invite branch -- all three previously sent with no reply_to at
// all, same gap as mass_email had. Each derives its own senderEmail
// locally via the same getUser(jwt) pattern (not shared/extracted,
// matching how none of this file's other per-type branches share
// helpers either). member_invite and event_contact_notify are both
// reachable by staff (Directory/People has no visible permission gate;
// event creation/editing only needs canManageEvents); the staff-invite
// branch is confirmed owner-only in the UI (isOwner-gated
// client-side), so inviterName there is never actually a staff
// member's name -- fixed anyway for consistency with the other three,
// since it's still a strict improvement over no reply_to at all.
//
// PASTED INTO THE DASHBOARD 2026-09-14 per the user's own confirmation
// (all three edits above, on top of the already-deployed mass_email
// reply_to fix) -- NOT independently re-verified from this environment
// (no dashboard access here), taken on the user's word.
//
// Dispatches on body.type: welcome_email, contact_church, mass_email,
// group_join_request, ownership_handoff, member_invite,
// event_contact_notify, and a no-type default (staff invite, keyed on
// hasAccount).

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
    const body = await req.json();
    const resendApiKey = Deno.env.get('RESEND_API_KEY');

    if (!resendApiKey) {
      return new Response(JSON.stringify({ error: 'Email service not configured' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    if (body.type === 'welcome_email') {
      const { email, name } = body;
      const firstName = (name || '').split(' ')[0] || 'there';
      const html = `<p>Hi ${firstName},</p><p>Welcome to FaithDock! We're glad you're here.</p><p>You can now browse churches near you, register for events, join groups, and — if you're setting up a church — manage your congregation's whole presence in one place.</p><p>If you have any questions getting started, just reply to this email.</p>`;

      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: 'FaithDock <invites@faithdock.com>', to: [email], subject: 'Welcome to FaithDock!', html: html }),
      });
      const data = await res.json();
      if (!res.ok) {
        return new Response(JSON.stringify({ error: data }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
      }
      return new Response(JSON.stringify({ success: true }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    if (body.type === 'contact_church') {
      const { churchId, senderName, senderEmail, subject, messageBody } = body;
      if (!churchId || !senderEmail || !subject || !messageBody) {
        return new Response(JSON.stringify({ error: 'Missing required fields.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
      const { data: churchRow, error: churchError } = await supabaseAdmin
        .from('churches').select('name, owner_id').eq('id', churchId).single();
      if (churchError || !churchRow || !churchRow.owner_id) {
        return new Response(JSON.stringify({ error: 'Could not find this church.' }), {
          status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      const { data: ownerData, error: ownerError } = await supabaseAdmin.auth.admin.getUserById(churchRow.owner_id);
      if (ownerError || !ownerData || !ownerData.user || !ownerData.user.email) {
        return new Response(JSON.stringify({ error: 'Could not find a contact email for this church.' }), {
          status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      const html = `<p>New message from ${senderName || 'a visitor'} (${senderEmail}) via your ${churchRow.name} page on FaithDock:</p><div>${messageBody}</div>`;
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: 'FaithDock <invites@faithdock.com>', to: [ownerData.user.email], reply_to: senderEmail,
          subject: `[${churchRow.name}] ${subject}`, html: html,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        return new Response(JSON.stringify({ error: data }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
      }
      return new Response(JSON.stringify({ success: true }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    if (body.type === 'mass_email') {
      const { recipientEmails, subject, bodyHtml, churchName, churchId, audienceLabel } = body;
      if (!recipientEmails || !recipientEmails.length) {
        return new Response(JSON.stringify({ error: 'No recipients found for this audience.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      // Delivery/open/bounce tracking (see migration
      // 028_message_delivery_tracking.sql and resend-webhook.ts): one
      // message_batches row for this send, then one message_log row per
      // recipient once we have Resend's own id for that email back. churchId
      // is optional so this stays backward-compatible with any other caller
      // of this same type that doesn't send it — tracking is skipped, the
      // email itself still goes out exactly as before. A tracking failure
      // must never block or fail the actual send.
      //
      // senderEmail also drives reply_to below -- Messages has no staff
      // permission gate at all (unlike Billing/Settings), so the person
      // who actually clicked Send here is frequently a staff member the
      // owner invited, not the owner. Hardcoding reply_to to the owner
      // would misroute replies away from whoever the recipient actually
      // needs to reach; getUser() already returns the sender's email
      // alongside their id from the same JWT, so no second lookup needed.
      const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
      let senderId = null;
      let senderEmail = null;
      const authHeader = req.headers.get('Authorization');
      if (authHeader) {
        try {
          const { data: authData } = await supabaseAdmin.auth.getUser(authHeader.replace('Bearer ', ''));
          senderId = authData && authData.user ? authData.user.id : null;
          senderEmail = authData && authData.user ? authData.user.email : null;
        } catch (e) { /* best-effort — proceed without a sender id/email */ }
      }

      let batchId = null;
      if (churchId) {
        try {
          const { data: batchRow, error: batchError } = await supabaseAdmin
            .from('message_batches')
            .insert({
              church_id: churchId,
              message_type: recipientEmails.length === 1 ? 'individual' : 'mass_email',
              subject: subject,
              audience_label: audienceLabel || null,
              recipient_count: recipientEmails.length,
              created_by: senderId,
            })
            .select('id').single();
          if (!batchError && batchRow) batchId = batchRow.id;
        } catch (e) { /* best-effort — send proceeds untracked */ }
      }

      const fromLine = `${churchName} via FaithDock <invites@faithdock.com>`;
      const html = `<div>${bodyHtml}</div><p style="color:#8791A5;font-size:12px;margin-top:24px;">Sent via FaithDock on behalf of ${churchName}.</p>`;

      const chunkSize = 100;
      let totalSent = 0;
      for (let i = 0; i < recipientEmails.length; i += chunkSize) {
        const chunk = recipientEmails.slice(i, i + chunkSize);
        const payload = chunk.map((email) => (
          senderEmail
            ? { from: fromLine, to: [email], subject: subject, html: html, reply_to: senderEmail }
            : { from: fromLine, to: [email], subject: subject, html: html }
        ));
        const res = await fetch('https://api.resend.com/emails/batch', {
          method: 'POST',
          headers: { 'Authorization': `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });
        if (!res.ok) {
          const errData = await res.json();
          return new Response(JSON.stringify({ error: errData, sentBeforeError: totalSent }), {
            status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
          });
        }
        const resData = await res.json();
        if (batchId && resData && Array.isArray(resData.data)) {
          const logRows = resData.data
            .map((item, idx) => ({
              batch_id: batchId,
              church_id: churchId,
              resend_email_id: item && item.id ? item.id : null,
              recipient_email: chunk[idx],
            }))
            .filter((r) => r.resend_email_id);
          if (logRows.length) {
            try { await supabaseAdmin.from('message_log').insert(logRows); } catch (e) { /* best-effort */ }
          }
        }
        totalSent += chunk.length;
      }

      return new Response(JSON.stringify({ success: true, sentCount: totalSent, batchId: batchId }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    if (body.type === 'group_join_request') {
      const { recipientEmails, groupName, requesterName, churchName, dashboardUrl } = body;
      const subject = `New request to join ${groupName}`;
      const html = `<p>Hi,</p><p><strong>${requesterName}</strong> has requested to join <strong>${groupName}</strong> at ${churchName} on FaithDock.</p><p><a href="${dashboardUrl}">Review this request in your dashboard</a></p>`;

      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: 'FaithDock <invites@faithdock.com>', to: recipientEmails, subject: subject, html: html }),
      });
      const data = await res.json();
      if (!res.ok) {
        return new Response(JSON.stringify({ error: data }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
      }
      return new Response(JSON.stringify({ success: true, data }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    if (body.type === 'ownership_handoff') {
      const { email, churchName } = body;
      const subject = `You've been offered ownership of ${churchName} on FaithDock`;
      const html = `<p>Hi,</p><p>You've been offered ownership of <strong>${churchName}</strong> on FaithDock. Nothing changes until you accept — sign in (or create an account with this same email address) to review and respond.</p><p><a href="https://faithdock.com/#signup">https://faithdock.com/#signup</a></p><p>If you don't recognize this or weren't expecting it, you can safely ignore this email — no action is taken unless you actively accept.</p>`;

      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: 'FaithDock <invites@faithdock.com>', to: [email], subject: subject, html: html }),
      });
      const data = await res.json();
      if (!res.ok) {
        return new Response(JSON.stringify({ error: data }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
      }
      return new Response(JSON.stringify({ success: true, data }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    // Congregation member invite — bulk CSV import and the individual
    // "Resend invite" button both land here. One personalized email
    // per recipient (chunked in batches of 100 via Resend's batch
    // endpoint, same shape mass_email already uses, just with each
    // entry's own html instead of one shared html) so the greeting
    // can use each person's actual name rather than a generic one.
    if (body.type === 'member_invite') {
      const { recipients, churchName, inviterName, signupUrl } = body;
      if (!recipients || !recipients.length) {
        return new Response(JSON.stringify({ error: 'No recipients provided.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      // reply_to the actual sender, same reasoning and pattern as
      // mass_email above -- the Directory/People tab this is triggered
      // from (bulk CSV import, the per-row "Resend invite" button) has
      // no visible staff permission gate either, so inviterName here
      // can already be a staff member's own name, not necessarily the
      // owner's. getUser(jwt) is the only extra call needed; the
      // client already sends its auth header on every
      // supabase.functions.invoke() call.
      const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
      let senderEmail = null;
      const authHeader = req.headers.get('Authorization');
      if (authHeader) {
        try {
          const { data: authData } = await supabaseAdmin.auth.getUser(authHeader.replace('Bearer ', ''));
          senderEmail = authData && authData.user ? authData.user.email : null;
        } catch (e) { /* best-effort — proceed without a sender email */ }
      }

      const subject = `You're invited to connect with ${churchName} on FaithDock`;
      const chunkSize = 100;
      let totalSent = 0;
      for (let i = 0; i < recipients.length; i += chunkSize) {
        const chunk = recipients.slice(i, i + chunkSize);
        const payload = chunk.map((r) => {
          const firstName = (r.name || '').split(' ')[0] || 'there';
          const html = `<p>Hi ${firstName},</p><p>${inviterName} has invited you to connect with <strong>${churchName}</strong> on FaithDock — see upcoming events, groups, and updates from your church home.</p><p>Sign up using this email address (${r.email}) and you'll be connected automatically:</p><p><a href="${signupUrl}">${signupUrl}</a></p>`;
          return senderEmail
            ? { from: 'FaithDock <invites@faithdock.com>', to: [r.email], subject: subject, html: html, reply_to: senderEmail }
            : { from: 'FaithDock <invites@faithdock.com>', to: [r.email], subject: subject, html: html };
        });
        const res = await fetch('https://api.resend.com/emails/batch', {
          method: 'POST',
          headers: { 'Authorization': `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });
        if (!res.ok) {
          const errData = await res.json();
          return new Response(JSON.stringify({ error: errData, sentBeforeError: totalSent }), {
            status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
          });
        }
        totalSent += chunk.length;
      }

      return new Response(JSON.stringify({ success: true, sentCount: totalSent }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    // Event contact notify — one personalized email per contact (same
    // batched-with-per-recipient-html shape as member_invite above);
    // the client only calls this for a contact who's newly added or
    // newly opted into "Notify" on this particular save, not on every
    // re-save of an already-notified one.
    if (body.type === 'event_contact_notify') {
      const { recipients, eventTitle, eventWhen, churchName, addedByName } = body;
      if (!recipients || !recipients.length) {
        return new Response(JSON.stringify({ error: 'No recipients provided.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      // reply_to the actual sender, same reasoning and pattern as
      // mass_email above -- event creation/editing (where a contact
      // gets added) is reachable by any staff member with
      // canManageEvents, not just the owner, so addedByName here is
      // frequently a staff member's own name.
      const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
      let senderEmail = null;
      const authHeader = req.headers.get('Authorization');
      if (authHeader) {
        try {
          const { data: authData } = await supabaseAdmin.auth.getUser(authHeader.replace('Bearer ', ''));
          senderEmail = authData && authData.user ? authData.user.email : null;
        } catch (e) { /* best-effort — proceed without a sender email */ }
      }

      const subject = `You've been added as a contact for ${eventTitle}`;
      const chunkSize = 100;
      let totalSent = 0;
      for (let i = 0; i < recipients.length; i += chunkSize) {
        const chunk = recipients.slice(i, i + chunkSize);
        const payload = chunk.map((r) => {
          const firstName = (r.name || '').split(' ')[0] || 'there';
          const html = `<p>Hi ${firstName},</p><p>${addedByName ? addedByName + ' has' : 'You\'ve'} listed you as a contact for <strong>${eventTitle}</strong>${eventWhen ? ' (' + eventWhen + ')' : ''} at ${churchName} on FaithDock.</p><p>People interested in the event may reach out to you with questions about it.</p>`;
          return senderEmail
            ? { from: 'FaithDock <invites@faithdock.com>', to: [r.email], subject: subject, html: html, reply_to: senderEmail }
            : { from: 'FaithDock <invites@faithdock.com>', to: [r.email], subject: subject, html: html };
        });
        const res = await fetch('https://api.resend.com/emails/batch', {
          method: 'POST',
          headers: { 'Authorization': `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });
        if (!res.ok) {
          const errData = await res.json();
          return new Response(JSON.stringify({ error: errData, sentBeforeError: totalSent }), {
            status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
          });
        }
        totalSent += chunk.length;
      }

      return new Response(JSON.stringify({ success: true, sentCount: totalSent }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    // Default: staff invite notification. Unlike the other three
    // branches above, "Add staff by email" is owner-only in the UI
    // (gated behind isOwner client-side) -- inviterName here is always
    // the owner's own name, never a staff member's, since staff can't
    // reach this form at all. Still worth the same reply_to fix: it's
    // a strict improvement over no reply_to at all (today's behavior,
    // replies going to the shared invites@faithdock.com address), and
    // keeps this branch consistent with the other three rather than
    // being the one exception.
    const supabaseAdminForInvite = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    let inviteSenderEmail = null;
    const inviteAuthHeader = req.headers.get('Authorization');
    if (inviteAuthHeader) {
      try {
        const { data: inviteAuthData } = await supabaseAdminForInvite.auth.getUser(inviteAuthHeader.replace('Bearer ', ''));
        inviteSenderEmail = inviteAuthData && inviteAuthData.user ? inviteAuthData.user.email : null;
      } catch (e) { /* best-effort — proceed without a sender email */ }
    }

    const { email, churchName, inviterName, hasAccount, signupUrl, loginUrl } = body;
    const subject = hasAccount
      ? `You've been added to ${churchName}'s team on FaithDock`
      : `You're invited to join ${churchName}'s team on FaithDock`;
    const html = hasAccount
      ? `<p>Hi,</p><p>${inviterName} has added you as staff for <strong>${churchName}</strong> on FaithDock. Sign in to see your new dashboard access.</p><p><a href="${loginUrl}">${loginUrl}</a></p>`
      : `<p>Hi,</p><p>${inviterName} has invited you to join <strong>${churchName}</strong>'s team on FaithDock.</p><p>Sign up using this email address and you'll automatically join the team:</p><p><a href="${signupUrl}">${signupUrl}</a></p>`;

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(
        inviteSenderEmail
          ? { from: 'FaithDock <invites@faithdock.com>', to: [email], subject: subject, html: html, reply_to: inviteSenderEmail }
          : { from: 'FaithDock <invites@faithdock.com>', to: [email], subject: subject, html: html }
      ),
    });
    const data = await res.json();
    if (!res.ok) {
      return new Response(JSON.stringify({ error: data }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }
    return new Response(JSON.stringify({ success: true, data }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }
});
