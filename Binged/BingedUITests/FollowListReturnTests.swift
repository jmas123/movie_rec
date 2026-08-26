//
//  FollowListReturnTests.swift
//  BingedUITests
//
//  Going out to a follow list and coming back.
//
//  A unit test cannot see this one. `UserProfileView` reloads from `.task`,
//  which SwiftUI cancels when a view disappears and restarts when it reappears
//  — so a push and a pop are a full reload, and whether the screen survives
//  that round trip is a property of the *navigation*, not of the view model.
//  Both the view model and the wiring can be individually correct while the
//  screen still comes back wrong.
//
//  Runs against the seeded mock social world, so it exercises structure rather
//  than latency: what it can prove is that the profile is whole again after the
//  pop — header, stats and the ranking picker all back on screen — and that the
//  trip did not leave a spinner, an error, or an empty page behind.
//

import XCTest

final class FollowListReturnTests: XCTestCase {

    private let timeout: TimeInterval = 20

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingInMemoryStore", "-uiTestingMockSocial"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: timeout))
        return app
    }

    private func openMinasProfile(in app: XCUIApplication) {
        app.tabBars.buttons.firstMatch.tap()
        let following = app.buttons["Following"]
        XCTAssertTrue(following.waitForExistence(timeout: timeout), "no feed switcher")
        following.tap()

        let author = app.staticTexts["Mina Okafor"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: timeout), "no author to tap")
        author.tap()
        XCTAssertTrue(
            app.staticTexts["@mina"].waitForExistence(timeout: timeout),
            "profile did not open"
        )
    }

    /// The row that opens the following list, labelled "Following, <n>".
    ///
    /// Anchored deliberately. The bare word "Following" is also the feed
    /// switcher two screens up **and** the follow button in this very header —
    /// a suffix match found the latter first and unfollowed the person whose
    /// profile the test was trying to read.
    private func followingRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label MATCHES %@", "^Following, [0-9]+$")
        ).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - The round trip

    @MainActor
    func testProfileIsWholeAfterReturningFromTheFollowingList() throws {
        let app = launch()
        openMinasProfile(in: app)
        capture(app, "01-profile-before")

        let row = followingRow(in: app)
        guard row.waitForExistence(timeout: timeout) else {
            throw XCTSkip("this account follows nobody, so the count is not a link")
        }
        row.tap()

        XCTAssertTrue(
            app.navigationBars["Following"].waitForExistence(timeout: timeout),
            "the following list did not open"
        )
        capture(app, "02-following-list")

        // The list's own back button, not whichever navigation bar the query
        // happens to reach first.
        app.navigationBars["Following"].buttons.firstMatch.tap()

        // Back on the profile. The header identifies it…
        XCTAssertTrue(
            app.staticTexts["@mina"].waitForExistence(timeout: timeout),
            "the profile did not come back"
        )
        capture(app, "03-profile-after")

        // …and the body is actually there. A profile stuck on its spinner, or
        // one that came back as an error, still has the navigation title — so
        // the title alone proves nothing, which is the trap this assertion
        // exists to avoid.
        XCTAssertTrue(
            app.buttons["Movies"].firstMatch.waitForExistence(timeout: timeout),
            "the ranking picker is missing — the profile came back empty"
        )
        XCTAssertFalse(
            app.staticTexts["No account with that handle."].exists,
            "the profile came back as not-found"
        )
        XCTAssertTrue(
            followingRow(in: app).waitForExistence(timeout: timeout),
            "the follow-list rows are missing after the return"
        )
    }
}
