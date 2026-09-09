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
// Confirmed deployed and working as of 2026-09-09 (this file is the exact
// version live in production), including the event_contact_notify feature
// and the member_invite fix documented in GOTCHAS.md.
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
      const { recipientEmails, subject, bodyHtml, churchName } = body;
      if (!recipientEmails || !recipientEmails.length) {
        return new Response(JSON.stringify({ error: 'No recipients found for this audience.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      const fromLine = `${churchName} via FaithDock <invites@faithdock.com>`;
      const html = `<div>${bodyHtml}</div><p style="color:#8791A5;font-size:12px;margin-top:24px;">Sent via FaithDock on behalf of ${churchName}.</p>`;

      const chunkSize = 100;
      let totalSent = 0;
      for (let i = 0; i < recipientEmails.length; i += chunkSize) {
        const chunk = recipientEmails.slice(i, i + chunkSize);
        const payload = chunk.map((email) => ({ from: fromLine, to: [email], subject: subject, html: html }));
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

      const subject = `You're invited to connect with ${churchName} on FaithDock`;
      const chunkSize = 100;
      let totalSent = 0;
      for (let i = 0; i < recipients.length; i += chunkSize) {
        const chunk = recipients.slice(i, i + chunkSize);
        const payload = chunk.map((r) => {
          const firstName = (r.name || '').split(' ')[0] || 'there';
          const html = `<p>Hi ${firstName},</p><p>${inviterName} has invited you to connect with <strong>${churchName}</strong> on FaithDock — see upcoming events, groups, and updates from your church home.</p><p>Sign up using this email address (${r.email}) and you'll be connected automatically:</p><p><a href="${signupUrl}">${signupUrl}</a></p>`;
          return { from: 'FaithDock <invites@faithdock.com>', to: [r.email], subject: subject, html: html };
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

      const subject = `You've been added as a contact for ${eventTitle}`;
      const chunkSize = 100;
      let totalSent = 0;
      for (let i = 0; i < recipients.length; i += chunkSize) {
        const chunk = recipients.slice(i, i + chunkSize);
        const payload = chunk.map((r) => {
          const firstName = (r.name || '').split(' ')[0] || 'there';
          const html = `<p>Hi ${firstName},</p><p>${addedByName ? addedByName + ' has' : 'You\'ve'} listed you as a contact for <strong>${eventTitle}</strong>${eventWhen ? ' (' + eventWhen + ')' : ''} at ${churchName} on FaithDock.</p><p>People interested in the event may reach out to you with questions about it.</p>`;
          return { from: 'FaithDock <invites@faithdock.com>', to: [r.email], subject: subject, html: html };
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

    // Default: staff invite notification.
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
      body: JSON.stringify({ from: 'FaithDock <invites@faithdock.com>', to: [email], subject: subject, html: html }),
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
