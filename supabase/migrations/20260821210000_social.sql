-- =============================================================================
-- WatchRank — Part III social schema (roadmap Phase 20)
--
-- Design rationale: docs/PART-III-SOCIAL.md §4 (trust model), §5 (schema),
-- §6 (policies). Read §4 before changing anything here.
--
-- The anon key ships in the app bundle and carries no privilege. Every rule
-- the client appears to enforce must also exist below, or it does not exist.
-- Consequently: RLS is enabled on every table, and a table with no policy for
-- a verb is a table on which nobody may perform that verb.
--
-- FILE ORDER IS LOAD-BEARING and the file is sectioned accordingly:
--   1 enums → 2 tables → 3 policy helpers → 4 RLS + policies → 5 triggers
--   → 6 indexes → 7 feed → 8 grants
-- A `language sql` function body is name-resolved when the function is created,
-- not when it is first called, so every helper must come after every table it
-- reads — and every policy after the helpers it calls. Grouping each table with
-- its own policies reads better and does not work.
-- =============================================================================

-- MARK: - 1. Enums ------------------------------------------------------------

create type public.media_type   as enum ('movie', 'tv_show');
create type public.sentiment    as enum ('liked', 'fine', 'disliked');
create type public.post_kind    as enum ('ranked', 'want_to_watch', 'reviewed');
create type public.follow_state as enum ('pending', 'active');

-- MARK: - 2. Tables -----------------------------------------------------------

-- profiles --------------------------------------------------------------------
--
-- A profile row is discoverable by any signed-in, non-blocked user even when
-- `is_private` is set — otherwise a private account could not be found and
-- therefore could never be sent a follow request. Privacy gates the *library*
-- (`ranked_items`, `posts`), not the existence of the account.

create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  handle       text        not null unique,
  display_name text        not null,
  avatar_url   text,
  bio          text,
  is_private   boolean     not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  -- Lowercase-only by construction, so a plain unique constraint is
  -- case-insensitive without needing the citext extension.
  constraint profiles_handle_format check (handle ~ '^[a-z0-9_]{3,20}$'),

  constraint profiles_handle_reserved check (
    handle not in (
      'admin','administrator','root','system','support','help','about','api',
      'watchrank','official','staff','moderator','mod','settings','login',
      'signup','signin','logout','me','you','null','undefined','everyone','all'
    )
  ),

  constraint profiles_display_name_length check (length(display_name) between 1 and 50),
  constraint profiles_bio_length          check (bio is null or length(bio) <= 300)
);

-- follows ---------------------------------------------------------------------

create table public.follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  followee_id uuid not null references public.profiles (id) on delete cascade,
  state       public.follow_state not null default 'active',
  created_at  timestamptz not null default now(),
  primary key (follower_id, followee_id),
  constraint follows_no_self check (follower_id <> followee_id)
);

-- ranked_items ----------------------------------------------------------------
--
-- The published projection of a local SwiftData library. The server stores
-- results; it never computes them (PART-III-SOCIAL.md §2, invariant 1).
--
-- `bucket_size` travels with every row so a viewer can apply ranking rule 6 —
-- hide the score below 5 items in a bucket — to someone else's library, which
-- is impossible from the row alone.

create table public.ranked_items (
  user_id        uuid not null references public.profiles (id) on delete cascade,
  media_type     public.media_type not null,
  external_id    text not null,
  title          text not null,
  year           int,
  poster_path    text,
  sentiment      public.sentiment,
  score          numeric(4,2),
  rank_in_bucket int,
  bucket_size    int not null default 0,
  review         text,
  date_watched   timestamptz,
  updated_at     timestamptz not null default now(),

  primary key (user_id, media_type, external_id),

  constraint ranked_items_score_range   check (score is null or (score >= 0 and score <= 10)),
  constraint ranked_items_rank_valid    check (rank_in_bucket is null or rank_in_bucket >= 0),
  constraint ranked_items_bucket_size   check (bucket_size >= 0),
  constraint ranked_items_review_length check (review is null or length(review) <= 2000),

  -- A ranked item has a sentiment, a score and a position, or it has none of
  -- them (a want-to-watch entry). A half-populated row is a bug in the sync
  -- engine and should fail here rather than render as "#null in null".
  constraint ranked_items_ranked_or_queued check (
    (sentiment is null     and score is null     and rank_in_bucket is null)
    or
    (sentiment is not null and score is not null and rank_in_bucket is not null)
  )
);

-- posts -----------------------------------------------------------------------
--
-- Posts are immutable and carry a denormalised `payload`. A feed row must
-- render without joining `ranked_items`, because by the time you read the post
-- the underlying ranking has moved — every insertion recomputes a whole bucket.
-- "Alex ranked Dune #1" is a statement about a moment (PART-III-SOCIAL.md §9).
--
-- There is deliberately NO update policy in section 4. Nobody may update a
-- post, which is also what stops a client writing its own `comment_count`.

create table public.posts (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles (id) on delete cascade,
  kind           public.post_kind not null,
  media_type     public.media_type not null,
  external_id    text not null,
  payload        jsonb not null,
  comment_count  int not null default 0,
  reaction_count int not null default 0,
  created_at     timestamptz not null default now()
);

-- comments --------------------------------------------------------------------

create table public.comments (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references public.posts (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  body       text not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint comments_body_length check (length(body) between 1 and 1000)
);

-- reactions -------------------------------------------------------------------
--
-- One kind (like). The primary key is the deduplication — "liked twice" is not
-- a case the client has to get right.

create table public.reactions (
  post_id    uuid not null references public.posts (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

-- blocks ----------------------------------------------------------------------
--
-- A block is mutual invisibility, enforced in `app.blocked_with` and therefore
-- in every policy that calls it — not a client-side filter.

create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocks_no_self check (blocker_id <> blocked_id)
);

-- reports ---------------------------------------------------------------------
--
-- Insert-only for users. There is no select policy at all, so a reporter cannot
-- read the report queue and a reported user cannot discover they were reported.
-- Moderation reads happen with the service role, never from the app.

create table public.reports (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid not null references public.profiles (id) on delete cascade,
  subject_kind text not null check (subject_kind in ('post', 'comment', 'profile')),
  subject_id   uuid not null,
  reason       text not null check (length(reason) between 1 and 500),
  created_at   timestamptz not null default now()
);

-- MARK: - 3. Policy helpers ---------------------------------------------------
--
-- Helpers live outside `public` so PostgREST never exposes them as RPCs.
--
-- Every helper is SECURITY DEFINER, and that is load-bearing rather than lazy:
-- a policy on `profiles` that reads `follows` would re-enter `follows`'s own
-- policy, which reads `profiles` — Postgres detects the cycle and fails the
-- query with "infinite recursion detected in policy". Running the helper as the
-- owner reads the tables without RLS and breaks the cycle.
--
-- `set search_path` is mandatory on a SECURITY DEFINER function: without it a
-- caller can prepend a schema of their own and have the function resolve
-- `profiles` to a table they control.

create schema if not exists app;
revoke all on schema app from public;
grant usage on schema app to authenticated;

create or replace function app.blocked_with(other uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.blocks
     where (blocker_id = auth.uid() and blocked_id = other)
        or (blocker_id = other       and blocked_id = auth.uid())
  );
$$;

create or replace function app.follows_actively(target uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.follows
     where follower_id = auth.uid()
       and followee_id = target
       and state = 'active'
  );
$$;

-- Can the caller see `owner`'s published library and posts?
--
-- The `auth.uid() is not null` guard is deliberate: without it an anonymous
-- caller passes the "profile is not private" branch and reads every public
-- library with nothing but the bundled anon key. Signed-out means signed-out.
create or replace function app.can_view_library(owner uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select auth.uid() is not null
     and (
           owner = auth.uid()
        or (
             not app.blocked_with(owner)
             and (
                   exists (select 1 from public.profiles p
                            where p.id = owner and not p.is_private)
                or app.follows_actively(owner)
             )
        )
     );
$$;

create or replace function app.can_view_post(target_post uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.posts p
     where p.id = target_post
       and app.can_view_library(p.user_id)
  );
$$;

create or replace function app.owns_post(target_post uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.posts p
     where p.id = target_post and p.user_id = auth.uid()
  );
$$;

grant execute on function
  app.blocked_with(uuid),
  app.follows_actively(uuid),
  app.can_view_library(uuid),
  app.can_view_post(uuid),
  app.owns_post(uuid)
to authenticated;

-- MARK: - 4. RLS and policies -------------------------------------------------

alter table public.profiles     enable row level security;
alter table public.follows      enable row level security;
alter table public.ranked_items enable row level security;
alter table public.posts        enable row level security;
alter table public.comments     enable row level security;
alter table public.reactions    enable row level security;
alter table public.blocks       enable row level security;
alter table public.reports      enable row level security;

-- profiles --------------------------------------------------------------------

create policy profiles_select on public.profiles for select to authenticated
  using (auth.uid() is not null and not app.blocked_with(id));

create policy profiles_insert on public.profiles for insert to authenticated
  with check (id = auth.uid());

create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy profiles_delete on public.profiles for delete to authenticated
  using (id = auth.uid());

-- follows ---------------------------------------------------------------------

create policy follows_select on public.follows for select to authenticated
  using (
       follower_id = auth.uid()
    or followee_id = auth.uid()
    or (app.can_view_library(follower_id) and app.can_view_library(followee_id))
  );

create policy follows_insert on public.follows for insert to authenticated
  with check (follower_id = auth.uid() and not app.blocked_with(followee_id));

-- Only the *followee* may change a row, and only into 'active'. This is how a
-- follow request is accepted; it is also why a follower cannot approve
-- themselves.
create policy follows_update on public.follows for update to authenticated
  using (followee_id = auth.uid())
  with check (followee_id = auth.uid() and state = 'active');

create policy follows_delete on public.follows for delete to authenticated
  using (follower_id = auth.uid() or followee_id = auth.uid());

-- ranked_items ----------------------------------------------------------------

create policy ranked_items_select on public.ranked_items for select to authenticated
  using (app.can_view_library(user_id));

create policy ranked_items_insert on public.ranked_items for insert to authenticated
  with check (user_id = auth.uid());

create policy ranked_items_update on public.ranked_items for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy ranked_items_delete on public.ranked_items for delete to authenticated
  using (user_id = auth.uid());

-- posts (no update policy — posts are immutable) -------------------------------

create policy posts_select on public.posts for select to authenticated
  using (app.can_view_library(user_id));

create policy posts_insert on public.posts for insert to authenticated
  with check (user_id = auth.uid());

create policy posts_delete on public.posts for delete to authenticated
  using (user_id = auth.uid());

-- comments --------------------------------------------------------------------

create policy comments_select on public.comments for select to authenticated
  using (app.can_view_post(post_id) and not app.blocked_with(user_id));

create policy comments_insert on public.comments for insert to authenticated
  with check (user_id = auth.uid() and app.can_view_post(post_id));

-- The post's owner may soft-delete a comment on their own post; the author may
-- edit or soft-delete their own. Which columns may actually change is enforced
-- by a trigger in section 5, since RLS cannot express column-level rules.
create policy comments_update on public.comments for update to authenticated
  using (user_id = auth.uid() or app.owns_post(post_id))
  with check (user_id = auth.uid() or app.owns_post(post_id));

create policy comments_delete on public.comments for delete to authenticated
  using (user_id = auth.uid() or app.owns_post(post_id));

-- reactions -------------------------------------------------------------------

create policy reactions_select on public.reactions for select to authenticated
  using (app.can_view_post(post_id));

create policy reactions_insert on public.reactions for insert to authenticated
  with check (user_id = auth.uid() and app.can_view_post(post_id));

create policy reactions_delete on public.reactions for delete to authenticated
  using (user_id = auth.uid());

-- blocks ----------------------------------------------------------------------

create policy blocks_select on public.blocks for select to authenticated
  using (blocker_id = auth.uid());

create policy blocks_insert on public.blocks for insert to authenticated
  with check (blocker_id = auth.uid());

create policy blocks_delete on public.blocks for delete to authenticated
  using (blocker_id = auth.uid());

-- reports (insert-only; no select policy at all) -------------------------------

create policy reports_insert on public.reports for insert to authenticated
  with check (reporter_id = auth.uid());

-- MARK: - 5. Triggers ---------------------------------------------------------

-- Every account gets a profile the moment it is created, with a placeholder
-- handle the user replaces in onboarding. Doing this in a trigger rather than
-- in the client means there is no window in which an authenticated user exists
-- with no profile row — a state every join above would have to defend against.
create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  placeholder text := 'u' || substr(replace(new.id::text, '-', ''), 1, 19);
begin
  insert into public.profiles (id, handle, display_name)
  values (
    new.id,
    placeholder,
    coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), placeholder)
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();

-- The client does not get to choose `state`. Sending state='active' at a
-- private account is the obvious attack and the WITH CHECK above cannot catch
-- it, because at insert time the row is the follower's to write.
create or replace function app.force_follow_state()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  new.state := case
                 when (select is_private from public.profiles where id = new.followee_id)
                 then 'pending'::public.follow_state
                 else 'active'::public.follow_state
               end;
  return new;
end;
$$;

create trigger follows_force_state
  before insert on public.follows
  for each row execute function app.force_follow_state();

create or replace function app.guard_comment_update()
returns trigger
language plpgsql
as $$
begin
  if new.id <> old.id or new.post_id <> old.post_id
     or new.user_id <> old.user_id or new.created_at <> old.created_at then
    raise exception 'only body and deleted_at may be updated on a comment';
  end if;
  -- The post owner may hide a comment but may not put words in its author's
  -- mouth: they can set deleted_at, never body.
  if new.body is distinct from old.body and old.user_id <> auth.uid() then
    raise exception 'only the author may edit a comment body';
  end if;
  return new;
end;
$$;

create trigger comments_guard_update
  before update on public.comments
  for each row execute function app.guard_comment_update();

-- Denormalised counters.
--
-- SECURITY DEFINER because `posts` has no update policy: a trigger running as
-- the invoking user would be filtered out by RLS and the count would silently
-- never change. This is the mechanism that lets the counts be trustworthy while
-- remaining unwritable by any client.

create or replace function app.sync_comment_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  target uuid := coalesce(new.post_id, old.post_id);
begin
  update public.posts p
     set comment_count = (
           select count(*) from public.comments c
            where c.post_id = target and c.deleted_at is null
         )
   where p.id = target;
  return null;
end;
$$;

create trigger comments_count_sync
  after insert or update or delete on public.comments
  for each row execute function app.sync_comment_count();

create or replace function app.sync_reaction_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  target uuid := coalesce(new.post_id, old.post_id);
begin
  update public.posts p
     set reaction_count = (select count(*) from public.reactions r where r.post_id = target)
   where p.id = target;
  return null;
end;
$$;

create trigger reactions_count_sync
  after insert or delete on public.reactions
  for each row execute function app.sync_reaction_count();

-- Blocking severs the graph in both directions. Leaving a stale follow row
-- behind would keep the blocked user in a follower count and hand them the
-- blocker's posts through the `follows_actively` branch of can_view_library.
create or replace function app.sever_on_block()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.follows
   where (follower_id = new.blocker_id and followee_id = new.blocked_id)
      or (follower_id = new.blocked_id and followee_id = new.blocker_id);
  return new;
end;
$$;

create trigger blocks_sever_follows
  after insert on public.blocks
  for each row execute function app.sever_on_block();

create or replace function app.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch      before update on public.profiles
  for each row execute function app.touch_updated_at();
create trigger ranked_items_touch  before update on public.ranked_items
  for each row execute function app.touch_updated_at();

-- MARK: - 6. Indexes ----------------------------------------------------------
--
-- `posts_feed_idx` is the feed's index: the query pages by (created_at, id)
-- descending within a set of followees, so the composite has to be in that
-- order to serve both the filter and the sort.

create index posts_feed_idx           on public.posts (user_id, created_at desc, id desc);
create index follows_active_idx       on public.follows (follower_id) where state = 'active';
create index follows_followee_idx     on public.follows (followee_id);
create index ranked_items_ranking_idx on public.ranked_items (user_id, media_type, score desc);
create index comments_post_idx        on public.comments (post_id, created_at);
create index reactions_post_idx       on public.reactions (post_id);

-- MARK: - 7. Feed -------------------------------------------------------------
--
-- Fan-out on read. Cursor pagination on (created_at, id), never OFFSET: new
-- posts land mid-scroll constantly, and offset paging would duplicate and skip
-- rows every time one did.
--
-- SECURITY INVOKER so `posts`'s RLS still applies underneath. The followee
-- filter narrows the feed to people you follow; RLS is what stops it returning
-- anything you are not allowed to see.

create or replace function public.feed(
  before_created_at timestamptz default null,
  before_id         uuid        default null,
  page_size         int         default 20
)
returns setof public.posts
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  -- Merge N sorted streams, one per followee, rather than filtering the whole
  -- table and sorting the survivors.
  --
  -- The obvious form —
  --     where p.user_id in (select followee_id from follows …)
  --     order by created_at desc limit 20
  -- — cannot use `posts_feed_idx` for the ordering, because that index orders
  -- posts *within* a user and the feed wants a global order *across* twenty of
  -- them. Measured on 6000 posts it read 2101 rows and evaluated the RLS
  -- predicate on every one to return 20, and it gets worse in proportion to how
  -- much the people you follow have posted.
  --
  -- The LATERAL takes the newest `page_size` from each followee by index — an
  -- equality on user_id plus an ordered scan, which is exactly the index's
  -- shape — and sorts the small union. Rows touched become
  -- (followees × page_size), bounded by who you follow rather than by how much
  -- anyone has written, which also caps how often the SECURITY DEFINER
  -- visibility check has to run.
  select p.*
    from (
          select f.followee_id
            from public.follows f
           where f.follower_id = auth.uid()
             and f.state = 'active'
         ) as followee
   cross join lateral (
          select p2.*
            from public.posts p2
           where p2.user_id = followee.followee_id
             and (
                   before_created_at is null
                or (p2.created_at, p2.id) < (before_created_at, before_id)
             )
           order by p2.created_at desc, p2.id desc
           limit least(greatest(page_size, 1), 100)
         ) as p
   order by p.created_at desc, p.id desc
   limit least(greatest(page_size, 1), 100);
$$;

-- MARK: - 8. Grants -----------------------------------------------------------
--
-- REVOKE FIRST. Supabase's base setup includes
--   alter default privileges for role postgres in schema public
--     grant all on tables to anon, authenticated, service_role;
-- so every table created above already carries the full privilege set for both
-- `anon` and `authenticated` before a line of this section runs. Without the
-- revoke the grants below are decoration: they add privileges that are already
-- held, and the carefully minimal per-table lists describe an intent the
-- database does not implement.
--
-- The sharp edge is TRUNCATE, which the default grant includes and which
-- **row-level security does not filter** — policies are not consulted for it at
-- all. An authenticated user holding TRUNCATE on `posts` can erase every user's
-- posts with one statement, and not one policy in section 4 would be evaluated.
-- SELECT/UPDATE/DELETE at least fall back to RLS returning zero rows; TRUNCATE
-- has no such backstop, so the privilege is the only thing standing in its way.
--
-- Verified by the suite: an authenticated client is refused both an UPDATE on
-- `posts` and a TRUNCATE of it (supabase/tests/rls_test.sql, tests 13–14).

revoke all on public.profiles, public.follows, public.ranked_items,
              public.posts, public.comments, public.reactions,
              public.blocks, public.reports
  from anon, authenticated;

revoke all on function public.feed(timestamptz, uuid, int) from anon, public;
grant execute on function public.feed(timestamptz, uuid, int) to authenticated;

grant select, insert, update, delete on public.profiles     to authenticated;
grant select, insert, update, delete on public.follows      to authenticated;
grant select, insert, update, delete on public.ranked_items to authenticated;
grant select, insert,         delete on public.posts        to authenticated;
grant select, insert, update, delete on public.comments     to authenticated;
grant select, insert,         delete on public.reactions    to authenticated;
grant select, insert,         delete on public.blocks       to authenticated;
grant         insert                 on public.reports      to authenticated;
