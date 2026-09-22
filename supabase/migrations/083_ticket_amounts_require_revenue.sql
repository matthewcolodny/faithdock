-- Run in Supabase SQL Editor.
--
-- Ticket income is income.
--
-- The last finding in docs/staff-permission-audit.md. Migration 079 put
-- donations behind can_view_revenue; ticket payments sat in
-- event_registrations, readable by any staff member, and the Reports
-- page printed them. Same exposure, different table, one page over.
--
-- WHY THIS ONE CANNOT BE A POLICY. RLS grants rows, and the rows are
-- needed: event_registrations is the check-in roster. A volunteer at a
-- door has to read the registration to tick somebody off. The sensitive
-- part is five columns, and row-level security has nothing to say about
-- columns.
--
-- So: column privileges. PostgreSQL will not let a column be revoked
-- while table-level SELECT is granted -- table-level implies every
-- column, including ones that do not exist yet -- so SELECT is revoked
-- and re-granted column by column.
--
-- CONSEQUENCE WORTH KNOWING. Any column added to event_registrations
-- from now on is unreadable until somebody grants it explicitly. That
-- fails closed, which is the safe direction, but it will eventually
-- surprise somebody whose new field comes back as an error rather than
-- a null. Recorded here and in the audit so it is findable when it
-- happens.
--
-- WHAT STAYS READABLE: payment_status. Whether a person paid is
-- operational -- the desk needs it, the registrant list shows it -- and
-- it is not an amount. What they paid is revenue.

-- ---------------------------------------------------------------------
-- Column privileges.
--
-- Enumerated rather than computed, deliberately. A loop over
-- information_schema would grant whatever it found, which is the same
-- as granting everything and defeats the point; this list is the
-- decision, and adding to it should be a deliberate act.
-- ---------------------------------------------------------------------
revoke select on event_registrations from authenticated;
revoke select on event_registrations from anon;

grant select (
  id,
  event_id,
  user_id,
  status,
  created_at,
  role,
  checked_in_at,
  guest_name,
  guest_email,
  guest_count,
  payment_status,          -- whether, not how much
  stripe_checkout_session_id,
  discount_code_id         -- which code, not what it was worth
) on event_registrations to authenticated;

-- Withheld: amount_paid_cents, discount_amount_cents, stripe_fee_cents,
-- application_fee_cents, net_amount_cents. Reachable only through the
-- function below.

-- ---------------------------------------------------------------------
-- The one way to read amounts.
--
-- SECURITY DEFINER, unlike the Insights functions, and for a reason
-- that is the mirror of theirs. Those aggregate data the caller may
-- already read, so invoker rights let RLS keep deciding. This one
-- exists precisely to read columns the caller may NOT read, so it has
-- to run as owner -- which means the permission check inside it is the
-- entire boundary, and there is no RLS behind it to catch a mistake.
--
-- Mirrors the rule in migration 079 exactly: owner, or staff holding
-- can_manage_giving or can_view_revenue. If those two ever disagree, a
-- church would see ticket income and not donations, or the reverse.
-- ---------------------------------------------------------------------
create or replace function get_ticket_payments(
  target_church_id uuid,
  p_from timestamptz default null,
  p_to   timestamptz default null
)
returns table (
  registration_id       uuid,
  event_id              uuid,
  event_title           text,
  event_price_cents     integer,
  person_name           text,
  created_at            timestamptz,
  payment_status        text,
  amount_paid_cents     integer,
  net_amount_cents      integer,
  discount_amount_cents integer,
  discount_code         text,
  role                  text
)
language plpgsql
security definer
set search_path = public
stable
as $fn$
begin
  if not (
    exists (select 1 from churches c
            where c.id = target_church_id and c.owner_id = auth.uid())
    or exists (select 1 from church_staff s
               where s.church_id = target_church_id and s.user_id = auth.uid()
                 and (coalesce(s.can_manage_giving, false) or coalesce(s.can_view_revenue, false)))
  ) then
    -- Raise rather than return nothing. An empty result reads as "this
    -- church has sold no tickets", which is a claim, and the wrong one.
    raise exception 'Not permitted to read ticket payments for this church.'
      using errcode = '42501';
  end if;

  return query
  select er.id,
         e.id,
         e.title,
         e.price_cents,
         p.full_name,
         er.created_at,
         er.payment_status,
         er.amount_paid_cents,
         er.net_amount_cents,
         er.discount_amount_cents,
         dc.code,
         er.role
  from event_registrations er
  join events e on e.id = er.event_id
  left join profiles p on p.id = er.user_id
  left join event_discount_codes dc on dc.id = er.discount_code_id
  where e.church_id = target_church_id
    and (p_from is null or er.created_at >= p_from)
    and (p_to   is null or er.created_at <= p_to)
  order by er.created_at;
end
$fn$;

-- ---------------------------------------------------------------------
-- What YOU paid.
--
-- The revoke above is about church income, and a person cancelling
-- their own paid registration is not reading church income -- they are
-- reading their own receipt. The cancel confirmation quotes the amount
-- back to them ("you paid $12.00; cancelling does not refund you"),
-- which is exactly the moment somebody deserves a number rather than a
-- blank.
--
-- Scoped to auth.uid() with no parameter for whose row to read, so it
-- cannot be pointed at anybody else.
-- ---------------------------------------------------------------------
create or replace function my_paid_amount_for_event(p_event_id uuid)
returns integer
language sql
security definer
set search_path = public
stable
as $fn$
  select er.amount_paid_cents
  from event_registrations er
  where er.event_id = p_event_id
    and er.user_id = auth.uid()
    and er.payment_status = 'succeeded'
  limit 1;
$fn$;

revoke all on function my_paid_amount_for_event(uuid) from public, anon;
grant execute on function my_paid_amount_for_event(uuid) to authenticated;

revoke all on function get_ticket_payments(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function get_ticket_payments(uuid, timestamptz, timestamptz) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify.
-- ---------------------------------------------------------------------
do $verify$
declare
  n_money_granted int;
  n_roster_cols   int;
begin
  -- The five money columns must not be selectable by authenticated.
  select count(*) into n_money_granted
  from information_schema.column_privileges
  where table_name = 'event_registrations'
    and grantee = 'authenticated'
    and privilege_type = 'SELECT'
    and column_name in ('amount_paid_cents','discount_amount_cents',
                        'stripe_fee_cents','application_fee_cents','net_amount_cents');
  if n_money_granted > 0 then
    raise exception 'VERIFY FAILED: % money column(s) still readable by authenticated.', n_money_granted;
  end if;

  -- And the roster must still work, or check-in breaks at a door on a
  -- Sunday morning, which is the worst possible time to find out.
  select count(*) into n_roster_cols
  from information_schema.column_privileges
  where table_name = 'event_registrations'
    and grantee = 'authenticated'
    and privilege_type = 'SELECT'
    and column_name in ('id','user_id','guest_name','guest_email','role',
                        'status','checked_in_at','event_id','payment_status');
  if n_roster_cols <> 9 then
    raise exception 'VERIFY FAILED: the roster needs 9 columns and has %. Check-in would break.', n_roster_cols;
  end if;

  if has_function_privilege('anon', 'get_ticket_payments(uuid, timestamptz, timestamptz)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can execute get_ticket_payments.';
  end if;

  raise notice 'OK: ticket amounts need a revenue ability; the roster is untouched.';
end
$verify$;
