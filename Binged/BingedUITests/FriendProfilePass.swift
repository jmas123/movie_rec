//
//  FriendProfilePass.swift
//  BingedUITests
//
//  A camera, like `ScreenshotPass` — pointed at somebody else's profile.
//
//  The comparison sections on that screen cannot be looked at in isolation:
//  they exist only when the *viewer's* library and the *subject's* ranking
//  overlap, which takes a seeded social world and a device library ranked
//  against it. So this pass ranks five of Mina's titles first — one of them
//  deliberately disliked, so "where you disagree" has something to say — and
//  then opens her profile.
//
//  Asserts almost nothing, for the same reason as its sibling: a failed
//  assertion halfway through produces fewer pictures.
//
//  Run it alone; it is skipped by the normal plans:
//    xcodebuild test -only-testing:BingedUITests/FriendProfilePass
//

import XCTest

final class FriendProfilePass: XCTestCase {

    private let timeout: TimeInterval = 20

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Pass

    @MainActor
    func testCaptureAFriendsProfile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingInMemoryStore", "-uiTestingMockSocial"]
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: timeout))

        // Five shared titles: the minimum a taste match will speak at.
        app.tabBars.buttons["Search"].tap()
        rank("Parasite", sentiment: "Liked it", in: app)
        rank("Inception", sentiment: "Liked it", in: app)
        rank("The Dark Knight", sentiment: "Liked it", in: app)
        rank("Moonlight", sentiment: "It was fine", in: app)
        // The disagreement. Mina has it near the top of her Liked bucket.
        rank("Interstellar", sentiment: "Didn't like it", in: app)

        // Home → Following → the feed, where an author's name is a route to
        // their profile.
        app.tabBars.buttons.firstMatch.tap()
        let following = app.buttons["Following"]
        if following.waitForExistence(timeout: timeout) { following.tap() }
        capture(app, "01-Feed")

        let mina = app.staticTexts["Mina Okafor"].firstMatch
        guard mina.waitForExistence(timeout: timeout) else {
            XCTFail("no route to a profile from the feed")
            return
        }
        mina.tap()

        XCTAssertTrue(app.staticTexts["@mina"].waitForExistence(timeout: timeout))
        capture(app, "02-Profile-overview")

        // The comparison sections sit below the fold on a phone.
        app.swipeUp()
        capture(app, "03-Profile-overview-scrolled")
        app.swipeUp()
        capture(app, "04-Profile-overview-bottom")

        // And the ranking itself, which is what the screen used to open on.
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()
        if app.buttons["Movies"].firstMatch.waitForExistence(timeout: timeout) {
            app.buttons["Movies"].firstMatch.tap()
            capture(app, "05-Profile-their-ranking")
        }
    }

    // MARK: - Ranking

    /// Search for `title`, mark it watched with `sentiment`, and end any
    /// comparison immediately with the tie — one tap instead of four, and the
    /// resulting order is deterministic.
    @MainActor
    private func rank(_ title: String, sentiment: String, in app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: timeout) else { return }
        field.tap()
        let clear = field.buttons.firstMatch
        if clear.exists { clear.tap() }
        field.typeText(title)

        let row = app.staticTexts[title].firstMatch
        guard row.waitForExistence(timeout: timeout) else { return }
        row.tap()

        let markWatched = app.buttons["Mark Watched"]
        guard markWatched.waitForExistence(timeout: timeout) else { return }
        markWatched.tap()

        let choice = app.buttons[sentiment]
        guard choice.waitForExistence(timeout: timeout) else { return }
        choice.tap()
        app.buttons["Rank it"].tap()

        let tie = app.buttons["Too close to call"]
        while tie.waitForExistence(timeout: 3) {
            tie.tap()
        }

        // Back to the search results for the next title.
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
    }
}
