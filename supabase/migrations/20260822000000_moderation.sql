-- Moderation, reports, rate limits, and account deletion.
--
-- Phase 28. Everything here exists because an app with accounts and
-- user-generated content cannot ship without it, not because it polishes
-- anything.

-- ---------------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------------
-- A closed reason list rather than free text: free-text-only reports are
-- unactionable at any volume, and the whole point is that these get reviewed.
--
-- This table is defined here and nowhere else. Phase 20 shipped a `reports`
-- draft keyed on (subject_kind, subject_id); it was removed from
-- 20260821210000_social.sql rather than left to collide, because the client
-- posts the shape below (SupabaseFeedService.report) and `create table if not
-- exists` would have silently kept the wrong one.

create type report_reason as enum (
  'spam', 'harassment', 'hate_speech', 'sexual_content', 'violence', 'other'
);

create table if not exists reports (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid not null references profiles(id) on delete cascade,
  post_id      uuid references posts(id) on delete cascade,
  comment_id   uuid references comments(id) on delete cascade,
  profile_id   uuid references profiles(id) on delete cascade,
  reason       report_reason not null,
  note         text check (note is null or char_length(note) <= 1000),
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz,

  -- Exactly one target. A report pointing at nothing, or at three things, is a
  -- row nobody can action.
  constraint one_target check (
    (post_id is not null)::int + (comment_id is not null)::int
      + (profile_id is not null)::int = 1
  )
);

create index if not exists reports_unresolved_idx
  on reports (created_at) where resolved_at is null;

alter table reports enable row level security;

-- Anyone signed in may report. Nobody may read reports back: a reporter who
-- could see the queue could tell whether the person they reported has been
-- actioned, which is not theirs to know.
create policy reports_insert on reports
  for insert to authenticated
  with check (reporter_id = auth.uid());

-- Grants mirror the policy, as everywhere else in this schema: RLS decides who
-- may act on a row, and the grant decides which verbs exist at all. Supabase's
-- default privileges hand `authenticated` everything on a new public table, so
-- the revoke is not optional.
revoke all on reports from anon, authenticated;
grant insert on reports to authenticated;

-- ---------------------------------------------------------------------------
-- Rate limits
-- ---------------------------------------------------------------------------
-- RLS authorises; it does not throttle. Without this, one account can write as
-- fast as the network allows.

create table if not exists rate_events (
  user_id    uuid not null references profiles(id) on delete cascade,
  action     text not null,
  created_at timestamptz not null default now()
);

create index if not exists rate_events_window_idx
  on rate_events (user_id, action, created_at desc);

alter table rate_events enable row level security;

-- No policy and no grant: nothing outside this file touches this table. The
-- trigger functions below are SECURITY DEFINER, so they write it as the owner.
revoke all on rate_events from anon, authenticated;

create or replace function enforce_rate_limit(
  p_action text, p_limit int, p_window interval
) returns void
language plpgsql security definer set search_path = public as $$
declare
  recent int;
begin
  select count(*) into recent
    from rate_events
   where user_id = auth.uid()
     and action = p_action
     and created_at > now() - p_window;

  if recent >= p_limit then
    -- A named error, so the client can say what happened rather than showing a
    -- generic failure or, worse, silently doing nothing.
    raise exception 'rate_limited: % (% per %)', p_action, p_limit, p_window
      using errcode = 'P0001';
  end if;

  insert into rate_events (user_id, action) values (auth.uid(), p_action);
end;
$$;

create or replace function rate_limit_comments() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform enforce_rate_limit('comment', 30, interval '1 hour');
  return new;
end;
$$;

create or replace function rate_limit_follows() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform enforce_rate_limit('follow', 100, interval '1 hour');
  return new;
end;
$$;

drop trigger if exists comments_rate_limit on comments;
create trigger comments_rate_limit before insert on comments
  for each row execute function rate_limit_comments();

drop trigger if exists follows_rate_limit on follows;
create trigger follows_rate_limit before insert on follows
  for each row execute function rate_limit_follows();

-- Old events are not evidence of anything once the window has passed.
create or replace function prune_rate_events() returns void
language sql security definer set search_path = public as $$
  delete from rate_events where created_at < now() - interval '7 days';
$$;

-- ---------------------------------------------------------------------------
-- Account deletion
-- ---------------------------------------------------------------------------
-- App Store guideline 5.1.1(v): a button, not an email address.
--
-- One statement, because `on delete cascade` runs the whole way down from
-- auth.users. A client deleting its own rows table by table would leave
-- orphans the first time someone added a table and forgot.

create or replace function delete_account() returns void
language plpgsql security definer set search_path = public, auth as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  delete from auth.users where id = uid;
end;
$$;

revoke all on function delete_account() from public;
grant execute on function delete_account() to authenticated;
