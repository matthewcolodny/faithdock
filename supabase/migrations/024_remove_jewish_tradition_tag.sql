-- Run in Supabase SQL Editor.
--
-- Removes "Jewish" from the Tradition taxonomy (migration 023), per
-- request. Companion to the index.html change removing the "Jewish"
-- checkbox from the Directory and Events Tradition/Family filter
-- panels and from the ALL_TRADITION_TAGS constant.
--
-- churches.denomination itself is untouched (a church with
-- denomination = 'Jewish' keeps that value, still correctly
-- translated via translateDenomination() wherever that single-value
-- column is displayed) -- this only touches denomination_tags, the
-- derived multi-value column the public Tradition filter actually
-- reads.
--
-- Redefines compute_denomination_tags() as migration 023's version
-- verbatim, minus the two "Jewish" detection branches (the
-- Synagogue/Jewish name-phrase check, and the denomination = 'jewish'
-- column check). CREATE OR REPLACE is safe here -- same name, same
-- parameter signature (text, text) as before, so this really does
-- replace the existing function rather than creating a second
-- overload (unlike search_churches in migration 023, which changed its
-- parameter list and needed an explicit DROP first).
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
  -- "Jewish"/"Synagogue" name-phrase detection removed -- see header.

  -- ===== 2) `denomination` column (structured signal) =====
  if d = 'baptist' then tags := tags || array['Baptist','Protestant'];
  elsif d = 'catholic' then tags := tags || array['Catholic'];
  elsif d = 'episcopal' then tags := tags || array['Episcopal','Protestant'];
  elsif d = 'lutheran' then tags := tags || array['Lutheran','Protestant'];
  elsif d = 'methodist' then tags := tags || array['Methodist','Protestant'];
  elsif d = 'non-denominational' then tags := tags || array['Non-denominational'];
  elsif d = 'pentecostal' then tags := tags || array['Pentecostal','Protestant'];
  elsif d = 'presbyterian' then tags := tags || array['Presbyterian','Protestant'];
  elsif d = 'christian / general' then tags := tags || array['Christian / General','Protestant']; -- judgment call, see migration 023 header
  elsif d = 'church of god' then tags := tags || array['Church of God','Protestant']; -- ambiguous, see migration 023 header
  elsif d = 'church of christ' then tags := tags || array['Church of Christ','Protestant'];
  elsif d = 'apostolic' then tags := tags || array['Apostolic','Protestant']; -- ambiguous, see migration 023 header
  elsif d = 'orthodox' then tags := tags || array['Orthodox'];
  elsif d = 'protestant / evangelical' then tags := tags || array['Protestant'];
  elsif d = 'nazarene' then tags := tags || array['Nazarene','Protestant'];
  elsif d = 'anglican' then tags := tags || array['Anglican','Protestant'];
  -- 'jewish' column-value branch removed -- see header.
  elsif d = 'adventist' then tags := tags || array['Adventist','Protestant'];
  end if;

  return array(select distinct t from unnest(tags) as t where t is not null and t <> '');
end;
$$;

-- Re-run the backfill so any row currently carrying a stale 'Jewish'
-- tag (from migration 023's version of this function) gets re-tagged
-- under the new rules. Idempotent, safe to run any time -- same as
-- migration 023's own backfill.
update churches set denomination_tags = compute_denomination_tags(denomination, name);

notify pgrst, 'reload schema';
