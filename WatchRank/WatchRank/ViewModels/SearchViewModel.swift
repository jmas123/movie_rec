//
//  SearchViewModel.swift
//  WatchRank
//
//  Drives the Search screen: owns the live query, debounces input, and holds
//  the catalog results. Depends only on the `MediaService` protocol so the
//  same view model works against the mock today and a TMDB-backed service
//  later. Deliberately free of SwiftUI — UI binds to its observable state.
//

import Foundation
import Observation

// MARK: - SearchViewModel

@MainActor
@Observable
final class SearchViewModel {

    // MARK: Phase

    /// What the Search screen should render right now. Derived from the query
    /// and the in-flight search so the view never has to juggle booleans.
    enum Phase: Equatable {
        case prompt          // no query yet — show the pre-search empty state
        case searching       // a query is in flight with nothing to show yet
        case results         // `results` holds at least one match
        case noResults       // searched, but nothing matched
        case error(String)   // the service threw
    }

    // MARK: Input

    /// The live search text. Setting it (re)schedules a debounced search.
    var query: String = "" {
        didSet { scheduleSearch() }
    }

    // MARK: Output

    private(set) var results: [MediaItem] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    /// The single value the view switches on.
    var phase: Phase {
        if let errorMessage { return .error(errorMessage) }
        if trimmedQuery.isEmpty { return .prompt }
        if isSearching && results.isEmpty { return .searching }
        return results.isEmpty ? .noResults : .results
    }

    // MARK: Dependencies

    private let service: MediaService
    private let debounce: Duration

    // MARK: State

    private var searchTask: Task<Void, Never>?

    // MARK: Init

    /// - Parameters:
    ///   - service: catalog source (protocol, never the concrete mock).
    ///   - debounce: how long to wait after the last keystroke before
    ///     searching. Tests pass `.zero` for determinism.
    init(service: MediaService, debounce: Duration = .milliseconds(300)) {
        self.service = service
        self.debounce = debounce
    }

    // MARK: Searching

    /// Runs the current query immediately, bypassing the debounce. Used on
    /// explicit submit and by unit tests that need a deterministic result.
    func search() async {
        searchTask?.cancel()
        await runSearch()
    }

    /// Debounced entry point fired on every keystroke via `query`'s `didSet`.
    private func scheduleSearch() {
        searchTask?.cancel()

        guard !trimmedQuery.isEmpty else {
            reset()
            return
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.debounce)
            } catch {
                return // cancelled by a newer keystroke during the debounce
            }
            guard !Task.isCancelled else { return }
            await self.runSearch()
        }
    }

    /// The actual fetch. Guards against stale completions so a slow search for
    /// an earlier query can't overwrite results for what the user typed since.
    private func runSearch() async {
        let inFlight = trimmedQuery
        guard !inFlight.isEmpty else {
            reset()
            return
        }

        isSearching = true
        errorMessage = nil

        do {
            let found = try await service.search(query: inFlight)
            guard trimmedQuery == inFlight else { return } // user moved on
            results = found
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard trimmedQuery == inFlight else { return }
            results = []
            errorMessage = "Something went wrong. Pull to try again."
        }

        if trimmedQuery == inFlight {
            isSearching = false
        }
    }

    /// Clears all derived state — used when the query becomes empty.
    private func reset() {
        results = []
        isSearching = false
        errorMessage = nil
    }

    // MARK: Helpers

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
