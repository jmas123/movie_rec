-- Content filtering, at the boundary that actually enforces it.
--
-- Its own file, for the reason `comment_editing_test.sql` is its own file: the
-- RLS suite's plan count is load-bearing and a failure there should read as
-- "RLS broke", not "somebody edited a word list".
--
-- **Every assertion below uses synthetic terms** — `zqxbadterm`, `zqx` — which
-- are inserted into `app.banned_terms` inside the test transaction and rolled
-- back with it. Two reasons, and the second is the important one. It keeps the
-- real list out of a file people read over each other's shoulders. And it makes
-- these tests assert the *mechanism* rather than the list's contents, so adding
-- or removing a real term tomorrow cannot turn this suite red.
--
-- The one thing asserted about the real list is that it is not empty: a filter
-- with nothing in it passes every mechanical test ever written.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, pg_temp;

select plan(18);

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

create temporary table ids (name text primary key, id uuid);
insert into ids values
  ('author', '11111111-1111-1111-1111-111111111111'),
  ('poster', '22222222-2222-2222-2222-222222222222');
grant select on ids to authenticated;

insert into auth.users (id, email, raw_user_meta_data)
select id, name || '@example.test', json_build_object('display_name', initcap(name))::jsonb
  from ids;

update public.profiles p set handle = i.name from ids i where p.id = i.id;

insert into public.posts (id, user_id, kind, media_type, external_id, payload)
select 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
       id, 'ranked', 'movie', 'tmdb:movie:27205',
       json_build_object('title', 'Inception')::jsonb
  from ids where name = 'poster';

insert into app.banned_terms (term, category) values
  ('zqxbadterm', 'harassment'),
  ('zqx',        'harassment');

-- MARK: - 1. The shipped list is not empty ------------------------------------
--
-- Asserted as the owner: `banned_terms` has RLS on and no policy, so
-- `authenticated` cannot count it. That is the point of the table, and this
-- assertion would fail from the other side of the boundary.

select ok(
  (select count(*) from app.banned_terms
    where term not like 'zqx%') > 0,
  'the migration seeds real terms, so the filter filters something'
);

-- MARK: - 2–7. Comments, and the ways around a filter -------------------------
--
-- **Logged in for the writes, not merely for RLS.** `comments_rate_limit` writes
-- `rate_events (user_id => auth.uid())`, and that column is NOT NULL — so a
-- comment inserted as the table owner fails on the rate limiter before it ever
-- reaches the filter, with an error that looks nothing like the thing under
-- test.

select tests_login((select id from ids where name = 'author'));

-- Planted *before* `zqxlaterterm` is banned, which is the situation
-- `scan_existing_content` exists for: the triggers guard writes, so a term added
-- on Tuesday has never been applied to Monday's comments.
insert into public.comments (post_id, user_id, body)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        'zqxlaterterm, honestly');

select lives_ok(
  $$insert into public.comments (post_id, user_id, body)
    values ('aaaaaaaa-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'Genuinely one of the best things I have seen all year.')$$,
  'ordinary text is not the filter''s business'
);

select throws_ok(
  $$insert into public.comments (post_id, user_id, body)
    values ('aaaaaaaa-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'you are a zqxbadterm')$$,
  'P0001',
  'That wording is not allowed here. Please edit it and try again.',
  'a banned term is rejected, with a message written for a person'
);

-- Character substitution: 4 -> a, 3 -> e, 0 -> o.
select throws_ok(
  $$insert into public.comments (post_id, user_id, body)
    values ('aaaaaaaa-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'you are a zqxb4dt3rm')$$,
  'P0001', null,
  'leetspeak substitution does not get past it'
);

select throws_ok(
  $$insert into public.comments (post_id, user_id, body)
    values ('aaaaaaaa-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'z q x b a d t e r m')$$,
  'P0001', null,
  'spacing the letters out does not get past it'
);

select throws_ok(
  $$insert into public.comments (post_id, user_id, body)
    values ('aaaaaaaa-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'z.q.x.b-a-d_t.e.r.m')$$,
  'P0001', null,
  'punctuation between the letters does not get past it'
);

select throws_ok(
  $$insert into public.comments (post_id, user_id, body)
    values ('aaaaaaaa-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'zqxbaaaaadterm')$$,
  'P0001', null,
  'padding a letter out does not get past it'
);

-- MARK: - 8. The edit path ----------------------------------------------------
--
-- The one that would have been missed. Comments are editable, so a filter on
-- INSERT alone is a filter you get past by posting "hello" and rewriting it.

select tests_as_owner();

create temporary table clean as
  select id from public.comments where body like 'Genuinely%';
grant select on clean to authenticated;

select tests_login((select id from ids where name = 'author'));

select throws_ok(
  $$update public.comments
       set body = 'actually you are a zqxbadterm', edited_at = now()
     where id = (select id from clean)$$,
  'P0001', null,
  'editing a clean comment into a banned one is rejected too'
);

-- MARK: - 9–10. Word boundaries -----------------------------------------------
--
-- `zqx` squeezes to three characters, below the threshold for the aggressive
-- substring pass, so it matches only as a whole word. This is the Scunthorpe
-- assertion: the cost of the filter's precision is measured here.

select throws_ok(
  $$insert into public.comments (post_id, user_id, body)
    values ('aaaaaaaa-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'what a zqx')$$,
  'P0001', null,
  'a short term is caught as a standalone word'
);

select lives_ok(
  $$insert into public.comments (post_id, user_id, body)
    values ('aaaaaaaa-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111',
            'the zqxylophone sequence is the best scene in it')$$,
  'a short term inside a longer word is left alone'
);

-- MARK: - 11–12. Profiles -----------------------------------------------------

select throws_ok(
  $$update public.profiles set bio = 'zqxbadterm enthusiast'
     where id = '11111111-1111-1111-1111-111111111111'$$,
  'P0001', null,
  'a bio is user-written text and is filtered like one'
);

select lives_ok(
  $$update public.profiles set bio = 'Mostly horror. Occasionally a musical.'
     where id = '11111111-1111-1111-1111-111111111111'$$,
  'an ordinary bio still saves'
);

-- MARK: - 13. Reviews ---------------------------------------------------------

select throws_ok(
  $$insert into public.ranked_items (user_id, media_type, external_id, title, review)
    values ('11111111-1111-1111-1111-111111111111', 'movie', 'tmdb:movie:1',
            'Some Film', 'the director is a zqxbadterm')$$,
  'P0001', null,
  'a synced review is filtered, not just what is typed in the feed'
);

-- MARK: - 14–15. Posts, and the catalogue carve-out ----------------------------

select throws_ok(
  $$insert into public.posts (user_id, kind, media_type, external_id, payload)
    values ('11111111-1111-1111-1111-111111111111', 'ranked', 'movie', 'tmdb:movie:2',
            '{"title":"Some Film","review_excerpt":"what a zqxbadterm"}')$$,
  'P0001', null,
  'the excerpt a post carries is the author''s words and is filtered'
);

-- The title comes from TMDB. A term list may not veto the catalogue: the app
-- does not choose what films are called, and a user who cannot post about a
-- film has no way to find out why.
select lives_ok(
  $$insert into public.posts (user_id, kind, media_type, external_id, payload)
    values ('11111111-1111-1111-1111-111111111111', 'ranked', 'movie', 'tmdb:movie:3',
            '{"title":"Zqxbadterm (1974)","review_excerpt":"A difficult watch."}')$$,
  'a banned term in a film title does not block the post'
);

-- MARK: - 16. Finding what predates the term ----------------------------------

select tests_as_owner();

insert into app.banned_terms (term, category) values ('zqxlaterterm', 'harassment');

select is(
  (select count(*)::int from app.scan_existing_content()
    where source = 'comments' and term = 'zqxlaterterm'),
  1,
  'scan_existing_content finds text that was posted before the term was banned'
);

-- MARK: - 17–18. The policy, asserted against the real list --------------------
--
-- The only two assertions here that read the shipped terms rather than a
-- synthetic one, and they are deliberately about what the filter must *not* do.
-- Both are worded so that the change which would break them is a change of
-- policy, not a change of implementation — if somebody adds general profanity
-- to the list, or a term short enough to swallow a surname, this suite says so
-- before a user discovers it as an unexplained rejection.

select is(
  app.first_banned_term('Dick Van Dyke is the best thing in Mary Poppins, and the '
                        || 'raccoon scene is auspicious'),
  null,
  'names and ordinary words a film app will see are not caught'
);

select is(
  app.first_banned_term('fucking brilliant, one of the best films of the decade'),
  null,
  'profanity is not filtered — the age rating declares it instead'
);

select * from finish();
rollback;
