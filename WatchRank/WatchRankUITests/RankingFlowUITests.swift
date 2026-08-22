//
//  RankingFlowUITests.swift
//  WatchRankUITests
//
//  The Phase 10 acceptance check, automated: cold launch → search → mark
//  watched → sentiment → pairwise comparison → the title shows up on Ranking.
//
//  Each test launches with `-uiTestingInMemoryStore`, so the app builds a
//  throwaway SwiftData store and every run starts from an empty library.
//
//  These tests name specific catalog titles rather than picking rows by index.
//  An earlier version read `app.cells.element(boundBy: 1)` right after typing,
//  which samples whatever the list is showing at that instant — on a loaded
//  machine that was still the previous query's rows, and the resulting failure
//  was misread as a genuine app bug. Waiting for a named title makes the test
//  fail only when the app is actually wrong.
//

import XCTest

final class RankingFlowUITests: XCTestCase {

    private let timeout: TimeInterval = 10

    /// Two titles that exist in `MockMedia.json` and match nothing else.
    private let firstTitle = "Inception"
    private let secondTitle = "Breaking Bad"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingInMemoryStore"]
        app.launch()
        return app
    }

    /// Searches for `query` and opens the row titled exactly `title`.
    ///
    /// Waits for *that title* rather than for "a cell to exist", so a list that
    /// has not re-rendered yet keeps the test waiting instead of handing it a
    /// stale row.
    @MainActor
    private func openResult(
        titled title: String,
        in app: XCUIApplication,
        query: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: timeout),
            "Search field never appeared", file: file, line: line
        )
        field.tap()

        // Clear whatever the previous search left behind.
        let clearButton = field.buttons.firstMatch
        if clearButton.exists { clearButton.tap() }
        field.typeText(query)

        let row = app.staticTexts[title]
        XCTAssertTrue(
            row.waitForExistence(timeout: timeout),
            "“\(title)” never appeared in the results for “\(query)”", file: file, line: line
        )
        row.tap()
    }

    /// Taps Mark Watched (or Change Rating), picks a sentiment, and confirms.
    @MainActor
    private func markWatched(
        _ app: XCUIApplication,
        sentiment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let markWatched = app.buttons["Mark Watched"]
        XCTAssertTrue(
            markWatched.waitForExistence(timeout: timeout),
            "No Mark Watched button", file: file, line: line
        )
        markWatched.tap()

        let sentimentButton = app.buttons[sentiment]
        XCTAssertTrue(
            sentimentButton.waitForExistence(timeout: timeout),
            "No \(sentiment) button", file: file, line: line
        )
        sentimentButton.tap()

        app.buttons["Rank it"].tap()
    }

    /// Answers every "Which did you prefer?" prompt by tapping the card whose
    /// accessibility label starts with `preferring`. Returns the number of taps.
    @MainActor
    @discardableResult
    private func answerComparisons(
        in app: XCUIApplication,
        preferring title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let prompt = app.staticTexts["Which did you prefer?"]
        guard prompt.waitForExistence(timeout: 3) else { return 0 }

        var taps = 0
        while prompt.exists {
            let card = app.buttons.containing(
                NSPredicate(format: "label BEGINSWITH %@", title)
            ).firstMatch
            guard card.waitForExistence(timeout: timeout) else { break }
            card.tap()
            taps += 1
            XCTAssertLessThan(taps, 10, "Comparison flow did not terminate", file: file, line: line)
        }
        return taps
    }

    /// Ranks `title` into the Liked bucket, answering any comparisons in favour
    /// of `preferring` (defaults to the item being ranked, floating it to #1).
    @MainActor
    @discardableResult
    private func rankLiked(
        _ title: String,
        in app: XCUIApplication,
        preferring: String? = nil
    ) -> Int {
        openResult(titled: title, in: app, query: title)
        markWatched(app, sentiment: "Liked it")
        return answerComparisons(in: app, preferring: preferring ?? title)
    }

    @MainActor
    private func goBackToSearch(in app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    // MARK: - Cold launch

    @MainActor
    func testColdLaunchShowsTabBarAndEmptyStates() throws {
        let app = launchApp()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: timeout), "No tab bar on launch")
        for tab in ["Home", "Search", "Ranking", "Profile"] {
            XCTAssertTrue(tabBar.buttons[tab].exists, "Missing \(tab) tab")
        }

        XCTAssertTrue(app.staticTexts["Nothing watched yet."].exists, "No empty state on Home")

        app.tabBars.buttons["Ranking"].tap()
        XCTAssertTrue(
            app.navigationBars["Ranking"].waitForExistence(timeout: timeout),
            "Ranking tab did not open"
        )
    }

    // MARK: - Golden path

    @MainActor
    func testMarkWatchedThroughComparisonLandsOnRanking() throws {
        let app = launchApp()
        app.tabBars.buttons["Search"].tap()

        // First title: the Liked bucket is empty, so no comparison is needed.
        rankLiked(firstTitle, in: app)
        XCTAssertTrue(
            app.staticTexts["#1 in “Liked it”"].waitForExistence(timeout: timeout),
            "First title did not land at rank 1"
        )

        // Second title: the bucket now has one item, so the comparison modal
        // must appear. Preferring the new item every time floats it to #1.
        goBackToSearch(in: app)
        let taps = rankLiked(secondTitle, in: app)
        XCTAssertGreaterThan(taps, 0, "Comparison modal never appeared for a non-empty bucket")
        XCTAssertTrue(
            app.staticTexts["#1 in “Liked it”"].waitForExistence(timeout: timeout),
            "Preferred title did not float to rank 1"
        )

        // Both titles are now on the Ranking screen.
        app.tabBars.buttons["Ranking"].tap()
        XCTAssertTrue(
            app.navigationBars["Ranking"].waitForExistence(timeout: timeout),
            "Ranking tab did not open"
        )
        XCTAssertTrue(
            app.staticTexts[secondTitle].waitForExistence(timeout: timeout),
            "“\(secondTitle)” missing from Ranking"
        )
        XCTAssertTrue(app.staticTexts[firstTitle].exists, "“\(firstTitle)” missing from Ranking")
    }

    // MARK: - Sheet choreography

    @MainActor
    func testCompletedComparisonKeepsItsEarnedPosition() throws {
        // MediaDetailView presents the Compare sheet with
        // `onDismiss: { library.cancelRanking(for: item) }`, so cancellation
        // runs on *every* dismissal — including a successful one. Nothing
        // rewinds the finished ranking only because `finalizeRanking` has
        // already torn the session down.
        //
        // If that interlock ever broke, the cancel path would re-insert the
        // item at the midpoint of a one-item bucket, i.e. #1. Ranking the
        // second title *below* the first and asserting #2 catches it.
        let app = launchApp()
        app.tabBars.buttons["Search"].tap()

        rankLiked(firstTitle, in: app)
        XCTAssertTrue(
            app.staticTexts["#1 in “Liked it”"].waitForExistence(timeout: timeout),
            "First title did not land at rank 1"
        )

        goBackToSearch(in: app)
        let taps = rankLiked(secondTitle, in: app, preferring: firstTitle)
        XCTAssertGreaterThan(taps, 0, "Comparison modal never appeared for a non-empty bucket")

        XCTAssertTrue(
            app.staticTexts["#2 in “Liked it”"].waitForExistence(timeout: timeout),
            "The completed comparison was overwritten — the sheet's onDismiss cancel path ran"
        )
    }
}
