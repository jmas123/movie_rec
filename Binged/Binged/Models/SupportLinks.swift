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
//  ⚠️ `watchrank.app` does not exist yet. `supportEmail` and `privacyPolicy`
//  point at a domain nobody has registered, so both currently resolve to a URL
//  that goes nowhere — a *valid* URL, which is why this type cannot detect the
//  problem for you. App Review checks the privacy policy link; it must be live
//  before submission.
//

import Foundation

// MARK: - SupportLinks

enum SupportLinks {

    /// Apple's standard EULA. Used when an app does not supply its own custom
    /// licence agreement, and the one link here that is real and permanent.
    static let termsOfUse = url("https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    static let privacyPolicy = url("https://watchrank.app/privacy")

    static let supportEmail = url("mailto:support@watchrank.app")

    /// Every link that resolved, for callers that want to know whether there is
    /// anything to show at all.
    static var all: [URL] {
        [termsOfUse, privacyPolicy, supportEmail].compactMap { $0 }
    }

    private static func url(_ string: String) -> URL? {
        URL(string: string)
    }
}
