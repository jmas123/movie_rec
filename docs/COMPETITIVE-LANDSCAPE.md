# Competitive landscape

**Compiled 2026-08-24.** What else exists, how Binged differs, and — the part
worth reading — where it does not.

Prompted by the naming exercise: searching the App Store for "Binge" turned up
four apps of that name in this exact category, and two apps shipping Binged's
*core mechanic*. That is a more consequential finding than the name, and it had
not been written down anywhere.

> **Read this as a snapshot, not a verdict.** These are app-listing descriptions
> and press, not hands-on use. Nobody on this project has installed the two
> closest competitors. Doing so is the single highest-value hour available
> before launch, and until someone has, every "we do X and they don't" below is
> a claim about a marketing page.

---

## 1. The three that matter

### Beli — the acknowledged ancestor

`CLAUDE.md` names Beli as the model, so it is the baseline rather than a rival:
restaurants, not films. The mechanic Binged inherited is
[well documented](https://hackernoon.com/belis-binary-search-rating-system-explained):
sort a new entry into **bad / okay / great**, then binary-insertion compare it
against existing entries *within that band*, then interpolate a 0–10 score from
final position. It also offers a "too hard to compare" escape.

Binged's rules 1, 2, 3, 4 and 7 are that system. The differences are deliberate
and documented in `CLAUDE.md`: buckets are `(media type, sentiment)` rather than
sentiment alone, and a score is withheld until its bucket holds five items.

**Not a competitor.** It is the proof the mechanic works on a different noun.

### Shortlist — the closest thing to a direct competitor

[Shortlist – Rank Movies & TV](https://apps.apple.com/us/app/shortlist-rank-movies-tv/id6759330695).
Free. Same category, same mechanic:

> "When you add a new title, Shortlist pits it against a series of titles
> already on your list; you just keep picking your favorite."

It has independently arrived at several of Binged's decisions — **separate
ranked lists for movies and TV**, and a refusal of star ratings. And it is
ahead on breadth: an activity feed, collaborative lists, spoiler-flagged
reviews, streaming-provider filtering across twelve services, a "Tonight's
Pick" for who is in the room, achievement streaks, and a global leaderboard.

It also makes the opposite bet on recommendations, explicitly rejecting
algorithmic suggestion in favour of "the people you actually trust."

**This is the app to install first.** If Binged has a reason to exist, it is
visible in the gap between these two products, and nobody here has looked.

### Podiums — same mechanic, wider net

[Podiums](https://apps.apple.com/us/app/podiums-rate-rank-discover/id6738963615).
Free, no ads, no subscription.

> "Rank what you like, playing a mini game where you choose which was better
> between two pieces of content, and we turn it into an accurate score."

That is Binged's description of itself. Podiums covers **films, TV, music,
albums, artists, podcasts and games in one profile**, with follows, comments,
reactions, custom lists ("Pods") and Spotify integration.

Breadth is its strategy and its weakness: ranking a podcast against a podcast
tells you nothing about films, and one profile spanning six media types cannot
apply a per-domain scale the way `(media type, sentiment)` buckets do.

### The rest of the field, briefly

| App | What it is | Overlap |
|---|---|---|
| [Letterboxd](https://apps.apple.com/us/app/letterboxd/id1054271011) | The incumbent film diary — logs, reviews, social | Huge audience, but star ratings and no ranking mechanic |
| [Binge: Movies and Shows](https://apps.apple.com/us/app/binge-movies-and-shows/id6755895331) | Tracker by a well-known indie dev; jump-scare timeline, showtimes | Tracking, not ranking |
| [Binge: Movie TV Tracker](https://apps.apple.com/us/app/binge-movie-tv-tracker/id6741734482) | Tracker with awards browsing, daily stories | Tracking, not ranking |
| [CircleRanks](https://apps.apple.com/us/app/circleranks-rate-movies-tv/id6480323927) | 1–10 decimal ratings, per-episode | Rates; does not compare |
| [BingeBoxd](https://apps.apple.com/us/app/bingeboxd-tv-movie-tracker/id6749491360), [Bingers](https://apps.apple.com/us/app/bingers-tv-movie-tracker/id6792080029) | Trackers | Name collision, not feature collision |

**The category splits cleanly in two:** *trackers* (what have I watched, what's
next) and *rankers* (what did I think, in what order). Most are trackers.
Binged, Shortlist and Podiums are rankers.

---

## 2. What is genuinely Binged's

Five things nothing above appears to do. Each is a real product decision with
code and tests behind it, not a slogan.

### 2.1 A score is withheld until it has been earned

Ranking rule 6: no number until its `(type, sentiment)` bucket holds five
items. Below that the UI shows **position** — "#2" — and how many more titles
are needed. The score is computed and stored throughout; only its *display* is
withheld.

Nobody else does this. Podiums turns comparisons into "an accurate score"
immediately; Beli scores from the first entry. A number derived from one
comparison is the band midpoint wearing a decimal point, and showing it claims
precision the app has not earned. **This is the clearest philosophical
difference in the category** — and it costs something real, because a new user
sees no numbers for a while.

Rule 6 applies to *other people's* profiles too, which is unusual: a stranger's
"8.4" from a bucket of one is the same unearned precision, published.

### 2.2 Prediction that is local, and visibly not a score

Part II predicts a score for unwatched titles from the user's own ranked
library — content-based, computed on device, no collaborative filtering and no
model download. TMDB supplies metadata, never a recommendation.

Two design consequences competitors do not have:
- **A prediction is rendered as an outlined badge, never the filled score
  pill**, so a guess cannot borrow the credibility of an earned score.
- Below a confidence floor it shows a **qualitative band** rather than a
  number, inheriting rule 6's discipline.

Shortlist rejects algorithmic recommendation outright; Podiums leans on Spotify
and social discovery. Binged is the only one attempting *your own residuals* as
the signal.

### 2.3 The app is complete signed out

Search, ranking, comparison, recommendations and profile all work with no
account, offline. Accounts add sync and social; they do not gate the product.
Every competitor above is account-first.

### 2.4 Storing and sharing are different questions

Part IV: a signed-in library syncs to the account **unconditionally**, so it
follows the user between devices — and `is_published` separately controls what
anyone else sees, off by default, enforced by row-level security rather than by
the client. Withdrawing hides rows; it never deletes them.

Most products conflate "back up my data" with "show my data". Binged separates
them at the security boundary.

### 2.5 Two escapes the comparison flow offers

- **"Too close to call"** ends the bisection early and seats the newcomer just
  below the incumbent, rather than forcing a coin-flip the user never meant.
  (Beli has a version of this; the trackers have nothing.)
- **Undo**, mid-session, which is rarer — the bisection cannot be inverted
  arithmetically, so it required keeping prior search bounds.

---

## 3. Where Binged is behind

The honest half, and the more useful one.

1. **It has not shipped.** Shortlist and Podiums are free, live, and
   accumulating reviews and ranking history. That is a compounding lead.
2. **Social breadth.** Shortlist has collaborative lists, streaming-provider
   filtering, a leaderboard, streaks and a "who's watching tonight" picker.
   Binged has follows, a feed, comments and reactions — the primitives, not the
   products built on them.
3. **No streaming-availability data.** "Where can I watch this" is table stakes
   in every competitor and Binged does not answer it, despite TMDB exposing
   watch providers.
4. **One domain.** Podiums ranks six media types. That is a real audience
   argument, whatever its scale problems.
5. **Rule 6 is a cold-start tax.** A new user ranks four films and sees no
   scores. It is the right call and it is *also* the kind of restraint that
   loses users who wanted a number. Worth measuring rather than assuming.
6. **The name is contested.** Four App Store apps were called Binge; Binged is
   less crowded but shares a search results page with all of them, and
   `binged.com` is an established OTT ratings site. See §5.

---

## 4. Where the wedge probably is

Not "a ranking app" — that space has three occupants. The defensible claim is
narrower:

> **The ranking app that refuses to lie to you.** A number only when it has
> been earned; a prediction that never dresses as a rating; your library backed
> up without being published; and nothing computed on a server that could be
> computed on your phone.

Everything in §2 is a variation on that one sentence, which suggests it is the
actual product rather than a retrofitted positioning.

---

## 5. On the name

Renamed WatchRank → Binge → Binged on 2026-08-23/24.

**Binge was a bad name** and the rename away from it was right: four
same-category App Store apps, [Foxtel's Binge](https://en.wikipedia.org/wiki/Binge_(streaming_service))
holding the trademark on a major streaming service, and `binge.app` already
resolving to a third party's host.

**Binged is better but not clean.** No App Store app of that name surfaced, and
the past tense fits a product about what you have *already watched* — Binge
described the wrong half of the loop. But App Store search does not care about
tense, [binged.com](https://www.binged.com/) is an established OTT ratings site,
and trademark similarity is judged by likelihood of confusion rather than
identity.

**Outstanding:** a real trademark search, and `binged.app` / `getbinged.com`
availability. Neither has been done — the above is app listings and press, not a
register.

---

## Sources

App Store listings for
[Shortlist](https://apps.apple.com/us/app/shortlist-rank-movies-tv/id6759330695),
[Podiums](https://apps.apple.com/us/app/podiums-rate-rank-discover/id6738963615),
[Letterboxd](https://apps.apple.com/us/app/letterboxd/id1054271011),
[Binge: Movies and Shows](https://apps.apple.com/us/app/binge-movies-and-shows/id6755895331),
[Binge: Movie TV Tracker](https://apps.apple.com/us/app/binge-movie-tv-tracker/id6741734482),
[CircleRanks](https://apps.apple.com/us/app/circleranks-rate-movies-tv/id6480323927),
[BingeBoxd](https://apps.apple.com/us/app/bingeboxd-tv-movie-tracker/id6749491360),
[Bingers](https://apps.apple.com/us/app/bingers-tv-movie-tracker/id6792080029);
[Beli's binary-search rating system](https://hackernoon.com/belis-binary-search-rating-system-explained);
[Binge (streaming service)](https://en.wikipedia.org/wiki/Binge_(streaming_service));
[binged.com](https://www.binged.com/).
