-- Run in Supabase SQL Editor. Requires 107_denomination_case.sql.
--
-- Folds "Other Christian" into "Other".
--
-- Both are the same bucket -- "none of the above" -- and having them
-- adjacent in the filter reads as the list being broken rather than as
-- two meanings. "Other" is in the display vocabulary index.html can
-- translate; "Other Christian" is not. It is the tail of the filter
-- CATEGORY "Nontrinitarian / Other Christian", which belongs to
-- denomination_tags and leaked into the display column on the way in.
--
-- Five churches.
--
-- Not to be confused with the other pair that looked like a duplicate:
-- "Non-denominational" and the blank group are opposites -- a church
-- that states it has no denomination, against a field nobody filled in
-- -- and the blank group is now labelled "Not recorded" in the panel so
-- it stops reading as a second Non-denominational.

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname = 'public' and p.proname = 'fd_norm_denom') then
    raise exception 'ABORT: fd_norm_denom is missing. Run 107_denomination_case.sql first.';
  end if;
end $$;

do $$
declare
  moved integer;
begin
  update churches
     set denomination = 'Other'
   where fd_norm_denom(denomination) = 'other christian'
     and denomination is distinct from 'Other';
  get diagnostics moved = row_count;
  raise notice 'Other Christian -> Other  (% churches)', moved;
end $$;

do $$
declare
  leftovers integer;
  n_other   integer;
begin
  select count(*) into leftovers from churches
   where fd_norm_denom(denomination) = 'other christian';
  if leftovers > 0 then
    raise exception 'VERIFY FAILED: % rows still say Other Christian.', leftovers;
  end if;

  select count(*) into n_other from churches where fd_norm_denom(denomination) = 'other';
  raise notice 'OK. % churches now under Other.', n_other;
end $$;
