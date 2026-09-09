-- Run in Supabase SQL Editor. URGENT -- this function currently
-- transfers real church ownership (`approve = true` sets
-- churches.owner_id directly) with NO permission check at all. Any
-- signed-in user can call this directly on their own submitted claim
-- and become that church's owner instantly, bypassing admin review
-- entirely.
--
-- Return type (void) is unchanged, so `create or replace` works here
-- without needing to drop the function first (unlike
-- get_pending_church_claims, which changed its return columns).

create or replace function review_church_claim(request_id uuid, approve boolean)
returns void
language plpgsql
security definer
as $$
declare
  target_church_id uuid;
  requesting_user_id uuid;
begin
  if not exists (
    select 1 from profiles where id = auth.uid() and is_platform_admin = true
  ) then
    raise exception 'You do not have permission to review claim requests.';
  end if;

  select church_id, user_id into target_church_id, requesting_user_id
  from church_claim_requests where id = request_id and status = 'pending';

  if target_church_id is null then
    raise exception 'Claim request not found or already reviewed.';
  end if;

  if approve then
    update churches set owner_id = requesting_user_id where id = target_church_id;
    update church_claim_requests set status = 'approved', reviewed_at = now() where id = request_id;
    -- Any other pending claims on the same church are now moot.
    update church_claim_requests set status = 'rejected', reviewed_at = now()
      where church_id = target_church_id and status = 'pending' and id != request_id;
  else
    update church_claim_requests set status = 'rejected', reviewed_at = now() where id = request_id;
  end if;
end;
$$;
