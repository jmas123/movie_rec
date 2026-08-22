//
//  CompareViewModelTests.swift
//  WatchRankTests
//
//  Drives `CompareViewModel` end-to-end against a real `MediaLibraryViewModel`
//  backed by an in-memory SwiftData store. Because the VM delegates the binary
//  search to the library VM, these tests verify the integration:
//    - the user makes at most ceil(log2(N + 1)) decisions
//    - a deterministic comparator lands the item at the expected position
//    - cancellation places the item at the bucket midpoint, never unranked
//    - progress reporting reflects the current step / total
//

import Foundation
import SwiftData
import Testing
@testable import WatchRank

// MARK: - Tests

@MainActor
@Suite("CompareViewModel")
struct CompareViewModelTests {

    // MARK: decision-count bound + bottom placement

    @Test(
        "Preferring the existing item every time sinks the candidate to the bottom in ≤ ceil(log2(N+1)) taps",
        arguments: [1, 2, 3, 4, 7, 8, 15]
    )
    func candidateSinksToBottom(n: Int) throws {
        let library = try makeLibrary()
        seedLikedBucket(vm: library, count: n)

        let candidate = makeItem("Candidate")
        library.markWatched(candidate, sentiment: .liked)
        let vm = CompareViewModel(newItem: candidate, library: library)

        var decisions = 0
        while let pair = vm.currentPair {
            vm.choose(pair.existingItem) // always prefer the existing item
            decisions += 1
        }

        #expect(vm.isFinished)
        #expect(decisions <= ceilLog2(n + 1))

        let bucket = library.bucket(for: .liked, type: .movie)
        #expect(bucket.count == n + 1)
        #expect(bucket.last?.id == candidate.id)
        #expect(candidate.rankInBucket == n)
    }

    // MARK: top placement

    @Test(
        "Preferring the candidate every time floats it to the top",
        arguments: [1, 2, 3, 4, 7]
    )
    func candidateFloatsToTop(n: Int) throws {
        let library = try makeLibrary()
        seedLikedBucket(vm: library, count: n)

        let candidate = makeItem("Candidate")
        library.markWatched(candidate, sentiment: .liked)
        let vm = CompareViewModel(newItem: candidate, library: library)

        var decisions = 0
        while let pair = vm.currentPair {
            vm.choose(pair.newItem) // always prefer the new item
            decisions += 1
        }

        #expect(vm.isFinished)
        #expect(decisions <= ceilLog2(n + 1))

        let bucket = library.bucket(for: .liked, type: .movie)
        #expect(bucket.first?.id == candidate.id)
        #expect(candidate.rankInBucket == 0)
    }

    // MARK: cancellation → midpoint

    @Test("Cancelling places the candidate at the bucket midpoint, fully scored")
    func cancelPlacesAtMidpoint() throws {
        let n = 4
        let library = try makeLibrary()
        seedLikedBucket(vm: library, count: n)

        let candidate = makeItem("Candidate")
        library.markWatched(candidate, sentiment: .liked)
        let vm = CompareViewModel(newItem: candidate, library: library)

        vm.cancel()

        #expect(vm.isFinished)
        #expect(vm.currentPair == nil)

        let bucket = library.bucket(for: .liked, type: .movie)
        #expect(bucket.count == n + 1)
        #expect(candidate.rankInBucket == n / 2) // inserted at midpoint index
        for item in bucket {
            #expect(item.score != nil)
        }
    }

    @Test("Cancelling after the search already resolved is a harmless no-op")
    func cancelAfterFinishIsNoOp() throws {
        let library = try makeLibrary()
        seedLikedBucket(vm: library, count: 3)

        let candidate = makeItem("Candidate")
        library.markWatched(candidate, sentiment: .liked)
        let vm = CompareViewModel(newItem: candidate, library: library)

        while let pair = vm.currentPair {
            vm.choose(pair.existingItem)
        }
        let positionAfterFinish = candidate.rankInBucket

        vm.cancel() // should not move anything
        #expect(candidate.rankInBucket == positionAfterFinish)
        #expect(library.bucket(for: .liked, type: .movie).count == 4)
    }

    // MARK: empty bucket → nothing to compare

    @Test("With an empty bucket there is no pending comparison and the VM is already finished")
    func emptyBucketFinishesImmediately() throws {
        let library = try makeLibrary()

        let solo = makeItem("Solo")
        library.markWatched(solo, sentiment: .liked) // empty bucket → auto-finalized
        let vm = CompareViewModel(newItem: solo, library: library)

        #expect(vm.isFinished)
        #expect(vm.currentPair == nil)
    }

    // MARK: progress reporting

    @Test("Progress text reports the current step out of the worst-case bound")
    func progressTextReflectsStepAndTotal() throws {
        let n = 3
        let library = try makeLibrary()
        seedLikedBucket(vm: library, count: n)

        let candidate = makeItem("Candidate")
        library.markWatched(candidate, sentiment: .liked)
        let vm = CompareViewModel(newItem: candidate, library: library)

        #expect(vm.progressText == "Comparison 1 of \(ceilLog2(n + 1))")
        #expect(vm.progressFraction == 0)
    }
}
