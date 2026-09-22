# Staff permissions: what they gate, and what they don't

Audit run 2026-09-22, after `can_view_revenue` turned out to gate a nav
link rather than the data behind it (migration 079, GOTCHAS).

Findings only. Nothing here is fixed except `donations`, which is what
prompted the audit.

## The model the database actually implements

Reading the policies together, there is a consistent design, and it is
not an accident:

> **Abilities gate writing. Membership gates reading.**

`church_rooms`, `giving_funds`, `event_rooms`, `event_questions` and
`event_discount_codes` all have a SELECT policy that asks only "are you
staff here" and an ALL policy that additionally requires
`can_manage_events` or `can_manage_giving`.

That is a defensible position: any staff member can see how the church
operates; only some can change it. It should be stated somewhere rather
than inferred, because half the findings below are only findings if you
disagree with it, and the other half are places the model was not
followed.

`donations` was the one table where reading is as sensitive as writing,
which is why it needed the stricter rule and now has it.

## Tier 1 — abilities that do not restrict writing

These matter most, because somebody can **do** a thing they were
explicitly told they cannot. In each case an ability exists, the client
hides the page, and the database allows the write anyway to anyone with
a `church_staff` row.

| Table | Policy | Ability bypassed |
| --- | --- | --- |
| `scheduled_messages` | ALL, membership only | `can_manage_messages` |
| `church_memberships` | ALL, membership only | `can_manage_members` |
| `events` | ALL, membership only | `can_manage_events` |
| `groups` | ALL, membership only | `can_manage_groups` |
| `group_members` | UPDATE, DELETE, membership or leader | `can_manage_groups` |
| `group_attendance` | ALL, membership only | `can_check_in` |
| `church_member_invites` | ALL, membership only | `can_manage_members` |
| `households`, `household_members` | ALL, membership only | `can_manage_members` |

**`scheduled_messages` is the worst of these.** A staff member with no
messaging ability can schedule mail to the whole congregation. It is
outward-facing, effectively irreversible once sent, and lands with the
church's name on it.

**`events` is the clearest inconsistency.** Its own child tables --
`event_questions`, `event_rooms`, `event_discount_codes` -- all require
`can_manage_events`. The parent does not. So a staff member without the
ability cannot add a question to an event but can delete the event.

## Tier 2 — reads that membership is the wrong bar for

| Table | What is in it |
| --- | --- |
| `event_registrations` | `amount_paid_cents`, `guest_email`, `guest_name`, payment status |
| `event_question_answers` | free-text answers to whatever the church asked |

`event_registrations` is the gap in the fix that prompted this audit.
Migration 079 closed giving, but ticket revenue lives here, and the
Reports page renders it. So the money is still readable by any staff
member -- through a different page, from a different table, by the same
mechanism.

`event_question_answers` deserves a look before a decision. Churches
write their own registration questions, and the plausible ones include
dietary requirements, medical notes, a child's age, who is allowed to
collect them. None of that is operational data in the sense rooms and
funds are.

## `can_check_in` gates nothing, anywhere

It is settable in the permissions UI, displayed as a tag on the staff
list, and sent on invite. The client reads it zero times.
`group_attendance` is membership-only in the database. Migration 045
created it.

`index.html` already says so, in the comment above the check-in focus
mode:

> "NOT a security boundary, and it must not be mistaken for one ... The
> real boundary is can_check_in (migration 045)"

The comment names the boundary. The boundary was never wired up.

**The scenario that makes this concrete.** A church adds a volunteer to
run the welcome desk on a Sunday and gives them `can_check_in` and
nothing else. Because reading is gated by membership rather than by
ability, that volunteer can read the full directory, every group's
membership, household structures, event registrations with payment
amounts, and -- until migration 079 -- all-time giving. They were given
one ability; they received the whole staff read surface.

Whether that is acceptable is a product decision, not a bug. But it
should be a decision.

## What is correctly gated today

Worth recording so a later pass does not "fix" these:

- `donations` SELECT -- `can_manage_giving OR can_view_revenue` (079)
- `giving_funds` ALL -- `can_manage_giving`
- `church_rooms` ALL -- `can_manage_events`
- `event_rooms`, `event_questions`, `event_discount_codes` ALL -- `can_manage_events`
- `church_staff_invites` ALL -- owner only
- `church_staff` DELETE -- owner, or removing yourself

## Client-side, separately

Six nav links get an ability check: billing, facility, giving,
messages, ministries, staff. These do not: **events, checkin,
directory, groups, insights, insights-reports, insights-saved, plans,
settings.**

- **directory** shows names, emails and phone numbers with no check,
  while `can_manage_members` exists.
- **insights-reports** hosts the payment reports, which is the
  `event_registrations` exposure above with a print button.
- **insights** was ungated entirely until 079's client half; attendance
  and groups figures remain so, which is probably right.

## Suggested order

1. **`scheduled_messages`** -- outward-facing and irreversible. Smallest
   change, largest consequence avoided.
2. **`event_registrations` SELECT** -- finishes the job 079 started;
   ticket revenue should sit behind the same bar as giving.
3. **Decide the read model explicitly**, then apply it. Either
   membership is the right bar for reading operational data -- in which
   case write it down and close only the Tier 1 write gaps -- or it is
   not, and `can_check_in` volunteers need a narrower surface. Doing
   Tier 1 without that decision leaves the more interesting half open.
4. **`events` ALL** -- if only for consistency with its own children.
5. **`event_question_answers`** -- after looking at what churches
   actually ask.

## What this audit did not cover

Only policies mentioning `church_staff` or `is_church_staff_member`.
Tables whose policies are written some other way, and anything reachable
through a SECURITY DEFINER function, were not examined -- a definer
function bypasses RLS entirely, so its own internal checks are the whole
boundary, and those were not read here.
