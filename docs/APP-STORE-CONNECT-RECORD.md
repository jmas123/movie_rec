# Creating the App Store Connect record

**Date:** 2026-08-26 · **Scope:** the one item in
[`TESTFLIGHT-CHECKLIST.md`](./TESTFLIGHT-CHECKLIST.md) §A that happens entirely outside this
repo — name, SKU, primary language, category, and the age-rating questionnaire.

> **Read §0 before you type anything into the Name field.** The record itself is fifteen
> minutes of form-filling and most of its fields are editable forever. Two are not, and one
> of those two is the name — not because App Store Connect locks it, but because the name
> "Binged" is already spoken for by a same-category product in a way that a free-looking
> Name field will not tell you.

---

## 0. "Binged" is taken in the ways that matter 🔴

Nothing in the US App Store is *called* Binged today — the reservation will probably go
through. That is not the same as the name being available, and three separate checks
(2026-08-26) say so:

| What | Finding |
|---|---|
| `binged.app` | **Registered, live, and serving a competitor.** Resolves via Vercel to `www.binged.app`, whose page title is *"Binged. — Handpicked recommendations"* — a film/TV recommendation product. |
| App Store publisher search | **"Binged LLC"** ships *Bingebound* under bundle id **`com.bingedapp`**. |
| Confusable marks in-category | *BINGE Movies & TV* (BINGE Networks, LLC), plus Foxtel's BINGE streaming brand. |

Three consequences, in descending order of how much they cost you:

1. **`TESTFLIGHT-CHECKLIST.md` §B is not achievable as written.** It says "register
   `binged.app`". Somebody else registered it. `Models/SupportLinks.swift` therefore points
   the privacy-policy and support links of this app at **a competitor's live website** — not
   at a dead domain, which is what the file's own comment assumes and what makes it worse. A
   reviewer following the privacy link lands on a working page belonging to someone else.
   That is a 5.1.1 rejection with an awkward explanation attached.
2. **A reserved name is not a defence.** Apple grants names first-come and reviews them under
   4.1 / 5.2.1 anyway; and a mark holder can file a dispute *after* you ship, at which point
   the name comes off a live listing rather than an empty record.
3. **The App Store name and the in-app brand are separate strings.** You can keep "Binged" on
   the launch screen and reserve something differentiated on the store, and that costs one
   `git grep` of the marketing copy. The reverse — shipping first and renaming later — costs a
   URL scheme's worth of link rot and every screenshot.

### Settled, 2026-08-26

**The brand stays `Binged`; the domain becomes `trybinged.com`** — registered through Cloudflare
at 18:46 UTC, with `Models/SupportLinks.swift` already repointed at
`https://trybinged.com/privacy` and `support@trybinged.com`, and a site under `docs/public/`.

That is the defensible version of the call: the conflict is a small LLC rather than a household
mark, and the two things that would actually have hurt — shipping links to somebody else's live
website, and having no domain of your own — are both now closed. What remains is residual and
worth knowing rather than acting on:

- **Reserve the exact name early.** It is free and it is first-come. The longer the record sits
  uncreated, the more of a race it is.
- **A dispute is still possible after launch**, and the answer to one is a rename, which is
  cheap in App Store Connect and expensive everywhere else. Keep the wordmark in as few places
  as `SupportLinks` keeps the domain.
- **The store name is `TryBinged`.** The record was created successfully under that name on
  2026-08-26. It is differentiated from the existing same-category Binged product and follows
  the domain without requiring another purchase.
- **Nothing may point at `binged.app` again.** It resolves, it belongs to someone else, and a
  dead link would at least have failed loudly.

---

## 1. Before the "New App" button

- **The bundle ID already exists in the Developer portal.** `com.trybinged.Binged` — registered
  2026-08-26 after Apple reported `app.binged.Binged` unavailable. It is decided and
  implemented across all six configurations (renamed off `Jude.WatchRank` on 2026-08-26).
  It follows the registered `trybinged.com` domain and is invisible to users. It was registered
  under team `LMN7BRGJ74` with no extra capabilities — the app needs none: keychain access needs no
  entitlement, there is no push, no Sign in with Apple, no iCloud. Note for later: sign-in is
  email/password only, so 4.8 (third-party login needs a private equivalent) does not apply.
  It applies the day you add a Google or Apple button.
- **The Free Apps agreement must be Active** under Business → Agreements. Paid Apps is not
  needed and drags a tax and banking questionnaire behind it; skip it.
- **iPad is already decided: iPhone only.** `TARGETED_DEVICE_FAMILY = "1"` in all six
  configurations. The app can still run on iPad in iPhone compatibility mode, but App Store
  Connect should not request native iPad screenshots. See `TESTFLIGHT-CHECKLIST.md` §C.

---

## 2. The record's five fields

App Store Connect → Apps → **+** → **New App**.

| Field | Value | Editable later? |
|---|---|---|
| **Platforms** | iOS only | Adding a platform later is fine |
| **Name** | **TryBinged** — created 2026-08-26 | Yes, until first submission; then per-version |
| **Primary Language** | **English (U.S.)** | Effectively yes, via a version |
| **Bundle ID** | `com.trybinged.Binged` | **No — permanent after first upload** |
| **SKU** | `binged-ios-001` | **No — permanent, and never shown to users** |
| **User Access** | Full Access | Yes |

**On the SKU.** It exists only to key your finance reports, nobody outside your team ever sees
it, and it cannot be changed. Which is exactly why it should be boring and should *not* be the
bundle ID: if the brand moves again, a SKU that reads `com.trybinged.Binged` becomes a permanent
record of a name you no longer use, sitting in a column you cannot edit. `binged-ios-001`
carries a counter for the day there is a second app and no promises otherwise.

**Categories** (set on the version's App Information page, not in the New App dialog — both are
editable per version):

- **Primary: Entertainment.** Where the trackers live — IMDb, TV Time, the watchlist apps. It
  is the category a user browsing for "what should I watch" is already in.
- **Secondary: Social Networking.** Honest — there are follows, a feed, comments and profiles —
  and it costs nothing, because App Review applies the 1.2 UGC rules based on what the app
  *does*, not on which category you picked. Choosing Entertainment does not exempt you from §4
  below, and choosing Social Networking does not add anything to it.

---

## 3. The age-rating questionnaire

The rating is **computed**, not chosen: you answer, Apple returns a tier. You cannot aim at a
number, and the failure mode is not "the rating came out too high" — it is answering *No* to a
capability you actually have, which is a misrepresentation that surfaces on a later submission
rather than this one.

Apple's wording shifts between revisions (the questionnaire gained capability questions and the
13+/16+/18+ tiers in the 2026 revision). Answer the **substance** below and match it to whatever
phrasing is on screen.

### Content questions — all None, and here is why that is defensible

| Question | Answer | Grounds |
|---|---|---|
| Cartoon or fantasy violence | None | The app renders TMDB posters, titles, overviews and cast. It contains no depictions of its own. |
| Realistic violence; prolonged graphic or sadistic violence | None | Same. |
| Sexual content or nudity | None | `include_adult=false` is set on every TMDB search and discover call — `Services/TMDBConfiguration.swift:232` and `:340`. Adult titles never enter the catalogue the app can show. |
| Horror or fear themes | None | Poster art for a horror film is not horror content; Apple has never read it that way for trackers. |
| Alcohol, tobacco, or drug use or references | None | |
| Simulated or real gambling | None / No | No wagering, no loot mechanic, no currency at all. |
| Contests | No | |
| Medical or treatment information | No | |
| Made for Kids | **No** | Do not check this. An app with accounts and UGC cannot be in the Kids category (1.3), and checking it is an instant rejection. |

### The one content answer that is genuinely arguable

| Question | Answer | Why |
|---|---|---|
| Profanity or crude humor | **Infrequent/Mild** | Comments are free text with **no content filter anywhere in the schema** (§4). Apple's own guidance is that the rating must account for what users can post, and "None" on an app that lets strangers type into a public thread is the answer that gets re-litigated later. Infrequent/Mild is honest and costs nothing — it does not by itself push past 12+/13+. |

If you would rather answer None, the way to earn it is to ship a filter first, not to argue the
point in Resolution Center.

### Capability questions — the ones that actually move the rating

| Question | Answer | Grounds |
|---|---|---|
| **Unrestricted web access** | **No** | There is no `WKWebView` and no `SFSafariViewController` in the project. Outbound links are specific `Link(destination:)` URLs — streaming providers (`Views/Detail/WatchProvidersRow.swift:44`), the policy pages and a `mailto:` — which hand off to Safari outside the app. **Answering Yes here forces 18+**, so answer it deliberately rather than defensively. |
| **User-generated content** | **Yes** | Comments, editable (`Views/Post/CommentEditor.swift`); display names, bios and handles (`Views/Settings/EditProfileView.swift`); and published libraries with reviews. Saying No here is the single most expensive wrong answer available on this form. |
| Users can communicate with each other | **Yes** | Public comments on posts. |
| Private messaging / chat | **No** | There are no DMs. `SocialService` exposes follows, blocks and reports; nothing sends a message from one user to another. |
| Moderation and safety controls present | **Yes** — enumerate them | Report with a closed reason list (`Views/Post/ReportSheet.swift` → `reports` table); block/unblock with mutual invisibility enforced in RLS, plus a Blocked Accounts screen; private accounts with follow requests; server-side rate limits. |
| In-app parental controls / age gate | **No** | There is no PIN, no age gate, no restricted mode. There is a terms-acceptance toggle at sign-up, which is a different thing. |
| Contains ads | **No** | No ad SDK, no analytics SDK — see `PrivacyInfo.xcprivacy` and `docs/PRIVACY-POLICY.md`. |

**Actual outcome, saved 2026-08-26: 13+ globally**, with Apple's automatic regional equivalents:
16+ in two countries or regions, A16 in Brazil, and 15+ in Korea; operating systems earlier
than version 26 show the legacy global rating of 12+. The UGC/communication capabilities carry
the rating there; nothing reaches 18+. No Korean RCN was added because this is not a game.

---

## 4. What answering "Yes" to UGC commits you to

Guideline 1.2 asks for four things. Three exist:

- ✅ **A report mechanism** — `ReportSheet` + the `reports` table.
- ✅ **Block abusive users** — `SocialService.block/unblock/blockedAccounts`, enforced in RLS.
- ✅ **An agreed EULA** — the sign-up toggle in `Views/Auth/SignInView.swift:197` gates account
  creation on Terms + Privacy, linked inline; Apple's standard EULA is the terms target.
- ⚠️ **A method for filtering objectionable material from being posted** — **written
  2026-08-26, not yet pushed.** `supabase/migrations/20260826010000_content_filter.sql` adds a
  term list in the `app` schema (unreachable over PostgREST) and a BEFORE INSERT OR UPDATE
  trigger on `comments.body`, `profiles.display_name/bio/handle`, `ranked_items.review` and
  `posts.payload.review_excerpt`. It resists the usual evasions — case, leetspeak, spacing,
  punctuation, padded letters — and covers the edit path, which is the one a filter written
  only for INSERT would miss.
  **It filters slurs and direct harassment, not profanity**, which is why the Profanity answer
  above stays Infrequent/Mild rather than becoming None. Verified locally with 18 pgTAP
  assertions; it counts for 1.2 only once `supabase db push` has run.
- ⚠️ **Published contact info** — required, and currently pointing at `binged.app`. See §0.

And two operational commitments the form does not mention but Review does:

- Reports must be **actionable within 24 hours** — which the app already promises the user in
  `ReportSheet.swift:48`. `TESTFLIGHT-CHECKLIST.md` §B is right that nothing grants `select` on
  `reports`; reading them from the Supabase dashboard satisfies it, as a habit you can describe.
- The rating must be **re-answered when the feature set changes**. Adding DMs, or an in-app
  browser, changes answers in §3 and is a re-submission, not a silent edit.

---

## 5. What is permanent, and what only feels permanent

| Permanent | Editable |
|---|---|
| Bundle ID (after first upload) | App name and subtitle (until first submission; per-version after) |
| SKU (from creation) | Categories, per version |
| Apple ID / adam id (assigned) | Primary language, via a version |
| | Age rating, any time — though **lowering** it after release invites questions |
| | Privacy policy URL, support URL |

Nothing in §2 or §3 requires a build to exist. You can create this record today and upload
weeks later; the record is a prerequisite for the upload, not the other way round.

---

## 6. Order of operations

1. Settle the name and buy the matching domain (§0). Update `Models/SupportLinks.swift` in the
   same sitting — it is the only file that knows the domain, by design.
2. ✅ Register `com.trybinged.Binged` in Certificates, Identifiers & Profiles — done 2026-08-26.
3. New App → the five fields in §2.
4. App Information → categories; leave the version metadata for later.
5. Age rating → the answers in §3. **Write the returned tier back into this file.**
6. Return to `TESTFLIGHT-CHECKLIST.md` §A and tick the record; §B's privacy-URL item unblocks
   only once the new domain is serving `docs/public/privacy/index.html`.
