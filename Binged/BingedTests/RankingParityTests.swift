//
//  RankingParityTests.swift
//  BingedTests
//
//  Proves the shipping bisection and the tested one are the same algorithm.
//
//  **The gap this closes.** `RankingEngine.insertionPosition` is what
//  `RankingEngineTests` proves correct, and it has *zero* production call
//  sites: `MediaLibraryViewModel` reimplements the bisection inline, spread
//  across `markWatched`, `applyComparisonChoice`, `midpointIndex` and
//  `finalizeRanking`, because the interactive flow has to pause on user input
//  and a closure-driven loop cannot. The reason is legitimate. The consequence
//  was not: the whole product rests on this mechanic, there were two
//  implementations of it, and the test suite guarded the one nobody runs.
//  `GAP-AUDIT.md` §5 records it as a standing risk.
//
//  Rather than unify them — which would mean either persisting a continuation
//  or making the engine stateful, both worse than the duplication — this file
//  pins them to each other. The engine stays the executable specification; if
//  the view model ever drifts from it, the difference shows up here as a
//  position that disagrees, not as a user's ranking quietly coming out wrong.
//
//  The sweep is exhaustive rather than sampled. Bucket sizes 0…12 crossed with
//  every position the newcomer could truly occupy is 91 insertions, which is
//  small enough to enumerate and is where off-by-one errors in a bisection
//  live — at the ends, and at the even/odd midpoint split.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - Oracle

/// A hidden total order over titles, which both implementations are asked to
/// discover through pairwise questions alone.
///
/// Keyed by `id` rather than by the stashed `rankInBucket` trick the engine's
/// own tests use, because `recomputeScores` overwrites `rankInBucket` — and
/// this suite runs the real flow, which rescores the bucket on every insertion.
/// The oracle has to survive that.
private struct PreferenceOracle {

    private var trueRank: [UUID: Int] = [:]

    mutating func declare(_ item: MediaItem, rank: Int) {
        trueRank[item.id] = rank
    }

    func rank(of item: MediaItem) -> Int { trueRank[item.id] ?? Int.max }

    /// The answer to "which did you prefer?" — lower true rank wins.
    func prefersLeft(_ left: MediaItem, over right: MediaItem) -> Bool {
        rank(of: left) < rank(of: right)
    }

    func comparison(_ left: MediaItem, _ right: MediaItem) -> RankingEngine.Comparison {
        prefersLeft(left, over: right) ? .preferLeft : .preferRight
    }
}

// MARK: - Tests

@MainActor
@Suite("Ranking parity — engine vs. shipping flow")
struct RankingParityTests {

    /// Drives the view model's session to completion against the oracle.
    /// - Returns: how many comparisons the user was asked.
    private func answerAll(
        vm: MediaLibraryViewModel,
        oracle: PreferenceOracle
    ) -> Int {
        var asked = 0
        // The bound is the guard, not a convenience: a bisection that fails to
        // narrow would otherwise hang the suite rather than fail it.
        while let pair = vm.pendingComparison, asked < 64 {
            asked += 1
            if oracle.prefersLeft(pair.newItem, over: pair.existingItem) {
                vm.applyComparisonChoice(winner: pair.newItem, loser: pair.existingItem)
            } else {
                vm.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
            }
        }
        return asked
    }

    // MARK: The parity sweep

    @Test("Every insertion lands where RankingEngine.insertionPosition says it should")
    func shippingFlowMatchesEngineExhaustively() throws {
        let engine = RankingEngine()

        // `size` is the bucket the newcomer is inserted into; `target` is the
        // position it truly deserves. Both ends included, so first-place and
        // last-place insertions are covered at every size.
        for size in 0...12 {
            for target in 0...size {
                let vm = MediaLibraryViewModel(modelContext: try makeContext())
                var oracle = PreferenceOracle()

                // Build the incumbent bucket through the real flow, so its
                // order is the product of actual comparisons rather than of
                // hand-set `rankInBucket` values.
                //
                // Incumbents are spaced 10 apart so the newcomer can be given a
                // true rank strictly between any two of them.
                for index in 0..<size {
                    let incumbent = makeItem("Incumbent \(index)")
                    oracle.declare(incumbent, rank: index * 10)
                    _ = vm.markWatched(incumbent, sentiment: .liked)
                    _ = answerAll(vm: vm, oracle: oracle)
                    vm.finalizeRanking(for: incumbent)
                }

                let before = vm.bucket(for: .liked, type: .movie)
                #expect(before.count == size)
                // The incumbents must already be in true order, or the parity
                // assertion below would be comparing against a broken bucket.
                let incumbentRanks = before.map { oracle.rank(of: $0) }
                let isSorted = incumbentRanks == incumbentRanks.sorted()
                #expect(isSorted, "incumbent bucket out of order at size \(size)")

                let newcomer = makeItem("Newcomer")
                // Sits just above whichever incumbent currently holds `target`.
                oracle.declare(newcomer, rank: target * 10 - 5)

                // The oracle answer, from the implementation the suite proves.
                let expected = engine.insertionPosition(
                    for: newcomer,
                    in: before,
                    comparator: { oracle.comparison($0, $1) }
                )

                // The shipping answer, from the implementation users run.
                _ = vm.markWatched(newcomer, sentiment: .liked)
                let asked = answerAll(vm: vm, oracle: oracle)
                vm.finalizeRanking(for: newcomer)

                let after = vm.bucket(for: .liked, type: .movie)
                let actual = after.firstIndex { $0.id == newcomer.id }

                #expect(
                    actual == expected,
                    "size \(size), target \(target): flow put it at \(actual as Int?), engine said \(expected)"
                )
                #expect(expected == target, "oracle disagreed with its own construction")
                #expect(after.count == size + 1)

                // CLAUDE.md rule 3. Asserted here as well as in the engine's own
                // tests because the *user-facing* count is the one produced by
                // this loop, not by the closure-driven one.
                #expect(asked <= ceilLog2(size + 1))
            }
        }
    }

    // MARK: Comparison count

    /// The progress label ("Comparison 2 of 3") promises a total up front, and
    /// the search has to respect it.
    ///
    /// **Only as an upper bound, deliberately.** A first attempt at this test
    /// asserted the flow always asks exactly as many questions as it promised,
    /// picking a dead-last newcomer as the presumed worst case. That is
    /// backwards: `lo = mid + 1` jumps the lower half, so a last-place insert
    /// is one of the *cheapest* paths — at size 2 it resolves in a single
    /// comparison against a promise of two. Binary insertion terminates as soon
    /// as `lo >= hi`, which happens early for plenty of targets.
    ///
    /// So the honest pair of properties is: the promise is never exceeded for
    /// any target, and it is *reached* by at least one — a bound that no input
    /// attains would be an inflated promise rather than a correct one. The
    /// user-visible consequence is that a session can end at "2 of 3", which is
    /// the mechanic being efficient, not a miscount.
    @Test("The promised comparison count bounds every path and is reached by one")
    func promisedStepsBoundEveryPathAndAreAttained() throws {
        for size in 1...12 {
            var promisedForSize: Int?
            var worstAsked = 0

            for target in 0...size {
                let vm = MediaLibraryViewModel(modelContext: try makeContext())
                var oracle = PreferenceOracle()

                for index in 0..<size {
                    let incumbent = makeItem("Incumbent \(index)")
                    oracle.declare(incumbent, rank: index * 10)
                    _ = vm.markWatched(incumbent, sentiment: .liked)
                    _ = answerAll(vm: vm, oracle: oracle)
                    vm.finalizeRanking(for: incumbent)
                }

                let newcomer = makeItem("Newcomer")
                oracle.declare(newcomer, rank: target * 10 - 5)

                let pairs = vm.markWatched(newcomer, sentiment: .liked)
                let promised = pairs.first?.totalSteps
                let asked = answerAll(vm: vm, oracle: oracle)
                vm.finalizeRanking(for: newcomer)

                #expect(promised == ceilLog2(size + 1))
                // The promise must hold for every target, not on average.
                #expect(asked <= (promised ?? 0), "size \(size), target \(target)")
                promisedForSize = promised
                worstAsked = max(worstAsked, asked)
            }

            #expect(
                worstAsked == promisedForSize,
                "size \(size): promised \(promisedForSize as Int?) but no target ever cost more than \(worstAsked)"
            )
        }
    }

    // MARK: Ties

    /// The engine has no notion of a tie, so this half of the flow has no
    /// oracle to check against — which is exactly why it is asserted directly.
    /// CLAUDE.md rule 7: a tie seats the newcomer *below* the incumbent it was
    /// weighed against, and costs fewer comparisons than a full answer.
    @Test("A tie seats the newcomer below the incumbent and ends the search early")
    func tieSeatsBelowAndEndsEarly() throws {
        for size in 1...12 {
            let vm = MediaLibraryViewModel(modelContext: try makeContext())
            var oracle = PreferenceOracle()

            for index in 0..<size {
                let incumbent = makeItem("Incumbent \(index)")
                oracle.declare(incumbent, rank: index * 10)
                _ = vm.markWatched(incumbent, sentiment: .liked)
                _ = answerAll(vm: vm, oracle: oracle)
                vm.finalizeRanking(for: incumbent)
            }

            let newcomer = makeItem("Newcomer")
            oracle.declare(newcomer, rank: 5)

            // Measured *before* `markWatched`, which provisionally seats the
            // newcomer at the bucket midpoint so it is never persisted
            // watched-but-unscored. Reading the bucket afterwards therefore
            // counts an item that has not been placed yet, and every index
            // below the midpoint shifts by one.
            let before = vm.bucket(for: .liked, type: .movie)

            let pairs = vm.markWatched(newcomer, sentiment: .liked)
            guard let first = pairs.first else {
                Issue.record("no comparison offered at size \(size)")
                continue
            }
            let weighedAgainst = first.existingItem
            let expectedBefore = before.firstIndex { $0.id == weighedAgainst.id }

            vm.applyComparisonTie()
            #expect(vm.pendingComparison == nil, "a tie must end the search")
            vm.finalizeRanking(for: newcomer)

            let after = vm.bucket(for: .liked, type: .movie)
            let incumbentIndex = after.firstIndex { $0.id == weighedAgainst.id }
            let newcomerIndex = after.firstIndex { $0.id == newcomer.id }

            #expect(incumbentIndex == expectedBefore)
            #expect(newcomerIndex == expectedBefore.map { $0 + 1 })
            #expect(after.count == size + 1)
        }
    }

    // MARK: Undo

    /// Undo rewinds the search rather than inverting it. Answering, taking it
    /// back, and answering the same way again must land in the same place as
    /// answering once — otherwise Undo silently changes the result.
    @Test("Undo then re-answer lands where answering once would have")
    func undoIsNeutralToTheOutcome() throws {
        // A smaller sweep than the parity test on purpose: undo neutrality is a
        // property of the bounds stack, not of bucket size, and each case here
        // costs two full library builds.
        for size in 1...8 {
            for target in 0...size {
                var positions: [Int?] = []

                for useUndo in [false, true] {
                    let vm = MediaLibraryViewModel(modelContext: try makeContext())
                    var oracle = PreferenceOracle()

                    for index in 0..<size {
                        let incumbent = makeItem("Incumbent \(index)")
                        oracle.declare(incumbent, rank: index * 10)
                        _ = vm.markWatched(incumbent, sentiment: .liked)
                        _ = answerAll(vm: vm, oracle: oracle)
                        vm.finalizeRanking(for: incumbent)
                    }

                    let newcomer = makeItem("Newcomer")
                    oracle.declare(newcomer, rank: target * 10 - 5)
                    _ = vm.markWatched(newcomer, sentiment: .liked)

                    var steps = 0
                    while let pair = vm.pendingComparison, steps < 64 {
                        steps += 1
                        let preferNew = oracle.prefersLeft(pair.newItem, over: pair.existingItem)
                        func answer() {
                            if preferNew {
                                vm.applyComparisonChoice(winner: pair.newItem, loser: pair.existingItem)
                            } else {
                                vm.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
                            }
                        }
                        answer()
                        if useUndo {
                            #expect(vm.canUndoComparison)
                            vm.undoLastComparison()
                            answer()
                        }
                    }

                    vm.finalizeRanking(for: newcomer)
                    positions.append(
                        vm.bucket(for: .liked, type: .movie).firstIndex { $0.id == newcomer.id }
                    )
                }

                #expect(
                    positions[0] == positions[1],
                    "size \(size), target \(target): undo changed the outcome"
                )
                #expect(positions[0] == target)
            }
        }
    }
}
