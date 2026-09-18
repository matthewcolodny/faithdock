-- Run in Supabase SQL Editor.
--
-- Gives churches.owner_id the foreign key it never had.
--
-- === How this was found ===
--   select conname, confdeltype from pg_constraint
--    where conrelid = 'churches'::regclass
--      and confrelid = 'auth.users'::regclass;
--   -> Success. No rows returned.
--
-- Not CASCADE, not SET NULL, not RESTRICT. Nothing. Deleting a user
-- left the church row in place holding the id of somebody who no longer
-- exists:
--
--   * nobody can sign in to manage it, because its owner is gone
--   * it is NOT claimable either -- review_church_claim (007) only
--     assigns churches whose owner_id is NULL, and a dead id is not null
--   * it stays in the public directory, run by no one
--   * and on a paid plan, Stripe keeps charging a card that nobody can
--     now reach the billing portal to stop
--
-- === Why RESTRICT and not the alternatives ===
--
-- CASCADE would delete the church and everything under it -- events,
-- groups, giving history, staff -- because one person closed their
-- account. It would also destroy the row holding stripe_subscription_id
-- while the subscription carried on billing, which is exactly the bug
-- migration-less v146 fixed on the church-delete path. Irreversible and
-- silent: the worst pair.
--
-- SET NULL is defensible -- the church becomes unclaimed and somebody
-- could claim it back. It is rejected because it makes closing an
-- account a way to quietly hand a live church, with its members and its
-- giving history, to whoever claims it next. That should be a decision,
-- and FaithDock already has one: transfer.
--
-- RESTRICT makes the database enforce what the application already
-- says. delete-account refuses while the caller owns a church, and this
-- is the same rule one layer down, where it cannot be bypassed by
-- calling the endpoint directly. A blocked delete is recoverable; a
-- cascade is not.
--
-- NOTE, so it is not a surprise later: after this, deleting a user from
-- the Supabase dashboard will FAIL while they still own a church, with
-- a foreign key error. That is the constraint working. Transfer or
-- delete the church first, the same as the app requires.

-- === Refuse to run if it would paper over existing damage ===
-- Adding the constraint would fail anyway on a bad row, but with a
-- generic message. This names the churches instead, because each one is
-- a live church nobody can reach and the decision about it belongs to a
-- person, not to an ALTER TABLE.
do $precheck$
declare
  v_bad int;
  v_names text;
begin
  select count(*), string_agg(c.name, ', ')
    into v_bad, v_names
    from churches c
    left join auth.users u on u.id = c.owner_id
   where c.owner_id is not null and u.id is null;

  if v_bad > 0 then
    raise exception
      'STOPPED: % church(es) are owned by a user that no longer exists (%). '
      'Each one is unmanageable and unclaimable. Decide what happens to them '
      '-- set owner_id to NULL to make them claimable again, or delete them -- '
      'and re-run. Adding the constraint first would only hide them.',
      v_bad, v_names;
  end if;

  raise notice 'OK: no church is owned by a missing user.';
end
$precheck$;

alter table churches drop constraint if exists churches_owner_id_fkey;
alter table churches
  add constraint churches_owner_id_fkey
  foreign key (owner_id) references auth.users(id)
  on delete restrict;

notify pgrst, 'reload schema';

do $verify$
declare
  v_rule char;
begin
  select con.confdeltype into v_rule
    from pg_constraint con
   where con.conrelid = 'churches'::regclass
     and con.confrelid = 'auth.users'::regclass
     and con.contype = 'f';

  if v_rule is null then
    raise exception 'VERIFY FAILED: the foreign key was not created.';
  end if;
  -- Checking it exists is not enough: the whole point is WHICH rule it
  -- carries, and a cascade here would be worse than no constraint.
  if v_rule <> 'r' then
    raise exception 'VERIFY FAILED: the foreign key exists but its ON DELETE rule is %, not RESTRICT.', v_rule;
  end if;

  raise notice 'OK: churches.owner_id now references auth.users ON DELETE RESTRICT.';
end
$verify$;
