-- Run in Supabase SQL Editor.
--
-- Account-less check-in: a link (and QR) that lets a door volunteer
-- work one event's roster without a FaithDock account.
--
-- Today check-in requires a session and the owner/can_manage_events/
-- can_check_in rule from 045. That is right for staff, and wrong for
-- the person who shows up on a Sunday to hold a tablet. The current
-- answer is to hand them a signed-in device -- which is why focused
-- mode exists -- but a signed-in device is still a signed-in device,
-- and it is one URL edit away from the Directory.
--
-- === What the token is and is not ===
-- It is a bearer secret: whoever holds the link can work that ONE
-- event's roster until it expires or is revoked. That is the whole
-- point, so it must be bounded rather than merely secret:
--   * scoped to a single event, never a church
--   * expiring, with a default tied to the event itself
--   * revocable at any moment, taking effect on the next request
--   * names only -- no email, no phone, no user id (see below)
--
-- === Why the token is stored in plain text ===
-- Hashing it would mean showing it once and never again, so a church
-- that loses the QR printout has to issue a new one. Weighed against
-- the exposure -- one event's attendee NAMES, for a bounded window,
-- revocable -- the usability of reprinting the same code wins. The
-- row is readable only by people who could already open that roster
-- while signed in, so the token grants them nothing new.

create table if not exists event_checkin_links (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  -- 244 bits from two v4 uuids. Deliberately not gen_random_bytes():
  -- that needs pgcrypto, and depending on an extension for the one
  -- thing that must never be guessable is a dependency worth not
  -- having. Hex is URL-safe by construction, so the token survives
  -- being a path segment without encoding.
  token text not null unique,
  label text,
  created_by uuid references auth.users(id) on delete set null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  -- Not for accounting, for deciding. "Has anyone actually used this
  -- one?" is the question a person asks before revoking a link they
  -- no longer recognise.
  last_used_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists event_checkin_links_event_idx
  on event_checkin_links (event_id, created_at desc);

alter table event_checkin_links enable row level security;

-- === Who may manage links ===
-- The same rule as set_registration_checked_in() after 045:
--     owner OR can_manage_events OR can_check_in
-- Extracted as a function here because this migration needs it in
-- four places. NOTE: 045 still carries the rule inline, so it now
-- lives in two places. Consolidating means replacing a function that
-- is currently the only thing making check-in work at all, which is
-- not a change to make in passing -- it is worth doing on its own,
-- with its own verification.
create or replace function can_run_event_checkin(p_church_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $fn$
  select exists (
      select 1 from churches c
       where c.id = p_church_id and c.owner_id = auth.uid()
    ) or exists (
      select 1 from church_staff cs
       where cs.church_id = p_church_id
         and cs.user_id = auth.uid()
         and (coalesce(cs.can_manage_events, false) or coalesce(cs.can_check_in, false))
    );
$fn$;

revoke all on function can_run_event_checkin(uuid) from public;
grant execute on function can_run_event_checkin(uuid) to authenticated;

drop policy if exists "Check-in staff manage their event links" on event_checkin_links;
create policy "Check-in staff manage their event links"
  on event_checkin_links for select to authenticated
  using (
    exists (select 1 from events e
             where e.id = event_checkin_links.event_id
               and can_run_event_checkin(e.church_id))
  );

drop policy if exists "Check-in staff revoke their event links" on event_checkin_links;
create policy "Check-in staff revoke their event links"
  on event_checkin_links for update to authenticated
  using (
    exists (select 1 from events e
             where e.id = event_checkin_links.event_id
               and can_run_event_checkin(e.church_id))
  )
  with check (
    exists (select 1 from events e
             where e.id = event_checkin_links.event_id
               and can_run_event_checkin(e.church_id))
  );

drop policy if exists "Check-in staff delete their event links" on event_checkin_links;
create policy "Check-in staff delete their event links"
  on event_checkin_links for delete to authenticated
  using (
    exists (select 1 from events e
             where e.id = event_checkin_links.event_id
               and can_run_event_checkin(e.church_id))
  );

-- === Grants, REVOKING FIRST ===
-- The lesson from 050: this project grants new public tables to both
-- roles by default, so naming columns in a GRANT adds nothing unless
-- something takes the table-wide privilege away first. Without the
-- revoke below, anon could read every token in the database.
revoke all on event_checkin_links from anon;
revoke all on event_checkin_links from authenticated;

grant select on event_checkin_links to authenticated;
-- Only the handled state. A link's token, event and expiry are what
-- it IS; changing them would silently turn a revoked link back into
-- a working one, or repoint a printed QR code at a different event.
grant update (label, revoked_at) on event_checkin_links to authenticated;
grant delete on event_checkin_links to authenticated;
-- No INSERT to anyone: links are created only through the function
-- below, which is what generates the token. A hand-written row could
-- carry a token somebody chose.

-- === Creating a link ===
create or replace function create_event_checkin_link(
  p_event_id uuid,
  p_label text default null,
  p_expires_at timestamptz default null
)
returns event_checkin_links
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_event events%rowtype;
  v_expires timestamptz;
  v_row event_checkin_links%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated.';
  end if;

  select * into v_event from events where id = p_event_id;
  if v_event.id is null then
    raise exception 'EVENT_NOT_FOUND';
  end if;
  if not can_run_event_checkin(v_event.church_id) then
    raise exception 'NOT_PERMITTED_TO_CHECK_IN';
  end if;

  -- Defaults to the event plus a few hours, so a link that nobody
  -- thinks about again stops working on its own. A door code that
  -- outlives the door is the failure this feature has to avoid.
  v_expires := coalesce(
    p_expires_at,
    coalesce(v_event.end_at, v_event.start_at + interval '4 hours') + interval '6 hours'
  );
  if v_expires <= now() then
    raise exception 'CHECKIN_LINK_EXPIRY_IN_PAST';
  end if;
  -- A ceiling regardless of what was asked for. Without it "expires"
  -- is a field rather than a property.
  if v_expires > now() + interval '90 days' then
    raise exception 'CHECKIN_LINK_EXPIRY_TOO_FAR';
  end if;

  insert into event_checkin_links (event_id, token, label, created_by, expires_at)
  values (
    p_event_id,
    replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
    nullif(btrim(coalesce(p_label, '')), ''),
    auth.uid(),
    v_expires
  )
  returning * into v_row;

  return v_row;
end;
$fn$;

revoke all on function create_event_checkin_link(uuid, text, timestamptz) from public;
grant execute on function create_event_checkin_link(uuid, text, timestamptz) to authenticated;

-- === Resolving a token ===
-- One internal helper, so "is this link usable right now" is answered
-- in exactly one place. Two copies of an expiry check is how a
-- revoked link keeps working on one of the two paths.
create or replace function checkin_link_event_id(p_token text)
returns uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $fn$
  select l.event_id
    from event_checkin_links l
   where l.token = p_token
     and l.revoked_at is null
     and l.expires_at > now();
$fn$;
revoke all on function checkin_link_event_id(text) from public;

-- === What the door sees ===
-- NAMES ONLY, and that is the significant line in this migration.
--
-- The signed-in roster reads user_id, guest_name, role, status and
-- the joined profile. This returns a display name, whether they are a
-- participant or a volunteer, and whether they are already checked
-- in. Nothing else, because the audience is different: a signed-in
-- staff member is someone the church chose, while the holder of this
-- link is whoever the link reached. Handing a congregation's email
-- addresses to a URL is not a thing to do for the convenience of a
-- check-in desk.
create or replace function checkin_link_open(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_event_id uuid;
  v_event events%rowtype;
  v_church_name text;
  v_roster jsonb;
begin
  v_event_id := checkin_link_event_id(p_token);
  if v_event_id is null then
    -- One answer for missing, revoked and expired alike. Telling the
    -- difference would confirm to someone guessing tokens that they
    -- had found a real one.
    return jsonb_build_object('valid', false);
  end if;

  select * into v_event from events where id = v_event_id;
  select name into v_church_name from churches where id = v_event.church_id;

  select coalesce(jsonb_agg(r order by r.name), '[]'::jsonb) into v_roster
  from (
    select er.id,
           coalesce(er.guest_name, p.full_name, 'Unknown') as name,
           er.role,
           er.checked_in_at,
           (er.guest_name is not null) as is_walk_in
      from event_registrations er
      left join profiles p on p.id = er.user_id
     where er.event_id = v_event_id
       and er.status = 'confirmed'
  ) r;

  update event_checkin_links set last_used_at = now() where token = p_token;

  return jsonb_build_object(
    'valid', true,
    'event', jsonb_build_object(
      'id', v_event.id,
      'title', v_event.title,
      'start_at', v_event.start_at,
      'church_name', v_church_name
    ),
    'roster', v_roster
  );
end;
$fn$;

revoke all on function checkin_link_open(text) from public;
grant execute on function checkin_link_open(text) to anon, authenticated;

-- === Marking someone in ===
create or replace function checkin_link_mark(
  p_token text,
  p_registration_id uuid,
  p_checked_in boolean
)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_event_id uuid;
  v_new_value timestamptz;
  v_matched integer;
begin
  v_event_id := checkin_link_event_id(p_token);
  if v_event_id is null then
    raise exception 'CHECKIN_LINK_INVALID';
  end if;

  v_new_value := case when p_checked_in then now() else null end;

  -- event_id is in the WHERE clause, not merely checked beforehand:
  -- it is what stops a valid token for one event being used to tick
  -- a registration id belonging to another. Scoping the link to a
  -- single event is the entire security model, so the scope belongs
  -- in the statement that writes.
  update event_registrations
     set checked_in_at = v_new_value
   where id = p_registration_id
     and event_id = v_event_id;
  get diagnostics v_matched = row_count;

  if v_matched = 0 then
    raise exception 'REGISTRATION_NOT_FOUND';
  end if;

  update event_checkin_links set last_used_at = now() where token = p_token;

  -- The stored value, so the caller paints what was actually written
  -- rather than what it hoped -- the same reason 044 returns it.
  return v_new_value;
end;
$fn$;

revoke all on function checkin_link_mark(text, uuid, boolean) from public;
grant execute on function checkin_link_mark(text, uuid, boolean) to anon, authenticated;

notify pgrst, 'reload schema';
