-- Run in Supabase SQL Editor.
--
-- Adds a phone number to the claim request form, alongside the
-- existing name/role/email/note fields -- "standard needed info" for
-- reviewing a claim, per request.

alter table church_claim_requests add column if not exists requester_phone text;

-- NOTE: at the time this migration was written, get_pending_church_claims()
-- needed a matching one-line addition (`cr.requester_phone,` in both the
-- SELECT and RETURNS TABLE). That edit is already folded into this
-- function's CURRENT, superseding definition in
-- 009_fix_ambiguous_id_admin_check.sql -- see that file, not the earlier
-- 006_church_claim_admin_checks.sql version, for the function's real
-- current source.
