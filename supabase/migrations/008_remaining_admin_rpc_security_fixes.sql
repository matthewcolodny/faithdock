-- Run in Supabase SQL Editor. Fixes the remaining 6 confirmed gaps
-- found by reading through the full function list. All six keep
-- their existing return type, so create or replace works directly --
-- no drop-first needed (unlike get_pending_church_claims earlier).

-- 1. search_users_admin -- worst of this batch: full user directory
-- (email, name, church affiliation) with zero check, to anyone.
create or replace function search_users_admin(
  p_keyword text default null, p_role text default null,
  p_limit integer default 30, p_offset integer default 0
)
returns table (id uuid, email text, full_name text, created_at timestamptz, role text, church_name text, plan_type text, total_count bigint)
language plpgsql
security definer
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to search users.';
  end if;

  return query
    with base as (
      select
        u.id, u.email::text as email, p.full_name, u.created_at,
        ownedinfo.church_name as owned_church_name, ownedinfo.plan_type as owned_plan_type,
        staffinfo.church_name as staff_church_name, staffinfo.plan_type as staff_plan_type,
        (ownedinfo.church_name is not null) as is_owner,
        (staffinfo.church_name is not null) as is_staff
      from auth.users u
      left join profiles p on p.id = u.id
      left join lateral (
        select c.name as church_name, c.plan_type from churches c where c.owner_id = u.id limit 1
      ) ownedinfo on true
      left join lateral (
        select c.name as church_name, c.plan_type from church_staff cs join churches c on c.id = cs.church_id where cs.user_id = u.id limit 1
      ) staffinfo on true
      where (
        p_keyword is null or p_keyword = ''
        or u.email ilike '%' || p_keyword || '%'
        or p.full_name ilike '%' || p_keyword || '%'
      )
    )
    select
      b.id, b.email, b.full_name, b.created_at,
      case when b.is_owner then 'owner' when b.is_staff then 'staff' else 'individual' end,
      coalesce(b.owned_church_name, b.staff_church_name),
      coalesce(b.owned_plan_type, b.staff_plan_type),
      count(*) over() as total_count
    from base b
    where (
      p_role is null or p_role = ''
      or (case when b.is_owner then 'owner' when b.is_staff then 'staff' else 'individual' end) = p_role
    )
    order by b.created_at desc
    limit p_limit offset p_offset;
end;
$$;

-- 2. admin_delete_unclaimed_church -- destructive, was fully open.
create or replace function admin_delete_unclaimed_church(target_church_id uuid)
returns void
language plpgsql
security definer
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to delete churches.';
  end if;

  delete from churches where id = target_church_id and owner_id is null;
end;
$$;

-- 3. get_church_claims_history -- same PII class as get_pending_church_claims.
create or replace function get_church_claims_history(
  p_keyword text default null, p_status text default null,
  p_limit integer default 30, p_offset integer default 0
)
returns table (id uuid, church_id uuid, church_name text, church_address text, requester_name text, requester_role text, requester_email text, note text, status text, created_at timestamptz, reviewed_at timestamptz, total_count bigint)
language plpgsql
security definer
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to view claim history.';
  end if;

  return query
    select r.id, r.church_id, c.name, c.address, r.requester_name, r.requester_role, r.requester_email, r.note, r.status,
      r.created_at, r.reviewed_at,
      count(*) over() as total_count
    from church_claim_requests r
    join churches c on c.id = r.church_id
    where r.status in ('approved', 'rejected')
      and (p_status is null or p_status = '' or r.status = p_status)
      and (
        p_keyword is null or p_keyword = ''
        or c.name ilike '%' || p_keyword || '%'
        or r.requester_name ilike '%' || p_keyword || '%'
        or r.requester_email ilike '%' || p_keyword || '%'
      )
    order by r.reviewed_at desc
    limit p_limit offset p_offset;
end;
$$;

-- 4. search_all_churches_admin -- exposes owner_id for every church.
create or replace function search_all_churches_admin(
  p_keyword text default null, p_status text default null,
  p_limit integer default 30, p_offset integer default 0
)
returns table (id uuid, name text, denomination text, address text, verification_status text, owner_id uuid, total_count bigint)
language plpgsql
security definer
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to search churches.';
  end if;

  return query
    select c.id, c.name, c.denomination, c.address, c.verification_status, c.owner_id,
      count(*) over() as total_count
    from churches c
    where
      (p_keyword is null or p_keyword = '' or c.name ilike '%' || p_keyword || '%')
      and (
        p_status is null or p_status = ''
        or (p_status = 'unclaimed' and c.owner_id is null)
        or (p_status != 'unclaimed' and c.verification_status = p_status)
      )
    order by c.name
    limit p_limit offset p_offset;
end;
$$;

-- 5. admin_import_churches -- anyone could bulk-insert church listings.
create or replace function admin_import_churches(rows jsonb)
returns setof uuid
language plpgsql
security definer
as $$
declare
  row_data jsonb;
  new_id uuid;
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to import churches.';
  end if;

  for row_data in select * from jsonb_array_elements(rows)
  loop
    insert into churches (name, denomination, address, phone, website, logo_url, lat, lng, owner_id)
    values (
      row_data->>'name', row_data->>'denomination', row_data->>'address', row_data->>'phone',
      row_data->>'website', row_data->>'logo_url',
      nullif(row_data->>'lat', '')::double precision, nullif(row_data->>'lng', '')::double precision,
      null
    )
    on conflict (dedupe_key) do nothing
    returning id into new_id;

    if new_id is not null then
      return next new_id;
    end if;
    new_id := null;
  end loop;
  return;
end;
$$;

-- 6. get_group_notification_recipients -- didn't even have a placeholder
-- comment; no check was ever attempted. Adds the same owner-or-staff
-- pattern already used correctly by get_mass_email_recipients, just
-- reached through the group's own church_id instead of taking one directly.
create or replace function get_group_notification_recipients(target_group_id uuid)
returns text[]
language plpgsql
security definer
as $$
declare
  recipient_emails text[];
  owner_email text;
  group_church_id uuid;
begin
  select church_id into group_church_id from groups where id = target_group_id;
  if group_church_id is null or not (
    exists (select 1 from churches where id = group_church_id and owner_id = auth.uid())
    or is_church_staff_member(group_church_id)
  ) then
    raise exception 'You do not have permission to view this group''s recipients.';
  end if;

  select array_agg(u.email) into recipient_emails
  from group_members gm
  join auth.users u on u.id = gm.user_id
  where gm.group_id = target_group_id and gm.role = 'leader' and gm.status = 'active';

  if recipient_emails is null or array_length(recipient_emails, 1) is null then
    select u.email into owner_email
    from groups g
    join churches c on c.id = g.church_id
    join auth.users u on u.id = c.owner_id
    where g.id = target_group_id;
    if owner_email is not null then
      recipient_emails := array[owner_email];
    end if;
  end if;

  return recipient_emails;
end;
$$;
