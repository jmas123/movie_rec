-- What the people you follow liked, across a set of titles.
--
-- The question a cast member's screen asks: "I have just tapped an actor —
-- which of their films did my people actually rate?" `title_watchers` answers
-- the same shape of question for exactly one title, and calling it once per
-- credit would be sixty round trips to draw one screen.
--
-- So this is `title_watchers` with the title as an *array* and the sentiment
-- pinned to 'liked'. Everything else about it is deliberately identical, and
-- where it is identical the reasoning is recorded there rather than repeated:
--
--   * **An RPC rather than a PostgREST filter**, because narrowing to followees
--     needs the `follows` table in the query and `ranked_items_select` alone
--     would answer "who on this whole service liked it".
--   * **`security invoker`**, so RLS still decides which rows exist and this
--     only narrows them. Publication and blocking are enforced once, in the
--     policy.
--   * **The caller's own rows are excluded.** You know what you thought of it.
--
-- **Only 'liked'.** The screen is "films of theirs your people liked", so a
-- three-star shrug is not an answer to it, and returning every sentiment would
-- mean shipping rows the client throws away. A caller that wants the full
-- spread of opinion on one title already has `title_watchers`.
--
-- **The array is sliced, not trusted.** A filmography is however long TMDB says
-- it is, and an unbounded `= any()` from a client is an invitation to send ten
-- thousand ids. 300 is far past the longest real filmography and far short of
-- anything that hurts.

create index if not exists ranked_items_title_idx
  on public.ranked_items (external_id)
  where sentiment is not null;

comment on index public.ranked_items_title_idx is
  'Supports the by-title reads — title_watchers and titles_liked_by_followees — '
  'which are the only queries that do not know whose library they want. '
  'Partial: a want-to-watch row has no opinion on it and is never the answer.';

create or replace function public.titles_liked_by_followees(
  p_external_ids text[],
  p_limit        int default 200
)
returns table (
  external_id    text,
  media_type     public.media_type,
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
  select ri.external_id,
         ri.media_type,
         ri.user_id,
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
   where ri.external_id = any(p_external_ids[1:300])
     and ri.sentiment = 'liked'
     and ri.user_id <> auth.uid()
     and app.follows_actively(ri.user_id)
   -- Grouped by title so the client can walk the result in one pass, and best
   -- opinion first within each so the row it draws leads with the strongest.
   order by ri.external_id asc, ri.score desc nulls last, pr.handle asc
   limit greatest(0, least(p_limit, 500));
$$;

comment on function public.titles_liked_by_followees is
  'Titles from the given set that accounts the caller actively follows put in '
  'their Liked bucket. RLS still decides which rows exist; this only narrows '
  'them to followees, and to liked.';

-- `authenticated` only, for the reason `title_watchers` is: signed out there is
-- no `auth.uid()`, so every row would fail `follows_actively` anyway, and
-- granting to `anon` would advertise a function that can never answer.
revoke all on function public.titles_liked_by_followees(text[], int) from public;
grant execute on function public.titles_liked_by_followees(text[], int) to authenticated;
