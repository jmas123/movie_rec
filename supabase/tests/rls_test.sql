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

select plan(42);

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


-- MARK: - 34–36. The follow-request inbox -------------------------------------
--
-- The whole chain from "A taps Follow" to "B sees a request", which was the one
-- link in the private-account feature nothing asserted. Every part of it was
-- covered in isolation — the trigger writes `pending` (17), the follower cannot
-- self-approve (18), `follows_select` lets the followee read the row — but the
-- function the inbox screen actually calls was never exercised, so a join that
-- dropped the requester (via `profiles_select`, say, or a block) would have
-- looked exactly like "nobody has asked yet".
--
-- 36 is the other half, and the one that gets reported as a bug: on a **public**
-- account `app.force_follow_state` writes `active`, so no request is ever
-- created and this inbox is empty permanently rather than temporarily.

select tests_as_owner();
delete from public.follows
 where follower_id = (select id from ids where name = 'alice')
   and followee_id = (select id from ids where name = 'carol');

select tests_login((select id from ids where name = 'alice'));
insert into public.follows (follower_id, followee_id)
values ((select id from ids where name = 'alice'),
        (select id from ids where name = 'carol'));

select tests_as_owner();
select tests_login((select id from ids where name = 'carol'));

select is(
  (select count(*)::int from public.pending_requests()),
  1,
  'a private account sees the request waiting on it');

select is(
  (select handle from public.pending_requests()),
  'alice',
  'and sees who is asking, not a bare edge');

-- Public account: carol follows bob, who is not private.
select tests_as_owner();
select tests_login((select id from ids where name = 'carol'));
insert into public.follows (follower_id, followee_id)
values ((select id from ids where name = 'carol'),
        (select id from ids where name = 'bob'))
on conflict do nothing;

select tests_as_owner();
select tests_login((select id from ids where name = 'bob'));

select is(
  (select count(*)::int from public.pending_requests()),
  0,
  'a public account never accrues requests — the follow is already active');


-- MARK: - 37–38. Following twice ----------------------------------------------
--
-- The client's `follow` is an upsert, and **which** upsert is load-bearing.
--
-- `ON CONFLICT DO UPDATE` — PostgREST's `resolution=merge-duplicates` — takes
-- the UPDATE path on the second follow, where `follows_update` applies:
-- `using (followee_id = auth.uid())`. The follower is not the followee, so
-- Postgres raises 42501 and the app reported "No such account." for an account
-- plainly on screen. That policy is right and must not be loosened: it is what
-- stops a follower approving their own request (assertion 18).
--
-- So the client uses `ON CONFLICT DO NOTHING` instead, and these two assertions
-- are the contract that makes that safe: the repeat insert succeeds, and it
-- leaves the existing state exactly as it was. The second matters more than it
-- looks — if a repeat insert could reset an *accepted* follow to `pending`,
-- tapping Follow again would silently revoke your own access.

select tests_as_owner();
select tests_login((select id from ids where name = 'alice'));

-- alice → carol already exists and is pending, from assertion 34.
insert into public.follows (follower_id, followee_id)
values ((select id from ids where name = 'alice'),
        (select id from ids where name = 'carol'))
on conflict (follower_id, followee_id) do nothing;

select is(
  (select count(*)::int from public.follows
    where follower_id = (select id from ids where name = 'alice')
      and followee_id = (select id from ids where name = 'carol')),
  1,
  'following twice is not an error and does not duplicate the edge');

-- Now with an *accepted* edge: bob → carol was approved at assertion 20.
select tests_as_owner();
select tests_login((select id from ids where name = 'bob'));

insert into public.follows (follower_id, followee_id)
values ((select id from ids where name = 'bob'),
        (select id from ids where name = 'carol'))
on conflict (follower_id, followee_id) do nothing;

select is(
  (select state::text from public.follows
    where follower_id = (select id from ids where name = 'bob')
      and followee_id = (select id from ids where name = 'carol')),
  'active',
  'a repeat follow never sends an accepted request back to pending');


-- MARK: - 39–42. title_watchers narrows to followees ---------------------------
--
-- The RPC's whole job is to answer "who that I follow has an opinion about this"
-- rather than "who on this service does". The narrowing is a courtesy — nothing
-- it hides is anything RLS would have let through — but the two rules it must
-- NOT weaken are policy, and those are what the negative assertions below pin:
-- an unpublished row stays invisible even to a follower, and a stranger's
-- published row stays invisible for want of a follow edge.
--
-- Edges are (re)established here as the table owner rather than inherited from
-- the assertions above, so this block does not silently change meaning when
-- something earlier is reordered.

select tests_as_owner();

-- Bob follows alice and nobody else relevant; mallory stays a stranger.
delete from public.follows where follower_id = (select id from ids where name = 'bob');

-- Inserted as bob, not as the owner. `rate_limit_follows` records `auth.uid()`
-- into `rate_events`, which is NOT NULL — so an owner-side insert fails on a
-- constraint that has nothing to do with what is being tested here.
select tests_login((select id from ids where name = 'bob'));
insert into public.follows (follower_id, followee_id)
values ((select id from ids where name = 'bob'),
        (select id from ids where name = 'alice'));

-- Forced rather than assumed: whether a fresh edge lands `active` or `pending`
-- is the follow trigger's business and is asserted elsewhere. These four
-- assertions are about what `title_watchers` does with an active edge.
select tests_as_owner();
update public.follows set state = 'active'
 where follower_id = (select id from ids where name = 'bob')
   and followee_id = (select id from ids where name = 'alice');

-- Bob has his own published opinion of the same film, to prove self-exclusion.
insert into public.ranked_items
  (user_id, media_type, external_id, title, year, sentiment, score, rank_in_bucket, bucket_size)
select id, 'movie', 'tmdb:movie:27205', 'Inception', 2010, 'liked', 7.10, 2, 5
  from ids where name = 'bob'
on conflict (user_id, media_type, external_id) do nothing;

-- And alice has one that is deliberately NOT published. Set by UPDATE for the
-- same reason the fixture above does: the BEFORE INSERT trigger overwrites
-- whatever a caller sends, and by now alice's standing answer is "published".
insert into public.ranked_items
  (user_id, media_type, external_id, title, year, sentiment, score, rank_in_bucket, bucket_size)
select id, 'movie', 'tmdb:movie:99999', 'Unreleased', 2026, 'liked', 8.00, 0, 5
  from ids where name = 'alice'
on conflict (user_id, media_type, external_id) do nothing;

update public.ranked_items set is_published = true
 where external_id = 'tmdb:movie:27205';
update public.ranked_items set is_published = false
 where external_id = 'tmdb:movie:99999';

select tests_login((select id from ids where name = 'bob'));

select is(
  (select count(*)::int from public.title_watchers('movie', 'tmdb:movie:27205')
    where handle = 'alice'),
  1,
  'title_watchers returns a followee''s published opinion');

select is(
  (select count(*)::int from public.title_watchers('movie', 'tmdb:movie:27205')
    where handle = 'bob'),
  0,
  'title_watchers never returns the caller to themselves');

select is(
  (select count(*)::int from public.title_watchers('movie', 'tmdb:movie:27205')
    where handle = 'mallory'),
  0,
  'title_watchers does not return a stranger, published or not');

select is(
  (select count(*)::int from public.title_watchers('movie', 'tmdb:movie:99999')),
  0,
  'an unpublished row stays invisible even to an active follower');


-- `finish()` belongs after the last assertion, not in the middle. It used to sit
-- ~200 lines up, which meant its summary counted only the assertions above it
-- and reported every run as "planned N but ran 27" — a permanent, ignorable
-- warning of exactly the kind that hides a real one.
select * from finish();

rollback;
