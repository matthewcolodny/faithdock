# Pending policy decisions

Questions the code cannot answer, because nobody has decided them yet.

Each entry says **what happens today** (verified against the code, not
remembered), **why it matters**, and **what is waiting on it**. Nothing
here is a bug report — a bug is something the code gets wrong against a
known intention. These are the places where there is no known intention.

When one is decided, move it to a "Decided" note at the bottom with the
date and the reasoning, rather than deleting it. The reasoning is the
part that gets lost.

Related: [`GOTCHAS.md`](GOTCHAS.md) holds what was broken and how it was
fixed. This file holds what has not been decided.

---

## 1. The pricing page advertises fees that are not charged

**The most urgent item here, and it is live.**

What the pricing page says:

| | Advertised |
|---|---|
| Free plan, giving | `1% FaithDock fee applies` |
| Free plan, tickets | `3% per ticket` |
| Paid plans | `0% fee` |

What the deployed code does: `PLATFORM_FEE_PERCENT = 0` in **both**
`stripe-create-checkout.ts` and `stripe-event-checkout.ts`, for every
plan. `application_fee_amount` is therefore `0` on every donation and
every ticket. FaithDock collects nothing.

**And donors are being asked to cover it anyway.** On a Free-plan
church the Give form shows a checkbox — **ticked by default** — reading
"Add 1% so the church receives your full gift, covering FaithDock's fee
on this plan". When ticked, the client charges `amount / 0.99`. Since
the platform fee is 0, the entire uplifted amount transfers to the
church.

So a donor typing $100 is charged $101.01, told it covers a FaithDock
fee, and FaithDock takes none of it. The church receives all of it,
which is where the donor wanted their money to go — so nobody is out of
pocket in a way they would object to. But the stated reason is not true,
and it is opt-out rather than opt-in.

**The decision:** start charging what the pricing page says, or change
the pricing page and remove the cover-fee checkbox. Either is a few
lines. Shipping neither means the public pricing and the actual
behaviour keep disagreeing.

**Blocked on this:** any fee claim in customer-facing copy. The About
page deliberately says nothing about fees for exactly this reason.

---

## 2. Refunds

**Today:** none, anywhere. Nothing in the codebase issues one.

- Deleting a church cancels its plan **immediately** and the rest of the
  paid period is forfeited. The confirmation says so.
- Downgrading schedules cancellation for the end of the paid period, so
  nothing is lost — that path needs no refund.

**The decision:** is forfeiting the remainder on deletion the intended
policy? The alternative is `stripe.subscriptions.cancel(id, { prorate:
true })`, which credits the unused portion.

---

## 3. Proration when a church changes hands mid-period

**Today:** nothing. A transfer does not create, move or alter any
subscription, so there is nothing to prorate.

**The decision:** only becomes real once #4 is decided.

---

## 4. Transfer leaves the previous owner paying

**Today:** `plan_type` and the Stripe ids live on the **church row** and
travel with it. The Stripe Customer was created against the *original*
owner's email and card, and `accept_church_ownership_handoff` touches
none of it.

So after a transfer the previous owner's card still funds a church they
no longer own. Both parties are now warned about this before they act
(v143), and the billing portal no longer leaks one person's card details
to the other (v144) — but the underlying situation is unchanged.

**The options:**

1. Leave it, with the warnings. The previous owner cancels when they
   choose; the new owner starts their own plan.
2. Cancel the subscription on accept. The church drops to Free until the
   new owner subscribes — a paid church silently loses features.
3. Cancel at period end on accept. The new owner gets the rest of the
   month that was already paid for, then chooses.

Option 3 is probably right, and needs an edge-function change.

---

## 5. Grace period before a church loses paid features

**Today:** FaithDock has none of its own — it inherits Stripe's. The
webhook treats `past_due` as **active**:

```js
const isActive = sub.status === 'active' || sub.status === 'trialing' || sub.status === 'past_due';
```

So a church whose card fails keeps every paid feature for as long as
Stripe keeps retrying, and drops to Free only when Stripe cancels the
subscription. The app shows a red "past due" banner throughout and does
nothing else.

**The decision:** how long that window should be. It is a **Stripe
Dashboard setting** (Billing → retry rules), not a code change. Nobody
has chosen it, so it is whatever Stripe's default is.

---

## 6. Discounts and promotional codes for plans

**Today:** discount codes exist for **event tickets** only
(`event_discount_codes`, validated server-side, single-use limits,
percent or fixed). There is nothing equivalent for subscriptions.

**The decision:** whether plan discounts are wanted at all — a founding-
church rate, a nonprofit rate, an annual-payment discount. Stripe
supports coupons natively, so this is mostly a product question rather
than an engineering one.

---

## 7. What being over a plan's limit should mean

**Today:** nothing is ever removed on a downgrade. Limits are checked
**only at creation**:

- events: counted as *created this calendar month*, not total
- groups and staff: counted as they stand

A Large church that drops to Free keeps all 8 staff and all its groups —
it simply cannot add a 9th. Since v143 the Billing page states the
overage plainly with the real numbers.

**The decision:** is "keep everything, block new" the permanent policy?
It is the humane default and probably right. Writing it down stops it
being re-litigated by whoever next notices a Free church with 8 staff.

---

## 8. Multi-Church tier limits

**Today:** `planLimits.multi_church` is `Infinity` for events, groups and
staff, with a code comment saying this is "a placeholder meaning no
client-side cap, not a promised limit". The pricing card is a
"Contact Sales" mailto with no self-serve checkout.

**The decision:** what the negotiated limits actually are, or an explicit
"genuinely unlimited".

---

## 9. What happens to giving history when a church is deleted

**Today:** deleting a church deletes everything under it, including its
donation records. The confirmation says so: "events, groups, giving
history, staff, and its public page".

**The decision:** donors may need those records for tax purposes, and
the church may have obligations to retain them. Possibilities: export
before deletion, retain donation rows detached from the church, or a
cooling-off period before the data actually goes.

---

## 10. Data retention generally

**Today:** nothing is deleted on a schedule, anywhere. Rows live until
somebody removes them.

**The decision:** whether anything should age out — old check-in records,
declined membership requests, `client_error_logs`, contact messages.

---

## 11. Whether pending join requests count as "people"

**Today:** inconsistent, and deliberately so.

- `get_directory_people` and `get_mass_email_recipients` require
  `status = 'approved'` — somebody who merely asked to join is **not** a
  member for anything that shows them to others or emails them.
- `compute_involvement_snapshot_internal` has **no** status filter, so a
  pending request is counted among a church's people, scores 0, and is
  filed under "disengaged".

The first two were fixed as bugs (migrations 040 and 064) because they
decided who *receives* something. The third was left alone because it
decides what a *number means*, and changing a church's analytics quietly
is not the same call.

**The decision:** should the involvement metric count people who asked to
join and were not accepted? If no, it is a one-line change.

---

## 12. Staff can resolve any email address to an account

**Today:** `get_user_id_by_email` permits "owns any church, **or** is
staff of any church, **or** leads any group" — not scoped to a
particular church.

This is necessary: it resolves an email when inviting staff or adding a
group member, both of which are for people who are not in that church
yet. Scoping it per church would break the thing it exists for.

The residual risk is that any staff member anywhere can learn whether an
address has a FaithDock account. Most signup forms leak this anyway.

**The decision:** accept it explicitly, or rate-limit it. Recorded here
so it is not "fixed" into a broken invite flow by somebody who spots the
check and assumes it is an oversight.

---

## 13. Contact details within a church directory

**Today:** staff and owners always see every person's email and phone.
Members see them only if the church enables
`members_see_contact_details`, and see the directory at all only if
`directory_visibility = 'members'` (enforced since migration 063).

**The decision:** whether "staff" should be that broad. `is_church_staff_member`
is membership of `church_staff`, full stop — it does not consider
abilities, so a volunteer added to the team to help with events can read
every member's phone number.

---

## Decided

*(Move entries here with the date and the reasoning when they are
settled.)*
