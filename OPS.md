# Pending operational work

Work that is known, intended, and not yet done -- and that lives outside
this repository. DNS records, third-party dashboards, account structure,
secrets. None of it is in the code, so none of it shows up in a diff or
a code review, which is exactly why it needs writing down somewhere.

Each entry says **the state today** (verified, not remembered), **why it
matters**, and **what doing it involves**.

The distinction between the three files:

- [`GOTCHAS.md`](GOTCHAS.md) -- what was broken, and how it was fixed.
- [`POLICY.md`](POLICY.md) -- what has not been decided.
- this file -- what has been decided but not yet done, off-repo.

When one is finished, move it to "Done" at the bottom with the date.
The state it ended in is worth more later than the fact it was on a list.

---

## 1. Nobody is reading our DMARC reports

**Today**, verified by DNS lookup on 2026-09-21:

```
_dmarc.faithdock.com  TXT
  v=DMARC1; p=quarantine; adkim=r; aspf=r;
  rua=mailto:dmarc_rua@onsecureserver.net;
```

`onsecureserver.net` is the registrar's own default address, not ours.
The policy itself is sound -- `p=quarantine` with relaxed alignment, and
Resend passes it via DKIM on the root domain plus SPF on `send.` -- but
every aggregate report the receiving world sends back about our domain
goes somewhere we cannot read.

**Why it matters:** DMARC aggregate reports are the only mechanism that
tells you somebody is sending mail as `@faithdock.com` who is not us.
There is no other signal. You find out through the reports, or you find
out when a church tells you they got a phishing email from FaithDock.
They are also the evidence you would want before tightening to
`p=reject`, which is where this should eventually land.

**What doing it involves.** The naive version is to point `rua` at an
address we own:

```
v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:dmarc@faithdock.com;
```

That works, and needs no extra authorization record because the mailbox
is on the same domain as the policy. But what arrives is gzipped XML,
one file per reporting provider per day, and in practice nobody reads
it. An unread mailbox is the state we are already in.

The practical version is a free DMARC report reader -- Postmark's DMARC
Digests, dmarcian, or URIports all have free tiers. You sign up, they
give you an address, you put it in `rua`, and they email a plain-English
weekly summary instead of raw XML. They also publish the cross-domain
authorization record on their side automatically, which otherwise has to
be done by hand: a `rua` address on a different domain is ignored unless
that domain publishes `faithdock.com._report._dmarc.<theirdomain>`
saying it accepts reports for us.

Both addresses can be listed if you want the raw files kept as well:

```
rua=mailto:dmarc@faithdock.com, mailto:<service-address>;
```

The record is edited wherever faithdock.com's DNS is hosted -- the
registrar, given the `onsecureserver.net` default currently in place.

**Not urgent.** Nothing is broken and no mail is failing. It is worth
doing before signups open, because that is when the domain becomes worth
spoofing.

---

## 2. Two Resend accounts, one of them empty

**Today:** there are two Resend accounts -- a personal one
(`matthewcolodny`) and one created around 2026-09-14 against the Google
Workspace (`faithdock`). Only the personal one is live.

Established by DNS and by inference rather than by looking, on
2026-09-21: `faithdock.com` carries exactly one DKIM key at the standard
`resend._domainkey` selector, so it can be verified in only one account.
And Resend disabled the personal account's webhook for *failed delivery
of events*, which requires events to have existed -- an account that
sends nothing generates nothing to fail. So the personal account holds
the verified domain and the API key in `RESEND_API_KEY`.

**Why it matters:** production email is reachable only through a personal
Gmail login. That is a single point of failure with no second holder.

**What doing it involves.** Not a migration. Moving accounts means a new
DKIM key, a DNS swap, sending broken until it propagates, rotating
`RESEND_API_KEY`, rebuilding the webhook, and losing the send history.

The cheap route is Settings -> Team in the existing account: invite the
workspace address as an owner. Same account, same domain, same key, no
DNS change -- it just stops being the only way in. Then delete the empty
`faithdock` account so there is one obvious place to look.

**Unverified:** Resend's free plan may cap the account at a single team
seat. If the invite is gated behind Upgrade, a real migration becomes
the only option, and should be done as its own deliberate operation
rather than alongside anything else.

---

## Done

### Insights numbers verified against real data -- 2026-09-22

All four Insights loaders were moved from browser-side aggregation to
Postgres RPCs (migrations 077 and 078) and then checked against SQL
written independently from what the old JavaScript did. Twenty-four
scalar comparisons, all matching.

Verifying it needed data that did not exist. Test 7 was seeded
deliberately (supabase/checks/seed_test7.sql), checked, then cleaned
up -- because zeros cannot verify anything: 0 = 0 matches whether the
SQL is right or wrong, and the first run against an unseeded church
reported a clean pass that meant nothing.

**The case most likely to be wrong was right.** A gift stored at
2026-09-01 04:30 UTC is 2026-08-31 23:30 in America/Chicago. It
landed in August: the month totals came back 10245 and 7035, matching
the seed exactly. Bucketed in UTC they would have read 4567 and 12713
and the chart would have disagreed with the church's own books.

The two deliberate definitional splits also held: attendance by age
reported 2 while people by age reported 1, from a church containing
one person, which is check-ins versus people demonstrated rather than
asserted; and the donor counts came back 4 and 1, so the giving page
and the people report are provably not using the same rule.

**What it did not establish.** The check runs as the SQL Editor's
role, which bypasses RLS, so the invoker-rights path is still
untested -- these functions are SECURITY INVOKER precisely so that a
caller sees only what RLS allows, and nothing here proves that holds.
A signed-in staff member reading correct numbers off the real Insights
page is the remaining check, and it is a small one.

Also worth recording: two predictions in the seed were wrong. It
expected 3 registrations and 1 group; the answers were 4 and 2,
because Test 7 already held a registration and a group. Both sides of
each comparison agreed, so the verification stands -- but a stated
expectation that assumed an empty church was not a safe assumption.


### Verify JWT was on for `resend-webhook` -- fixed 2026-09-21

Endpoint re-enabled in Resend the same day, and the whole chain probed
end to end: gateway open, `RESEND_WEBHOOK_SECRET` set, Svix verification
running, `apply_resend_webhook_event` present and correctly toothless to
an anonymous caller (SECURITY INVOKER against a table with RLS on and
SELECT-only policies, so it matches zero rows). The one thing not
verifiable from outside is which event types the Resend endpoint
subscribes to.

Resend disabled the webhook endpoint after every event since deployment
on 2026-09-15 was rejected. The cause was Supabase's per-function
"Verify JWT", which defaults **on**: Resend has no Supabase JWT and never
will, so the gateway returned `UNAUTHORIZED_NO_AUTH_HEADER` before a
single line of the function ran. It had therefore never worked, on any
event, for the whole six days it existed. The same defect had been found
and fixed on `unsubscribe` hours earlier.

The tell is specific and worth recognising again: a plain request to the
function URL returns `401` with an `sb-error-code` header. A function
whose gate is open answers in its own voice instead -- `400`, `405`,
whatever it does with a request it does not like -- and its response
carries `x-deno-execution-id`.

Verified state of all four functions after the fix:

| Function | Gateway | Why |
| --- | --- | --- |
| `unsubscribe` | open | called from an email link, no session |
| `stripe-subscription-webhook` | open | called by Stripe, signed instead |
| `resend-webhook` | open | called by Resend, Svix-signed instead |
| `smooth-action` | closed | called by our own signed-in client |

`smooth-action` being closed is correct and must stay that way. Three of
the four are deliberately open, which makes "off" the common case and
"on" the exception -- the opposite of the default, and the reason this
keeps happening.

The lasting lesson is that none of this is visible from the repository.
The function's own header comment had stated the requirement in plain
words since the day it was written, and it still shipped wrong, because
a comment cannot set a toggle in somebody else's dashboard. Any new
function called by a third party needs the gate checked by probing the
deployed URL, not by reading the source.
