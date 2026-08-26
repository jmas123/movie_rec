-- Comment editing.
--
-- The capability was already half-present and unusable: `comments_update`
-- (20260821210000) lets an author update their own row, and
-- `app.guard_comment_update` explicitly contemplates a body edit —
--
--   if new.body is distinct from old.body and old.user_id <> auth.uid() then
--     raise exception 'only the author may edit a comment body';
--
-- — which is a rule that only means anything if authors *can* edit. There was
-- no service method and no UI, so the policy guarded a door with no handle.
-- `GAP-AUDIT.md` §2 #14 lists it as outstanding.
--
-- What this migration adds is the part that makes editing honest rather than
-- merely possible: a record that it happened.

-- MARK: - edited_at ------------------------------------------------------------

-- Without this an edit is invisible. A comment somebody read, replied to, or
-- reported could be silently rewritten into something else, and the thread
-- would show no sign — which is a moderation problem, not a cosmetic one: a
-- report names a comment id, and a moderator looking at it must be able to see
-- that its text moved after the report was filed.
--
-- Nullable, with no default. NULL means "never edited", which is the truth for
-- every row that already exists; a default of now() would retroactively claim
-- the entire existing table had been edited at migration time.
alter table public.comments
  add column if not exists edited_at timestamptz;

comment on column public.comments.edited_at is
  'When the author last changed the body. NULL means never edited.';

-- MARK: - The guard ------------------------------------------------------------

-- Restated rather than left to inference. The existing trigger names the columns
-- that may *not* change (id, post_id, user_id, created_at) and permits anything
-- else, so `edited_at` is already writable — but it is writable by the *post
-- owner* too, who may set deleted_at on a comment that is not theirs. An owner
-- who could also stamp edited_at could make an untouched comment look rewritten.
--
-- The body rule below is unchanged from 20260821210000; it is repeated because
-- CREATE OR REPLACE replaces the whole function and dropping it here would
-- silently remove it.
create or replace function app.guard_comment_update()
returns trigger
language plpgsql
as $$
begin
  if new.id <> old.id or new.post_id <> old.post_id
     or new.user_id <> old.user_id or new.created_at <> old.created_at then
    raise exception 'only body, edited_at and deleted_at may be updated on a comment';
  end if;
  -- The post owner may hide a comment but may not put words in its author's
  -- mouth: they can set deleted_at, never body.
  if new.body is distinct from old.body and old.user_id <> auth.uid() then
    raise exception 'only the author may edit a comment body';
  end if;
  -- Nor may they claim somebody else's comment was edited.
  if new.edited_at is distinct from old.edited_at and old.user_id <> auth.uid() then
    raise exception 'only the author may mark a comment edited';
  end if;
  return new;
end;
$$;

-- MARK: - post_comments --------------------------------------------------------

-- Replaced only to carry the new column through. The body of the query is
-- unchanged from 20260822010000, including the soft-delete blanking: a deleted
-- comment returns an empty body, so its edit history is moot and `edited_at`
-- rides along harmlessly.
--
-- **Dropped rather than replaced.** `create or replace function` cannot widen a
-- `returns table (...)`; Postgres rejects it with "cannot change return type of
-- existing function". Dropping takes the grants with it, which is why they are
-- restated at the bottom — and why the revoke is restated too: EXECUTE defaults
-- to PUBLIC on a freshly created function, so omitting it would quietly make
-- this callable with the anon key.
drop function if exists public.post_comments(uuid, int);

create function public.post_comments(
  post      uuid,
  page_size int default 50
)
returns table (
  id                  uuid,
  post_id             uuid,
  author_id           uuid,
  body                text,
  created_at          timestamptz,
  deleted_at          timestamptz,
  edited_at           timestamptz,
  author_handle       text,
  author_display_name text,
  author_avatar_url   text
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select c.id,
         c.post_id,
         c.user_id,
         case when c.deleted_at is null then c.body else '' end,
         c.created_at,
         c.deleted_at,
         c.edited_at,
         a.handle,
         a.display_name,
         a.avatar_url
    from public.comments c
    join public.profiles a on a.id = c.user_id
   where c.post_id = post
   order by c.created_at asc, c.id asc
   limit least(greatest(page_size, 1), 200);
$$;

revoke all on function public.post_comments(uuid, int) from anon, public;
grant execute on function public.post_comments(uuid, int) to authenticated;

-- MARK: - add_comment ----------------------------------------------------------

-- Posting a comment did not work against a real database at all, and could not
-- have, for two independent reasons. The client inserted straight into
-- `public.comments` with a column named `author_id` — `comments` has `user_id`,
-- so PostgREST answered PGRST204 and no comment was ever written. Had the name
-- been right, the request asked for `Prefer: return=representation` and decoded
-- the reply as a `PostComment`, which requires `author_handle`; an insert
-- returns the bare table row, which has no such column, so it would then have
-- failed to decode. `MockFeedService` encodes nothing and joins nothing, so the
-- suite was green throughout.
--
-- The shape this fixes is the one `post_comments` already established: the
-- author fields arrive joined, in one request. Doing it as an RPC rather than
-- an insert plus a re-select keeps the write and the read of the same row in a
-- single statement, so a thread cannot render a comment that is missing its
-- author.
--
-- SECURITY INVOKER, deliberately. `comments_insert` still applies —
-- `user_id = auth.uid() and app.can_view_post(post_id)` — so this adds no
-- privilege. It is a shape, not an exemption. `auth.uid()` supplies the author
-- rather than the caller naming themselves, which removes the question of what
-- happens when a client passes somebody else's id.
create or replace function public.add_comment(
  post         uuid,
  comment_body text
)
returns table (
  id                  uuid,
  post_id             uuid,
  author_id           uuid,
  body                text,
  created_at          timestamptz,
  deleted_at          timestamptz,
  edited_at           timestamptz,
  author_handle       text,
  author_display_name text,
  author_avatar_url   text
)
language sql
volatile
security invoker
set search_path = public, pg_temp
as $$
  with inserted as (
    insert into public.comments (post_id, user_id, body)
    values (post, auth.uid(), comment_body)
    returning id, post_id, user_id, body, created_at, deleted_at, edited_at
  )
  select i.id,
         i.post_id,
         i.user_id,
         i.body,
         i.created_at,
         i.deleted_at,
         i.edited_at,
         a.handle,
         a.display_name,
         a.avatar_url
    from inserted i
    join public.profiles a on a.id = i.user_id;
$$;

revoke all on function public.add_comment(uuid, text) from anon, public;
grant execute on function public.add_comment(uuid, text) to authenticated;
