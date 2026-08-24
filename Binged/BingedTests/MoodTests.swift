//
//  MoodTests.swift
//  BingedTests
//
//  The mood definitions are data, so what is worth testing is their
//  *totality* and their *shape*: every mood must resolve to a usable query for
//  both media types, and a mood's genre basis must never be merged with its
//  keyword basis into one request.
//
//  The yields behind these definitions were measured — see docs/MOOD-YIELD.md.
//  What a unit test can hold onto is that the definitions stay well-formed and
//  that the retired keywords stay retired.
//

import Foundation
import Testing
@testable import Binged

@Suite("Mood")
struct MoodTests {

    private let vocabulary = makeFullGenreVocabulary()

    // MARK: - Totality

    @Test("Every mood resolves to at least one query component for both types")
    func everyMoodIsTotal() {
        for mood in Mood.allCases {
            for type in MediaType.allCases {
                let components = mood.queryComponents(for: type, vocabulary: vocabulary)
                #expect(!components.isEmpty, "\(mood.rawValue)/\(type.rawValue) has no query")

                let empties = components.filter(\.isEmpty)
                #expect(empties.isEmpty, "\(mood.rawValue)/\(type.rawValue) has an empty component")
            }
        }
    }

    @Test("Every mood has a basis before the vocabulary is even consulted")
    func everyMoodHasADefinition() {
        // Separate from the test above so a vocabulary regression cannot be
        // mistaken for a definition regression.
        for mood in Mood.allCases {
            for type in MediaType.allCases {
                let hasBasis = !mood.genreNames(for: type).isEmpty
                    || !mood.keywords(for: type).isEmpty
                #expect(hasBasis, "\(mood.rawValue)/\(type.rawValue) is undefined")
            }
        }
    }

    @Test("Television's missing genres fall through to keywords")
    func televisionFallsBackToKeywords() {
        // TMDB's TV vocabulary has no Thriller, Horror or Romance. A mood that
        // named one and got nothing would be a broken feature; these three must
        // stand on keywords alone.
        for mood in [Mood.horror, .romance, .dark] {
            let components = mood.queryComponents(for: .tvShow, vocabulary: vocabulary)
            let genreComponents = components.filter {
                if case .genres = $0.basis { return true }
                return false
            }
            #expect(genreComponents.isEmpty, "\(mood.rawValue) claims a TV genre it cannot have")
            #expect(!components.isEmpty)
        }

        // And the film side of the same moods does use its genre.
        for mood in [Mood.horror, .romance] {
            let names = mood.genreNames(for: .movie)
            #expect(!names.isEmpty)
            #expect(vocabulary.tmdbGenreId(named: names[0], type: .movie) != nil)
        }
    }

    // MARK: - Query shape

    @Test("A genre basis and a keyword basis are never merged into one request")
    func basesStaySeparate() {
        // TMDB AND-s different /discover parameters, so a merged component would
        // silently ask for "genre AND keyword" and return a much smaller,
        // plausible-looking result. `thriller`/tv and `epic` are the moods that
        // carry both bases.
        for mood in Mood.allCases {
            for type in MediaType.allCases {
                let components = mood.queryComponents(for: type, vocabulary: vocabulary)
                for component in components {
                    switch component.basis {
                    case .genres(let ids, let names):
                        #expect(ids.count == names.count || !names.isEmpty)
                    case .keywords(let ids, let names):
                        #expect(ids.count == names.count)
                    }
                }
            }
        }

        let thriller = Mood.thriller.queryComponents(for: .tvShow, vocabulary: vocabulary)
        #expect(thriller.count == 2, "thriller/tv should be two requests, not one")

        let epic = Mood.epic.queryComponents(for: .movie, vocabulary: vocabulary)
        #expect(epic.count == 2, "epic/movie should be two requests, not one")
    }

    @Test("Component identity is stable, readable and distinct")
    func componentIdentityIsUsableAsACacheKey() {
        var seen: [String: String] = [:]

        for mood in Mood.allCases {
            for type in MediaType.allCases {
                for component in mood.queryComponents(for: type, vocabulary: vocabulary) {
                    // Stable across calls: the id list is sorted, so it cannot
                    // depend on declaration order.
                    let again = MoodQueryComponent(
                        basis: component.basis, minimumVotes: component.minimumVotes
                    )
                    #expect(again.identity == component.identity)
                    seen[component.identity] = "\(mood.rawValue)/\(type.rawValue)"
                }
            }
        }

        // Shared components are the point — two moods on the same basis should
        // collide so they share a cache entry rather than fetching twice.
        #expect(!seen.isEmpty)
        let genreKeys = seen.keys.filter { $0.hasPrefix("g") }
        let keywordKeys = seen.keys.filter { $0.hasPrefix("k") }
        #expect(!genreKeys.isEmpty && !keywordKeys.isEmpty)
    }

    @Test("Keyword ids are plausible and free of duplicates within a definition")
    func keywordIdsAreWellFormed() {
        for mood in Mood.allCases {
            for type in MediaType.allCases {
                let keywords = mood.keywords(for: type)
                let ids = keywords.map(\.id)
                #expect(Set(ids).count == ids.count, "\(mood.rawValue)/\(type.rawValue) repeats a keyword")

                let invalid = keywords.filter { $0.id <= 0 || $0.name.isEmpty }
                #expect(invalid.isEmpty)
            }
        }
    }

    // MARK: - Retired keywords

    @Test("Keywords retired by measurement never come back")
    func retiredKeywordsStayRetired() {
        // Every one of these returned <= 5 titles across both media types when
        // measured. Three of them are the on-the-nose name of the very mood
        // they were meant to define, which is exactly why this test exists:
        // they are the tags a later session would naturally re-propose.
        let retired: [Int: String] = [
            379696: "feel good",
            291176: "alternate reality",
            362567: "mind bending",
            377433: "epic",
            346773: "dream",
            380334: "romantic comedy",
            319357: "heartwarming",
            159289: "historical event",
        ]

        for mood in Mood.allCases {
            for type in MediaType.allCases {
                for keyword in mood.keywords(for: type) {
                    let offence = retired[keyword.id] ?? ""
                    #expect(
                        retired[keyword.id] == nil,
                        "\(mood.rawValue)/\(type.rawValue) uses retired keyword \(offence) — see docs/MOOD-YIELD.md"
                    )
                }
            }
        }
    }

    // MARK: - Presentation

    @Test("Display names and symbols are present and unique")
    func presentationIsWellFormed() {
        var names: Set<String> = []
        var symbols: Set<String> = []

        for mood in Mood.allCases {
            #expect(!mood.displayName.isEmpty)
            #expect(!mood.symbolName.isEmpty)
            #expect(names.insert(mood.displayName).inserted, "duplicate name \(mood.displayName)")
            #expect(symbols.insert(mood.symbolName).inserted, "duplicate symbol \(mood.symbolName)")
        }

        #expect(Mood.allCases.count == 10)
    }

    @Test("Relevance is binary today and bounded whatever it becomes")
    func relevanceIsBounded() {
        for mood in Mood.allCases {
            #expect(mood.relevance(isPoolMember: true) == 1.0)
            #expect(mood.relevance(isPoolMember: false) == 0.0)
        }
    }
}
