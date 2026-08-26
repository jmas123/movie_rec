# TestFlight readiness checklist

**Date:** 2026-08-26 · **Scope:** everything between the current working tree and a build
strangers can install · **Companion to:** [`GAP-AUDIT.md`](./GAP-AUDIT.md) §1 (closed) and
[`MANUAL-VERIFICATION.md`](./MANUAL-VERIFICATION.md)

> **The store blockers are already closed.** `GAP-AUDIT.md` §1 shut all seven on 2026-08-23 —
> icon, privacy manifest, EULA gate, real URLs, version bump, migration plan. What is left is
> almost entirely work that *cannot happen inside the repo*: a domain registration, an App Store
> Connect record, a function deploy, a decision about iPad. That is why this is a separate file
> and not another audit section: an audit finds things, and every box below is already found.

**Status key:** 🔴 blocks the upload · 🟠 blocks Beta App Review (external testers only) ·
🟡 do before strangers install it · ✅ done

> **Internal vs external is the whole shape of this document.** Up to 100 people on your own
> team can install a build with **no review at all** — upload, answer export compliance, done.
> Everything marked 🟠 exists only because an *external* group triggers Beta App Review. If the
> goal this week is "get it on my own phone and my friend's", §A is the entire list.

---

## A. Blocks the upload itself 🔴

- [x] **Decide the bundle identifier.** ✅ **Done 2026-08-26 — `com.trybinged.Binged`**, with
      `.tests` and `.uitests` beneath it, across all six configurations (Debug and Release × three
      targets). Was `Jude.WatchRank`: the retired brand, two renames ago.
      **This is permanent in App Store Connect after the first upload**, which is why it sat at the
      top of the list rather than with the other cosmetic-looking items — and why it was worth
      spending a question on rather than defaulting.
      Signing is unchanged and fine: `DEVELOPMENT_TEAM = LMN7BRGJ74`, `CODE_SIGN_STYLE = Automatic`.

      **Two things went with it, and the second is the interesting one.**
      `KeychainTokenStore`'s default service was `com.watchrank.supabase` — the same stale brand,
      in the one place that *persists across launches*. Renaming it to `com.trybinged.supabase`
      orphans any token stored under the old name, so the next launch finds no session and asks
      the user to sign in. Free today; after a TestFlight build the identical edit signs every
      tester out with no explanation and no way to correlate it. **Identifier renames get cheaper
      the earlier they happen, and there is no later point at which they get cheap again.**

      Left alone deliberately: `ConnectivityMonitor`'s dispatch-queue label
      `com.watchrank.connectivity`. It is diagnostic only — it shows up in Instruments and crash
      logs, persists nothing, and is a one-line change whenever somebody is in that file anyway.

      Verified: `-showBuildSettings` resolves `com.trybinged.Binged`, and the unit plan is green at
      **745 tests**. Note the local simulator now treats this as a different app — the old
      install's SwiftData store is still on disk under the previous id and is not read.

- [x] **Add the export-compliance key.** ✅ **Done 2026-08-26** — `ITSAppUsesNonExemptEncryption`
      is `false` in `Config/Info.plist`. Without it *every* upload stops and asks; the app makes
      only HTTPS calls, which is the standard exemption.
      It belongs in `Config/Info.plist` (the partial plist) rather than an `INFOPLIST_KEY_*` build
      setting — same reason `TMDBReadToken` lives there; see `Base.xcconfig`'s comment and the
      `xcode-custom-infoplist-keys` note.

- [x] **Create the App Store Connect record.** ✅ **Done 2026-08-26 — `TryBinged`,** bundle ID
      `com.trybinged.Binged`, SKU `binged-ios-001`, iOS, English (U.S.), Full Access. The
      remaining editable app-information fields—categories and the **age-rating questionnaire**—
      plus every answer and the reasoning behind it are written out in
      [`APP-STORE-CONNECT-RECORD.md`](./APP-STORE-CONNECT-RECORD.md). Two things from it belong
      here rather than there: the questionnaire's expensive wrong answer is declaring **no**
      user-generated content (there is: comments, bios, display names, published libraries), and
      **the name is not as available as the Name field will make it look** — see §B below and
      §0 of that document.

- [ ] **Archive with Xcode 26 and `Secrets.xcconfig` in place.** ⚠️ **The 2026-08-26 archive is
      locally valid but App Store Connect rejected it because it was built with the iOS 18.2 SDK
      in Xcode 16.2; uploads now require the iOS 26 SDK in Xcode 26 or later.** This Mac is on
      macOS 15.1.1 with only 12 GB free, so it must free substantial space, update macOS, install
      Xcode 26+, and create a new archive. The obsolete `Binged 2.0 (2)` archive at 4:04 pm
      otherwise passes `tools/verify-release-bundle.sh`: correct bundle ID,
      iPhone-only device family, Supabase credentials present, TMDB token absent, export
      compliance key correct, privacy manifest present, and app icon present. It is gitignored (`.gitignore:66`) but must
      exist at archive time carrying `SUPABASE_URL` and `SUPABASE_ANON_KEY`. Without them the
      shipped app has **no accounts at all** and silently falls back to `MockMediaService` — a
      build that looks fine on the surface and is inert underneath.
      Verify after archiving rather than trusting it:

      ```bash
      tools/verify-release-bundle.sh path/to/Binged.xcarchive
      ```

      Checks identity (bundle id, device family, version), credentials (Supabase present, **TMDB
      token absent**), and the compliance files (encryption key, privacy manifest, icon). Exit 0
      means nothing blocking an upload. Takes a `.app` too, and `--allow-tmdb-token` downgrades the
      token check to a warning for a dev build.

      **State 2026-08-26: no archive exists yet, and the item stays open until one does.** A full
      `-configuration Release` simulator build now passes `verify-release-bundle.sh` completely:
      identity, device family, version, Supabase credentials, empty TMDB token, encryption,
      privacy manifest and icon. `Base.xcconfig` blanks `TMDB_READ_TOKEN` for Release after
      including the local secrets, while Debug retains it for direct local debugging.

      The two former gates to the real archive are both closed:
      1. ✅ **Apple Distribution certificate created 2026-08-26** in Xcode under team
         `LMN7BRGJ74`.
      2. ✅ **App Store Connect record created 2026-08-26** — `TryBinged`, bundle ID
         `com.trybinged.Binged`.

      The bundle id is **not** one of them — see §A, it is decided and final.

      So the order is: register the id → create the record → archive → run this script → upload.

      **This was two hand-written greps until 2026-08-26, and both were wrong — in opposite
      directions, which is the reason the script exists.** Recorded here because the second one is
      still quoted in other documents and is worth recognising on sight:

      | Command | What it does | Direction of the lie |
      |---|---|---|
      | `strings Binged.app/Binged \| grep -i supabase` | Finds nothing on a **healthy** build | Safe. The Supabase values go through the partial `Info.plist` and never enter the Mach-O binary, so this greps a file that was never going to contain them. |
      | `grep -rl "$TOKEN" Binged.app` | Finds nothing on a build that **does** ship the token | **Dangerous.** The built `Info.plist` is a *binary* plist; BSD grep classifies it as binary and exits 1 with no output — identical to a clean result. `grep -a` finds it instantly. |

      Verified rather than reasoned: `grep -rl "eyJhbGci" Binged.app` → nothing, exit 1;
      `grep -ral "eyJhbGci" Binged.app` → `Info.plist`, exit 0, on the same bundle.
      **The general form: a verification command that returns "clean" by doing nothing at all is
      worse than no check, because it is filed as evidence.** Ask `plutil` for plist values instead
      of grepping bytes, and pass `-a` for any sweep over a bundle.

- [x] **Bump `CURRENT_PROJECT_VERSION`.** ✅ **Done 2026-08-26** — `Base.xcconfig` now reads
      `2.0 (2)`. Every upload under the same marketing version needs a unique build number, and no
      automation exists — `GAP-AUDIT.md` §1 lists this as permanently manual, so **bump it again
      before the next upload**, and reset it to 1 whenever `MARKETING_VERSION` moves.
      Verified in the built app: `CFBundleShortVersionString` `2.0`, `CFBundleVersion` `2`. The
      `CURRENT_PROJECT_VERSION = 1` lines still in `project.pbxproj` belong to the **test and
      UI-test targets** (`…Binged.tests`, `…Binged.uitests`), which are never uploaded; the app
      target carries no override and takes the xcconfig value.

---

## B. Blocks Beta App Review — external testers only 🟠

- [x] **Register `trybinged.com` and host the privacy policy.** ✅ **Done 2026-08-26.** *The one item with no code path
      around it — but not, it turns out, the longest lead time: registration at Cloudflare is
      instant, and the whole item is about thirty minutes.*

      **⚠️ `binged.app` is not available to register.** It is live on Vercel, serving *"Binged. —
      Handpicked recommendations"* — a film/TV recommendation product owned by somebody else,
      plausibly the "Binged LLC" that publishes *Bingebound* under bundle id `com.bingedapp`.
      Pointing this app's privacy link there would hand a reviewer a working page belonging to a
      stranger, which is worse than a 404. The full three-check finding is in
      [`APP-STORE-CONNECT-RECORD.md`](./APP-STORE-CONNECT-RECORD.md) §0, and the store-name
      decision is the same decision — read it before reserving a name.

      **Decided 2026-08-26: `trybinged.com`** (available, RDAP 404 at the time of the check;
      `usebinged.com` and `bingedhq.com` were the runners-up, and `getbinged.com`, `binged.co`,
      `binged.io`, `binged.fyi` are all taken). Already wired into `SupportLinks.swift`,
      `PRIVACY-POLICY.md`, `MANUAL-VERIFICATION.md`, `FeedStarterView` and the served pages —
      All of those links are now live.

      1. ✅ **Registered 2026-08-26** at Cloudflare Registrar, on Cloudflare nameservers
         (`ridge`/`emma.ns.cloudflare.com`), which is what makes steps 2 and 3 free.
      2. ✅ **Deployed 2026-08-26** and live at **https://binged-site.pages.dev** — `/`,
         `/privacy`, `/support` all 200, unknown paths 404. Redeploy after any edit under
         `docs/public/` with:
         ```bash
         npx wrangler pages deploy docs/public --project-name binged-site --branch main --commit-dirty=true
         ```
         **Direct upload, not Git-connect, on purpose:** this repo is private and pointing any
         host at `docs/` would publish `ROADMAP`, `GAP-AUDIT`, `PART-III-SOCIAL` and
         `PART-IV-SYNC`. `docs/public/` exists so exactly one directory is servable; uploading
         that path keeps the guarantee mechanical rather than remembered. (GitHub Pages is out
         regardless — private repos need Pro.)

         ✅ Custom domain attached 2026-08-26. `https://trybinged.com/`, `/privacy/`, and
         `/support/` return 200; unknown paths return 404.
      3. ✅ **Mail configured and delivery tested 2026-08-26.** Cloudflare Email Routing forwards
         `support@trybinged.com` to a verified, monitored mailbox. All three MX records and the
         SPF TXT record resolve publicly.
      4. ✅ **Verified 2026-08-26** — `/privacy` and `/support` both redirect to their canonical
         trailing-slash URLs and return 200 with the expected page titles.

      **Both URLs are required fields, and they are different fields.** App Store Connect wants a
      Support URL as well as a privacy URL, and it will not accept a `mailto:`. That page is now
      written — `docs/public/support/index.html` — and deploys with the same command.

      Two corrections to what this item used to say. `SupportLinks` does **not** render each link
      "only if it resolves": `URL(string:)` succeeds on any well-formed string, so a dead domain
      still draws a live-looking link — the About section is populated and broken, not quietly
      **Corrected 2026-08-26:** Apple reported `app.binged.Binged` unavailable when registration
      was attempted. `com.trybinged.Binged` was then registered successfully under the project
      team and replaced it across all targets before any upload. It follows the domain this
      project actually owns and is the identifier to select in App Store Connect.

- [x] **A support email that reaches you.** ✅ **Done and delivery-tested 2026-08-26.**
      `support@trybinged.com`, step 3 above. Both served
      pages already commit to it, and the support page also commits to acting on in-app reports
      within 24 hours — Guideline 1.2's requirement, and now a promise in public copy.

- [ ] **Beta App Review metadata:** beta app description, feedback email, marketing URL.

- [ ] **Demo account credentials.** Sign-up is open so a reviewer *could* make their own, but
      supply one anyway — and add the note that **the app is fully usable signed out**. That
      sentence is worth writing explicitly: a reviewer who assumes the sign-in wall is the whole
      app sees a fraction of it.

- [ ] **Be able to read the reports table.** `supabase/migrations/20260822000000_moderation.sql:50`
      grants `insert` on `reports` to authenticated users and **nothing grants `select`** — reports
      currently land in a table no human path reads. Guideline 1.2 asks you to act on reported
      content within 24 hours. Reading them from the Supabase dashboard satisfies it (service role
      bypasses RLS), but it has to be a habit you can describe, not a table that exists.
      The three UGC mechanics themselves — report, block, blocked-accounts list — are wired and
      reachable; see §D.

- [ ] **Push `20260826010000_content_filter.sql`.** Guideline 1.2's fourth requirement — a way
      to filter objectionable material *before* it is posted — had no implementation until
      2026-08-26 and now has one that is local-only. `supabase db push`; it needs the database
      password, so it cannot be done from inside the repo. Slurs and direct harassment only, by
      design — see the migration's header for why filtering profanity in a film app is the wrong
      trade, and `APP-STORE-CONNECT-RECORD.md` §4 for how that squares with the age rating.

---

## C. Before strangers install it 🟡

- [ ] **Rotate the TMDB token — Phase 35.** The client half landed
      2026-08-24 (`TMDBConfiguration.resolve` prefers proxy → bundled token → mock). Until the
      function is live, **every build still ships an extractable TMDB credential**, which
      `Base.xcconfig`'s own comment calls "not acceptable for distribution".

      ```bash
      supabase functions deploy tmdb-proxy
      supabase secrets set TMDB_READ_TOKEN=…
      ```

      The proxy is deployed and active (version 3, verified 2026-08-26), and
      `Base.xcconfig` now forcibly blanks `TMDB_READ_TOKEN` for Release while preserving it for
      local Debug builds. **Rotate the token before upload** — any value that has appeared in a
      development bundle should be treated as exposed, even though it has not reached TestFlight.
      Acceptance is `tools/verify-release-bundle.sh` reporting `TMDBReadToken is empty`, **not** a
      bare grep of the built `.app` — see §A for why that grep passes on a build that still ships
      the token.

- [ ] **TMDB attribution.** JustWatch is credited properly (`WatchProvidersRow.swift:52`), but
      TMDB's own terms want the logo plus "This product uses the TMDB API but is not endorsed or
      certified by TMDB". Not an Apple rule directly — but 5.2.5 makes third-party content rights
      Apple's business too.

- [x] **Decide on iPad.** ✅ **Dropped 2026-08-26.** `TARGETED_DEVICE_FAMILY` is `"1"` in all six
      configurations and the two now-dead `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad`
      entries are gone. The built bundle reports `UIDeviceFamily = [1]`; unit plan green at 745.

      Clean removal, because there was nothing to remove: **zero** hits across the app for
      `userInterfaceIdiom`, `horizontalSizeClass`, `NavigationSplitView` or any size-class
      branch. Nothing had ever been laid out for that screen — the `"1,2"` was Xcode's default,
      not a decision, and it was quietly promising a reviewer an iPad app.

      The app still *installs* on iPad in iPhone compatibility mode, which is the normal outcome
      and is reviewed as an iPhone app. Reversing this later is one line plus real layout work —
      the setting was never the hard part.

      `verify-release-bundle.sh` now asserts `UIDeviceFamily == [1]`, so it cannot drift back
      unnoticed the next time someone opens the target editor.

- [ ] **Run once on an iOS 17 runtime.** The deployment target was lowered to 17.0 on 2026-08-24
      and CLAUDE.md is explicit that it has been *compiled and unit-tested* at 17.0 and never run
      there — only 18.3 is installed locally. External testers on 17 would be the first to find
      out, which is the wrong way round.

- [ ] **Full test plan, not `BingedUnit`.** `BingedApp.init()` is unexercised by the unit suite,
      and the composition root is exactly what an archive changes. Run the whole plan before
      archiving.

---

## D. Already closed — do not redo ✅

Kept here so the next session (or the next you) does not re-derive them. Evidence is in
`GAP-AUDIT.md` §1's closure log unless noted.

| Item | State |
|---|---|
| App icon | Three 1024² variants, light one alpha-free (`sips -g hasAlpha` → `no`) |
| `PrivacyInfo.xcprivacy` | Present in the built `.app`; declares email, handle, name, user content, plus `UserDefaults` reason CA92.1 |
| EULA / terms gate at sign-up | `SignInView.termsSection`, gates `canSubmit` |
| In-app account deletion (5.1.1(v)) | `SettingsView.swift:91` → `SessionViewModel.deleteAccount` → `delete_account()` RPC |
| Report / block reachable | Feed row context menu, post-author menu, comment swipe; `BlockedAccountsView` for the list |
| Version | `2.0 (2)`, single source of truth in `Base.xcconfig` |
| Migration plan | `BingedSchemaV1` + `BingedMigrationPlan`, `StoreRecoveryView` instead of `fatalError` |
| Supabase migrations | All ten applied remotely — verified 2026-08-25 with `supabase migration list` |
| Force-unwraps in non-test code | Zero |

---

## E. Not required — do not spend time on it

- **Sign in with Apple.** Guideline 4.8 triggers on *third-party or social* login; Binged has
  email and password only. `MANUAL-VERIFICATION.md` §6 lists it as unbuilt, which is accurate and
  fine. It becomes required the day a Google or Facebook button appears, and not before.
- **App Store screenshots and full metadata.** Needed for App Store submission, not for
  TestFlight.

---

## Critical path

Two things have lead times measured in days rather than minutes, and everything else is an
afternoon:

1. **Register the domain** (§B) — DNS, hosting, then the policy is live.
2. ~~**Decide the bundle ID** (§A)~~ — done 2026-08-26. It was the gate on the App Store Connect
   record, which gates the first upload; that record can now be created.

**The domain is now the only long-lead item.** Everything else left is an afternoon.
