-- Run in Supabase SQL Editor.
--
-- churches.city and churches.state exist and are NULL on every row --
-- 22,401 of 22,401 measured from the client before writing this. The
-- town has only ever lived inside the address string, so the one search
-- box that suggests towns has been parsing it out per keystroke:
--
--   "122 W Fay St, Edinburg, TX"            -> Edinburg, TX
--   "1234 Evans Rd, San Antonio, TX 78258, USA" -> San Antonio, TX
--   "Dallas St, Houston, TX, USA"           -> Houston, TX
--   "PO BOX 10938, SAN ANTONIO, TX 78210-0938"  -> SAN ANTONIO, TX
--
-- This puts the same answer in the columns, once, and keeps it there.
--
-- ---------------------------------------------------------------------
-- THE RULE, AND WHERE IT GIVES UP
--
-- Split on commas; drop a trailing "USA"; the last part must START with
-- two letters (so a postcode hanging off the state does not matter) and
-- that is the state; the part before it is the town. Anything that does
-- not fit leaves both columns NULL rather than guessing -- a wrong town
-- is worse than no town, because the search would offer it.
--
-- Nothing is overwritten: the backfill only touches rows where city is
-- already NULL, which today is all of them, but that stops this from
-- clobbering a town an owner has typed if it is ever re-run.

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='churches' and column_name='city') then
    raise exception 'ABORT: churches.city does not exist.';
  end if;
end $$;

-- Two small immutable helpers rather than one inline expression: the
-- trigger below needs the same rule, and two copies of a regex is how
-- they drift apart.
create or replace function fd_address_city(addr text)
returns text language sql immutable as $$
  select nullif(btrim(p[cardinality(p) - 1]), '')
    from (select string_to_array(
                   regexp_replace(coalesce(addr, ''), ',\s*(USA|United States)\s*\.?\s*$', '', 'i'),
                   ',') as p) t
   where cardinality(p) >= 2
     and btrim(p[cardinality(p)]) ~ '^[A-Za-z]{2}($|[^A-Za-z])'
$$;

create or replace function fd_address_state(addr text)
returns text language sql immutable as $$
  select upper(substring(btrim(p[cardinality(p)]) from '^([A-Za-z]{2})'))
    from (select string_to_array(
                   regexp_replace(coalesce(addr, ''), ',\s*(USA|United States)\s*\.?\s*$', '', 'i'),
                   ',') as p) t
   where cardinality(p) >= 2
     and btrim(p[cardinality(p)]) ~ '^[A-Za-z]{2}($|[^A-Za-z])'
$$;

update churches
   set city  = fd_address_city(address),
       state = fd_address_state(address)
 where city is null
   and address is not null
   and fd_address_city(address) is not null;

-- New churches, and edited addresses, keep the columns true without
-- anyone remembering to. A town typed by hand on insert is respected; a
-- changed address re-derives, because a stale town is the failure this
-- is meant to prevent.
create or replace function fd_sync_church_city_state()
returns trigger language plpgsql as $$
begin
  if TG_OP = 'INSERT' then
    new.city  := coalesce(nullif(new.city, ''),  fd_address_city(new.address));
    new.state := coalesce(nullif(new.state, ''), fd_address_state(new.address));
  elsif new.address is distinct from old.address then
    new.city  := fd_address_city(new.address);
    new.state := fd_address_state(new.address);
  elsif new.city is null then
    new.city  := fd_address_city(new.address);
    new.state := coalesce(new.state, fd_address_state(new.address));
  end if;
  return new;
end $$;

drop trigger if exists churches_city_state_sync on churches;
create trigger churches_city_state_sync
  before insert or update on churches
  for each row execute function fd_sync_church_city_state();

-- Prefix and substring matching on a 22k-row table was ~150ms without
-- an index, which is survivable but is per keystroke. Trigram if the
-- extension will install, and nothing if it will not -- the search
-- works either way.
do $$
begin
  begin
    create extension if not exists pg_trgm;
  exception when others then
    raise notice 'pg_trgm not available (%), skipping the index.', sqlerrm;
    return;
  end;
  execute 'create index if not exists churches_city_trgm_idx on churches using gin (lower(city) gin_trgm_ops)';
end $$;

grant select (city, state) on churches to anon, authenticated;

-- ---------------------------------------------------------------------
do $$
declare
  total     bigint;
  filled    bigint;
  unparsed  bigint;
  sample    text;
begin
  select count(*) into total from churches;
  select count(*) into filled from churches where city is not null;
  select count(*) into unparsed from churches where city is null and address is not null and address <> '';

  select string_agg(city || ', ' || coalesce(state, '?'), ' | ')
    into sample
    from (select distinct city, state from churches
           where city is not null order by city limit 5) t;

  raise notice 'city/state filled on % of % churches.', filled, total;
  raise notice 'Sample: %', coalesce(sample, '(none)');
  raise notice '% rows have an address this rule could not parse; they keep NULL and are simply not offered as towns.', unparsed;

  if filled = 0 then
    raise exception 'VERIFY FAILED: nothing was filled. The address format is not what this rule expects -- do not keep this migration.';
  end if;
end $$;
