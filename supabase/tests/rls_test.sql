-- =============================================================================
-- WatchRank — row-level security tests (roadmap Phase 20)
--
--   supabase start && supabase test db
--
-- These assertions are the phase's acceptance criteria, and they are almost all
-- negative. That is the point: the anon key ships in the app bundle, so "the
-- client would never ask for that" protects nothing (PART-III-SOCIAL.md §4).
-- What matters is what the database refuses.
--
-- The whole file runs inside a transaction that is rolled back, so it leaves no
-- state behind and can be re-run against a live local stack.
-- =============================================================================

begin;

-- pgTAP lives in `extensions`, and the temp fixture tables below resolve
-- through pg_temp. Both have to be on the search_path before plan() is called,
-- and the whole thing is rolled back, so nothing here reaches a real project.
create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_temp;

select plan(33);

-- MARK: - Role switching ------------------------------------------------------
--
-- SET ROLE is checked against session_user, which stays `postgres` here, so a
-- test can drop into `authenticated` for an assertion and climb back out to set
-- up the next one. `request.jwt.claims` is what `auth.uid()` reads.

create or replace function tests_login(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', uid::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function tests_logout() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
end $$;

create or replace function tests_as_owner() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);
end $$;

-- MARK: - Fixture -------------------------------------------------------------

create temporary table ids (name text primary key, id uuid);
insert into ids values
  ('alice',   '11111111-1111-1111-1111-111111111111'),
  ('bob',     '22222222-2222-2222-2222-222222222222'),
  ('carol',   '33333333-3333-3333-3333-333333333333'),
  ('mallory', '44444444-4444-4444-4444-444444444444');

-- Every assertion below reads `ids` while the session is SET ROLE authenticated,
-- and a temp table created by postgres grants that role nothing by default.
grant select on ids to authenticated;

insert into auth.users (id, email, raw_user_meta_data)
select id, name || '@example.test', json_build_object('display_name', initcap(name))::jsonb
  from ids;

-- The on_auth_user_created trigger has given each account a placeholder handle.
update public.profiles p set handle = i.name from ids i where p.id = i.id;
update public.profiles set is_private = true
 where id = (select id from ids where name = 'carol');

-- `is_published` is NOT set on these inserts, and cannot be: the
-- `ranked_items_inherit_publication` trigger is BEFORE INSERT and
-- unconditional, so it overwrites whatever a caller sends. That is correct for
-- the app — a row adopts its bucket's decision, or the account's standing
-- answer — but it means a fixture cannot seed a published row by INSERT. The
-- first version of this file tried, and every visibility assertion failed for a
-- reason unrelated to the policy it was testing.
--
-- So publication is applied by UPDATE below, as the table owner. The trigger
-- does not fire on UPDATE, and the column revoke applies to `authenticated`,
-- not to the owner.
insert into public.ranked_items
  (user_id, media_type, external_id, title, year, sentiment, score, rank_in_bucket, bucket_size)
select id, 'movie', 'tmdb:movie:27205', 'Inception', 2010, 'liked', 9.20, 0, 5
  from ids where name in ('alice', 'carol', 'mallory');

-- Alice keeps one bucket to herself: a TV title she has synced but not
-- published. Nothing else in this file may see it — assertion 28 — but only
-- until assertion 31, where `set_library_published(true)` correctly publishes
-- every bucket she owns, this one included. Do not reorder those two.
insert into public.ranked_items
  (user_id, media_type, external_id, title, year, sentiment, score, rank_in_bucket, bucket_size)
select id, 'tv_show', 'tmdb:tv:1396', 'Breaking Bad', 2008, 'liked', 9.60, 0, 5
  from ids where name = 'alice';

-- Everyone's film bucket is published; Alice's TV bucket is not. Both audiences
-- of the select policy are now exercisable.
update public.ranked_items set is_published = true where media_type = 'movie';

insert into public.posts (id, user_id, kind, media_type, external_id, payload)
select ('aaaaaaaa-0000-0000-0000-00000000000' || row_number() over (order by name))::uuid,
       id, 'ranked', 'movie', 'tmdb:movie:27205',
       json_build_object('title', 'Inception', 'rank', 1, 'sentiment', 'liked')::jsonb
  from ids where name in ('alice', 'carol', 'mallory');

create temporary table posts_of (name text primary key, id uuid);
insert into posts_of
select i.name, p.id from public.posts p join ids i on i.id = p.user_id;
grant select on posts_of to authenticated;

-- MARK: - 1–4. A signed-out client reads nothing ------------------------------
--
-- `anon` is granted no table privileges at all, so these are privilege
-- failures rather than empty result sets — a stronger guarantee than RLS alone,
-- and the reason `app.can_view_library` also refuses a null `auth.uid()`.

select tests_logout();

select throws_ok(
  'select count(*) from public.profiles'::text,
  '42501'::text,
  null::text,
  'anon cannot read profiles');

select throws_ok(
  'select count(*) from public.ranked_items'::text,
  '42501'::text,
  null::text,
  'anon cannot read ranked_items');

select throws_ok(
  'select count(*) from public.posts'::text,
  '42501'::text,
  null::text,
  'anon cannot read posts');

select throws_ok(
  'select count(*) from public.comments'::text,
  '42501'::text,
  null::text,
  'anon cannot read comments');

-- MARK: - 5–8. Library visibility --------------------------------------------

select tests_as_owner();
select tests_login((select id from ids where name = 'bob'));

select is(
  (select count(*)::int from public.ranked_items
    where user_id = (select id from ids where name = 'alice')),
  1,
  'a published row is readable by any signed-in user');

select is(
  (select count(*)::int from public.ranked_items
    where user_id = (select id from ids where name = 'carol')),
  0,
  'a private library is invisible to a non-follower');

select is(
  (select count(*)::int from public.profiles
    where id = (select id from ids where name = 'carol')),
  1,
  'a private account is still discoverable, or it could never be followed');

-- Bob follows Carol; the trigger forces `pending` (asserted at 16 below).
insert into public.follows (follower_id, followee_id)
values ((select id from ids where name = 'bob'), (select id from ids where name = 'carol'));

select is(
  (select count(*)::int from public.ranked_items
    where user_id = (select id from ids where name = 'carol')),
  0,
  'a pending follow grants nothing — approval is what opens the library');

-- MARK: - 9–11. Blocks are mutual --------------------------------------------

select tests_as_owner();
select tests_login((select id from ids where name = 'mallory'));

insert into public.follows (follower_id, followee_id)
values ((select id from ids where name = 'mallory'), (select id from ids where name = 'alice'));

select tests_as_owner();
select tests_login((select id from ids where name = 'alice'));

insert into public.blocks (blocker_id, blocked_id)
values ((select id from ids where name = 'alice'), (select id from ids where name = 'mallory'));

select is(
  (select count(*)::int from public.posts
    where user_id = (select id from ids where name = 'mallory')),
  0,
  'the blocker cannot see the blocked user''s posts');

select is(
  (select count(*)::int from public.follows
    where follower_id = (select id from ids where name = 'mallory')
      and followee_id = (select id from ids where name = 'alice')),
  0,
  'blocking severs an existing follow, so it cannot re-open the library');

select tests_as_owner();
select tests_login((select id from ids where name = 'mallory'));

select is(
  (select count(*)::int from public.posts
    where user_id = (select id from ids where name = 'alice')),
  0,
  'the blocked user cannot see the blocker''s posts either');

-- MARK: - 12–16. A client cannot write as someone else ------------------------

select tests_as_owner();
select tests_login((select id from ids where name = 'bob'));

select throws_ok(
  format($q$insert into public.posts (user_id, kind, media_type, external_id, payload)
             values (%L, 'ranked', 'movie', 'tmdb:movie:1', '{}'::jsonb)$q$,
         (select id from ids where name = 'alice')),
  '42501'::text,
  null::text,
  'a client cannot post as another user');

select throws_ok(
  'update public.posts set comment_count = 999'::text,
  '42501'::text,
  null::text,
  'no client may write a post at all, which is what makes the counters trustworthy');

-- TRUNCATE is not filtered by row-level security — no policy in the schema is
-- consulted for it. Only the absence of the privilege stops an authenticated
-- client erasing every user's posts, which is why section 8 revokes before it
-- grants.
select throws_ok(
  'truncate public.posts'::text,
  '42501'::text,
  null::text,
  'no client may TRUNCATE, the one write RLS would never have caught');

select throws_ok(
  format($q$insert into public.ranked_items
             (user_id, media_type, external_id, title, year, bucket_size)
             values (%L, 'movie', 'tmdb:movie:2', 'Forgery', 2026, 1)$q$,
         (select id from ids where name = 'alice')),
  '42501'::text,
  null::text,
  'a client cannot publish into another user''s library');

update public.profiles set display_name = 'Hacked'
 where id = (select id from ids where name = 'alice');

select tests_as_owner();
select is(
  (select display_name from public.profiles
    where id = (select id from ids where name = 'alice')),
  'Alice',
  'another user''s profile update matches no rows and changes nothing');

-- MARK: - 17–20. Follow state is the server's to decide -----------------------

select tests_login((select id from ids where name = 'bob'));

select is(
  (select state::text from public.follows
    where follower_id = (select id from ids where name = 'bob')
      and followee_id = (select id from ids where name = 'carol')),
  'pending',
  'following a private account yields pending, whatever the client sent');

update public.follows set state = 'active'
 where follower_id = (select id from ids where name = 'bob')
   and followee_id = (select id from ids where name = 'carol');

select is(
  (select state::text from public.follows
    where follower_id = (select id from ids where name = 'bob')
      and followee_id = (select id from ids where name = 'carol')),
  'pending',
  'a follower cannot approve their own request');

select tests_as_owner();
select tests_login((select id from ids where name = 'carol'));

update public.follows set state = 'active'
 where follower_id = (select id from ids where name = 'bob')
   and followee_id = (select id from ids where name = 'carol');

select tests_as_owner();
select tests_login((select id from ids where name = 'bob'));

select is(
  (select count(*)::int from public.ranked_items
    where user_id = (select id from ids where name = 'carol')),
  1,
  'once the followee approves, the private library opens');

select throws_ok(
  format($q$insert into public.follows (follower_id, followee_id) values (%L, %L)$q$,
         (select id from ids where name = 'bob'), (select id from ids where name = 'bob')),
  '23514'::text,
  null::text,
  'self-follow is refused by a check constraint, not by the UI');

-- MARK: - 21–23. Constraints and dedupe ---------------------------------------

select tests_as_owner();

select throws_ok(
  format($q$update public.profiles set handle = 'admin' where id = %L$q$,
         (select id from ids where name = 'bob')),
  '23514'::text,
  null::text,
  'reserved handles are rejected');

select throws_ok(
  format($q$update public.profiles set handle = 'Bob Smith!' where id = %L$q$,
         (select id from ids where name = 'bob')),
  '23514'::text,
  null::text,
  'handles are lowercase, 3–20, [a-z0-9_] — enforced in the schema');

select tests_login((select id from ids where name = 'bob'));

insert into public.reactions (post_id, user_id)
values ((select id from posts_of where name = 'alice'), (select id from ids where name = 'bob'));

select throws_ok(
  format($q$insert into public.reactions (post_id, user_id) values (%L, %L)$q$,
         (select id from posts_of where name = 'alice'),
         (select id from ids where name = 'bob')),
  '23505'::text,
  null::text,
  'the primary key is the dedupe — a client cannot like twice');

-- MARK: - 24–25. Counters and cascade ----------------------------------------

insert into public.comments (post_id, user_id, body)
values ((select id from posts_of where name = 'alice'),
        (select id from ids where name = 'bob'),
        'no way that is your number one');

select is(
  (select comment_count from public.posts where id = (select id from posts_of where name = 'alice')),
  1,
  'the comment counter is maintained by a trigger the client cannot reach');

select tests_as_owner();

delete from auth.users where id = (select id from ids where name = 'mallory');

select is(
  (select count(*)::int from public.profiles p
     join ids i on i.id = p.id
    where i.name = 'mallory')
  + (select count(*)::int from public.posts p
       join ids i on i.id = p.user_id
      where i.name = 'mallory')
  + (select count(*)::int from public.ranked_items r
       join ids i on i.id = r.user_id
      where i.name = 'mallory'),
  0,
  'deleting the account cascades to every table — the basis of in-app account deletion');

-- MARK: - 26–27. The feed is the graph, not the catalogue ---------------------
--
-- RLS alone would hand Bob every public account's posts. The followee filter
-- inside `feed()` is what makes it a feed, so it is asserted separately: Alice
-- is public and readable, and must still not appear.

select tests_login((select id from ids where name = 'bob'));

select is(
  (select count(*)::int from public.feed(null, null, 20)
    where user_id = (select id from ids where name = 'carol')),
  1,
  'the feed carries a followee''s post');

select is(
  (select count(*)::int from public.feed(null, null, 20)
    where user_id = (select id from ids where name = 'alice')),
  0,
  'a public account you do not follow is readable but not in your feed');

select * from finish();
-- MARK: - 28–31. Stored is not the same as visible -----------------------------
--
-- Part IV (`docs/PART-IV-SYNC.md`). A signed-in user's whole library reaches the
-- server unconditionally; `is_published` decides what anyone else sees. These
-- four are the assertions that make that a database guarantee rather than a
-- client convention, and three of them are negative for the usual reason: the
-- anon key ships in the bundle, so what matters is what Postgres refuses.

select tests_as_owner();
select tests_login((select id from ids where name = 'bob'));

select is(
  (select count(*)::int from public.ranked_items
    where user_id = (select id from ids where name = 'alice')
      and media_type = 'tv_show'),
  0,
  'an unpublished row is invisible to others');

select tests_as_owner();
select tests_login((select id from ids where name = 'alice'));

select is(
  (select count(*)::int from public.ranked_items where user_id = auth.uid()),
  2,
  'the owner reads her whole library, published or not');

-- The column revoke is what stops a client flipping one row and leaving a
-- bucket half-visible, which would let a viewer read `bucket_size` against rows
-- they cannot see.
select throws_ok(
  $q$update public.ranked_items set is_published = true where media_type = 'tv_show'$q$::text,
  '42501'::text,
  null::text,
  'a client cannot set is_published directly');

-- And the RPC moves a whole bucket, which is the only granularity that keeps
-- `bucket_size` honest.
select is(
  public.set_library_published(true),
  2,
  'set_library_published flips every row it owns');

-- `where user_id = auth.uid()` inside the function body is now the ONLY
-- boundary protecting every account's library, because the function is
-- SECURITY DEFINER and writes past the column revoke. A future edit that
-- parameterised it — for an admin screen, say — would remove that boundary
-- without failing anything else in this file. So it gets its own assertion.
--
-- **As the owner, deliberately.** Read as alice this cannot distinguish "the
-- RPC did not modify these rows" from "alice may not see these rows" — and at
-- this point she may not: she has no active follow to carol, so RLS hides that
-- library and the count is 0 for a reason unrelated to the boundary. Reading as
-- owner bypasses RLS and asks the question actually being asked. `auth.uid()`
-- is null for the owner, so alice is named by id instead.
--
-- Expected 1, not 2: mallory's account was deleted at assertion 25, so carol is
-- the only other library still standing.
select tests_as_owner();

select is(
  (select count(*)::int from public.ranked_items
    where user_id <> (select id from ids where name = 'alice')
      and is_published),
  1,
  'set_library_published touched nobody else''s rows');

select tests_login((select id from ids where name = 'alice'));

-- The empty-bucket case. A consented user ranking into a bucket that has no
-- rows yet must inherit the account's standing answer, or their first TV show
-- lands silently private and the only symptom is a follower not seeing it.
insert into public.ranked_items
  (user_id, media_type, external_id, title, year, sentiment, score, rank_in_bucket, bucket_size)
values (auth.uid(), 'movie', 'tmdb:movie:603', 'The Matrix', 1999, 'fine', 5.10, 0, 1);

select is(
  (select is_published from public.ranked_items
    where user_id = auth.uid() and external_id = 'tmdb:movie:603'),
  true,
  'a new bucket adopts the standing answer');


rollback;
