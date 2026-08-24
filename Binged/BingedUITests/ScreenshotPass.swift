//
//  ScreenshotPass.swift
//  BingedUITests
//
//  Not a test — a camera. Drives the app to the states Phase 11's manual smoke
//  test cares about and attaches a screenshot of each, so the visual half of
//  that phase can be reviewed without a person sitting at the simulator.
//
//  **This asserts almost nothing on purpose.** Its job is to produce pictures,
//  and a failed assertion halfway through produces fewer of them. The
//  behavioural assertions live in `RankingFlowUITests`; duplicating them here
//  would mean a real regression breaks the camera too, exactly when the
//  pictures would be most useful.
//
//  It exists because the one thing nobody had seen was the rank pill — the
//  "#2" shown in place of a score while a bucket is under five items, which
//  ranking rule 6 requires and which shipped tested-but-unlooked-at. Whether it
//  reads as a *different kind of claim* than the filled score pill beside it is
//  not something a unit test can answer.
//
//  Run it alone; it is skipped by the normal plans:
//    xcodebuild test -only-testing:BingedUITests/ScreenshotPass
//

import XCTest

final class ScreenshotPass: XCTestCase {

    private let timeout: TimeInterval = 15

    override func setUpWithError() throws {
        // The opposite of the usual setting. A tap that misses should cost one
        // blank frame, not the rest of the roll.
        continueAfterFailure = true
    }

    // MARK: - Camera

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways // survives a passing run, which is the point
        add(shot)
    }

    // MARK: - Pass

    @MainActor
    func testCaptureTheScreensPhase11CaresAbout() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingInMemoryStore"]
        app.launch()

        // 1. Cold launch, empty library: every rail is an empty state at once.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: timeout))
        capture(app, "01-Home-empty")

        app.tabBars.buttons["Ranking"].tap()
        capture(app, "02-Ranking-empty")

        app.tabBars.buttons["Search"].tap()
        capture(app, "03-Search-prompt")

        // 2. Rank two films into Liked, so the bucket holds 2 of the 5 it needs.
        //    This is the state the rank pill exists for.
        rank("Inception", in: app)
        capture(app, "04-Detail-first-title-sentiment-only")

        goBackToSearch(in: app)
        rank("Parasite", in: app)
        capture(app, "05-Detail-second-title-with-position")

        // 3. The screen this whole exercise is for: a list of ranked rows whose
        //    bucket has not earned a score, showing "#1"/"#2" where the filled
        //    score pill would otherwise be.
        app.tabBars.buttons["Ranking"].tap()
        XCTAssertTrue(app.navigationBars["Ranking"].waitForExistence(timeout: timeout))
        capture(app, "06-Ranking-rank-pills-under-threshold")

        // Movies tab: the only place drag-to-reorder is offered, and the tab
        // whose Edit button rule 5 governs.
        app.buttons["Movies"].firstMatch.tap()
        capture(app, "07-Ranking-movies-tab")

        // 4. Home with content, and Profile.
        app.tabBars.buttons.firstMatch.tap()
        capture(app, "08-Home-populated")

        if app.tabBars.buttons["Profile"].exists {
            app.tabBars.buttons["Profile"].tap()
            capture(app, "09-Profile")
        }
    }

    // MARK: - Navigation

    @MainActor
    private func rank(_ title: String, in app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: timeout) else { return }
        field.tap()
        let clear = field.buttons.firstMatch
        if clear.exists { clear.tap() }
        field.typeText(title)

        let row = app.staticTexts[title]
        guard row.waitForExistence(timeout: timeout) else { return }
        row.tap()

        let markWatched = app.buttons["Mark Watched"]
        guard markWatched.waitForExistence(timeout: timeout) else { return }
        markWatched.tap()

        let sentiment = app.buttons["Liked it"]
        guard sentiment.waitForExistence(timeout: timeout) else { return }
        sentiment.tap()
        app.buttons["Rank it"].tap()

        // Answer any comparisons in favour of the incumbent, so the newcomer
        // lands at #2 and the two pills sit next to each other in the list.
        let prompt = app.staticTexts["Which did you prefer?"]
        if prompt.waitForExistence(timeout: 3) {
            capture(app, "04a-Compare-modal")
            var taps = 0
            while prompt.exists && taps < 10 {
                let card = app.buttons.containing(
                    NSPredicate(format: "label BEGINSWITH %@", "Inception")
                ).firstMatch
                guard card.waitForExistence(timeout: timeout) else { break }
                card.tap()
                taps += 1
            }
        }
    }

    @MainActor
    private func goBackToSearch(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
    }
}
