-- Comment editing, at the boundary that actually enforces it.
--
-- Separate from `rls_test.sql` deliberately: that file is the standing RLS
-- suite and its plan count is load-bearing, so bolting eight assertions onto it
-- would make every future failure read as "the RLS suite broke".
--
-- What is worth asserting here is not that an author can edit — it is the three
-- ways the rule can be got wrong:
--
--   * a post's owner rewriting somebody else's words under their name,
--   * a post's owner stamping "edited" on a comment nobody edited,
--   * `add_comment` letting a caller name somebody else as the author.
--
-- Each of those is invisible to the Swift suite, which runs against
-- `MockFeedService` and therefore cannot disagree with a column name, a policy
-- or a trigger. That blindness is what let `addComment` ship writing to a
-- column that does not exist — see `GAP-AUDIT.md` §2, the 2026-08-25 finding.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, pg_temp;

select plan(10);

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

-- `poster` owns the post; `author` writes the comment on it. That split is what
-- makes the owner-vs-author assertions meaningful.
insert into public.posts (id, user_id, kind, media_type, external_id, payload)
select 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
       id, 'ranked', 'movie', 'tmdb:movie:27205',
       json_build_object('title', 'Inception')::jsonb
  from ids where name = 'poster';

-- MARK: - 1–3. add_comment ----------------------------------------------------

select tests_login((select id from ids where name = 'author'));

-- The whole reason this is an RPC: an insert into `comments` can only return
-- the bare row, and a `PostComment` needs the author's profile joined onto it.
select is(
  (select author_handle from public.add_comment(
     'aaaaaaaa-0000-0000-0000-000000000001'::uuid, 'First')),
  'author',
  'add_comment returns the author handle joined on'
);

select is(
  (select author_id from public.add_comment(
     'aaaaaaaa-0000-0000-0000-000000000001'::uuid, 'Second')),
  (select id from ids where name = 'author'),
  'add_comment attributes the comment to auth.uid()'
);

-- A fresh comment is not an edited one. If `edited_at` defaulted to now(), the
-- marker would be on every comment ever written and would mean nothing.
select is(
  (select edited_at from public.add_comment(
     'aaaaaaaa-0000-0000-0000-000000000001'::uuid, 'Third')),
  null,
  'a new comment is not marked edited'
);

-- MARK: - 4–6. The author may edit --------------------------------------------

select tests_as_owner();

-- Two comments, because the owner assertions need one live row to attempt a
-- rewrite on and a separate one to soft-delete. Doing both to the same row made
-- the last assertion meaningless: `post_comments` deliberately returns deleted
-- rows (blanked, so the thread keeps its shape), so a row that was edited and
-- then deleted still comes back and proves nothing about the edit.
create temporary table target as select id from public.comments where body = 'First';
create temporary table doomed as select id from public.comments where body = 'Second';
grant select on target, doomed to authenticated;

select tests_login((select id from ids where name = 'author'));

select lives_ok(
  $$update public.comments set body = 'First, revised', edited_at = now()
     where id = (select id from target)$$,
  'the author may rewrite their own comment'
);

select is(
  (select body from public.comments where id = (select id from target)),
  'First, revised',
  'the rewrite landed'
);

select isnt(
  (select edited_at from public.comments where id = (select id from target)),
  null,
  'the author may mark it edited'
);

-- MARK: - 7–9. The post owner may hide but not rewrite -------------------------
--
-- `comments_update` admits the post's owner, because they must be able to
-- soft-delete a comment on their own post. The column-level half of the rule
-- lives in `app.guard_comment_update`, since RLS cannot express it. These three
-- are the reason that trigger exists.

select tests_login((select id from ids where name = 'poster'));

select lives_ok(
  $$update public.comments set deleted_at = now()
     where id = (select id from doomed)$$,
  'the post owner may soft-delete a comment on their post'
);

select throws_ok(
  $$update public.comments set body = 'Words I did not write'
     where id = (select id from target)$$,
  'only the author may edit a comment body',
  'the post owner may not rewrite somebody else''s comment'
);

-- Otherwise an owner could make an untouched comment look rewritten, which is
-- the same disclosure attacked from the other side.
--
-- `clock_timestamp()`, not `now()`: `now()` is the *transaction* start time and
-- is therefore identical to the value the author's edit above wrote, so the
-- guard's `is distinct from` correctly sees no change and does not fire. The
-- first version of this assertion used `now()` and failed with "caught: no
-- exception" — testing nothing, and looking for a moment like a hole in the
-- trigger.
select throws_ok(
  $$update public.comments set edited_at = clock_timestamp()
     where id = (select id from target)$$,
  'only the author may mark a comment edited',
  'the post owner may not stamp somebody else''s comment as edited'
);

-- MARK: - 10. post_comments carries the column through -------------------------

select tests_login((select id from ids where name = 'author'));

select isnt(
  (select edited_at from public.post_comments(
     'aaaaaaaa-0000-0000-0000-000000000001'::uuid)
    where id = (select id from target)),
  null,
  'post_comments carries edited_at through to the client'
);

select finish();
rollback;
