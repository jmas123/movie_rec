-- =============================================================================
-- Follower / following lists.
--
-- The last two functions the client calls that no migration defined. They were
-- missed in 20260822010000 because `SupabaseSocialService` builds their names
-- through a helper (`people(rpc:userID:limit:)`) rather than as literals, so a
-- grep for `rpc("…")` does not see them.
--
-- SECURITY INVOKER, like every other RPC here: `follows_select` decides what a
-- viewer may read, so a private account the viewer does not follow yields an
-- empty list rather than an error — the same answer as "nobody follows them",
-- which is the point.
--
-- The client paginates these with a Range header, so the ordering has to be
-- total and stable. `handle` is unique, which makes it both.
-- =============================================================================

create or replace function public.followers_of(target uuid)
returns setof public.profiles
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select pr.*
    from public.follows f
    join public.profiles pr on pr.id = f.follower_id
   where f.followee_id = target
     and f.state = 'active'
   order by pr.handle asc;
$$;

create or replace function public.following_of(target uuid)
returns setof public.profiles
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select pr.*
    from public.follows f
    join public.profiles pr on pr.id = f.followee_id
   where f.follower_id = target
     and f.state = 'active'
   order by pr.handle asc;
$$;

revoke all on function public.followers_of(uuid) from anon, public;
grant execute on function public.followers_of(uuid) to authenticated;

revoke all on function public.following_of(uuid) from anon, public;
grant execute on function public.following_of(uuid) to authenticated;
