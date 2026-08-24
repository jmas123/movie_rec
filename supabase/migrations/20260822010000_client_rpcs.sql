-- =============================================================================
-- The RPCs the client actually calls.
--
-- Phases 24–27 wrote client code against five Postgres functions that no
-- migration ever defined: `feed_page`, `author_posts`, `post_comments`,
-- `relationship` and `pending_requests`. Phase 20 shipped `public.feed`, which
-- is the hard part of the feed — the keyset-paginated LATERAL merge — but
-- returns `setof public.posts`, so it carries no author fields, no counts and
-- no viewer state. The client needs a rendered feed row, in one request.
--
-- So `feed_page` wraps `public.feed` rather than replacing it: the pagination
-- and index strategy documented there stay in one place, and this file only
-- adds the joins. The other four are new.
--
-- Every function here is SECURITY INVOKER, which is what makes them safe to
-- expose. Row-level security applies to the caller exactly as it would to a
-- direct PostgREST request; none of these can read a row the user could not
-- have read themselves. A SECURITY DEFINER function would have to re-implement
-- the visibility rules, and would be wrong the first time either drifted.
-- =============================================================================

-- MARK: - Feed ----------------------------------------------------------------

-- One page of the viewer's feed, rendered.
--
-- `kind` is cast to text because the client decodes it into a Swift enum whose
-- raw values are the enum labels; PostgREST would render the enum the same way,
-- and the cast makes that a stated contract rather than an accident.
create or replace function public.feed_page(
  before_created_at timestamptz default null,
  before_id         uuid        default null,
  page_size         int         default 20
)
returns table (
  id                  uuid,
  author_id           uuid,
  kind                text,
  created_at          timestamptz,
  author_handle       text,
  author_display_name text,
  author_avatar_url   text,
  payload             jsonb,
  comment_count       int,
  reaction_count      int,
  viewer_has_reacted  boolean
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  -- Every reference below is table-qualified. `returns table` introduces output
  -- names that collide with the columns they are built from, and a bare
  -- `created_at` would be ambiguous.
  select p.id,
         p.user_id,
         p.kind::text,
         p.created_at,
         a.handle,
         a.display_name,
         a.avatar_url,
         p.payload,
         p.comment_count,
         p.reaction_count,
         exists (
           select 1
             from public.reactions r
            where r.post_id = p.id
              and r.user_id = auth.uid()
         )
    from public.feed(before_created_at, before_id, page_size) p
    join public.profiles a on a.id = p.user_id
   order by p.created_at desc, p.id desc;
$$;

-- One author's posts, for their profile screen.
--
-- Not `feed_page` with a filter: the feed is "people I follow" and this is "one
-- person, whether or not I follow them". `posts_select` decides whether the
-- viewer sees anything, so a private library returns zero rows rather than an
-- error — which is what the client reads as private.
create or replace function public.author_posts(
  target            uuid,
  before_created_at timestamptz default null,
  before_id         uuid        default null,
  page_size         int         default 20
)
returns table (
  id                  uuid,
  author_id           uuid,
  kind                text,
  created_at          timestamptz,
  author_handle       text,
  author_display_name text,
  author_avatar_url   text,
  payload             jsonb,
  comment_count       int,
  reaction_count      int,
  viewer_has_reacted  boolean
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select p.id,
         p.user_id,
         p.kind::text,
         p.created_at,
         a.handle,
         a.display_name,
         a.avatar_url,
         p.payload,
         p.comment_count,
         p.reaction_count,
         exists (
           select 1
             from public.reactions r
            where r.post_id = p.id
              and r.user_id = auth.uid()
         )
    from public.posts p
    join public.profiles a on a.id = p.user_id
   where p.user_id = target
     and (
           before_created_at is null
        or (p.created_at, p.id) < (before_created_at, before_id)
     )
   order by p.created_at desc, p.id desc
   limit least(greatest(page_size, 1), 100);
$$;

-- MARK: - Comments ------------------------------------------------------------

-- A post's comments with their authors joined, oldest first.
--
-- The join is the whole point: a comment list that fetched a profile per row
-- would be an N+1 on the busiest screen in the app.
--
-- A soft-deleted comment keeps its row and its place in the thread but returns
-- an empty body. The client already renders "Comment deleted" for it
-- (`PostComment.displayBody`), so withholding the text costs nothing and means
-- deleted words are not sitting in a response nobody displays.
create or replace function public.post_comments(
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
         a.handle,
         a.display_name,
         a.avatar_url
    from public.comments c
    join public.profiles a on a.id = c.user_id
   where c.post_id = post
   order by c.created_at asc, c.id asc
   limit least(greatest(page_size, 1), 200);
$$;

-- MARK: - Social graph --------------------------------------------------------

-- Everything a profile screen needs to render its follow button, in one request
-- rather than three that would paint a half-populated control in between.
--
-- `state` is text, not `public.follow_state`. The enum has two values because
-- only two edges can be stored; the client's `FollowState` has four, because
-- "no edge" and "blocked" are states of the *relationship* rather than rows in
-- a table. Returning text is what lets the server answer the question the
-- client is actually asking.
--
-- Blocked is checked first and wins. `app.blocked_with` is symmetric, so a
-- blocked viewer cannot tell which direction the block went — and the counts
-- below are subject to `follows_select`, so a private account the viewer does
-- not follow reports zeroes rather than leaking the shape of its graph.
create or replace function public.relationship(target uuid)
returns table (
  state            text,
  follower_count   int,
  following_count  int,
  follows_viewer   boolean
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select
    case
      when app.blocked_with(target) then 'blocked'
      else coalesce(
        (
          select f.state::text
            from public.follows f
           where f.follower_id = auth.uid()
             and f.followee_id = target
        ),
        'none'
      )
    end,
    (
      select count(*)::int
        from public.follows f
       where f.followee_id = target
         and f.state = 'active'
    ),
    (
      select count(*)::int
        from public.follows f
       where f.follower_id = target
         and f.state = 'active'
    ),
    exists (
      select 1
        from public.follows f
       where f.follower_id = target
         and f.followee_id = auth.uid()
         and f.state = 'active'
    );
$$;

-- Who is waiting on the viewer to approve them.
--
-- Returns profiles rather than edges: the screen shows people, and the edge
-- carries nothing else it needs. `follows_select` already lets the followee
-- read their own incoming rows, so this needs no privilege of its own.
create or replace function public.pending_requests()
returns setof public.profiles
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select pr.*
    from public.follows f
    join public.profiles pr on pr.id = f.follower_id
   where f.followee_id = auth.uid()
     and f.state = 'pending'
   order by f.created_at desc;
$$;

-- MARK: - Grants --------------------------------------------------------------
--
-- EXECUTE defaults to PUBLIC on a new function, so each revoke is load-bearing:
-- without it these would be callable with the anon key by anyone holding the
-- bundle. RLS would still refuse the rows, but an endpoint that answers a
-- signed-out caller at all is one more thing to reason about.

revoke all on function public.feed_page(timestamptz, uuid, int) from anon, public;
grant execute on function public.feed_page(timestamptz, uuid, int) to authenticated;

revoke all on function public.author_posts(uuid, timestamptz, uuid, int) from anon, public;
grant execute on function public.author_posts(uuid, timestamptz, uuid, int) to authenticated;

revoke all on function public.post_comments(uuid, int) from anon, public;
grant execute on function public.post_comments(uuid, int) to authenticated;

revoke all on function public.relationship(uuid) from anon, public;
grant execute on function public.relationship(uuid) to authenticated;

revoke all on function public.pending_requests() from anon, public;
grant execute on function public.pending_requests() to authenticated;
