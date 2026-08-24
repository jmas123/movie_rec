# Part III — Social (v2.0)

> **This document lifts the project's founding constraint.** Every other doc in
> this repo asserts "local-only, no backend, no auth, no social features."
> That was true through v1.1 and is no longer the direction. User data now
> leaves the device — deliberately, with an explicit boundary around *what*
> leaves and *who* can read it. Sections 4, 8 and 13 are that boundary.
>
> **Sequencing:** Part III starts after Phase 19. Part II (recommendations)
> finishes first; Phases 14–19 are unaffected by anything here.

- **Roadmap entries:** [`ROADMAP.md`](./ROADMAP.md) Phases 20–28 — steps,
  acceptance criteria, and files per phase.
- **This document:** the decisions those phases inherit — backend choice, trust
  model, schema, sync semantics, feed design. Phases implement; this explains.

---

## 1. The product in one paragraph

Binged becomes a place where your ranking is *seen*. You keep a private,
derived, pairwise-built ranking exactly as before, and you choose to publish it
under a handle. You follow people, their ranking activity arrives in a feed —
"Alex ranked *Dune* #1 in Liked it", "Sam wants to watch *Sinners*" — and you
comment and react on it. The ranking mechanic is unchanged and remains the
reason the social layer is worth reading: a feed of numbers people typed would
be worthless, and a feed of numbers people *earned through comparisons* is not.

## 2. What does not change

These are invariants, not preferences. A social phase that violates one is
wrong even if it ships.

1. **The ranking engine stays pure and local.** `RankingEngine` takes no
   network, no auth, no async. Scores are derived from bucket position on
   device. The server stores results; it never computes them.
2. **The comparison flow never waits on a network.** "Which did you prefer?"
   resolves at local latency, always, including in airplane mode. Publishing
   happens after, in the background, and can fail without the user losing a
   ranking.
3. **The app is fully usable signed out.** Account creation gates the *social*
   features, not the app. Search, mark watched, compare, rank, Profile, and
   Discover all work with no account — which is also what keeps the existing
   219 tests meaningful, since none of them get a session.
4. **Buckets stay `(media type, sentiment)` and scores stay derived.** Nothing
   in Part III introduces a server-computed score, a global leaderboard score,
   or a cross-user normalisation. Two users' 9.4s are not comparable and the UI
   must never imply they are.
5. **Rule 6 still holds, and now holds twice.** A score is hidden below 5 items
   in its bucket. That threshold applies to *other people's* profiles too — if
   anything, more strictly: showing a stranger's "8.4" from a bucket of one is
   the same unearned precision, published.

## 3. Why Supabase over URLSession

The requirement is a relational social graph (follows, posts, comments,
reactions) with per-row authorisation, reachable from an iOS client that must
not gain a package dependency.

- **Chosen: Supabase, hand-rolled `URLSession` client.** PostgREST is a plain
  REST surface over Postgres; GoTrue is a plain REST surface over auth. Both
  are JSON over HTTPS with a bearer token — precisely what `TMDBMediaService`
  already does. Row-level security gives per-row authorisation *in the
  database*, which is the only place it can be enforced when the client is
  untrusted (section 4). Zero SPM dependencies, so the project's rule survives.
- **Rejected: Firebase.** The iOS SDK is a Swift Package, which breaks the
  zero-dependency rule outright. Its document model also fits a social graph
  worse than Postgres: "posts by everyone I follow, newest first, paginated"
  is one SQL statement and several Firestore round trips.
- **Rejected: CloudKit.** Tempting — no third-party service at all, and auth is
  the Apple ID with no signup screen to build. But user discovery by handle is
  something you end up building by hand in the public database anyway, the
  friend-feed query is a fan-out the API does not want to express, there is no
  server-side authorisation logic beyond record ACLs, and it requires a paid
  developer account before the first line works.
- **Rejected: custom backend.** A second codebase to write, host, patch and
  secure before a single social feature is visible on screen.

**The client mirrors the existing service pattern.** `MediaService` /
`MockMediaService` / `TMDBMediaService` is the template: a protocol in
`Services/`, a fake for tests and offline, a live implementation nothing
outside `Services/` knows about. Part III adds `AuthService` and
`SocialService` with the same shape. No view or view model ever sees a URL.

## 4. Trust model: the anon key is public

The Supabase anon key ships in the app bundle and is extractable by anyone with
the `.app`. **This is not a leak — it is the design.** The anon key identifies
the project, not the user; it carries no privilege of its own. Every request
also carries the user's JWT, and *authorisation lives entirely in row-level
security policies in Postgres*.

The consequences are load-bearing and every phase must respect them:

- **RLS is enabled on every table, with deny-by-default.** A table without a
  policy is a table anyone can read with `curl`. There is no such thing as a
  "the client would never ask for that" protection.
- **The client is untrusted input.** Any check the app performs — you can only
  comment on posts from people you follow, you can only edit your own profile —
  must exist as a policy, or it does not exist. The client-side version is a
  UX affordance, not a control.
- **Derived counts and privileged transitions go in SQL**, as triggers or
  `security definer` RPCs, not in the app. A comment count the client
  increments is a comment count the client can set to anything.
- **Revoke before you grant, and never assume a fresh table is empty of
  privileges.** Supabase's base setup carries
  `alter default privileges … grant all on tables to anon, authenticated,
  service_role`, so a table arrives fully granted to both API roles the moment
  it is created. A per-table `grant` list written on top of that is decoration:
  it describes an intent the database does not implement. Phase 20 shipped
  exactly that bug and the RLS suite caught it.
- **TRUNCATE is the privilege RLS cannot save you from.** Policies are not
  consulted for it. `select`, `update` and `delete` degrade to "zero rows" when
  a policy denies them; `truncate` simply runs. The default grant above includes
  it, so before the revoke any authenticated user could have erased every row of
  `posts` — with every policy in §6 intact and none of them evaluated.

This also resolves **roadmap open question 11** ("does the TMDB key ship in the
binary?"). Once a backend exists, TMDB reads can move behind an edge function
and the TMDB token can leave the bundle. That is a distribution concern, not a
v2.0 blocker — but it stops being impossible here, and Phase 28 records it.

## 5. Schema

Postgres, all under RLS. Sketch, not final DDL — Phase 20 writes the migration.

```sql
-- Identity ---------------------------------------------------------------
profiles (
  id            uuid primary key references auth.users on delete cascade,
  handle        citext unique not null,          -- 3–20 chars, [a-z0-9_]
  display_name  text not null,
  avatar_url    text,
  bio           text,
  is_private    boolean not null default false,
  created_at    timestamptz not null default now()
)

-- Social graph -----------------------------------------------------------
follows (
  follower_id   uuid references profiles on delete cascade,
  followee_id   uuid references profiles on delete cascade,
  state         follow_state not null,           -- 'active' | 'pending'
  created_at    timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
)

-- The published projection of a local library ----------------------------
ranked_items (
  user_id       uuid references profiles on delete cascade,
  external_id   text not null,                   -- 'tmdb:movie:27205'
  media_type    media_type not null,
  title         text not null,
  year          int,
  poster_path   text,
  sentiment     sentiment,                       -- null for want-to-watch
  score         numeric(4,2),
  rank_in_bucket int,
  bucket_size   int not null,                    -- so rule 6 is enforceable
  review        text,
  date_watched  timestamptz,
  updated_at    timestamptz not null default now(),
  primary key (user_id, media_type, external_id)
)

-- Feed -------------------------------------------------------------------
posts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references profiles on delete cascade,
  kind          post_kind not null,   -- 'ranked' | 'want_to_watch' | 'reviewed'
  media_type    media_type not null,
  external_id   text not null,
  payload       jsonb not null,       -- denormalised title/poster/rank/sentiment
  comment_count int not null default 0,   -- trigger-maintained
  reaction_count int not null default 0,  -- trigger-maintained
  created_at    timestamptz not null default now()
)

comments (
  id            uuid primary key default gen_random_uuid(),
  post_id       uuid references posts on delete cascade,
  user_id       uuid references profiles on delete cascade,
  body          text not null check (length(body) between 1 and 1000),
  created_at    timestamptz not null default now(),
  deleted_at    timestamptz
)

reactions (
  post_id       uuid references posts on delete cascade,
  user_id       uuid references profiles on delete cascade,
  primary key (post_id, user_id)     -- the PK is the dedupe; no "like twice"
)

-- Safety -----------------------------------------------------------------
blocks  (blocker_id uuid, blocked_id uuid, created_at, primary key (blocker_id, blocked_id))
reports (id uuid pk, reporter_id uuid, subject_kind text, subject_id uuid, reason text, created_at)
```

**Why `payload jsonb` on `posts` is denormalised on purpose.** A feed row must
render without joining `ranked_items`, because by the time you read the post
the underlying row may have moved — every insertion into a bucket recomputes
every score in it. "Alex ranked *Dune* #1" is a statement about a moment. If
the feed joined live data it would silently rewrite history every time Alex
ranked something else, and a comment saying "no way it's your #1" would end up
attached to a post that no longer says that.

**`bucket_size` is stored so rule 6 can be enforced server-side.** Without it
the client cannot know whether a foreign item's score is displayable, and
"hide the number" would depend on data the viewer does not have.

**`external_id` is the join key across users, which only works because of Phase
12a.** Items whose `externalId` is nil — mock-catalog entries, anything the
`ExternalIDMigration` could not resolve — **cannot be published**. They stay
local. This is a real and visible limitation: a user's published list may be
smaller than their local one, and the UI has to say so rather than silently
dropping titles.

## 6. Policy sketch

| Table | select | insert | update | delete |
|---|---|---|---|---|
| `profiles` | public if `not is_private`, else self + active followers | self only, at signup | self only | via account deletion |
| `follows` | rows where you are either side | self as `follower_id` | followee may accept `pending` | self as follower (unfollow), or followee (remove) |
| `ranked_items` | self, or viewer follows owner and is not blocked | self | self | self |
| `posts` | same visibility rule as `ranked_items` | self, `user_id = auth.uid()` | none — posts are immutable | self |
| `comments` | whoever can read the post | self, if you can read the post | self, body only | self, or the post's owner |
| `reactions` | whoever can read the post | self | — | self |
| `blocks` | self | self | — | self |

Every "self" is `auth.uid() = user_id`. Every visibility rule composes with
`blocks` — a block is mutual invisibility, not just a mute, and it must be
enforced in the policy rather than filtered in the app.

## 7. Auth and sessions

- **Email + password via GoTrue** (`/auth/v1/signup`, `/auth/v1/token`).
  **Sign in with Apple** is a strong second (`AuthenticationServices` is a
  system framework, so still no dependency) and should land in the same phase
  if it is cheap. Note guideline 4.8 requires an equivalent private option only
  once you offer *third-party* sign-in — email/password alone does not trigger
  it, so Apple sign-in is a UX call, not a compliance one, until Google is added.
- **Tokens live in the Keychain**, never `UserDefaults`. The refresh token is
  a long-lived credential; `UserDefaults` is a plist in a backup.
- **Refresh is single-flight.** On a 401 the client refreshes once and retries;
  concurrent 401s await the same refresh rather than each firing one. A feed
  screen makes several parallel requests and a token expiring mid-screen would
  otherwise send five refreshes and invalidate four of them.
- **Signed out is a first-class state**, not an error state. The session store
  publishes `.signedOut | .signedIn(UserID)` and the app renders both.

## 8. Sync: what leaves the device

**Local SwiftData stays the source of truth for your own library.** The server
holds a *published projection* of it. Nothing about ranking depends on the
server being reachable, ever.

**What publishes:** watched items with a resolved `externalId` — title, year,
poster path, sentiment, score, rank, bucket size, review, date watched. Want-to-watch
items publish too (they are half the feed's interest). **What never publishes:**
untracked items, anything with a nil `externalId`, and the local `id` UUID.

**The bucket is the unit of sync, not the item.** This is the single most
important thing in this section, and it follows directly from ranking rule 4:
inserting one title rewrites the score of *every* item in its bucket. Pushing
only the touched item leaves every other row on the server holding a score
computed for the old N — the same class of bug as the vacated-bucket one, with
a network in the middle. So a publish is a **batch upsert of a whole
`(type, sentiment)` bucket**, and any write that moves an item out of a bucket
owes that bucket a push as well.

**Mechanism:** an outbox. Local writes enqueue a `PendingPublish(bucket)` row
in SwiftData; a `SyncEngine` coalesces duplicates and drains the queue on a
background task, on foreground, and on connectivity return. Idempotent by
construction — the payload is the full bucket, so a retry is a no-op, and the
queue survives a crash.

**Conflicts:** ~~v2.0 assumes one device per account.~~ **Superseded by Part IV
(2026-08-23) — see [`PART-IV-SYNC.md`](./PART-IV-SYNC.md).** Two things in this
section changed:

1. **The server is no longer a published projection of the device.** It holds
   the user's whole library, unconditionally once signed in, and `is_published`
   decides separately what other accounts can see. "What leaves the device"
   above still holds for a signed-out user and for nil-`externalId` titles; it
   no longer holds for the published/unpublished distinction.
2. **Multi-device is supported rather than assumed away.** Sign-in restores the
   account's library and merges it with the device's, keyed on `externalId`.
   Nothing is discarded. A *sentiment* disagreement is resolved by the newest
   deliberate act (`MediaItem.lastRankedAt` against the row's `updated_at`); a
   *position* disagreement is not treated as a conflict at all, because rule 4
   says the user never chose a position.

**What is still true, and still uncomfortable:** two devices ranking
concurrently produce an order neither of them chose. Merge means nothing is
*lost* — a real improvement on losing a bucket wholesale — but a merged bucket
is a union of two partial orders that never met, and the user may find their top
five rearranged by a merge rather than by a comparison they made. The principled
fix remains storing comparison *decisions* rather than derived positions, which
is still unbuilt and still worth its own phase.

## 9. Feed design

**One event per ranking session, not one per score change.** A single
insertion mutates a whole bucket. The naive implementation posts a feed item
per changed row and floods every follower with twelve posts saying nothing.
The user performed one act — "I ranked *Dune*" — and the feed carries one post
for it. This is the same reason `posts` is separate from `ranked_items`
instead of being a view over it.

- **Fan-out on read, as a lateral merge of one stream per followee.** The
  obvious form — `where user_id in (select followee_id from follows …) order by
  created_at desc limit 20` — is a trap, and measurement is what exposed it.
  `posts (user_id, created_at desc, id desc)` orders posts *within* one user,
  while the feed wants a global order *across* twenty of them, so Postgres
  merge-joins the followees' entire post history and top-N sorts the result:
  **2101 rows read and 2101 visibility checks to return 20**, on a table of only
  6000. The cost scales with how much the people you follow have written.

  `feed()` instead cross-joins lateral, taking the newest `page_size` from each
  followee by index. Rows touched become `followees × page_size` — 400 for a
  20-post page, whatever the library size. Verified at 50,000 posts: an ordered
  `Index Scan using posts_feed_idx`, 20 rows per followee, no scan of anyone's
  back catalogue.

  Fan-out on write (a per-follower inbox table) is the answer at a scale that
  is not a realistic problem here, and it makes unfollow and deletion expensive.
- **Cursor pagination on `(created_at, id)`, not `OFFSET`.** Offset paging
  duplicates and skips rows whenever a new post lands mid-scroll, which for a
  feed is always.
- **Posts are immutable.** Editing a review creates a new `reviewed` post or
  nothing at all; it does not rewrite a post someone already commented on.
- **Backfill on first follow:** a newly followed user's recent posts appear in
  the feed, or a new account's feed is empty until its followees next rank
  something — which can be days. The query above gives backfill for free.

## 10. Comments and reactions

- Threading is **flat** in v2.0. One level of replies is a data-model change
  (`parent_id`) and a much larger UI; flat is the right v1 of a comment system
  and Beli-style activity does not generate deep threads.
- Reaction is a **single kind** (like), with `primary key (post_id, user_id)`
  doing the deduplication. Multiple emoji reactions are a schema change away
  and a scope trap now.
- Counts are **trigger-maintained columns on `posts`**, not `count(*)`
  subqueries per row — a feed of 20 posts should be one query, and the client
  must not be trusted to maintain them (section 4).
- **Comment bodies are user-generated content**, which is what makes Phase 27
  a moderation phase and not just a text field. See section 13.

## 11. Client architecture

```
Binged/
  Models/
    UserProfile.swift        // remote identity; not a @Model
    FollowState.swift
    FeedPost.swift
    PostComment.swift        // not `Comment` — reads as a language keyword
    PendingPublish.swift     // @Model, the outbox row
  Services/
    Supabase/
      SupabaseClient.swift       // URLSession, headers, refresh, decoding
      SupabaseConfiguration.swift// URL + anon key from Info.plist, like TMDB
      KeychainTokenStore.swift
    AuthService.swift            // protocol
    SupabaseAuthService.swift
    MockAuthService.swift
    SocialService.swift          // protocol: graph, feed, comments, profiles
    SupabaseSocialService.swift
    MockSocialService.swift
    SyncEngine.swift             // outbox drain
  ViewModels/
    SessionViewModel.swift       // signed-in/out, the app's auth root
    FeedViewModel.swift
    UserProfileViewModel.swift
    UserSearchViewModel.swift
    PostViewModel.swift          // one post + its comments
  Views/
    Auth/SignInView.swift, SignUpView.swift, HandleClaimView.swift
    Feed/FeedView.swift, FeedPostCard.swift
    Social/UserProfileView.swift, UserSearchView.swift, FollowListView.swift
    Post/PostDetailView.swift, CommentComposer.swift
```

Config follows the TMDB precedent exactly: `SUPABASE_URL` and
`SUPABASE_ANON_KEY` in `Secrets.xcconfig`, surfaced through the partial
`Config/Info.plist`, read back by `SupabaseConfiguration`. An unconfigured
checkout must still build and run — it comes up signed-out with social
disabled, the same way a missing TMDB token falls back to `MockMediaService`.

**Tab bar.** Five tabs is the ceiling. Proposal: **Feed, Search, Ranking,
Discover, Profile**, with today's Home rails folded into Profile (which already
owns totals, top 5, and taste analysis) and Ranking. Signed out, the Feed tab
shows the sign-in prompt rather than disappearing — a tab bar that changes
shape on sign-in is disorienting. Flagged as open question 1.

## 12. Testing

- **No test touches the network.** `StubURLProtocol` in `TMDBTestSupport.swift`
  already does this job and is reused for the Supabase client — it keys
  handlers per session precisely because Swift Testing runs in parallel.
- **View models are tested against `MockSocialService` / `MockAuthService`**,
  never against a live project, matching how `MockMediaService` is used today.
- **RLS policies need their own tests**, and they cannot be tested from the
  app. Phase 20 ships a SQL test script run against a local
  `supabase start` — asserting the negative cases, which are the ones that
  matter: a stranger cannot read a private profile's `ranked_items`, a blocked
  user cannot read the blocker's posts, a client cannot insert a post as
  someone else, a client cannot write `comment_count`.
- **The existing 219 tests must stay green with no session.** Any new required
  dependency on `MediaLibraryViewModel` or the app root must have a
  signed-out-safe default; a test that has to log in to rank a movie means
  invariant 3 was broken.

## 13. Privacy, moderation, and shipping

Accounts and user-generated content turn several things from polish into
release blockers. Phase 28 exists for these and should not be compressed.

- **In-app account deletion is mandatory** (App Store guideline 5.1.1(v)) for
  any app that offers account creation. Not "email us" — a button. It must
  delete the server rows; `on delete cascade` throughout the schema is what
  makes that one statement.
- **UGC requires the guideline 1.2 set:** a way to report content, a way to
  block a user, filtering of objectionable material, published contact info,
  and acting on reports within 24 hours. `blocks` and `reports` are in the
  schema for this reason and are not optional extras.
- **The privacy policy and nutrition labels change materially.** The app now
  collects an email, a handle, and user content, and links them to identity.
  README and CLAUDE.md's "never leaves the device" language is now false and is
  corrected as part of Part III, not after it.
- **Publishing must be a decision, not a default.** The first launch after
  updating an existing local library must not silently upload it. Signed out is
  the default state; publishing starts when an account is created and the user
  is told what becomes visible.
- **A private account is not a security feature if RLS says otherwise.**
  `is_private` must gate reads in policy, tested per section 12.

## 14. Open questions

1. **Does the Feed replace Home, or does Home survive as a sixth tab?** The
   proposal in section 11 folds Home's rails into Profile. That is a real loss
   for a signed-out user, for whom Home is currently the app's front door.
   Decide before Phase 26 builds the screen.
2. **Follow or friend?** Section 5 models asymmetric follow with a `pending`
   state, which can express both. Beli is mutual-friend; Letterboxd is follow.
   Follow is the simpler graph and the better default for a small network
   (you can consume before anyone accepts you), and `is_private` covers the
   people who want approval. Confirm before Phase 24.
3. ~~**Multi-device.**~~ **Answered by Part IV (2026-08-23).** A device no
   longer loses a bucket wholesale: sign-in restores the account's library and
   merges both sides, and only a sentiment disagreement is treated as a
   conflict. See [`PART-IV-SYNC.md`](./PART-IV-SYNC.md) §6.3.

   The *other* half of this question is still open, and is now the more
   interesting half: publishing comparison **decisions** rather than derived
   positions would let any device replay a ranking, making a merged bucket
   reproducible rather than merely non-destructive — and making the ranking
   portable and auditable as a side effect. Part IV does not do it, and
   deliberately does not make it harder: the outbox and the merge both sit above
   `RankingEngine`, which stays pure either way.
4. **Does social signal feed back into recommendations?** Part II predicts from
   your own residuals. "People whose ranking correlates with yours ranked this
   highly" is a materially better predictor and arrives free with the social
   graph. It is also the point where the app starts telling you what your
   friends' taste implies about yours, which is a product decision as much as a
   modelling one. Revisit after Phase 28.
5. **What happens to a published item when the user un-watches it?** Deleting
   the `ranked_items` row is obvious; whether the *post* also disappears is
   not — someone may have commented on it. Immutable posts (section 9) suggest
   the post stays and the link goes stale, which is defensible but needs UI.
6. **Rate limits and abuse.** Nothing in v2.0 limits how fast an account can
   comment, follow, or create posts. RLS authorises but does not throttle.
   Decide whether that is a Phase 28 item or an accepted risk for a small
   private beta.
