-- =============================================================================
-- Visibility is the account's privacy setting. There is no second opt-in.
--
-- `20260823000000_library_sync.sql` split "stored for you" from "visible to
-- them" and gave the second half its own switch, `is_published`, defaulted to
-- false and answered through a consent sheet. That was one more question than
-- the app needs, and it read as a bug from the inside: two accounts that follow
-- each other saw empty profiles of one another, because each had been asked the
-- sharing question at a moment when it could not be asked (a fresh account has
-- an empty library, and `SyncEngine.needsConsentDecision` skipped the prompt),
-- and neither ever found the switch in Settings.
--
-- The model this replaces it with is the one every social app already teaches:
--
--   public account   → any signed-in user can read the ranking.
--   private account  → only accounts whose follow request has been ACCEPTED.
--
-- Both halves already existed. `app.can_view_library` has implemented exactly
-- this since `20260821210000_social.sql`, and `app.follows_actively` already
-- means an accepted follow (`state = 'active'`) rather than a pending request.
-- `is_published` was AND-ed on top of a predicate that was already correct.
--
-- MARK: - What this changes for existing rows ---------------------------------
--
-- Every ranked row in the database becomes visible according to its owner's
-- `profiles.is_private`, which defaults to false. So libraries that were
-- unpublished — including every library belonging to somebody who answered "no"
-- to the old sharing question, and every library belonging to somebody who was
-- never asked — become readable by any signed-in user unless that account turns
-- Private on.
--
-- That is the intended product change and not a side effect, but it is a
-- one-way door for the accounts that had answered "no", so it is written down
-- here rather than left for someone to infer from a policy diff. The client
-- change that lands with this migration removes the consent sheet and states
-- the rule at account creation and in Settings instead; the control a user has
-- is now the Private account toggle in Edit Profile, and it is the only one.
--
-- MARK: - Order of operations -------------------------------------------------
--
-- The policy goes first. `ranked_items_select` reads `is_published`, and
-- `ALTER TABLE … DROP COLUMN` refuses while a policy depends on it — the CASCADE
-- that would force it through drops the policy too, which would leave the table
-- with no SELECT policy at all and every read returning nothing. Replacing the
-- policy first makes the column drop an ordinary drop.
-- =============================================================================

-- MARK: - The policy ----------------------------------------------------------

drop policy ranked_items_select on public.ranked_items;

create policy ranked_items_select on public.ranked_items for select to authenticated
  using (
    user_id = auth.uid()
    or app.can_view_library(user_id)
  );

comment on policy ranked_items_select on public.ranked_items is
  'The owner always reads their own library; everybody else reads it only '
  'through app.can_view_library — public account, or an accepted follow of a '
  'private one. There is no per-row publication flag.';

-- MARK: - The machinery that existed only to serve the flag -------------------
--
-- All of it goes. A dormant column with a BEFORE INSERT trigger keeping it
-- consistent and two SECURITY DEFINER functions writing past a column-level
-- revoke is not a cheap thing to leave lying around: it is three moving parts
-- that no longer mean anything, one of which (`inherit_bucket_publication`)
-- silently overwrites what a caller sends on every single insert.

drop trigger if exists ranked_items_inherit_publication on public.ranked_items;
drop function if exists app.inherit_bucket_publication();

-- SECURITY DEFINER, so these are reachable by anyone holding the anon key and
-- a session. Leaving them behind would leave two write endpoints for a concept
-- the database no longer has.
drop function if exists public.set_library_published(boolean);
drop function if exists public.set_bucket_published(
  public.media_type, public.sentiment, boolean
);

alter table public.ranked_items drop column is_published;
alter table public.profiles     drop column publishes_library;

-- MARK: - Privileges ----------------------------------------------------------
--
-- Nothing to re-grant, and the reason is worth stating so the next person does
-- not go looking. `20260823010000_fix_is_published_privileges.sql` replaced the
-- table-wide UPDATE grant with a column-by-column one that named every column
-- EXCEPT `is_published`. Dropping the column therefore leaves a grant list that
-- covers the table exactly, with nothing missing and nothing dangling.
--
-- **The consequence outlives this migration:** UPDATE on `ranked_items` is
-- granted per column, so a column added later is NOT writable by `authenticated`
-- until it is granted by name. A future migration that adds a column the client
-- upserts must grant it, or every publish after a bucket's first row fails
-- 42501. That was the original bug in this area and the trap is still armed.
