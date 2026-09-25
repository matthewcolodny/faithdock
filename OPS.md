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

**One migration is pending as of 2026-09-25: 099.** 091-096 and 098
are run and verified and are under Done below; 097 is run and
deliberately inert.

## Migration 099 -- the church list cannot show what was just imported

**State today (2026-09-25):**
`supabase/migrations/099_admin_churches_import_columns.sql` is written
and committed. It has **not** been run. Until it does, the All churches
list says "needs migration 099" and names the file rather than showing
PostgREST's schema-cache wording. Verified in a local preview.

**Why it matters:** 22 rows were imported into 1,309 and there was no
way to find them again. The list returned no dates and no batch, sorted
by name, so a fresh import scattered alphabetically through the whole
table.

**What it involves:** paste the file into the SQL Editor and run it. It
replaces `search_all_churches_admin` -- adding `created_at`,
`import_batch_id`, `import_source_filename` and `is_hidden` to the
result, and `p_sort` / `p_batch` arguments. It DROPS the old
four-argument signature first, deliberately: CREATE OR REPLACE cannot
change an argument list, so without the drop there would be two
overloads live and PostgREST would pick one at random. Migration 020
hit exactly that with `admin_import_churches`.

Read the assertion block at the bottom: it fails if more than one
`search_all_churches_admin` exists afterwards, which is the specific
thing that goes wrong here. Like 098, it cannot call the function --
admin RPCs are unreachable from the SQL Editor.

## The Maps API key rejects localhost, so the map cannot be tested locally

**State today (2026-09-25):** measured, not assumed. Loading the app
from `http://localhost:5173` gives
`Google Maps JavaScript API error: RefererNotAllowedMapError`, and the
console names the URL it wants authorising. Everything that goes
through Google -- the coverage map, the church page map, address
autocomplete, and geocoding during a CSV import -- is dead locally.

**Why it matters:** it is the right default, and it also means map work
can only be verified on a deployed preview or in production. Anything
"verified locally" that involves Maps was not.

**What it involves, if wanted:** Google Cloud Console → the Maps
JavaScript API key → Website restrictions → add
`http://localhost:5173/*`. Worth weighing: it widens where the key can
be used from, and the key ships in the page anyway, so the restriction
list is the only thing limiting it. Leaving it alone is defensible.

## Google Play — blocked on a D-U-N-S number

**State today (2026-09-24):** the code and assets are finished. Waiting
on a D-U-N-S number from Dun & Bradstreet, which the LLC needs before
Play Console will accept an **organisation** account. Parked
deliberately, not forgotten.

**Why the organisation account matters:** individual accounts registered
since late 2023 must run a closed test with 12 testers for 14 continuous
days before they can apply for production. Organisations are exempt. The
D-U-N-S wait is the cheaper of the two delays.

**Done already, nothing more needed:**

- Manifest is TWA-ready; 1024/512 and maskable PNGs exist
- Play billing compliance is in the code — `window.isAndroidAppShell()`
  and the gate inside `startPlanCheckout()`. Donations and event tickets
  are exempt and untouched; church plans cannot be bought in the app
- `.well-known/` is confirmed served by Cloudflare Pages (measured, with
  an empty `[]` placeholder still in place)
- `store/feature-graphic.png`, 1024×500
- `store/listing.md` — title, short and full descriptions, all within
  Play's limits
- [`PLAY.md`](PLAY.md) is the runbook

**What is left, in order:**

1. D-U-N-S arrives → register Play Console **as the organisation**. The
   LLC's legal name and address must match the D&B record exactly, or
   verification bounces and the wait restarts.
2. Screenshots — at least two, taken from the app on a real phone.
   The only asset not generated.
3. Build the package (PWABuilder or Bubblewrap). Set the TWA launch URL
   to `/?shell=android` — **not** the manifest's `start_url`, which is
   shared with the ordinary installed PWA.
4. Take the SHA-256 from **Play Console → Setup → App signing**, not the
   local keystore — Google re-signs the app. Put it in
   `.well-known/assetlinks.json`; `tools/check.js` validates the shape
   once it is no longer empty.
5. Fill in **App content → App access** with working test credentials.
   The app is invite-gated, so a reviewer cannot exercise it otherwise,
   and that is a standard rejection.
6. Data safety form, agreeing with the site's privacy policy.

## `SUPABASE_DB_URL` repository secret

For `.github/workflows/security-invariants.yml`. Until it is added the
weekly security check is skipped rather than run — so the invariants
only run when somebody remembers to run them, which is the problem they
were written to solve.

**The role exists and is deliberately inert.** Migration 097 created
`ci_invariants` with **NOLOGIN and no password**: correct shape, not
connectable. It is NOINHERIT, not superuser, holds no table grants of
its own, and can only `SET ROLE` to `anon` or `authenticated` — which is
all the checks need, once it is enabled.

**Enable it only at the moment you are setting the GitHub secret**, as a
single statement typed by hand and never committed:

```sql
alter role ci_invariants login password '<generated>';
```

Then immediately build the connection string and paste it into GitHub →
Settings → Secrets and variables → Actions, named `SUPABASE_DB_URL`.
Leaving the role enabled with the secret unset is the worst of both —
a live credential doing no work.

```
postgresql://ci_invariants.<project-ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres
```

Take the host and project-ref from the dashboard's **Connect** sheet
(`O` then `C` — it is no longer under Database Settings), **Session
pooler** tab. Not the direct connection: Supabase serves that over IPv6
only without the paid add-on, and GitHub runners have no IPv6. The
pooler wants `role.project-ref` as the username, which is easy to get
subtly wrong.

**Then trigger the workflow by hand** from the Actions tab
(`workflow_dispatch` is enabled) rather than waiting for Monday. That is
the first real test of the role, and it is worth finding out
immediately.

Note: testing it with `set role ci_invariants` in the SQL Editor proves
nothing about the role switching. `SET ROLE` is checked against the
session user, which would still be `postgres` there, so the nested
`set role anon` would succeed whatever `ci_invariants` can do. Only a
real connection as that role tests it.
---
---
---

---

## Done

### Migration 098 run -- the coverage map has data -- 2026-09-25

```
unmapped,mappable,total
0,1287,1287
```

Every church in the table is geocoded. Nothing is missing from the map.

**1,287 in the table against 800 that `search_churches` returns to an
anonymous visitor.** The difference is 487 hidden rows -- the
non-Christian and zero-signal ministries filtered out after the San
Antonio import. Worth knowing before reading the map: 38% of what it
draws is not in the directory, so counting it overstates coverage. The
map has a "Count hidden churches" toggle for exactly this, on by
default, and the summary line names the number either way.

**It took two runs.** The first ended with
`select * from admin_church_coverage_cells(0)`, which raised "You do
not have permission to view the coverage map." That was the gate
working. `is_platform_admin()` reads
`profiles.is_platform_admin where id = auth.uid()`, and the SQL Editor
carries no JWT -- so it returns false for everyone, always, whoever is
logged into the dashboard. **No admin RPC in this database can be
called from the SQL Editor**; they are only reachable from the app,
signed in. The editor also wraps the script in one transaction, so that
error rolled back the functions created above it and nothing was left
half-applied.

The verify block now asserts from `pg_proc` -- both functions exist,
are SECURITY DEFINER, executable by `authenticated` and not by `anon`
-- and raises rather than printing a column nobody reads. The data
check runs the function's own grouping directly against `churches`.

Third time a verify step has been the thing that was wrong here: 092
verified signed out against a membership policy, 094 printed a grant it
had predicted incorrectly. **A check that cannot fail for the right
reason is not a check.**

### Migration 097 -- CI-only role -- verified 2026-09-24, then reworked the same day

**Read this before writing another migration that creates a role.**

The first version shipped a placeholder password with a comment saying
to replace it before running. It was run as written — reasonably, since
it looked runnable — which created a login role on the production
database whose password was published in a **public** repository. A
placeholder password in a runnable statement is not a placeholder. It
is a password.

The role is NOINHERIT with no table grants, which sounds contained and
is not: it can `SET ROLE authenticated` and then set
`request.jwt.claims` to any user id, which is impersonation of any
member or church owner. Closed within minutes by
`alter role ci_invariants nologin;`.

The migration now creates the role **NOLOGIN with no password at all**.
Run as written it produces something nobody can connect to; enabling it
is a separate statement typed by hand. Re-running it on an enabled role
disables it again — the safe direction. `tools/check.js` was also
guarding the wrong thing (it allowed the placeholder); it now rejects
any password literal in that file's runnable SQL.

### Migration 097 -- the role's shape, verified 2026-09-24

`ci_invariants`, for the weekly security check, so CI never holds the
master database password. That mattered more than it first looked:
Supabase does not let you retrieve the database password after project
creation — the dashboard offers only a reset, which it warns will break
existing connections. Using the master credential would have meant
resetting a password other things may depend on, in order to hand a CI
job the keys to everything.

`NOINHERIT` is the load-bearing word. The checks have to switch roles,
so the role must be a member of `anon` and `authenticated`; ordinary
membership would hand it their privileges passively, including writes
through every permitting RLS policy. `NOINHERIT` grants only the right
to `SET ROLE`. Anything that does not switch explicitly gets nothing.

```
can_login              true
inherits_passively     false     <- the one that mattered
is_superuser           false
can_create_db          false
can_create_role        false
member_of              anon, authenticated
reads_tables_as_itself 0
```

`tools/check.js` fails the build if the migration's password
placeholder ever goes missing — the file is exactly the kind someone
fills in, runs, and then commits. Verified against a copy with a
real-looking password substituted.

### Migration 096 -- events manage policy documented and de-duplicated -- verified 2026-09-24

`events` carried a policy, "owner and permitted staff can manage
events", calling `can_manage_church_events(uuid)`. Neither appeared in
any migration, while all twelve other policy helpers did. It duplicated
"owner or staff can manage events" from 082, which wrote the same test
inline.

Not a hole. The two rules were compared by the migration's own preflight
against every real (user, church) pair and agreed on all of them, so
neither was looser. The problem was that the repository was not a
complete description of the database: a rebuild from these migrations
would have silently lacked the rule.

096 recorded the function with `CREATE OR REPLACE` (byte-identical, so
no behaviour change and existing grants kept) and dropped 082's inline
copy. Verified output:

```
events_select_policies : 3
duplicate_remaining    : 0
remaining_policies     : Drafts staff-only; members-only needs membership
                         | owner and permitted staff can manage events
                         | public events are visible to all
auth_can_execute       : true
```

Dropping a PERMISSIVE policy can only narrow access, never widen it, so
the exposure invariants could not regress from this — the meaningful
check was the opposite one, that owners and staff kept event management,
which the preflight's pair-by-pair comparison established before the
drop.

Two observations recorded while reading the full policy dump, neither
acted on:

- `staff_beyond_checkin()` is fail-open for a *new* ability.
  `is_checkin_only_staff()` works by enumerating every ability flag, so
  a twelfth ability granted on its own makes someone "not check-in
  only", which grants broad church-wide read. Worth remembering before
  the next `can_*` column is added to `church_staff`.
- Most policy helpers grant `EXECUTE` to `anon`. Harmless today — they
  are all keyed on `auth.uid()`, which is null for anon — but the
  `contact_messages` and `event_checkin_links` helpers are restricted to
  `authenticated`, so the tighter default was clearly intended at some
  point and never applied generally.

### Registrant lists and payment reports after 083 -- verified 2026-09-24

Carried for a while as "needs a click-through". It did not; it needed
reading the grant list against the client.

083 revoked table-level SELECT on `event_registrations` and re-granted
column by column, and warns in its own header that any column not on
that list fails closed. So the question was whether the app reads a
column it was not granted.

Every column the client selects from `event_registrations`:

```
checked_in_at, event_id, id, payment_status, role, status, user_id
```

All seven appear in 083's grant to `authenticated` and in 085's
matching grant to `anon`. Nothing reads a withheld column: the five
amount columns never appear in a `from('event_registrations')` select
at all. Amounts reach the client only through `get_ticket_payments`
(three call sites) and `my_paid_amount_for_event` (one), which is
exactly the single door 083 built, and the anon side of it was
measured when 085 ran (`amount_paid_cents` -> 42501 through the
function, `[]` from the table).

Nothing to click. Closed.

### Migration 095 run -- anon revoked, deceased permitted -- 2026-09-24

```
anon_can_read,authenticated_can_read,kind_constraint,policies_on_log
false,true,"CHECK ((kind = ANY (ARRAY[left, removed, deceased])))",1
```

Closes the grant 094 left open. Nothing had leaked -- RLS returned
`[]` to anon throughout, measured before and after -- but the table
privilege is gone now, so the log no longer depends on a single policy
holding.

`deceased` is a legal kind. Nothing writes it. The joins-and-leaves
chart already filters to `left` and `removed`, verified with a
deceased row present: three departures in the data, two on the chart.

### Migration 094 run -- departures are recorded -- 2026-09-24

```
rls_on,trigger_present,policies_on_log,authenticated_can_read,anon_can_read,logging_starts
true,true,1,true,true,2026-09-24
```

Four of the six as intended. `anon_can_read` came back **true** where I
had said false -- see migration 095 under Pending, which revokes it.
No data was exposed (RLS returns `[]` to anon, measured), but the
prediction was wrong and the verify block had not checked it. Worth
keeping as the pattern: **assert the grants you expect, do not just
print them.** A printed column is only caught if somebody reads it.

Departure logging begins 2026-09-24. Months that ended before then are
drawn blank rather than zero on the joins-and-leaves chart, because
those are different claims.

### Migration 093 run -- members-only events hole closed -- 2026-09-24

The policy "private events visible to members" tested only that a
`church_memberships` row EXISTED for the caller -- no `is_permanent`,
no `status`. Since migration 035 lets anyone insert their own row for
any church ("Request to join", trigger forces `status := pending`),
any signed-in account could request membership anywhere and read that
church's hidden events immediately. A rejected row still counted.

Dropped. Nothing replaced it -- 092's policy already covers the real
case through `is_approved_church_member()`.

Four SELECT-capable policies remain on `events`, all narrow:

| policy | grants a read to |
| --- | --- |
| Drafts staff-only; members-only needs membership | the intended rule (092) |
| public events are visible to all | `visibility = 'public'` only |
| owner and permitted staff can manage events | `can_manage_church_events()` |
| owner or staff can manage events | owner, or staff with `can_manage_events` |

Verified signed out, after: 0 private, 0 draft, and an unfiltered
query returns only `public` rows. Ordinary anonymous browsing still
works (3 events, 200) -- the failure mode that matters most here, and
the one migration 085 had to repair once already.

**Now measured, 2026-09-24.** The signed-in non-member case was the
one gap: closed by reading the policy text, not by testing. The user
requested membership at a church holding a members-only event and
still could not see the event. That is the exact bypass 093 closed --
a pending `church_memberships` row no longer unlocks anything -- and
it is now confirmed from the direction that matters, by somebody
signed in rather than by an anonymous request that could never have
matched a membership row in the first place.

**The lesson, since it cost two migrations:** 092 was verified signed
OUT, where `auth.uid()` is null and matches no membership row. That
test was structurally incapable of catching a policy keyed on
membership. What found it was the policy COUNT in 092's own output --
three where one was expected. Enumerate the policies on a table BEFORE
writing one, not after; permissive policies OR together and the
loosest wins.

### Migration 092 run -- members-only events are hidden -- 2026-09-24

The event form's third visibility option says "Members only -- hidden
from everyone except your members" and stores visibility='private'.
The SELECT policy read `visibility <> 'draft' or owner or staff`, so
private fell through the first branch and was visible to the whole
internet.

Measured on production, signed out, with only the anon key that ships
in the page:

```
                    before   after
visibility=private     5        0
visibility=draft       0        0
visibility=public      3        3
```

11 private events existed at the time of the fix.

The four read paths that had to survive are named in the policy:
approved members, anyone already registered, check-in volunteers at
the door, and owner/full staff. Anonymous check-in links never
consulted this policy -- `checkin_link_open` is SECURITY DEFINER.

Left an open question behind it, now under Pending above: there are
three SELECT policies on `events` and only one of them has been read.

### Migration 091 run -- group sign-ups counted, activity dated -- 2026-09-23

Shipped with build 2026-09-23-v255 and run the same day. Verified
output:

```
dir_authenticated,dir_anon,activity_authenticated,activity_anon,group_flag_returned,group_only_people_now_visible
true,false,true,false,true,2
```

`dir_anon` false is the one that mattered: this migration DROPS and
recreates `get_directory_people`, and a drop takes every grant with
it while Postgres hands EXECUTE to PUBLIC on the new function by
default. Had the revoke not taken, every signed-out visitor would
have had a church's member list.

`group_only_people_now_visible` = 2 is the live bug this closed: two
people whose only connection to their church is a group were absent
from the directory entirely, and the "Group sign-ups" filter had
never matched anybody because the flag it reads was returned by
nothing.

Its column names came from `supabase/checks/reports_schema_probe.sql`
rather than from memory -- which is why it needed no correction,
unlike 089. `group_members` has `joined_at` and no `created_at`, the
opposite of the obvious guess, and `donations` uses `donor_id`.

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

### Cloudflare Email Routing says "Misconfigured". Leave it. -- 2026-09-25

The Email Routing page shows faithdock.com as Enabled / DNS records
**Misconfigured** / 0 emails received. That is the correct state, and
the one thing not to do is click whatever button offers to fix it.

Measured, not assumed:

```
faithdock.com   MX   1   smtp.google.com
```

Cloudflare Email Routing receives mail by owning the domain's MX and
pointing it at route1/2/3.mx.cloudflare.net. Ours points at Google
Workspace, because mcolodny@faithdock.com is a real Workspace mailbox.
Two services cannot both hold the MX for one domain. "Misconfigured"
means only "Email Routing is switched on and is not the one receiving
mail" -- accepting Cloudflare's fix would replace the Workspace MX and
stop all inbound mail to the domain.

Routing was presumably enabled to explore it and never turned off.
Turning it off is the tidy-up; it changes nothing either way, since it
has never handled a message. It does contribute the Cloudflare rua
address now sitting in the DMARC record alongside Postmark's, which is
harmless.

**Outbound is unaffected and always was.** Sending is Resend, which
never touches MX -- MX is inbound only.

### Sending addresses are not mailboxes -- 2026-09-25

`invites@faithdock.com`, and now `messages@faithdock.com`, are string
literals in `supabase/functions/smooth-action.ts`. Neither has a
mailbox anywhere. Resend authorises the whole verified DOMAIN, so any
local part sends without a DNS change:

- DKIM signs with `d=faithdock.com`, key at `resend._domainkey`
- SPF is evaluated against the MAIL FROM subdomain
  `send.faithdock.com`, which carries its own
  `include:dc-fd741b8612._spfm.send.faithdock.com`
- DMARC has `aspf=r`, so that subdomain aligns with the root

The root domain's own SPF is `include:_spf.google.com ~all` and does
**not** list Resend. It does not need to: SPF authenticates MAIL FROM,
not the From header.

Changing a sending address is therefore a one-line code change. What
it cannot do is create somewhere for mail to arrive. Anything sent to
either address depends on Google Workspace having an alias or
catch-all for it -- unverified, and worth checking before any address
is printed somewhere a human might write to it. The contact-church
branch does not depend on this, because `reply_to` is the visitor.

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
