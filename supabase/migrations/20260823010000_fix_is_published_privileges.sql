-- MARK: - Making the is_published revoke actually bite
--
-- `20260823000000_library_sync.sql` contains:
--
--     revoke update (is_published) on public.ranked_items from authenticated;
--
-- **That statement does nothing.** It succeeds, it reports no warning, and the
-- privilege it means to remove is still held afterwards:
--
--     select grantee, privilege_type, column_name
--       from information_schema.column_privileges
--      where table_name = 'ranked_items' and column_name = 'is_published';
--     -- authenticated | UPDATE | is_published     <-- still there
--
-- The reason is a documented Postgres rule that reads like a footgun: **a
-- column-level REVOKE cannot carve an exception out of a table-level GRANT.**
-- `20260821210000_social.sql` §8 grants table-wide UPDATE to `authenticated`,
-- which is a single privilege entry covering every column the table has now or
-- gains later. The column-level REVOKE looks for a column-level grant, finds
-- none, and removes nothing. Table-wide UPDATE keeps allowing every column.
--
-- Caught by `supabase/tests/rls_test.sql` test 30, which asserted 42501 on a
-- direct `update … set is_published = true` and caught no exception at all.
--
-- **What was actually exposed.** Any authenticated client could publish a
-- single row — `PATCH /ranked_items?id=eq.…` with `{"is_published": true}` —
-- which is precisely the half-visible bucket the column exists to prevent.
-- Every row carries `bucket_size`, so three published rows of a seven-row
-- bucket tell a viewer that four titles exist which they may not see, and show
-- a score computed over a bucket they cannot verify (`PART-IV-SYNC.md` §4).
--
-- **Why a new migration rather than an edit.** `20260823000000` has already been
-- applied to the hosted project. Editing an applied migration leaves the file
-- and the database disagreeing, and `db push` will not re-run it — so the fix
-- has to be a migration of its own, whatever the original said.

-- MARK: - Revoke the table-wide grant, then hand back the columns by name -----
--
-- The order matters and the completeness matters. Revoking table-wide UPDATE
-- removes the privilege that was masking everything; the GRANT then re-issues
-- it column by column, which is the only form a later column-level REVOKE could
-- ever modify.
--
-- **Every column except `is_published` is listed, deliberately including the
-- key columns.** `user_id`, `media_type` and `external_id` are the upsert's
-- conflict target, and PostgREST compiles `resolution=merge-duplicates` into
-- `INSERT … ON CONFLICT DO UPDATE SET` over the columns in the payload — which
-- the client sends, key columns included. Omitting them here would make every
-- publish after a bucket's first one fail 42501: the same shape of bug this
-- migration is fixing, introduced from the other side. Narrowing that set is a
-- separate change that needs its own test, not a free tightening to fold in
-- here.

revoke update on public.ranked_items from authenticated;

grant update (
    user_id,
    media_type,
    external_id,
    title,
    year,
    poster_path,
    sentiment,
    score,
    rank_in_bucket,
    bucket_size,
    review,
    date_watched,
    updated_at
  ) on public.ranked_items to authenticated;

-- `anon` holds nothing on this table and must keep holding nothing. Stated
-- rather than assumed: the revoke above names only `authenticated`, and a
-- reader should not have to go back two migrations to learn who else can write.
revoke update on public.ranked_items from anon;

comment on column public.ranked_items.is_published is
  'Whether anybody but the owner can read this row. Set uniformly across a '
  '(user_id, media_type, sentiment) bucket. NOT writable by `authenticated`: '
  'the table-wide UPDATE grant is revoked and re-issued per column in '
  '20260823010000, so this column is the one omission. Change it through '
  'public.set_library_published() or public.set_bucket_published().';
