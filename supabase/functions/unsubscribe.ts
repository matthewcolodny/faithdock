// Deploy by hand from the Supabase dashboard as a function named
// `unsubscribe`, with "Verify JWT" turned OFF.
//
// JWT verification MUST be off. The whole point is that somebody who
// cannot sign in -- an imported address with no account, a person on a
// phone that is not logged in -- can still stop the mail. Requiring a
// session here would make the opt-out not work, which under CAN-SPAM is
// the same as not having one.
//
// What replaces the JWT is a signed token generated when the email was
// sent. It proves this link came from us and names exactly one church
// and one address. Nothing else is accepted.
//
// Secrets this needs (Settings -> Edge Functions -> Secrets):
//   UNSUBSCRIBE_SECRET   any long random string, shared with the sender
//   SUPABASE_URL         already present
//   SUPABASE_SERVICE_ROLE_KEY  already present

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SECRET = Deno.env.get('UNSUBSCRIBE_SECRET')!;

// --- The token -------------------------------------------------------
//
// churchId.email.expiry, HMAC-SHA256 over exactly that string. The
// expiry is in it so a link found in an old forwarded email cannot be
// replayed years later, and the church id is in it so a token for one
// church can never unsubscribe somebody from another.
async function hmac(data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(SECRET),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Constant-time compare. A plain === leaks, through timing, how much of
// a guessed signature was right, which is enough to forge one given
// patience. Not a theoretical concern for a public endpoint.
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function makeUnsubscribeToken(churchId: string, email: string, daysValid = 180) {
  const expiry = Math.floor(Date.now() / 1000) + daysValid * 86400;
  const payload = `${churchId}.${email.toLowerCase()}.${expiry}`;
  return `${expiry}.${await hmac(payload)}`;
}

function page(title: string, body: string, status = 200): Response {
  return new Response(
    `<!doctype html><meta charset="utf-8">
     <meta name="viewport" content="width=device-width,initial-scale=1">
     <title>${title}</title>
     <body style="font-family:system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1.5rem;line-height:1.6;color:#16233F;">
       <h1 style="font-size:1.4rem;">${title}</h1>${body}
     </body>`,
    { status, headers: { 'Content-Type': 'text/html; charset=utf-8' } },
  );
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const churchId = url.searchParams.get('c') ?? '';
  const email = (url.searchParams.get('e') ?? '').toLowerCase();
  const token = url.searchParams.get('t') ?? '';

  if (!churchId || !email || !token) {
    return page('That link is incomplete', '<p>Please use the unsubscribe link exactly as it appears in the email.</p>', 400);
  }

  const [expiryRaw, signature] = token.split('.');
  const expiry = Number(expiryRaw);
  if (!expiry || !signature) {
    return page('That link is not valid', '<p>Please use the unsubscribe link from the email.</p>', 400);
  }
  if (expiry < Math.floor(Date.now() / 1000)) {
    return page('That link has expired', '<p>Open a more recent message from this church and use the unsubscribe link there, or reply asking them to remove you.</p>', 410);
  }
  const expected = await hmac(`${churchId}.${email}.${expiry}`);
  if (!safeEqual(signature, expected)) {
    return page('That link is not valid', '<p>Please use the unsubscribe link from the email.</p>', 400);
  }

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // Only the church and the address. record_email_optout resolves the
  // account itself (migration 073) -- auth.users is not reachable from
  // a supabase-js client even with the service role, so the lookup has
  // to happen inside a SECURITY DEFINER function, not out here.
  const { error } = await admin.rpc('record_email_optout', {
    p_church_id: churchId,
    p_email: email,
    p_source: 'link',
  });

  if (error) {
    console.error('record_email_optout failed', error);
    return page('Something went wrong', '<p>We could not record that just now. Please try the link again, or reply to the email and ask to be removed.</p>', 500);
  }

  // A GET that changes state is how every unsubscribe link works, and
  // mail clients pre-fetch links. That is acceptable here precisely
  // because the action is the one the person wanted and is reversible
  // from their account -- the opposite trade to a delete.
  return page(
    'You have been unsubscribed',
    `<p>You will not receive further email from this church through FaithDock.</p>
     <p style="color:#5a6478;font-size:0.95rem;">This does not affect any other church, and it does not close your account.
     You can turn it back on from your account settings at any time.</p>`,
  );
});
