-- =============================================================================
-- Content filtering for user-generated text.
--
-- App Store guideline 1.2 asks an app with UGC for four things. Three have been
-- here since Phase 28: a report mechanism (`reports`), a way to block an abusive
-- user (`blocks`), and an agreed EULA (the sign-up toggle). The fourth —
-- **"a method for filtering objectionable material from being posted"** — had no
-- implementation at all. The only word lists in this schema reserved *handles*,
-- which is an impersonation control, not a moderation one.
--
-- `docs/APP-STORE-CONNECT-RECORD.md` §4 is where that gap was written down; this
-- file is it closed.
--
-- -----------------------------------------------------------------------------
-- What this deliberately does NOT do
-- -----------------------------------------------------------------------------
-- It does not filter profanity. "Fuck" is in the title of real films, in the
-- dialogue of more of them, and in an honest one-line review of most of what is
-- on Netflix. An app for arguing about films that rejects the word is an app
-- that trains its users to work around it, and the age rating already declares
-- Infrequent/Mild profanity on exactly that basis.
--
-- What it blocks is the narrow set with no plausible use in a comment about a
-- film: slurs and direct harassment. That narrowness is the design, not a first
-- draft — a filter with false positives is worse than none, because the false
-- positive is silent and the user cannot tell a moderation rule from a bug.
-- `dyke` is the example that settled the shape: it is a slur, and it is also
-- Dick Van *Dyke*, whose name a film app will see. It is not on the list.
--
-- The rest is `reports` and `blocks` doing the job they exist for. A term list
-- cannot read context and nothing here pretends otherwise.
-- =============================================================================

-- MARK: - The list -------------------------------------------------------------

-- In schema `app`, which PostgREST does not expose, so this is unreachable over
-- the API no matter what the anon key is pointed at. The revoke below is the
-- second lock rather than the only one.
--
-- **Terms are stored in normalised form** — lowercase letters and single spaces,
-- enforced by a check. Two things follow. Matching needs no regex escaping,
-- because there is nothing in a term that regex reads as punctuation. And the
-- list can be extended with an INSERT rather than a migration, which matters
-- the first time somebody is being harassed with a word nobody anticipated.
create table if not exists app.banned_terms (
  term     text primary key,
  category text not null,
  added_at timestamptz not null default now(),

  constraint banned_terms_normalised check (term ~ '^[a-z]([a-z ]{1,38}[a-z])?$'),
  constraint banned_terms_category   check (
    category in ('racial', 'homophobic', 'transphobic', 'ableist',
                 'harassment', 'sexual_exploitation')
  )
);

comment on table app.banned_terms is
  'Terms rejected in user-written text. Slurs and direct harassment only — '
  'general profanity is deliberately absent (see the header of '
  '20260826010000_content_filter.sql). Extend with INSERT; no migration needed.';

alter table app.banned_terms enable row level security;

-- No policy and no grant. The trigger functions below are SECURITY DEFINER and
-- read it as the owner; nothing else has any business seeing this table.
-- Keeping the list unreadable is not tidiness — a client that could read it
-- could work around it, and a client that could *query* the matcher would have
-- an oracle for testing evasions one request at a time.
revoke all on app.banned_terms from anon, authenticated;

insert into app.banned_terms (term, category) values
  ('nigger',        'racial'),
  ('nigga',         'racial'),
  ('chink',         'racial'),
  ('gook',          'racial'),
  ('spic',          'racial'),
  ('wetback',       'racial'),
  ('beaner',        'racial'),
  ('kike',          'racial'),
  ('jigaboo',       'racial'),
  ('towelhead',     'racial'),
  ('raghead',       'racial'),
  ('paki',          'racial'),
  ('faggot',        'homophobic'),
  ('tranny',        'transphobic'),
  ('shemale',       'transphobic'),
  ('retard',        'ableist'),
  ('retarded',      'ableist'),
  ('kill yourself', 'harassment'),
  ('kys',           'harassment'),
  ('child porn',    'sexual_exploitation')
on conflict (term) do nothing;

-- MARK: - Normalisation --------------------------------------------------------

-- Two views of the same text, because the two evasions are different problems.
--
-- `moderate_normalize` folds case, maps the common character substitutions
-- (`n1gg3r`, `f@ggot`) back to letters, and reduces everything else to single
-- spaces. Word boundaries survive, so matching against it is precise: `\mspic\M`
-- does not fire on "auspicious".
--
-- Mapping digits to letters costs nothing here and would be wrong anywhere else:
-- `1917` normalises to `igit`. That is fine because this output is *only* ever
-- compared against the term list — it is never stored, shown, or written back.
create or replace function app.moderate_normalize(input text)
returns text
language sql
immutable
as $$
  select btrim(regexp_replace(
           regexp_replace(
             translate(lower(coalesce(input, '')),
                       '01345789@$!|', 'oieastbgasii'),
             '[^a-z]+', ' ', 'g'),
           ' +', ' ', 'g'));
$$;

-- `moderate_squeeze` throws the boundaries away: every non-letter removed, and
-- runs of a repeated letter collapsed to one. `n i g g e r`, `n-i-g-g-e-r` and
-- `niiiigger` all land on the same string, and so does the term it is compared
-- against (`nigger` -> `niger`), which is why both sides are squeezed.
--
-- This is the aggressive pass, so it is used only for terms whose squeezed form
-- is 5 characters or longer — see `app.first_banned_term`. Short terms squeezed
-- into a boundary-free haystack are how a filter starts rejecting innocent
-- words, and the false positive would be invisible to everybody but the user.
--
-- **The cost of that threshold, stated rather than discovered:** `k y s` gets
-- through, because `kys` is three characters and only the boundary pass applies
-- to it. Accepted knowingly. The alternative is a three-letter string matched
-- inside every word in the table, which is how you end up rejecting a review of
-- *Skyscraper*.
create or replace function app.moderate_squeeze(input text)
returns text
language sql
immutable
as $$
  select regexp_replace(
           regexp_replace(app.moderate_normalize(input), ' ', '', 'g'),
           '(.)\1+', '\1', 'g');
$$;

-- MARK: - The matcher ----------------------------------------------------------

-- Returns the term that matched, or NULL. The term is for the server log, never
-- for the client: telling somebody which word tripped the filter is telling them
-- what to try next.
--
-- Trailing `s?` on the boundary match covers plurals without the fuzzier
-- suffix-matching that would put `Fagin` (Oliver Twist) on the wrong side of a
-- three-letter term.
--
-- Cost is one regex per term per write against a list of tens, on text capped at
-- 2000 characters. That is nothing at this size and would need rethinking as a
-- trigram index the day the list runs to thousands.
create or replace function app.first_banned_term(input text)
returns text
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  with subject as (
    select app.moderate_normalize(input) as plain,
           app.moderate_squeeze(input)   as squeezed
  )
  select t.term
    from app.banned_terms t, subject s
   where s.plain ~ ('\m' || t.term || 's?\M')
      or (length(app.moderate_squeeze(t.term)) >= 5
          and position(app.moderate_squeeze(t.term) in s.squeezed) > 0)
   order by length(t.term) desc
   limit 1;
$$;

revoke all on function app.first_banned_term(text) from anon, authenticated, public;

-- MARK: - The trigger ----------------------------------------------------------

-- One function for every guarded table; the columns to read come from the
-- trigger's arguments. A dotted argument walks into `jsonb`, which is how
-- `posts` gets checked on the author's words (`payload.review_excerpt`) without
-- checking the title beside them — titles come from TMDB, and a catalogue whose
-- contents this app does not choose is not something a term list may veto.
--
-- Fires on UPDATE as well as INSERT, which is not optional: comments have been
-- editable since 20260825000000, so a filter that only ran on insert would be a
-- filter you get past by posting "hello" and then editing it.
create or replace function app.reject_banned_terms()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare
  subject text := '';
  col     text;
  hit     text;
begin
  foreach col in array tg_argv loop
    subject := subject || ' ' ||
               coalesce(to_jsonb(new) #>> string_to_array(col, '.'), '');
  end loop;

  hit := app.first_banned_term(subject);

  if hit is not null then
    -- The matched term goes to the log, where a moderator can see it, and
    -- nowhere the client can read.
    raise log 'content filter: % rejected on %.% (%)',
      hit, tg_table_schema, tg_table_name, tg_op;

    -- This message is shown to the user verbatim: PostgREST puts it in the
    -- error body's `message`, `SupabaseError.http` returns it unchanged, and
    -- `SocialError.underlying` hands it to the view. So it is written as a
    -- sentence to a person, not as an error string to a developer.
    raise exception 'That wording is not allowed here. Please edit it and try again.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

-- **The trigger name matters, and not for the reason it looks like.** Triggers
-- fire in name order, so `comments_word_filter` runs after `comments_rate_limit`
-- — but a rejected write rolls the whole statement back, the rate event
-- included, so ordering cannot make a rejected attempt cost quota either way.
-- Worth stating because the opposite is easy to assume: **the filter is not
-- rate-limited by anything**, and somebody probing it for holes pays nothing per
-- attempt. Report and block remain the backstop; this is a floor, not a wall.
drop trigger if exists comments_word_filter on public.comments;
create trigger comments_word_filter
  before insert or update on public.comments
  for each row execute function app.reject_banned_terms('body');

drop trigger if exists profiles_word_filter on public.profiles;
create trigger profiles_word_filter
  before insert or update on public.profiles
  for each row execute function app.reject_banned_terms('display_name', 'bio', 'handle');

drop trigger if exists ranked_items_word_filter on public.ranked_items;
create trigger ranked_items_word_filter
  before insert or update on public.ranked_items
  for each row execute function app.reject_banned_terms('review');

drop trigger if exists posts_word_filter on public.posts;
create trigger posts_word_filter
  before insert or update on public.posts
  for each row execute function app.reject_banned_terms('payload.review_excerpt');

-- MARK: - Scanning what is already there ---------------------------------------

-- The triggers guard writes, so adding a term tomorrow does not reach the text
-- posted yesterday. This is how you find it: run after every edit to the list,
-- from the SQL editor as the service role.
--
-- It returns rows, not judgements. Deleting somebody's comment is a decision a
-- person makes.
create or replace function app.scan_existing_content()
returns table (source text, row_id text, term text)
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select 'comments', c.id::text, app.first_banned_term(c.body)
    from public.comments c
   where c.deleted_at is null and app.first_banned_term(c.body) is not null
  union all
  select 'profiles', p.id::text,
         app.first_banned_term(concat_ws(' ', p.display_name, p.bio, p.handle))
    from public.profiles p
   where app.first_banned_term(concat_ws(' ', p.display_name, p.bio, p.handle)) is not null
  union all
  select 'ranked_items', r.user_id::text || ':' || r.external_id,
         app.first_banned_term(r.review)
    from public.ranked_items r
   where r.review is not null and app.first_banned_term(r.review) is not null
  union all
  select 'posts', o.id::text,
         app.first_banned_term(o.payload ->> 'review_excerpt')
    from public.posts o
   where app.first_banned_term(o.payload ->> 'review_excerpt') is not null;
$$;

revoke all on function app.scan_existing_content() from anon, authenticated, public;
