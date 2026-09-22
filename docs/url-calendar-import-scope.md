# Importing a calendar from a URL

A scope, not a plan of record. Nothing here is built. It exists so the
decision can be made with the awkward parts already on the table rather
than discovered halfway through.

## The problem it solves

A church that already keeps its calendar on its own website has entered
every event once. Asking them to enter it again is the single largest
piece of work between "signed up" and "has a useful listing", and it is
work they will reasonably resent.

The file importer already covers part of this. What it does not cover is
the shape most church sites actually publish.

## What the file importer leaves on the table

Measured against a real church site (whpc.org, Squarespace) on
2026-09-22:

- There is **no whole-calendar feed**. `/allevents?format=ical` returns
  the HTML page, not a calendar.
- Every event page carries its **own** `?format=ical` link.
- That page lists 37 events, of which **7 are upcoming**; the collection
  holds 506 all-time, paginated 30 at a time.

So a church with seven upcoming events performs seven downloads and
seven trips through a file picker. Multi-file select (build v190) turns
that into one review screen, which is most of the benefit -- but the
downloads are still manual, and they must be repeated every time the
calendar changes.

## Why this cannot be done in the browser

Squarespace publishes a perfectly good JSON API: `?format=json` on the
collection returns the whole calendar in one request, with `upcoming`
and `past` arrays and full pagination.

It sends **no `Access-Control-Allow-Origin` header**. A page on
faithdock.com therefore cannot read it, and no amount of client-side
cleverness changes that -- it is the browser refusing, on the other
site's instruction, and correctly.

The same is true of essentially every church website. So a URL importer
is a server-side feature or it is nothing, and that is the whole reason
this is not a small change to the existing importer.

## Shape

An Edge Function, `calendar-fetch`, because that is where every other
server-side call in this project already lives.

**Request:** a URL, and the id of the church importing.
**Response:** the same structure `parseIcsEvents` already returns, so
the existing review modal renders it unchanged.

That last point is the main design constraint worth holding: this should
produce input for the review step that already exists, not a second
import path with its own review and its own bugs. The preview, the draft
safety model, the plan-cap exemption, the venue splitting -- all of it
stays exactly where it is.

### What the function does

1. Fetch the URL.
2. If the response is `text/calendar`, parse it and return.
3. If it is HTML, look for calendar links in it -- `?format=ical`
   hrefs, `<link rel="alternate" type="text/calendar">`, `webcal://`.
4. Fetch those, up to a limit, and merge.
5. Return events plus a plain account of what it did and did not read.

Step 3 is the part that is genuinely uncertain and should be treated as
such. It works on Squarespace because Squarespace is consistent. It will
work less well elsewhere, and the honest design is one that reports what
it found rather than one that pretends to understand every site.

### Parsing stays where it is

`parseIcsEvents` lives in `index.html` and is already tested against
real Squarespace output. Reimplementing it in the Edge Function would
create two parsers that must agree, which is the failure this codebase
has hit more than any other.

Two options, both acceptable:

- The function returns **raw .ics text** (one blob per source) and the
  client parses. Simplest, keeps one parser, costs a little bandwidth.
- The parser moves to a shared file both can import. Cleaner, more work,
  and only worth it if something else needs it server-side.

**Prefer the first** until there is a second reason to do the second.

## The parts that need a decision before any code

### 1. This is a fetcher that takes a URL from a user

Which is a server-side request forgery primitive if built carelessly.
Required, not optional:

- HTTPS only.
- Resolve the hostname and **reject private ranges** -- `127.0.0.0/8`,
  `10/8`, `172.16/12`, `192.168/16`, `169.254/16` (the cloud metadata
  endpoint), and IPv6 equivalents. Re-check after every redirect, or a
  redirect to `169.254.169.254` walks straight past the first check.
- Cap redirects, response size, and total time.
- Rate limit per church.

None of this is unusual, and all of it is easy to leave until later and
then never do.

### 2. One-time import, or a subscription?

The genuinely useful version watches the URL and keeps the listing in
step. That is also a different feature with its own questions: what
happens when an event is edited at the source after being published
here, what happens when one disappears, does a change un-publish
something a person has already seen.

**Recommendation: build the one-time import first and do not design for
the subscription.** It delivers most of the value, and the answers to
the sync questions will be much clearer after watching people use the
one-time version.

### 3. Whose events are these?

Imported events land as drafts, which is the right answer and already
settled. Worth stating explicitly here because a URL importer makes bulk
much easier, and "8 public events" on the free tier is a cap somebody
will meet through an import rather than by typing.

Drafts are exempt from the caps, so nothing breaks. But a church that
imports 40 events and can publish 8 should be told that before it
imports, not after.

### 4. Where the URL is entered

Probably beside the file picker, as a second way into the same review
step. Saving it on the church record only makes sense once #2 is
answered.

## What it is worth

The file importer plus multi-file select already covers a church willing
to click seven links. This removes those seven clicks and makes repeat
imports painless.

That is real but not enormous, and it costs an Edge Function with a
security surface that has to be got right rather than mostly right. It
is a good feature to build when churches are actually signing up and
this is the thing slowing them down -- and a poor one to build first,
because a fetcher nobody uses is still a fetcher somebody can point at
your network.

## If built, verify

Against real sites, not fixtures. The two findings that mattered most in
the file importer both came from real data and neither would have
occurred to anyone writing test cases: a line-folded `LOCATION` that
would have silently truncated every address, and a title carrying
invisible `U+FEFF` characters. Sites that are worth trying: Squarespace,
Wix, WordPress with The Events Calendar, Planning Center, and a plain
Google Calendar public feed.
