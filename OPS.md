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

### Migration 091 -- group sign-ups, and a last-activity date -- 2026-09-23

**State today:** `supabase/migrations/091_group_signups_and_activity.sql`
is in the repo and has NOT been run. The client changes that use it
shipped in build 2026-09-23-v255.

**Why it matters, in two parts.**

The first is a live bug, not a new feature. `get_directory_people`
never returned `has_group_signup`, and the client filters on exactly
that property -- so the Directory's "Group sign-ups" filter has always
matched nobody. Its WHERE clause also omits group members entirely, so
anyone whose only connection to the church is a group is missing from
the directory altogether. The probe counted **2 such people** today.
Both are fixed by this migration and by nothing else.

The second is `get_people_activity`, which the new Engagement report
needs. Until it exists that section says so rather than rendering
zeroes -- "everyone has no activity" and "the data is not available"
look identical on a chart and mean opposite things.

**What doing it involves:** paste the file into the Supabase SQL
Editor and run it. It drops and recreates `get_directory_people`, so
it re-grants EXECUTE afterwards and checks that anon did NOT keep it
-- the same failure 089 had to guard against. Expect one result row:
`dir_authenticated` and `activity_authenticated` true, both `_anon`
columns false, `group_flag_returned` true, and
`group_only_people_now_visible` showing the 2.

**Its column names came from a probe, not from memory.**
`supabase/checks/reports_schema_probe.sql` confirmed that
`group_members` has `joined_at` and no `created_at`, and that
`donations` uses `donor_id`. Worth keeping as the pattern: 089's first
draft was written from a remembered schema and got five rules wrong.

---

---

## Done

### Migration 090 run -- groups can name the ministry that runs them -- 2026-09-23

Shipped with build 2026-09-23-v248 and run the same day. Verified
output:

```
column_name,column_exists,can_select,can_update,index_exists
groups.ministry_id,true,true,true,true
```

`can_select` and `can_update` are the two that mattered. Postgres
extends TABLE-level privileges to a new column automatically but not
column-level ones, and a table that had ever been granted per-column
would have produced a column `authenticated` could not read or write
-- the same failure migration 085 had to repair on
`event_registrations`, where it silently broke public event browsing.
The migration checks for it by name rather than assuming, which is
why those two columns are in the output at all.

The client was written to work before this ran (it omitted the Groups
section rather than showing an empty one) and needs no change now
that it has: the section appears on its own.

### Migrations 084 and 085 run -- public event browsing restored -- 2026-09-22

Both were sitting in the repo unrun. 085 was the urgent one: public
event browsing on faithdock.com was broken for every signed-out
visitor, and I had broken it.

Two mistakes with the same shape, from two earlier migrations. 081
revoked `execute` on `staff_beyond_checkin` from `anon` and then wrote
that function into the events SELECT policy -- and a policy is
evaluated as the caller, so a caller without the grant gets an error
on every query rather than fewer rows. 083 revoked SELECT on
`event_registrations` from `anon` while carefully re-granting it
column by column to `authenticated` only. Neither migration tested a
signed-out page.

**Verified after running, as `anon`** -- a raw REST call carrying only
the publishable key, so PostgREST resolves the role to `anon` rather
than to a logged-in session:

- `GET /events` -> 200 with rows. The policy evaluates instead of
  erroring.
- `GET /event_registrations?select=id,status` -> `[]`. No permission
  error, so `search_events` can count remaining capacity again. Empty
  is RLS filtering rows, which is correct for a signed-out caller.
- `GET /event_registrations?select=amount_paid_cents` -> 42501,
  permission denied. The money columns did NOT come back with the
  rest, which is the half of 083 that was right.

084 added a unique index on `(church_id, lower(trim(name)))` for
active rooms, so a duplicate room name is now refused by the database
and not only by the browser. Its preflight found no existing
duplicates to rename first.

**The lesson, for the next revoke:** `authenticated` and `anon` are
two roles, and a migration that carefully re-grants one of them has
done half a job.

---

Done

### Production email is no longer behind one personal login -- 2026-09-22

Resend was reachable only through a personal Gmail account. One
person, one login, no second holder: if that account became
unreachable, nobody could rotate an API key, re-verify the domain or
read why sending had stopped.

mcolodny@faithdock.com (the Google Workspace identity) was invited to
the existing account as a team member with **full access**, and the
invite accepted. Not a migration, deliberately: same account, same
verified domain, same `RESEND_API_KEY`, no DNS change and no
gap in sending. Keys belong to the account rather than to a person, so
nothing needed rotating.

The free plan turned out to allow a second seat, which was the open
question that had stalled this. Had it not, the only route would have
been a real migration -- new DKIM key, DNS swap, sending broken until
it propagated, key rotation, webhook rebuilt, send history lost -- and
that would have wanted doing on its own rather than alongside anything
else.

The role matters as much as the invite. A view-only second seat looks
like a fix and is not one: it cannot rotate a key or re-verify a
domain, which are exactly the things needed on the day the first
login is gone.

DNS re-checked afterwards and unchanged: exactly one DKIM key at
`resend._domainkey`, so the domain is still verified in exactly
one account, and the MAIL FROM subdomain still carries its SPF and its
feedback-smtp MX.

**Left open on purpose:** the empty second Resend account, created
2026-09-14 against the Workspace, still exists. Deleting it is tidying
rather than risk reduction -- it holds no domain, no keys and no
history -- but leaving it is what made the webhook outage confusing to
diagnose, because there were two plausible places for the answer to
be. Worth removing when convenient, and safe to: it cannot affect DNS,
having never verified a domain.

---


### DMARC reports now reach us -- 2026-09-22

Aggregate reports went to dmarc_rua@onsecureserver.net, a registrar
default nobody could read -- so the one mechanism that reports
somebody sending mail as @faithdock.com was pointed at a bin. They now
go to Postmark's free DMARC Digests, which returns a weekly summary in
plain English rather than gzipped XML.

Final record, identical on 8.8.8.8 and 1.1.1.1, every tag exactly once:

```
v=DMARC1; p=quarantine; adkim=r; aspf=r;
  rua=mailto:re+as3iexljqvl@dmarc.postmarkapp.com;
```

**Two things nearly went wrong, both worth remembering.**

Postmark hands you a complete record to paste, and theirs says
`p=none`. Pasting it would have downgraded an already-correct
domain from quarantining failures to doing nothing. They default that
way because most people arrive with no policy at all; taking only the
rua address out of what they give you is the right move.

The first attempt also arrived carrying `sp=none` and a
duplicate `aspf=r`. `sp` is the subdomain policy,
and when it is absent subdomains inherit `p` -- so
`sp=none` exempted every subdomain from quarantine while doing
nothing at all for our own mail, which is From the root domain and
governed by `p`. Pure downside. The duplicate tag was untidy
rather than harmful, but a receiver strict about the RFC could treat
the whole record as malformed -- which would mean no DMARC rather than
a lenient one.

**Where this goes next.** Reports begin within 24-72 hours, weekly
digests after. The thing to watch for is a legitimate sender nobody
remembers: anything sending as @faithdock.com that is not Resend or
Google Workspace. Finding those is the whole reason to sit at
`p=quarantine` for a few weeks before considering
`p=reject` -- reject on a domain you cannot observe is how a
forgotten sender silently stops being delivered.

---

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
