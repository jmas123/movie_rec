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

select plan(41);

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

-- Nothing here sets a publication flag, because there is no longer one to set
-- (`20260826020000_visibility_follows_account_privacy.sql`). A ranked row is
-- readable by exactly the audience its owner's `is_private` allows, so the
-- fixture only has to decide who is private — carol, above — and insert rows.
insert into public.ranked_items
  (user_id, media_type, external_id, title, year, sentiment, score, rank_in_bucket, bucket_size)
select id, 'movie', 'tmdb:movie:27205', 'Inception', 2010, 'liked', 9.20, 0, 5
  from ids where name in ('alice', 'carol', 'mallory');

-- Alice has a second bucket, in the other media type. It exists so that "the
-- owner reads her whole library" and "a viewer reads her whole library" are
-- assertions about more than one row — the old per-bucket publication flag is
-- exactly the kind of thing a single-row fixture would have missed.
insert into public.ranked_items
  (user_id, media_type, external_id, title, year, sentiment, score, rank_in_bucket, bucket_size)
select id, 'tv_show', 'tmdb:tv:1396', 'Breaking Bad', 2008, 'liked', 9.60, 0, 5
  from ids where name = 'alice';

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
  2,
  'a public account''s library is readable by any signed-in user');

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

-- MARK: - 28–32. Visibility is the account's privacy setting -------------------
--
-- Part IV (`docs/PART-IV-SYNC.md`), as amended by
-- `20260826020000_visibility_follows_account_privacy.sql`. A signed-in user's
-- whole library reaches the server unconditionally, and what anybody else sees
-- is decided by the owner's `is_private` and the follow graph — not by a second
-- per-row opt-in.
--
-- The last three are negative and assert *absence*, which is unusual enough to
-- justify. A dormant `is_published` column would be read again: the trigger that
-- kept it consistent overwrote whatever a client sent on every insert, and the
-- two functions that wrote it were SECURITY DEFINER and reachable by anyone
-- holding the anon key. Removing the gate from the policy without removing the
-- machinery would leave all of that in place, one migration away from mattering
-- again.

select tests_as_owner();
select tests_login((select id from ids where name = 'bob'));

select is(
  (select count(*)::int from public.ranked_items
    where user_id = (select id from ids where name = 'alice')
      and media_type = 'tv_show'),
  1,
  'a public account''s whole library is readable — there is no publish step');

select tests_as_owner();
select tests_login((select id from ids where name = 'alice'));

select is(
  (select count(*)::int from public.ranked_items where user_id = auth.uid()),
  2,
  'the owner reads her whole library');

select hasnt_column(
  'public', 'ranked_items', 'is_published',
  'the per-row publication flag is gone, not merely unused');

select hasnt_function(
  'public', 'set_library_published',
  'and so is the definer function that wrote it past the column revoke');

select hasnt_function(
  'public', 'set_bucket_published',
  'and its per-bucket sibling');


-- MARK: - 33–35. The follow-request inbox -------------------------------------
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


-- MARK: - 36–37. Following twice ----------------------------------------------
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


-- MARK: - 38–41. title_watchers narrows to followees ---------------------------
--
-- The RPC's whole job is to answer "who that I follow has an opinion about this"
-- rather than "who on this service does". The narrowing is a courtesy — nothing
-- it hides is anything RLS would have let through — but the two rules it must
-- NOT weaken are policy, and those are what the negative assertions below pin:
-- a stranger stays invisible for want of a follow edge, and a private account
-- the caller does not follow stays invisible even though the title matches.
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

-- Carol is private and bob does not follow her, and she has an opinion about
-- the same film — the fixture for the last assertion below.

select tests_login((select id from ids where name = 'bob'));

select is(
  (select count(*)::int from public.title_watchers('movie', 'tmdb:movie:27205')
    where handle = 'alice'),
  1,
  'title_watchers returns a followee''s opinion');

select is(
  (select count(*)::int from public.title_watchers('movie', 'tmdb:movie:27205')
    where handle = 'bob'),
  0,
  'title_watchers never returns the caller to themselves');

select is(
  (select count(*)::int from public.title_watchers('movie', 'tmdb:movie:27205')
    where handle = 'mallory'),
  0,
  'title_watchers does not return a stranger');

-- Carol's row survives `ranked_items_select` only for somebody who follows her,
-- and bob does not. Two rules could hide it — the RPC's own `follows_actively`
-- and the policy's — and that redundancy is the point: this is the assertion
-- that fails if a future edit relaxes either one.
select is(
  (select count(*)::int from public.title_watchers('movie', 'tmdb:movie:27205')
    where handle = 'carol'),
  0,
  'a private account the caller does not follow stays invisible');


-- `finish()` belongs after the last assertion, not in the middle. It used to sit
-- ~200 lines up, which meant its summary counted only the assertions above it
-- and reported every run as "planned N but ran 27" — a permanent, ignorable
-- warning of exactly the kind that hides a real one.
select * from finish();

rollback;
