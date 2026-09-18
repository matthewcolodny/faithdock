-- Run in Supabase SQL Editor.
--
-- The account level's own settings.
--
-- FaithDock has no `accounts` table: an "account" is the owner user
-- plus the churches they own. So this is keyed on the owner's auth
-- user id, one row each, created on first save rather than at sign-up
-- (nothing needs a row to exist, and back-filling one for every user
-- who will never open this page is storage for nothing).
--
-- === Why the defaults are NULLABLE ===
-- Every default_* column may be null, and null means "this account has
-- no opinion" -- not "off" and not "the same as the column default".
-- The church-creation path only puts a column in its INSERT when the
-- account actually set one, so the churches table's own defaults stay
-- in charge otherwise. A NOT NULL default here would quietly become a
-- policy every new church inherits, which is the opposite of what an
-- unset setting should do.

create table if not exists account_settings (
  owner_id uuid primary key references auth.users(id) on delete cascade,

  -- Who FaithDock contacts about the account's own billing. This is
  -- NOT where Stripe sends invoices -- Stripe emails the customer
  -- record it holds, which is changed in the Stripe billing portal
  -- behind "Manage billing". Wiring this through to the Stripe
  -- customer needs a change to the stripe-subscription edge function,
  -- which is deployed by hand and must never be guessed at, so until
  -- that happens the UI says exactly this rather than implying it
  -- controls invoice delivery.
  billing_contact_name text,
  billing_email text,

  -- Defaults applied to a NEW church created under this account.
  -- Deliberately only the three that are genuine house policy for a
  -- multi-church organisation. The on/off switches (events, giving,
  -- messaging, groups, ministries) are not here: they all default to
  -- on, which is what a new church wants, and five more rows of UI to
  -- restate that would be furniture.
  default_directory_visibility text,
  default_members_see_contact boolean,
  default_receipt_footer_text text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Same two values the per-church column accepts (059). Written as its
-- own constraint rather than a foreign key to a lookup table, matching
-- how churches.directory_visibility does it -- and null passes, which
-- is the "no opinion" case above.
alter table account_settings drop constraint if exists account_settings_default_directory_visibility_check;
alter table account_settings add constraint account_settings_default_directory_visibility_check
  check (default_directory_visibility is null or default_directory_visibility in ('staff', 'members'));

alter table account_settings enable row level security;

-- One person's row, and only their own. No church_staff path: these
-- are the ACCOUNT's settings, and staff belong to a church, not to the
-- account that owns it.
drop policy if exists "owners read their own account settings" on account_settings;
create policy "owners read their own account settings" on account_settings
  for select using (auth.uid() = owner_id);

drop policy if exists "owners create their own account settings" on account_settings;
create policy "owners create their own account settings" on account_settings
  for insert with check (auth.uid() = owner_id);

drop policy if exists "owners update their own account settings" on account_settings;
create policy "owners update their own account settings" on account_settings
  for update using (auth.uid() = owner_id) with check (auth.uid() = owner_id);

-- === Privileges ===
-- REVOKE FIRST. This project's default privileges hand anon and
-- authenticated every privilege on every new table in public, so the
-- grants below would ADD nothing and narrow nothing if written on
-- their own -- that is exactly what 049 got wrong. Naming the columns
-- only means something once the table-wide privilege is gone.
revoke all on account_settings from anon;
revoke all on account_settings from authenticated;

-- anon gets nothing at all. There is no public view of an account.
grant select on account_settings to authenticated;
grant insert (owner_id, billing_contact_name, billing_email,
              default_directory_visibility, default_members_see_contact,
              default_receipt_footer_text)
  on account_settings to authenticated;
grant update (billing_contact_name, billing_email,
              default_directory_visibility, default_members_see_contact,
              default_receipt_footer_text, updated_at)
  on account_settings to authenticated;
-- No DELETE. Closing an account is not "delete your settings row", and
-- the cascade from auth.users handles the real thing.

-- owner_id is not in the UPDATE grant, so a row cannot be walked over
-- to another user even by someone who reaches the REST endpoint
-- directly -- the policy would refuse it too, but a privilege that is
-- simply absent cannot be reasoned about wrongly.

create or replace function account_settings_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  -- Pinned, not trusted from the request. The UPDATE grant already
  -- omits owner_id; this makes the row's identity immutable even if a
  -- future grant is widened without thinking about it.
  new.owner_id := old.owner_id;
  return new;
end;
$$;

drop trigger if exists account_settings_touch on account_settings;
create trigger account_settings_touch
  before update on account_settings
  for each row execute function account_settings_touch_updated_at();

notify pgrst, 'reload schema';

-- Confirm, rather than trusting that the statements ran.
do $verify$
declare
  v_cols int;
begin
  select count(*) into v_cols from information_schema.columns
   where table_name = 'account_settings'
     and column_name in ('owner_id','billing_contact_name','billing_email',
                         'default_directory_visibility','default_members_see_contact',
                         'default_receipt_footer_text','updated_at');
  if v_cols <> 7 then
    raise exception 'VERIFY FAILED: expected 7 columns, found %', v_cols;
  end if;

  if not exists (select 1 from pg_tables where tablename = 'account_settings' and rowsecurity) then
    raise exception 'VERIFY FAILED: RLS is not enabled on account_settings.';
  end if;

  -- Both directions. A revoke that missed would leave anon able to
  -- read billing contacts, and a grant that missed would leave the
  -- page unable to load its own settings.
  if has_table_privilege('anon', 'account_settings', 'SELECT') then
    raise exception 'VERIFY FAILED: anon can still SELECT account_settings.';
  end if;
  if has_table_privilege('anon', 'account_settings', 'INSERT')
     or has_table_privilege('anon', 'account_settings', 'UPDATE') then
    raise exception 'VERIFY FAILED: anon can still write to account_settings.';
  end if;
  if not has_table_privilege('authenticated', 'account_settings', 'SELECT') then
    raise exception 'VERIFY FAILED: authenticated cannot SELECT account_settings.';
  end if;
  if not has_column_privilege('authenticated', 'account_settings', 'billing_email', 'UPDATE') then
    raise exception 'VERIFY FAILED: authenticated cannot UPDATE billing_email.';
  end if;
  if has_column_privilege('authenticated', 'account_settings', 'owner_id', 'UPDATE') then
    raise exception 'VERIFY FAILED: owner_id is still updatable, so a row could be moved to another user.';
  end if;

  raise notice 'OK: account_settings created, locked to its owner, anon has nothing.';
end
$verify$;
