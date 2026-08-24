-- =============================================================================
-- Account sync: separating "stored for you" from "visible to them".
--
-- Part IV (`docs/PART-IV-SYNC.md`). Until now `ranked_items` did two jobs with
-- one row: it was the user's cloud copy *and* the thing followers read off a
-- profile. One row meant one decision, so "back up my library" and "show my
-- library to strangers" were the same switch — and the client resolved that by
-- gating the upload itself, which meant a user who declined got no backup at
-- all.
--
-- This migration splits the two at the security boundary, which per CLAUDE.md
-- is the only place a rule counts: a rule the client enforces and Postgres does
-- not is not a rule.
--
--   stored  = every row you own. Unconditional once signed in. Yours to read
--             from any device.
--   visible = `is_published`. Opt-in, per bucket, and the only thing another
--             account can see.
--
-- MARK: - Why the default is false --------------------------------------------
--
-- Every pre-existing row becomes private on upgrade. That is a deliberate
-- regression rather than an oversight: under the old model a user consented to
-- an *upload*, and this migration redefines what an uploaded row means. Consent
-- to store is not consent to publish, and inferring the second from the first
-- is exactly the silent publication `PART-III-SOCIAL.md` §13 forbids. Anyone
-- who had published re-publishes explicitly; nobody is exposed by a migration.
-- =============================================================================

alter table public.ranked_items
  add column is_published boolean not null default false;

-- The account's *standing* answer to "let followers see your ranking?", as
-- opposed to the per-row state of what is currently visible.
--
-- Both are needed, and the reason is a gap that only appears months in. A user
-- says yes, then ranks films for a while, then ranks their first TV show. That
-- TV bucket is empty until this moment, so there is no sibling row for a new
-- row to inherit from — and without a standing answer to fall back on it lands
-- private. Nothing in the UI says so; the only symptom is a follower not seeing
-- a show. Found by the session that built the consent flow, before it shipped.
alter table public.profiles
  add column publishes_library boolean not null default false;

comment on column public.profiles.publishes_library is
  'The account''s standing answer to the publish question. New buckets adopt '
  'it; existing buckets keep whatever they were set to. Written only by '
  'public.set_library_published().';

comment on column public.ranked_items.is_published is
  'Visible to other accounts. Set uniformly across a (user_id, media_type, '
  'sentiment) bucket — never per row. Writable only through '
  'public.set_bucket_published(); direct UPDATE of this column is revoked.';

-- MARK: - Visibility ----------------------------------------------------------
--
-- `app.can_view_library` already short-circuits on `owner = auth.uid()`, so the
-- self-read half would work without naming it here. It is named anyway: it puts
-- both audiences in one predicate where a reader can see them, and it stops a
-- future edit to `can_view_library` from quietly taking a user's own library
-- away from them.

drop policy ranked_items_select on public.ranked_items;

create policy ranked_items_select on public.ranked_items for select to authenticated
  using (
    user_id = auth.uid()
    or (is_published and app.can_view_library(user_id))
  );

-- MARK: - The bucket is the unit of publication -------------------------------
--
-- A partially published bucket leaks, and the leak is not obvious, so it is
-- worth stating precisely.
--
-- Every row carries `bucket_size` so a viewer can apply ranking rule 6 — hide a
-- score until its bucket holds five — to somebody else's library. Publish three
-- of seven Liked films and a viewer sees three rows claiming `bucket_size: 7`.
-- That tells them four titles exist which they are not allowed to see, and it
-- shows a score computed over a bucket they cannot verify. Rule 6 exists to
-- stop the app implying precision it has not earned; a half-published bucket
-- implies precision the *viewer* cannot check.
--
-- So all-or-nothing per bucket. Two mechanisms enforce it, because the client
-- has two ways to break it:
--
--   1. Flipping one row. Prevented by revoking UPDATE on the column and routing
--      every change through a function that takes a bucket, not a row.
--   2. Inserting into a published bucket. The client upserts a whole bucket and
--      does not send `is_published`, so a newly ranked title would arrive with
--      the column default — `false` — inside a bucket that is otherwise true.
--      Prevented by the trigger below, which makes a new row inherit whatever
--      its bucket already decided.
--
-- The second is the one that would have shipped unnoticed: it needs no bug in
-- the client, only the normal flow of ranking one more film.

-- **This next line does nothing, and it is left here on purpose.**
--
-- `revoke update (is_published)` looks like it removes one column from the
-- table-wide UPDATE that `20260821210000_social.sql:658` grants to
-- `authenticated`. It does not: a column-level REVOKE cannot carve an exception
-- out of a table-level GRANT. The table grant is one privilege entry covering
-- every column, present and future; this statement removes a column-level grant
-- that never existed, succeeds, reports nothing, and changes nothing.
-- `information_schema.column_privileges` still lists UPDATE on the column.
--
-- The window it left open was real: any authenticated client could PATCH a
-- single row's `is_published` and produce the half-visible bucket this whole
-- section exists to prevent. Found by the pgTAP run, not by review.
--
-- It is not edited here because this migration was already applied to the
-- hosted project. Rewriting an applied migration makes the file and the
-- database disagree permanently, and `db push` never re-runs it — so the fix
-- ships as `20260823010000_fix_is_published_privileges.sql`, which drops the
-- table-level grant and re-grants by column. A fresh `db reset` replays both
-- and lands in the same place.
revoke update (is_published) on public.ranked_items from authenticated;

create or replace function app.inherit_bucket_publication()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Three fallbacks, in order, and each covers a case the next one cannot:
  --
  --   1. What this bucket already decided. A bucket with rows governs its own
  --      new members, so deliberately unpublishing one bucket survives ranking
  --      another title into it.
  --   2. The account's standing answer, for a bucket that has no rows yet.
  --      Without this a consented user's first TV show lands silently private.
  --   3. False, for an account that has never answered.
  --
  -- `is not distinct from` rather than `=`: a want-to-watch entry has a null
  -- sentiment, and the queue is a bucket like any other. `=` would never match
  -- it, and every queued row would arrive unpublished regardless of the bucket.
  --
  -- `bool_or` over zero rows returns null rather than false, which is precisely
  -- what lets case 2 be reachable at all.
  select coalesce(
           bool_or(ri.is_published),
           (select p.publishes_library from public.profiles p where p.id = new.user_id),
           false
         )
    into new.is_published
    from public.ranked_items ri
   where ri.user_id    = new.user_id
     and ri.media_type = new.media_type
     and ri.sentiment is not distinct from new.sentiment;

  return new;
end $$;

create trigger ranked_items_inherit_publication
  before insert on public.ranked_items
  for each row execute function app.inherit_bucket_publication();

-- MARK: - Publishing a bucket -------------------------------------------------
--
-- SECURITY DEFINER, which the client RPCs in `20260822010000_client_rpcs.sql`
-- deliberately are not. The reasoning there — that a DEFINER function has to
-- re-implement the visibility rules and will be wrong the first time either
-- drifts — does not apply, because this function implements no visibility rule
-- at all. It needs DEFINER only to write past the column-level revoke above,
-- and its entire authorisation surface is one predicate: `user_id = auth.uid()`.
-- A caller cannot name another user's bucket, because there is no parameter for
-- one.

create or replace function public.set_bucket_published(
  p_media_type public.media_type,
  p_sentiment  public.sentiment,
  p_published  boolean
)
returns int
language sql
security definer
set search_path = public, pg_temp
as $$
  with updated as (
    update public.ranked_items
       set is_published = p_published
     where user_id    = auth.uid()
       and media_type = p_media_type
       and sentiment is not distinct from p_sentiment
    returning 1
  )
  select count(*)::int from updated;
$$;

comment on function public.set_bucket_published(public.media_type, public.sentiment, boolean) is
  'Publishes or unpublishes one whole (media_type, sentiment) bucket of the '
  'calling user''s library. Returns the number of rows affected. A null '
  'p_sentiment addresses the want-to-watch queue.';

-- EXECUTE defaults to PUBLIC on a new function, so the revoke is load-bearing:
-- without it this is callable with the anon key by anyone holding the bundle.
-- `auth.uid()` would be null and the update would match nothing, but an
-- endpoint that answers a signed-out caller at all is one more thing to reason
-- about.
revoke all on function public.set_bucket_published(public.media_type, public.sentiment, boolean)
  from anon, public;
grant execute on function public.set_bucket_published(public.media_type, public.sentiment, boolean)
  to authenticated;

-- MARK: - Publishing the whole library ----------------------------------------
--
-- The bucket-level function above is the general case. The *question the UI
-- asks* is library-wide — "let followers see your ranking?" is one answer, not
-- six — so the common path gets its own entry point rather than making the
-- client loop over buckets and half-succeed.
--
-- A library-wide flip is strictly stronger than the per-bucket guarantee: every
-- bucket ends uniform because every row does. Per-bucket control stays for the
-- finer-grained UI that `docs/PART-IV-SYNC.md` Phase 32 describes; nothing today
-- calls it.

create or replace function public.set_library_published(p_published boolean)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  affected int;
begin
  -- The standing answer first, so that a row inserted concurrently by a drain
  -- already in flight inherits the new answer rather than the old one.
  update public.profiles
     set publishes_library = p_published
   where id = auth.uid();

  update public.ranked_items
     set is_published = p_published
   where user_id = auth.uid();

  get diagnostics affected = row_count;
  return affected;
end $$;

comment on function public.set_library_published(boolean) is
  'Publishes or unpublishes the calling user''s entire library and records the '
  'answer on profiles.publishes_library, which new buckets inherit. Returns '
  'rows affected. Never deletes: unpublishing hides rows from other accounts '
  'and leaves the user''s own copy intact.';

revoke all on function public.set_library_published(boolean) from anon, public;
grant execute on function public.set_library_published(boolean) to authenticated;

-- MARK: - Indexing ------------------------------------------------------------
--
-- No new index. `ranked_items_ranking_idx (user_id, media_type, score desc)`
-- still leads on the column every query filters first — a profile read names
-- one `user_id` — so `is_published` is a cheap filter on an already-narrow
-- result, not a scan. Revisit only if a query arrives that does not know whose
-- library it wants, which today none does.
