-- Who among the people you follow has watched a given title.
--
-- The question a title page asks: "before I spend two hours on this, what did
-- my friends make of it?" Everything it needs was already stored — the ranking
-- rows, the profiles, the follow edges — and none of it was queryable in that
-- direction. `ranked_items` could only be read one library at a time, by owner.
--
-- **Why an RPC rather than a PostgREST filter.** `ranked_items?external_id=eq.X`
-- with an embedded profile very nearly works: `ranked_items_select` already
-- restricts the result to published rows of libraries the viewer may read. But
-- "may read" is `app.can_view_library`, which passes for *any* non-private
-- account, so a bare filter answers "who on this whole service watched it",
-- including strangers. Narrowing to followees needs the `follows` table in the
-- query, and that is exactly what a client cannot be trusted to remember to do.
--
-- **`security invoker`, like every other RPC here.** The function adds the
-- follow restriction on top of RLS; it does not replace it. Both still apply,
-- so a row that `ranked_items_select` would refuse stays refused — publication
-- and blocking are enforced once, in the policy, not re-implemented here.
--
-- Deliberately NOT returned: rows the viewer owns. You know what you thought of
-- it; the section exists to show other people.

create or replace function public.title_watchers(
  p_media_type  public.media_type,
  p_external_id text,
  p_limit       int default 20
)
returns table (
  user_id        uuid,
  handle         text,
  display_name   text,
  avatar_url     text,
  sentiment      public.sentiment,
  score          numeric(4,2),
  rank_in_bucket int,
  bucket_size    int,
  review         text
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  -- Table-qualified throughout: `returns table` introduces output names that
  -- collide with the columns they are built from.
  select ri.user_id,
         pr.handle,
         pr.display_name,
         pr.avatar_url,
         ri.sentiment,
         ri.score,
         ri.rank_in_bucket,
         ri.bucket_size,
         ri.review
    from public.ranked_items ri
    join public.profiles pr on pr.id = ri.user_id
   where ri.media_type  = p_media_type
     and ri.external_id = p_external_id
     -- A want-to-watch entry is not an opinion. `ranked_items_ranked_or_queued`
     -- guarantees these three are null together, so one test is enough.
     and ri.sentiment is not null
     and ri.user_id <> auth.uid()
     and app.follows_actively(ri.user_id)
   -- Best first, so the most enthusiastic opinion leads. The enum is declared
   -- ('liked','fine','disliked') and Postgres orders enums by declaration, so
   -- ascending IS best-first here; only the score within a sentiment descends.
   order by ri.sentiment asc, ri.score desc nulls last, pr.handle asc
   limit greatest(0, least(p_limit, 50));
$$;

comment on function public.title_watchers is
  'Published opinions on one title from accounts the caller actively follows. '
  'RLS still decides which rows exist; this only narrows them to followees.';

-- `authenticated` only. Signed out there is no `auth.uid()`, so every row would
-- fail `follows_actively` anyway — but granting execute to `anon` would still
-- advertise the function, and `app.can_view_library` documents why signed-out
-- means signed-out rather than "sees the public subset".
revoke all on function public.title_watchers(public.media_type, text, int) from public;
grant execute on function public.title_watchers(public.media_type, text, int) to authenticated;
