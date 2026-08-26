//
//  SupportLinks.swift
//  Binged
//
//  The outbound links an app with accounts and user-generated content is
//  obliged to carry: somewhere to complain to, terms, and a privacy policy.
//
//  **Why these are optional.** They were previously three `URL(string:)!`
//  literals inline in `SettingsView` — the only force-unwraps in non-test code,
//  against the project's own rule. A typo in any of them was a launch-time
//  crash on the Settings screen. Here they resolve or they don't, and a link
//  that does not resolve is simply not drawn.
//
//  ⚠️ **`trybinged.com` is chosen but not yet registered or hosted.** Both
//  links resolve to a domain that serves nothing yet — a *valid* URL, which is
//  why this type cannot detect the problem for you: `URL(string:)` succeeds on
//  any well-formed string, so a dead domain still draws a live-looking link.
//  App Review follows the privacy-policy link; it must return 200 before
//  submission. `docs/public/privacy/index.html` is the page and
//  `TESTFLIGHT-CHECKLIST.md` §A is the registration runbook.
//
//  **Not `binged.app`, and not by accident.** That domain is registered and
//  live: it serves another company's product, "Binged. — Handpicked
//  recommendations", in this app's own category (checked 2026-08-26). Do not
//  "correct" these literals back to it. The name collision itself is an open
//  question in `docs/COMPETITIVE-LANDSCAPE.md`.
//
//  These said `watchrank.app` until 2026-08-25 — two product renames after the
//  product stopped being called that. The mechanical WatchRank → Binge → Binged
//  sweeps rewrote type names and prose but not string literals inside URLs, so
//  the links were wrong twice over: a dead domain *and* a retired brand, on the
//  one screen that exists to tell a user who they are dealing with. Changing
//  them here does not make them resolve; it means that when a domain is
//  registered, this file is the only place that has to know.
//

import Foundation

// MARK: - SupportLinks

enum SupportLinks {

    /// Apple's standard EULA. Used when an app does not supply its own custom
    /// licence agreement, and the one link here that is real and permanent.
    static let termsOfUse = url("https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    static let privacyPolicy = url("https://trybinged.com/privacy")

    static let supportEmail = url("mailto:support@trybinged.com")

    /// Every link that resolved, for callers that want to know whether there is
    /// anything to show at all.
    static var all: [URL] {
        [termsOfUse, privacyPolicy, supportEmail].compactMap { $0 }
    }

    private static func url(_ string: String) -> URL? {
        URL(string: string)
    }
}
