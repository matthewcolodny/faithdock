-- Run in Supabase SQL Editor.
--
-- Fixes a live, currently-broken bug found while verifying migration
-- 033: the homepage's "Upcoming events near you" preview and a church
-- profile page's own Events tab have both been silently returning
-- NOTHING, showing their empty states ("No upcoming events near you
-- yet" / "No events posted yet") regardless of how many real, public,
-- upcoming events actually exist.
--
-- Cause: there are TWO search_events functions in the database at once.
-- Migration 022 added a p_keyword parameter and did so with a plain
-- CREATE OR REPLACE, reasoning in its own comment that "appending, not
-- inserting, keeps this a backward-compatible CREATE OR REPLACE for
-- any other caller still on the old signature." That reasoning is
-- wrong in one specific way: in Postgres, CREATE OR REPLACE only
-- replaces a function with the SAME parameter list. Adding a parameter
-- -- even one with a default, even appended at the end -- produces a
-- brand new, separate function. So migration 019's 11-parameter
-- version is still live alongside 022's 12-parameter one.
--
-- PostgREST resolves an RPC overload by the set of named arguments the
-- caller actually sends, so this breaks callers selectively, which is
-- exactly why it went unnoticed:
--
--   renderEvents()      sends all 12 args incl. p_keyword -> matches
--                       only the 12-arg version -> WORKS. This is the
--                       main Events page, so Events "looked fine."
--   renderHomeEvents()  sends 5 args -> BOTH versions can satisfy it
--                       -> PGRST203 "Could not choose the best
--                       candidate function" -> BROKEN.
--   loadChurchEvents()  sends 3 args -> same ambiguity -> BROKEN.
--
-- Verified live against production by replicating each call site's
-- exact argument set: the 12-arg call returned rows, the other two
-- returned PGRST203. Also checked search_churches the same way -- it is
-- NOT affected, because migrations 023/031 correctly used drop-then-
-- create when its signature changed. This is the same hazard those two
-- migrations already documented; 022 is the one place it was missed.
--
-- Dropping the OLD 11-parameter version (no p_keyword) leaves exactly
-- one candidate, so every call site resolves unambiguously. Nothing
-- calls the 11-arg version deliberately -- the front end has passed
-- p_keyword since the build that shipped alongside 022.

drop function if exists public.search_events(
  timestamp with time zone,
  timestamp with time zone,
  boolean[],
  text[],
  uuid[],
  double precision,
  double precision,
  double precision,
  integer,
  integer,
  text[]
);

notify pgrst, 'reload schema';
