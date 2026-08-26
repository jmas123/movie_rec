//
//  ProfileNavigationTests.swift
//  BingedUITests
//
//  Opening somebody's profile, from each of the places that offer it.
//
//  A regression guard rather than a camera. Every one of these taps is a
//  `PersonRoute` push into the *same* navigation stack, and a stack with more
//  than one destination registered for that type silently drops all but one —
//  so a route that works from one screen can do nothing at all from another.
//  That failure is invisible to every unit test: the view models are fine, and
//  the wiring is what breaks.
//

import XCTest

final class ProfileNavigationTests: XCTestCase {

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

    /// Taps by coordinate. A toolbar `Menu`'s label refuses XCUITest's
    /// scroll-to-visible, which is a harness quirk rather than the app's.
    private func forceTap(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // MARK: - From the feed

    @MainActor
    func testTappingAnAuthorInTheFeedOpensTheirProfile() throws {
        let app = launch()
        openFeed(in: app)

        let author = app.staticTexts["Mina Okafor"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: timeout), "no author to tap")
        author.tap()

        XCTAssertTrue(
            app.navigationBars["@mina"].waitForExistence(timeout: timeout),
            "tapping an author in the feed did not open their profile"
        )
    }

    // MARK: - From people search

    @MainActor
    func testTappingAResultInPeopleSearchOpensTheirProfile() throws {
        let app = launch()
        app.tabBars.buttons.firstMatch.tap()

        let people = app.buttons["People"].firstMatch
        XCTAssertTrue(people.waitForExistence(timeout: timeout), "no people menu")
        forceTap(people)

        let find = app.buttons["Find People"]
        XCTAssertTrue(find.waitForExistence(timeout: timeout), "the people menu did not open")
        find.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "no search field")
        field.tap()
        field.typeText("theo")

        let row = app.staticTexts["@theo"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "search found nobody")
        row.tap()

        // The profile screen puts the handle in the navigation bar, which the
        // result row does not — so this distinguishes "pushed" from "still on
        // the search results".
        XCTAssertTrue(
            app.navigationBars["@theo"].waitForExistence(timeout: timeout),
            "tapping a search result did not open the profile"
        )
    }

    // MARK: - From a follower list

    /// The nested push: a profile opened *from* a profile, which is itself a
    /// pushed destination in the same stack.
    @MainActor
    func testTappingSomeoneInAFollowerListOpensTheirProfile() throws {
        let app = launch()
        openFeed(in: app)

        let author = app.staticTexts["Mina Okafor"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: timeout))
        author.tap()
        XCTAssertTrue(app.navigationBars["@mina"].waitForExistence(timeout: timeout))

        let followers = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Followers")
        ).firstMatch
        XCTAssertTrue(followers.waitForExistence(timeout: timeout), "no follower count to tap")
        followers.tap()

        let person = app.staticTexts["@you"].firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: timeout), "the follower list is empty")
        person.tap()

        XCTAssertTrue(
            app.navigationBars["@you"].waitForExistence(timeout: timeout),
            "tapping a follower did not open their profile\n\(app.debugDescription)"
        )
    }

    // MARK: - From the Search tab

    /// A different navigation stack from the one above, with its own
    /// destinations. It has been possible for one to work while the other did
    /// not, which is the whole reason both are tested.
    @MainActor
    func testTappingAPersonInTheSearchTabOpensTheirProfile() throws {
        let app = launch()
        app.tabBars.buttons["Search"].tap()

        let people = app.buttons["People"].firstMatch
        guard people.waitForExistence(timeout: timeout) else {
            throw XCTSkip("this build has no people scope in search")
        }
        people.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("mina")

        let row = app.staticTexts["@mina"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "search found nobody")
        row.tap()

        XCTAssertTrue(
            app.navigationBars["@mina"].waitForExistence(timeout: timeout),
            "tapping a person in the Search tab did not open their profile"
        )
    }

    // MARK: - A title on somebody's ranking

    @MainActor
    func testTappingATitleOnAProfileOpensIt() throws {
        let app = launch()
        openFeed(in: app)

        let author = app.staticTexts["Mina Okafor"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: timeout))
        author.tap()
        XCTAssertTrue(app.navigationBars["@mina"].waitForExistence(timeout: timeout))

        // Her ranking lives behind the Movies tab; Overview leads with the
        // comparison instead.
        let movies = app.buttons["Movies"].firstMatch
        XCTAssertTrue(movies.waitForExistence(timeout: timeout), "no ranking tab")
        movies.tap()

        let title = app.staticTexts["Parasite"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: timeout), "her ranking is empty")
        title.tap()

        XCTAssertTrue(
            app.navigationBars["Parasite"].waitForExistence(timeout: timeout),
            "tapping a title on somebody's ranking did not open it"
        )
    }

    /// The same tap, three pushes deep in a *different* stack.
    ///
    /// This is the case the test above cannot catch and the one that was
    /// actually broken: the Profile tab registered `PersonRoute` and
    /// `FollowListRoute` but no `TitleReference`, so a row that is a
    /// `NavigationLink` everywhere in the app was a link to nowhere here, and
    /// tapping a title did nothing at all. Nothing else in the suite goes
    /// looking — the view models are identical, and only the wiring differed.
    @MainActor
    func testTappingATitleOnAProfileOpenedFromTheProfileTab() throws {
        let app = launch()
        app.tabBars.buttons["Profile"].tap()

        let following = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Following")
        ).firstMatch
        XCTAssertTrue(following.waitForExistence(timeout: timeout), "no following count to tap")
        following.tap()

        // Asserted before looking for a row, so an empty list and a tap that
        // never pushed report as different failures rather than one confusing
        // one.
        XCTAssertTrue(
            app.navigationBars["Following"].waitForExistence(timeout: timeout),
            "tapping the following count did not push the list"
        )

        let person = app.staticTexts["@mina"].firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: timeout),
                      "the following list is empty\n\(app.debugDescription)")
        person.tap()
        XCTAssertTrue(app.navigationBars["@mina"].waitForExistence(timeout: timeout))

        let movies = app.buttons["Movies"].firstMatch
        XCTAssertTrue(movies.waitForExistence(timeout: timeout), "no ranking tab")
        movies.tap()

        let title = app.staticTexts["Parasite"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: timeout), "her ranking is empty")
        title.tap()

        XCTAssertTrue(
            app.navigationBars["Parasite"].waitForExistence(timeout: timeout),
            "a title tapped on a profile reached from the Profile tab did not open"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func openFeed(in app: XCUIApplication) {
        app.tabBars.buttons.firstMatch.tap()
        let following = app.buttons["Following"]
        XCTAssertTrue(following.waitForExistence(timeout: timeout), "no feed switcher")
        following.tap()
    }
}
