-- `titles_liked_by_followees`, the many-titles read behind a cast member's screen.
--
-- Its own file, for the reason `comment_editing_test.sql` and
-- `content_filter_test.sql` are their own files: the RLS suite's plan count is
-- load-bearing, and a failure here should read as "the cast screen's query
-- broke", not "RLS broke".
--
-- The function is `title_watchers` with the title as an array and the sentiment
-- pinned, so the assertions are deliberately the same four negatives — self,
-- stranger, private-and-unfollowed, and the one no single-title query could
-- have: a title the caller did not ask about. Each of them is a rule that lives
-- in two places at once (the RPC's `follows_actively` and the row policy), and
-- the redundancy is the point — this is what fails if a future edit relaxes
-- either one.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_temp;

select plan(9);

-- MARK: - Role switching ------------------------------------------------------

create or replace function tests_login(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', uid::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function tests_as_owner() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);
end $$;

-- MARK: - Fixture -------------------------------------------------------------
--
-- viewer   — the caller.
-- friend   — followed, active. The one account whose opinions should appear.
-- pending  — followed, but the request has not been accepted.
-- stranger — public, and nobody follows anybody.
-- hermit   — private, and the viewer does not follow them.

create temporary table ids (name text primary key, id uuid);
insert into ids values
  ('viewer',   '11111111-1111-1111-1111-111111111111'),
  ('friend',   '22222222-2222-2222-2222-222222222222'),
  ('pending',  '33333333-3333-3333-3333-333333333333'),
  ('stranger', '44444444-4444-4444-4444-444444444444'),
  ('hermit',   '55555555-5555-5555-5555-555555555555');
grant select on ids to authenticated;

insert into auth.users (id, email, raw_user_meta_data)
select id, name || '@example.test', json_build_object('display_name', initcap(name))::jsonb
  from ids;

update public.profiles p set handle = i.name from ids i where p.id = i.id;
update public.profiles set is_private = true
 where id = (select id from ids where name = 'hermit');

-- Three films of one actor's, and a fourth the screen will not ask about.
-- Everybody liked the first, so who is missing from the answer is the whole
-- test; only the friend's `fine` and out-of-set rows vary.
insert into public.ranked_items
  (user_id, media_type, external_id, title, year, sentiment, score, rank_in_bucket, bucket_size)
select id, 'movie', 'tmdb:movie:27205', 'Inception', 2010, 'liked', 9.20, 0, 8
  from ids where name in ('viewer', 'friend', 'pending', 'stranger', 'hermit');

-- The friend watched a second one and shrugged at it. A shrug is not a like.
insert into public.ranked_items
  (user_id, media_type, external_id, title, year, sentiment, score, rank_in_bucket, bucket_size)
select id, 'movie', 'tmdb:movie:1892', 'Return of the Jedi', 1983, 'fine', 5.10, 1, 8
  from ids where name = 'friend';

-- And loved a third that is not in the filmography being asked about.
insert into public.ranked_items
  (user_id, media_type, external_id, title, year, sentiment, score, rank_in_bucket, bucket_size)
select id, 'tv_show', 'tmdb:tv:1396', 'Breaking Bad', 2008, 'liked', 9.60, 0, 8
  from ids where name = 'friend';

-- A queued title carries no opinion, and must not surface as one.
insert into public.ranked_items
  (user_id, media_type, external_id, title, year, bucket_size)
select id, 'movie', 'tmdb:movie:157336', 'Interstellar', 2014, 0
  from ids where name = 'friend';

-- MARK: - Edges ---------------------------------------------------------------
--
-- Inserted as the follower, not as the owner: `rate_limit_follows` records
-- `auth.uid()` into `rate_events`, which is NOT NULL, so an owner-side insert
-- fails on a constraint that has nothing to do with what is being tested.

select tests_login((select id from ids where name = 'viewer'));
insert into public.follows (follower_id, followee_id)
select (select id from ids where name = 'viewer'), id
  from ids where name in ('friend', 'pending');

-- Forced rather than assumed: whether a fresh edge lands `active` or `pending`
-- is the follow trigger's business, asserted in the RLS suite. These assertions
-- are about what the RPC does with each state.
select tests_as_owner();
update public.follows set state = 'active'
 where follower_id = (select id from ids where name = 'viewer')
   and followee_id = (select id from ids where name = 'friend');
update public.follows set state = 'pending'
 where follower_id = (select id from ids where name = 'viewer')
   and followee_id = (select id from ids where name = 'pending');

-- MARK: - The answer ----------------------------------------------------------

select tests_login((select id from ids where name = 'viewer'));

create temporary view answer as
  select * from public.titles_liked_by_followees(
    array['tmdb:movie:27205', 'tmdb:movie:1892', 'tmdb:movie:157336']
  );

select is(
  (select count(*)::int from answer where handle = 'friend'),
  1,
  'returns a followee''s liked title');

select is(
  (select external_id from answer where handle = 'friend'),
  'tmdb:movie:27205',
  'and returns which title it was, since the caller asked about several');

select is(
  (select score::text from answer where handle = 'friend'),
  '9.20',
  'carrying the score the row was published with');

select is(
  (select count(*)::int from answer where handle = 'viewer'),
  0,
  'never returns the caller to themselves');

select is(
  (select count(*)::int from answer where handle = 'stranger'),
  0,
  'does not return an account the caller does not follow');

select is(
  (select count(*)::int from answer where handle = 'pending'),
  0,
  'a sent-but-unaccepted request is not a follow');

-- Two rules could hide the hermit — the RPC's own `follows_actively` and the
-- row policy's `can_view_library`. Neither is allowed to be the only one.
select is(
  (select count(*)::int from answer where handle = 'hermit'),
  0,
  'a private account the caller does not follow stays invisible');

select is(
  (select count(*)::int from answer where external_id = 'tmdb:movie:1892'),
  0,
  'a title they merely thought was fine is not a recommendation');

-- The queued row would have failed `sentiment = 'liked'` anyway; asserted
-- because `title_watchers` learned the same lesson the expensive way — a
-- want-to-watch entry is a legal row with a null sentiment, and reads that
-- forget it render "#null in null".
select is(
  (select count(*)::int from answer where external_id = 'tmdb:movie:157336'),
  0,
  'a want-to-watch entry is not an opinion');

select * from finish();

rollback;
