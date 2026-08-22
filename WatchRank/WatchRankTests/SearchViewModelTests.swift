//
//  SearchViewModelTests.swift
//  WatchRankTests
//
//  Exercises `SearchViewModel` against an in-memory stub `MediaService`:
//    1. no query → the pre-search prompt phase, no results
//    2. a matching query → results phase with the expected matches
//    3. a non-matching query → the no-results phase
//    4. clearing the query returns to the prompt phase
//    5. a throwing service surfaces the error phase
//    6. a stale slow search can't overwrite a newer query's results
//
//  Tests drive `search()` directly for determinism (it bypasses the debounce).
//  The suite is `@MainActor` because the view model is main-actor isolated.
//

import Foundation
import Testing
@testable import WatchRank

// MARK: - SearchViewModelTests

@Suite("SearchViewModel")
@MainActor
struct SearchViewModelTests {

    // MARK: Fixtures

    private func makeViewModel(
        service: MediaService
    ) -> SearchViewModel {
        SearchViewModel(service: service, debounce: .zero)
    }

    // MARK: Pre-search

    @Test("An empty query is the prompt phase with no results")
    func emptyQueryIsPrompt() {
        let vm = makeViewModel(service: StubMediaService())
        #expect(vm.phase == .prompt)
        #expect(vm.results.isEmpty)
    }

    @Test("A whitespace-only query stays in the prompt phase")
    func whitespaceQueryIsPrompt() async {
        let vm = makeViewModel(service: StubMediaService())
        vm.query = "   "
        await vm.search()
        #expect(vm.phase == .prompt)
        #expect(vm.results.isEmpty)
    }

    // MARK: Matching

    @Test("A partial match returns every matching title")
    func partialMatchReturnsMatches() async {
        let vm = makeViewModel(service: StubMediaService())
        vm.query = "Inter"
        await vm.search()
        #expect(vm.phase == .results)
        #expect(vm.results.count == 1)
        #expect(vm.results.first?.title == "Interstellar")
    }

    @Test("A shared substring returns several titles")
    func sharedSubstringReturnsSeveral() async {
        let vm = makeViewModel(service: StubMediaService())
        vm.query = "In" // Inception, Interstellar, and Break-in-g Bad
        await vm.search()
        #expect(vm.phase == .results)
        #expect(
            Set(vm.results.map(\.title))
                == ["Inception", "Interstellar", "Breaking Bad"]
        )
    }

    // MARK: No results

    @Test("A non-matching query is the no-results phase")
    func noMatchIsNoResults() async {
        let vm = makeViewModel(service: StubMediaService())
        vm.query = "zzz-nothing"
        await vm.search()
        #expect(vm.phase == .noResults)
        #expect(vm.results.isEmpty)
    }

    // MARK: Clearing

    @Test("Clearing the query returns to the prompt phase")
    func clearingReturnsToPrompt() async {
        let vm = makeViewModel(service: StubMediaService())
        vm.query = "Inception"
        await vm.search()
        #expect(vm.phase == .results)

        vm.query = ""
        #expect(vm.phase == .prompt)
        #expect(vm.results.isEmpty)
    }

    // MARK: Errors

    @Test("A throwing service surfaces the error phase")
    func throwingServiceIsError() async {
        let vm = makeViewModel(service: ThrowingMediaService())
        vm.query = "Inception"
        await vm.search()
        if case .error = vm.phase {
            #expect(vm.results.isEmpty)
        } else {
            Issue.record("Expected .error phase, got \(vm.phase)")
        }
    }

    // MARK: Staleness

    @Test("A slow search for an old query can't overwrite a newer one")
    func staleResultsAreDiscarded() async {
        // The service answers "Inception" slowly. We kick that off, then change
        // the query before it resolves — its late results must be dropped.
        let service = SlowMediaService(delay: .milliseconds(50))
        let vm = SearchViewModel(service: service, debounce: .zero)

        vm.query = "Inception"
        async let slow: Void = vm.search()

        vm.query = "Breaking"
        await vm.search()
        await slow

        #expect(vm.results.count == 1)
        #expect(vm.results.first?.title == "Breaking Bad")
    }

    // MARK: Debounce

    // Every test above passes `debounce: .zero` or calls `search()` directly,
    // so the code path a real keystroke takes — schedule, sleep, re-check for
    // cancellation, then search — had never executed. These use a real (short)
    // debounce with generous waits, since the point is the coalescing, not the
    // exact timing.

    @Test("Rapid keystrokes coalesce into a single search")
    func debounceCoalescesKeystrokes() async throws {
        let service = CountingMediaService()
        let vm = SearchViewModel(service: service, debounce: .milliseconds(60))

        for text in ["I", "In", "Inc", "Ince", "Incep"] {
            vm.query = text
        }
        #expect(service.callCount == 0, "the debounce fired before it had a chance to coalesce")

        try await Task.sleep(for: .milliseconds(600))

        #expect(
            service.callCount == 1,
            "expected one coalesced search, the service saw \(service.queries)"
        )
        #expect(service.queries.last == "Incep", "the search ran for a query the user had moved past")
    }

    @Test("A debounced search publishes results without an explicit submit")
    func debouncedSearchPublishesResults() async throws {
        let vm = SearchViewModel(service: StubMediaService(), debounce: .milliseconds(50))

        vm.query = "Interstellar"
        try await Task.sleep(for: .milliseconds(600))

        #expect(vm.phase == .results)
        #expect(vm.results.map(\.title) == ["Interstellar"])
    }

    @Test("Clearing the query cancels the search that was still pending")
    func clearingCancelsPendingSearch() async throws {
        let service = CountingMediaService()
        let vm = SearchViewModel(service: service, debounce: .milliseconds(60))

        vm.query = "Inception"
        vm.query = "" // cleared before the debounce elapsed

        try await Task.sleep(for: .milliseconds(600))

        #expect(service.callCount == 0, "a query the user had already cleared still reached the service")
        #expect(vm.phase == .prompt)
        #expect(vm.results.isEmpty)
    }

    // MARK: Cancellation

    @Test("A cancelled service call leaves the visible results alone")
    func cancellationLeavesResultsIntact() async {
        // A CancellationError means a newer search took over — it is not a
        // failure the user should see, and it must not blank the list.
        let service = CancellingMediaService(cancelling: "Breaking")
        let vm = SearchViewModel(service: service, debounce: .zero)

        vm.query = "Inception"
        await vm.search()
        #expect(vm.results.map(\.title) == ["Inception"])

        vm.query = "Breaking"
        await vm.search()

        #expect(vm.results.map(\.title) == ["Inception"], "a cancellation cleared the results")
        #expect(vm.errorMessage == nil, "a cancellation was surfaced to the user as an error")
    }

    // MARK: Error recovery

    @Test("A failed search recovers on the next successful one")
    func errorClearsOnNextSuccess() async {
        let service = SelectivelyFailingMediaService(failing: "Breaking")
        let vm = SearchViewModel(service: service, debounce: .zero)

        vm.query = "Breaking"
        await vm.search()
        guard case .error = vm.phase else {
            Issue.record("Expected .error phase, got \(vm.phase)")
            return
        }

        vm.query = "Inception"
        await vm.search()

        #expect(vm.errorMessage == nil, "the stale error outlived the query that caused it")
        #expect(vm.phase == .results)
        #expect(vm.results.map(\.title) == ["Inception"])
    }

    @Test("Clearing the query after an error returns to the prompt")
    func errorClearsWhenQueryIsCleared() async {
        let vm = SearchViewModel(service: ThrowingMediaService(), debounce: .zero)

        vm.query = "Inception"
        await vm.search()
        guard case .error = vm.phase else {
            Issue.record("Expected .error phase, got \(vm.phase)")
            return
        }

        vm.query = ""

        #expect(vm.phase == .prompt, "the error phase outranked an empty query")
        #expect(vm.errorMessage == nil)
    }

    // MARK: Loading flag

    @Test("A stale completion does not leave the loading flag stuck on")
    func staleCompletionSettlesTheLoadingFlag() async {
        // `runSearch` only lowers `isSearching` when the query it started with
        // is still current, on the theory that the newest search owns the flag.
        // That is a real hazard — `phase` reports `.searching` while the flag is
        // up — so the property worth pinning is that the flag always settles
        // once the newest search finishes, even if an older one lands late.
        let service = SlowMediaService(delay: .milliseconds(80))
        let vm = SearchViewModel(service: service, debounce: .zero)

        vm.query = "Inception"
        async let slow: Void = vm.search()
        vm.query = "Breaking" // the in-flight "Inception" search is now stale
        await vm.search()
        await slow

        #expect(!vm.isSearching, "the loading flag never settled after a stale completion")
        #expect(vm.results.map(\.title) == ["Breaking Bad"])
        #expect(vm.phase == .results)
    }
}
