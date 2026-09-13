-- Run in Supabase SQL Editor.
--
-- Adds a multi-value "Tradition" taxonomy on top of the existing
-- single-value `churches.denomination` string, so a church whose name
-- or denomination doesn't cleanly fit one bucket -- e.g. a "Christian
-- Methodist Episcopal Church" (a real, historically Black Methodist
-- body whose own name names its polity: episcopal/bishop-led
-- governance) -- can be found under any of Methodist, Episcopal, or
-- Protestant, instead of forcing one exact-match string to carry all
-- three facts at once.
--
-- `churches.denomination` is UNCHANGED -- still the free-text specific-
-- body value, still what's displayed on the card/profile, still fully
-- translated via translateDenomination() in index.html. This migration
-- only ADDS a derived `denomination_tags text[]` column alongside it:
--
--   Family   (broad): Protestant, Catholic, Orthodox, Jewish, Non-
--             denominational
--   Movement (specific, all Protestant-family in the data seen so
--             far): Baptist, Episcopal, Lutheran, Methodist,
--             Pentecostal, Presbyterian, Anglican, Adventist, Church of
--             God, Church of Christ, Apostolic, Nazarene, Christian /
--             General
--
-- A church can carry several tags at once (a CME church: Methodist +
-- Episcopal + Protestant). Movement tag strings are deliberately kept
-- identical to the existing `denomination` values they came from
-- (Church of God, Church of Christ, etc.) rather than renamed to more
-- academic terms (Restorationist, Holiness) -- every one of those
-- strings already has EN/ES translations wired up via denomI18nKeyMap
-- in index.html, so reusing them costs zero new translation work and
-- guarantees the filter checkbox's `value` always matches what's
-- actually stored in the array.
--
-- compute_denomination_tags() is called from a BEFORE INSERT/UPDATE
-- trigger, so every future insert or edit (owner self-edit, admin edit,
-- CSV import) gets tagged automatically with no application-code
-- changes needed anywhere else -- the mapping lives in exactly one
-- place. The backfill UPDATE at the bottom re-tags every existing row
-- once, the same way the trigger will from now on.
--
-- KNOWN BEST-EFFORT / AMBIGUOUS MAPPINGS -- flagging these explicitly
-- rather than presenting them as settled:
--   * "Church of God" is tagged Protestant only (no narrower movement
--     claim) -- several unrelated bodies share this exact name (e.g.
--     Church of God (Cleveland, TN), Pentecostal, vs. Church of God
--     (Anderson, IN), Holiness) and the stored value alone can't tell
--     them apart.
--   * "Apostolic" is tagged Protestant only, for the same reason --
--     usually (but not always) Oneness Pentecostal.
--   * "Christian / General" is tagged Protestant -- a judgment call for
--     a self-described "just Christian, no specific movement" entry;
--     most such US congregations are evangelical/Protestant in
--     practice, but this is an assumption, not a verified fact per
--     church.
-- None of this is destructive or hard to revise: re-running the
-- backfill UPDATE after editing compute_denomination_tags() below is
-- safe and idempotent any time these get refined.
--
-- NOT done here (deliberately out of scope for this pass): the "For
-- You" tab's denomination-expansion feature (window.myDenominationChurchIds
-- in index.html) still matches on the exact `denomination` string, not
-- these tags -- left as-is since the ask was the Tradition filter, not
-- that recommendation feature; a church's `denomination_tags` isn't
-- editable directly in the admin/owner edit forms (it's purely
-- derived) -- if a mapping ever needs a manual per-church override
-- instead of recomputing from name/denomination, that's a follow-up,
-- not part of this migration.

alter table churches add column if not exists denomination_tags text[] not null default '{}'::text[];

create index if not exists idx_churches_denomination_tags on churches using gin (denomination_tags);

-- search_churches is SECURITY INVOKER (see migration 018's own comment
-- on is_hidden for why) -- anon/authenticated need direct column-level
-- SELECT on denomination_tags for both the RPC's WHERE clause and the
-- Events page's own client-side `.overlaps('denomination_tags', ...)`
-- query (search_events has no p_denominations-style param of its own,
-- so Events resolves this the same client-side way it already does for
-- exact-denomination matching).
grant select (denomination_tags) on churches to anon, authenticated;

-- Pure function: given a church's raw `denomination` column and `name`,
-- returns its full Family + Movement tag set. Two independent signals,
-- unioned and deduped:
--   1) NAME-based compound/specific-body phrases, checked first -- the
--      highest-confidence signal, since many congregations literally
--      spell out their full denominational body in their own name
--      (many actual "X Christian Methodist Episcopal Church" churches
--      exist) even when the `denomination` column is blank, generic,
--      or "Other".
--   2) The `denomination` column itself -- the register-church
--      dropdown's fixed set, plus bulk-CSV-import and free-text
--      "Other" values audited in migration-era GOTCHAS notes (17
--      unique live values as of that audit).
-- \m / \M are Postgres's own regex word-boundary anchors (~* is
-- case-insensitive ILIKE-style matching) -- same whole-word discipline
-- as every keyword/acronym check elsewhere in this repo's scripts/, so
-- e.g. "Agape Fellowship" never matches "AG"-style Pentecostal cues and
-- "Templeton" never matches a bare "Temple" check (not used here at all,
-- for exactly that false-positive risk -- see note below).
create or replace function compute_denomination_tags(p_denomination text, p_name text)
returns text[]
language plpgsql
immutable
as $$
declare
  tags text[] := '{}';
  d text := lower(coalesce(trim(p_denomination), ''));
  n text := coalesce(p_name, '');
begin
  -- ===== 1) Compound / specific-body name phrases =====
  if n ~* '\mAfrican Methodist Episcopal Zion\M' or n ~* '\mA\.?M\.?E\.?\s*Zion\M' then
    tags := tags || array['Methodist','Episcopal','Protestant'];
  end if;
  if n ~* '\mAfrican Methodist Episcopal\M' or n ~* '\mA\.?M\.?E\.?\M' then
    tags := tags || array['Methodist','Episcopal','Protestant'];
  end if;
  if n ~* '\mChristian Methodist Episcopal\M' or n ~* '\mC\.?M\.?E\.?\M' then
    tags := tags || array['Methodist','Episcopal','Protestant'];
  end if;
  if n ~* '\mUnited Methodist\M' or n ~* '\mFree Methodist\M' then
    tags := tags || array['Methodist','Protestant'];
  end if;
  if n ~* '\mCumberland Presbyterian\M' then
    tags := tags || array['Presbyterian','Protestant'];
  end if;
  if n ~* '\mChurch of God in Christ\M' or n ~* '\mCOGIC\M' then
    tags := tags || array['Pentecostal','Protestant'];
  end if;
  if n ~* '\mSouthern Baptist\M' or n ~* '\mMissionary Baptist\M' or n ~* '\mBaptist\M' then
    tags := tags || array['Baptist','Protestant'];
  end if;
  if n ~* '\mSeventh-day Adventist\M' or n ~* '\mSeventh Day Adventist\M' or n ~* '\mAdventist\M' then
    tags := tags || array['Adventist','Protestant'];
  end if;
  if n ~* '\mEpiscopal\M' then
    tags := tags || array['Episcopal','Protestant'];
  end if;
  if n ~* '\mLutheran\M' then
    tags := tags || array['Lutheran','Protestant'];
  end if;
  if n ~* '\mPresbyterian\M' then
    tags := tags || array['Presbyterian','Protestant'];
  end if;
  if n ~* '\mPentecostal\M' then
    tags := tags || array['Pentecostal','Protestant'];
  end if;
  if n ~* '\mAnglican\M' then
    tags := tags || array['Anglican','Protestant'];
  end if;
  if n ~* '\mNazarene\M' then
    tags := tags || array['Nazarene','Protestant'];
  end if;
  if n ~* '\mCatholic\M' then
    tags := tags || array['Catholic'];
  end if;
  if n ~* '\mOrthodox\M' then
    tags := tags || array['Orthodox'];
  end if;
  -- Deliberately NOT matching a bare "Temple" here -- plenty of
  -- Christian (often Pentecostal/Holiness) congregations use "Temple"
  -- in their own name (e.g. many Church of God in Christ
  -- congregations), so it's not a reliable Jewish signal on its own.
  if n ~* '\mSynagogue\M' or n ~* '\mJewish\M' then
    tags := tags || array['Jewish'];
  end if;

  -- ===== 2) `denomination` column (structured signal) =====
  if d = 'baptist' then tags := tags || array['Baptist','Protestant'];
  elsif d = 'catholic' then tags := tags || array['Catholic'];
  elsif d = 'episcopal' then tags := tags || array['Episcopal','Protestant'];
  elsif d = 'lutheran' then tags := tags || array['Lutheran','Protestant'];
  elsif d = 'methodist' then tags := tags || array['Methodist','Protestant'];
  elsif d = 'non-denominational' then tags := tags || array['Non-denominational'];
  elsif d = 'pentecostal' then tags := tags || array['Pentecostal','Protestant'];
  elsif d = 'presbyterian' then tags := tags || array['Presbyterian','Protestant'];
  elsif d = 'christian / general' then tags := tags || array['Christian / General','Protestant']; -- judgment call, see migration header
  elsif d = 'church of god' then tags := tags || array['Church of God','Protestant']; -- ambiguous, see migration header
  elsif d = 'church of christ' then tags := tags || array['Church of Christ','Protestant'];
  elsif d = 'apostolic' then tags := tags || array['Apostolic','Protestant']; -- ambiguous, see migration header
  elsif d = 'orthodox' then tags := tags || array['Orthodox'];
  elsif d = 'protestant / evangelical' then tags := tags || array['Protestant'];
  elsif d = 'nazarene' then tags := tags || array['Nazarene','Protestant'];
  elsif d = 'anglican' then tags := tags || array['Anglican','Protestant'];
  elsif d = 'jewish' then tags := tags || array['Jewish'];
  elsif d = 'adventist' then tags := tags || array['Adventist','Protestant'];
  end if;

  -- Dedupe (a name-phrase rule and the denomination-column rule can
  -- both fire and add the same tag twice) and drop nulls/blanks.
  return array(select distinct t from unnest(tags) as t where t is not null and t <> '');
end;
$$;

-- Trigger: keeps denomination_tags in sync automatically on every
-- future insert/edit (register-church, admin edit, CSV import) with no
-- application-code changes needed anywhere else -- the mapping lives
-- in compute_denomination_tags() alone.
create or replace function churches_set_denomination_tags()
returns trigger
language plpgsql
as $$
begin
  new.denomination_tags := compute_denomination_tags(new.denomination, new.name);
  return new;
end;
$$;

drop trigger if exists trg_churches_set_denomination_tags on churches;
create trigger trg_churches_set_denomination_tags
  before insert or update of denomination, name on churches
  for each row execute function churches_set_denomination_tags();

-- One-time backfill for every row that already exists -- the trigger
-- above only fires on FUTURE inserts/updates. Safe to re-run any time
-- after editing compute_denomination_tags() (fully idempotent).
update churches set denomination_tags = compute_denomination_tags(denomination, name);

-- search_churches: migration 018's body verbatim + one new param
-- (p_tradition_tags) and one new WHERE clause using array-overlap
-- (&&) against denomination_tags, so checking "Methodist" OR
-- "Episcopal" OR "Protestant" all correctly surface a Christian
-- Methodist Episcopal Church. p_denominations (exact-match against the
-- old single denomination string) is left in place, unused by the app
-- going forward but harmless to keep for API back-compat.
--
-- IMPORTANT: Postgres identifies a function by name + full parameter
-- signature, not by name alone -- inserting a new parameter does NOT
-- get treated as "replacing" migration 018's 8-parameter version by
-- CREATE OR REPLACE, it creates a SECOND overloaded search_churches
-- alongside it. Confirmed this the hard way against a real local
-- Postgres 16 before catching it here: with both left in place,
-- `select * from search_churches()` (and, worse, PostgREST's own RPC
-- call from the app) fails outright with "function search_churches()
-- is not unique" -- so the OLD 8-parameter overload must be dropped
-- explicitly first, or this migration silently breaks every church
-- search on the live site the moment it's run.
drop function if exists search_churches(
  text, text[], double precision, double precision, double precision, integer, integer, integer
);

create or replace function search_churches(
  p_keyword text default null::text,
  p_denominations text[] default null::text[],
  p_tradition_tags text[] default null::text[],
  p_user_lat double precision default null::double precision,
  p_user_lng double precision default null::double precision,
  p_max_distance_miles double precision default null::double precision,
  p_events_within_days integer default null::integer,
  p_limit integer default 24,
  p_offset integer default 0
)
returns table(
  id uuid, name text, denomination text, address text, lat double precision, lng double precision,
  logo_url text, description text, website text, phone text, facebook_url text, instagram_url text,
  verification_status text, owner_id uuid, plan_type text, distance_miles double precision, total_count bigint
)
language sql
security invoker
as $$
  with bounded as (
    select
      c.id, c.name, c.denomination, c.address, c.lat, c.lng, c.logo_url, c.description, c.website,
      c.phone, c.facebook_url, c.instagram_url, c.verification_status, c.owner_id, c.plan_type,
      case when p_user_lat is not null and c.lat is not null and c.lng is not null then
        3958.8 * acos(least(1, greatest(-1,
          cos(radians(p_user_lat)) * cos(radians(c.lat)) * cos(radians(c.lng) - radians(p_user_lng))
          + sin(radians(p_user_lat)) * sin(radians(c.lat))
        )))
      else null end as computed_distance_miles
    from churches c
    where
      c.is_hidden = false
      and (p_keyword is null or p_keyword = '' or c.name ilike '%' || p_keyword || '%' or c.description ilike '%' || p_keyword || '%')
      and (p_denominations is null or c.denomination = any(p_denominations))
      and (p_tradition_tags is null or c.denomination_tags && p_tradition_tags)
      and (
        p_user_lat is null or p_max_distance_miles is null or p_max_distance_miles <= 0
        or (
          c.lat is not null and c.lng is not null
          and c.lat between p_user_lat - (p_max_distance_miles / 69.0) and p_user_lat + (p_max_distance_miles / 69.0)
          and c.lng between p_user_lng - (p_max_distance_miles / (69.0 * cos(radians(p_user_lat)))) and p_user_lng + (p_max_distance_miles / (69.0 * cos(radians(p_user_lat))))
        )
      )
      and (
        p_events_within_days is null or exists (
          select 1 from events e
          where e.church_id = c.id
          and e.start_at between now() and now() + (p_events_within_days || ' days')::interval
        )
      )
  ),
  final as (
    select * from bounded
    where p_user_lat is null or p_max_distance_miles is null or p_max_distance_miles <= 0
      or computed_distance_miles is null or computed_distance_miles <= p_max_distance_miles
  )
  select
    f.id, f.name, f.denomination, f.address, f.lat, f.lng, f.logo_url, f.description, f.website, f.phone,
    f.facebook_url, f.instagram_url, f.verification_status, f.owner_id, f.plan_type, f.computed_distance_miles,
    count(*) over() as total_count
  from final f
  order by
    case when p_user_lat is not null then f.computed_distance_miles end asc nulls last,
    f.name asc
  limit p_limit offset p_offset;
$$;

notify pgrst, 'reload schema';
