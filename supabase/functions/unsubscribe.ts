// EDITED 2026-09-22, NOT YET CONFIRMED DEPLOYED: this function no
// longer tries to show anybody a page. It records the opt-out and
// redirects to faithdock.com/#unsubscribed with the outcome in ?u=.
//
// The reason is a platform rule, not a preference. Supabase serves
// every edge function response from *.supabase.co with:
//
//     Content-Type: text/plain          (overriding whatever we set)
//     X-Content-Type-Options: nosniff
//     Content-Security-Policy: default-src 'none'; sandbox
//
// which is an anti-phishing measure for the shared supabase.co
// origin. HTML returned from here is therefore shown to the person as
// source code. It was, for every unsubscribe until this change: a
// wall of raw markup on a black screen, at the exact moment somebody
// is already annoyed enough to be leaving. Setting the header
// correctly does not help, because ours is discarded.
//
// Redirecting moves the page to our own origin where it renders, is
// bilingual, and looks like FaithDock. The opt-out is still recorded
// here, before the redirect, so the outcome does not depend on the
// person ever arriving.
//
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

// Where the person ends up. SITE_URL is overridable so a staging
// deploy does not send people to production, but the default is the
// real site because that is what almost every send is.
const SITE_URL = Deno.env.get('SITE_URL') ?? 'https://faithdock.com';

// 303 rather than 302. The request that got here is a GET whose side
// effect has already happened; 303 says plainly 'go and GET this
// other thing instead', which is the honest description and what
// every intermediary handles most predictably.
//
// The outcome rides in ?u= ahead of the fragment because the client
// is a hash router -- anything after the # belongs to it.
function finish(outcome: 'ok' | 'expired' | 'invalid' | 'error'): Response {
  return new Response(null, {
    status: 303,
    headers: {
      Location: `${SITE_URL}/?u=${outcome}#unsubscribed`,
      // Nothing about this response is worth keeping: the next person
      // to click a link has a different token and a different result.
      'Cache-Control': 'no-store',
    },
  });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const churchId = url.searchParams.get('c') ?? '';
  const email = (url.searchParams.get('e') ?? '').toLowerCase();
  const token = url.searchParams.get('t') ?? '';

  if (!churchId || !email || !token) {
    return finish('invalid');
  }

  const [expiryRaw, signature] = token.split('.');
  const expiry = Number(expiryRaw);
  if (!expiry || !signature) {
    return finish('invalid');
  }
  if (expiry < Math.floor(Date.now() / 1000)) {
    return finish('expired');
  }
  const expected = await hmac(`${churchId}.${email}.${expiry}`);
  if (!safeEqual(signature, expected)) {
    return finish('invalid');
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
    return finish('error');
  }

  // A GET that changes state is how every unsubscribe link works, and
  // mail clients pre-fetch links. That is acceptable here precisely
  // because the action is the one the person wanted and is reversible
  // from their account -- the opposite trade to a delete.
  return finish('ok');
});
