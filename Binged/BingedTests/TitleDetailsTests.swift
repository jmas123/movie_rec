//
//  TitleDetailsTests.swift
//  BingedTests
//
//  The detail screen's catalog payload: what TMDB's JSON becomes, and what it
//  refuses to become.
//
//  Two failure modes are worth guarding and neither shows up as a crash:
//
//  1. **A film's shape read as a series', or the reverse.** `credits` versus
//     `aggregate_credits`, `character` versus `roles`, director versus creator.
//     Get one wrong and the screen silently shows an empty cast for every show
//     in the catalog — a blank section looks like sparse metadata, which TMDB
//     genuinely has plenty of, so nobody investigates.
//
//  2. **Availability for the wrong country.** Watch providers are per region.
//     A lookup that falls back to whichever region happens to be first would
//     confidently tell a UK user a title is on a service that does not operate
//     there, which is worse than saying nothing.
//

import Foundation
import Testing

@testable import Binged

@Suite("Title details")
struct TitleDetailsTests {

    // MARK: - Fixtures

    /// A film with everything: tagline, runtime, backdrop, credits, providers.
    private static let movieJSON = """
    {
      "id": 496243,
      "title": "Parasite",
      "release_date": "2019-05-30",
      "overview": "A poor family schemes.",
      "poster_path": "/poster.jpg",
      "backdrop_path": "/backdrop.jpg",
      "tagline": "Act like you own the place.",
      "runtime": 132,
      "status": "Released",
      "original_language": "ko",
      "vote_average": 8.5,
      "vote_count": 17402,
      "genres": [{"id": 18, "name": "Drama"}],
      "credits": {
        "cast": [
          {"id": 1, "name": "Song Kang-ho", "order": 0, "character": "Ki-taek", "profile_path": "/a.jpg"},
          {"id": 2, "name": "Lee Sun-kyun", "order": 1, "character": "Mr. Park"}
        ],
        "crew": [
          {"id": 9, "name": "Bong Joon-ho", "job": "Director", "profile_path": "/d.jpg"},
          {"id": 10, "name": "Jung Jae-il", "job": "Original Music Composer"}
        ]
      },
      "watch/providers": {
        "results": {
          "US": {
            "link": "https://themoviedb.org/movie/496243/watch",
            "flatrate": [
              {"provider_id": 8, "provider_name": "Netflix", "logo_path": "/n.jpg", "display_priority": 2},
              {"provider_id": 15, "provider_name": "Hulu", "display_priority": 1}
            ],
            "rent": [{"provider_id": 2, "provider_name": "Apple TV", "display_priority": 0}]
          },
          "GB": {
            "link": "https://themoviedb.org/movie/496243/watch?locale=GB",
            "flatrate": [{"provider_id": 39, "provider_name": "NOW", "display_priority": 3}]
          }
        }
      }
    }
    """

    /// A series: aggregate credits, rolled-up roles, a creator, season counts.
    private static let seriesJSON = """
    {
      "id": 1396,
      "name": "Breaking Bad",
      "first_air_date": "2008-01-20",
      "overview": "A chemistry teacher turns to crime.",
      "episode_run_time": [49],
      "status": "Ended",
      "original_language": "en",
      "vote_average": 8.9,
      "vote_count": 12040,
      "number_of_seasons": 5,
      "number_of_episodes": 62,
      "created_by": [{"id": 66633, "name": "Vince Gilligan"}],
      "aggregate_credits": {
        "cast": [
          {
            "id": 17419, "name": "Bryan Cranston", "total_episode_count": 62,
            "roles": [
              {"character": "Walter White", "episode_count": 62},
              {"character": "Heisenberg", "episode_count": 3}
            ]
          },
          {
            "id": 84497, "name": "Aaron Paul", "total_episode_count": 60,
            "roles": [{"character": "Jesse Pinkman", "episode_count": 60}]
          }
        ]
      }
    }
    """

    private func decode(_ json: String) throws -> TMDBDetailDTO {
        try JSONDecoder().decode(TMDBDetailDTO.self, from: Data(json.utf8))
    }

    // MARK: - Film

    @Test("A film maps its scalar facts")
    func filmScalars() throws {
        let details = try decode(Self.movieJSON).makeTitleDetails(type: .movie, region: "US")

        #expect(details.tagline == "Act like you own the place.")
        #expect(details.runtimeMinutes == 132)
        #expect(details.runtimeText == "2h 12m")
        #expect(details.voteAverage == 8.5)
        #expect(details.voteCount == 17402)
        #expect(details.voteCountText == "17K")
        #expect(details.status == "Released")
        #expect(details.backdropURL?.contains("/backdrop.jpg") == true)
        // A film has no season counts even when the key would decode.
        #expect(details.seasonCount == nil)
        #expect(details.seasonText == nil)
    }

    @Test("A film credits its director, not its composer")
    func filmDirector() throws {
        let details = try decode(Self.movieJSON).makeTitleDetails(type: .movie, region: "US")

        #expect(details.directors.map(\.name) == ["Bong Joon-ho"])
        #expect(details.creditTitle(for: .movie) == "Director")
    }

    @Test("Film cast keeps billing order and characters")
    func filmCast() throws {
        let details = try decode(Self.movieJSON).makeTitleDetails(type: .movie, region: "US")

        #expect(details.cast.map(\.name) == ["Song Kang-ho", "Lee Sun-kyun"])
        #expect(details.cast.first?.role == "Ki-taek")
        #expect(details.cast.first?.imageURL?.contains("/a.jpg") == true)
        // No headshot in the payload — absent rather than a broken URL.
        #expect(details.cast.last?.imageURL == nil)
    }

    // MARK: - Series

    @Test("A series credits its creator and counts its seasons")
    func seriesShape() throws {
        let details = try decode(Self.seriesJSON).makeTitleDetails(type: .tvShow, region: "US")

        #expect(details.directors.map(\.name) == ["Vince Gilligan"])
        #expect(details.creditTitle(for: .tvShow) == "Creator")
        #expect(details.seasonCount == 5)
        #expect(details.episodeCount == 62)
        #expect(details.seasonText == "5 seasons · 62 episodes")
        // The representative episode length, not a film runtime.
        #expect(details.runtimeText == "49m")
    }

    @Test("A series orders cast by episode count and shows the most-seen role")
    func seriesCast() throws {
        let details = try decode(Self.seriesJSON).makeTitleDetails(type: .tvShow, region: "US")

        #expect(details.cast.map(\.name) == ["Bryan Cranston", "Aaron Paul"])
        // Not "Heisenberg", which is a three-episode credit on the same actor.
        #expect(details.cast.first?.role == "Walter White")
    }

    // MARK: - Watch providers

    @Test("Availability is read for the requested region only")
    func providersAreRegional() throws {
        let dto = try decode(Self.movieJSON)

        let us = dto.makeTitleDetails(type: .movie, region: "US")
        let gb = dto.makeTitleDetails(type: .movie, region: "GB")

        #expect(us.streamingProviders.map(\.name) == ["Hulu", "Netflix"])
        #expect(gb.streamingProviders.map(\.name) == ["NOW"])
        #expect(gb.providerLink?.hasSuffix("locale=GB") == true)
    }

    @Test("A region with no listing reports nothing rather than someone else's")
    func unlistedRegionIsEmpty() throws {
        let details = try decode(Self.movieJSON).makeTitleDetails(type: .movie, region: "JP")

        #expect(details.streamingProviders.isEmpty)
        #expect(details.providerLink == nil)
        // The rest of the payload still maps — an unavailable title is not a
        // failed fetch.
        #expect(details.runtimeMinutes == 132)
    }

    @Test("Rent and buy are excluded from the streaming row")
    func rentAndBuyExcluded() throws {
        let details = try decode(Self.movieJSON).makeTitleDetails(type: .movie, region: "US")
        let names = details.streamingProviders.map(\.name)

        #expect(!names.contains("Apple TV"))
    }

    @Test("Free and ad-supported count as streaming, deduplicated by provider")
    func freeAndAdsFoldIn() throws {
        let json = """
        {
          "id": 1, "title": "T", "watch/providers": { "results": { "US": {
            "flatrate": [{"provider_id": 8, "provider_name": "Netflix", "display_priority": 1}],
            "ads": [{"provider_id": 8, "provider_name": "Netflix", "display_priority": 1},
                    {"provider_id": 73, "provider_name": "Tubi", "display_priority": 5}],
            "free": [{"provider_id": 613, "provider_name": "Pluto TV", "display_priority": 3}]
          } } }
        }
        """
        let details = try decode(json).makeTitleDetails(type: .movie, region: "US")

        #expect(details.streamingProviders.map(\.name) == ["Netflix", "Pluto TV", "Tubi"])
    }

    // MARK: - Absence

    @Test("Empty strings are treated as missing, not printed")
    func emptyStringsBecomeNil() throws {
        let json = """
        {"id": 1, "title": "T", "tagline": "", "status": "  ", "original_language": "",
         "runtime": 0, "vote_average": 0, "backdrop_path": ""}
        """
        let details = try decode(json).makeTitleDetails(type: .movie, region: "US")

        #expect(details.tagline == nil)
        #expect(details.status == nil)
        #expect(details.originalLanguage == nil)
        #expect(details.languageName == nil)
        #expect(details.runtimeMinutes == nil)
        #expect(details.runtimeText == nil)
        #expect(details.voteAverage == nil)
        #expect(details.backdropURL == nil)
        #expect(details.isEmpty)
    }

    @Test("A payload with one usable fact is not empty")
    func oneFactIsEnough() throws {
        let details = try decode("""
        {"id": 1, "title": "T", "runtime": 94}
        """).makeTitleDetails(type: .movie, region: "US")

        #expect(!details.isEmpty)
    }

    // MARK: - Formatting

    @Test("Runtime reads as hours and minutes", arguments: [
        (45, "45m"), (60, "1h"), (94, "1h 34m"), (132, "2h 12m"), (201, "3h 21m"),
    ])
    func runtimeFormatting(minutes: Int, expected: String) {
        #expect(TitleDetails(runtimeMinutes: minutes).runtimeText == expected)
    }

    @Test("Vote counts are abbreviated once they stop being readable", arguments: [
        (0, nil), (873, "873"), (1_400, "1.4K"), (17_402, "17K"),
    ])
    func voteCountFormatting(count: Int, expected: String?) {
        #expect(TitleDetails(voteCount: count).voteCountText == expected)
    }

    @Test("A lone season or a lone episode count still reads")
    func partialSeasonText() {
        #expect(TitleDetails(seasonCount: 1).seasonText == "1 season")
        #expect(TitleDetails(episodeCount: 8).seasonText == "8 episodes")
        #expect(TitleDetails().seasonText == nil)
    }

    @Test("Several directors are pluralised")
    func pluralCredit() {
        let two = TitleDetails(directors: [
            .init(id: "1", name: "Joel Coen"),
            .init(id: "2", name: "Ethan Coen"),
        ])
        #expect(two.creditTitle(for: .movie) == "Directors")
        #expect(two.creditTitle(for: .tvShow) == "Creators")
    }

    // MARK: - Facts row

    @Test("The facts row draws nothing for a payload with no facts")
    func factsRowEmptiness() {
        #expect(!TitleFactsRow.hasFacts(TitleDetails(), type: .movie))
        #expect(TitleFactsRow.hasFacts(TitleDetails(runtimeMinutes: 94), type: .movie))
    }

    @Test("Status is shown only when it carries news")
    func statusIsFilteredToWhatMatters() {
        func statusFact(_ status: String, type: MediaType = .tvShow) -> String? {
            TitleFactsRow.facts(for: TitleDetails(status: status), type: type)
                .first { $0.id == "status" }?
                .text
        }

        // "Released" beside a year the screen already prints is noise.
        #expect(statusFact("Released", type: .movie) == nil)
        #expect(statusFact("Returning Series") == "Ongoing")
        #expect(statusFact("Ended") == "Ended")
        #expect(statusFact("Post Production") == "Not out yet")
    }

    // MARK: - Transport

    @Test("The display request asks for credits and providers on one round trip")
    func displayEndpointShape() throws {
        let film = try #require(TMDBEndpoint.detailForDisplay(type: .movie, tmdbId: 496243))
        let series = try #require(TMDBEndpoint.detailForDisplay(type: .tvShow, tmdbId: 1396))

        #expect(film.path == "/3/movie/496243")
        #expect(film.query?.contains("credits") == true)
        #expect(film.query?.contains("watch") == true)
        // Television needs the rolled-up credits, not an episode snapshot.
        #expect(series.query?.contains("aggregate_credits") == true)
    }

    @Test("The display payload is cached apart from the detail and feature ones")
    func cacheKeysAreDistinct() {
        let display = CatalogCacheKey.display(type: .movie, tmdbId: 1)
        let detail = CatalogCacheKey.detail(type: .movie, tmdbId: 1)
        let features = CatalogCacheKey.features(type: .movie, tmdbId: 1)

        #expect(display != detail)
        #expect(display != features)
        // And a film does not share a key with the series of the same id.
        #expect(display != CatalogCacheKey.display(type: .tvShow, tmdbId: 1))
    }

    @Test("A service with no detail payload answers nil rather than inventing one")
    func bundledCatalogHasNoDetails() async {
        let details = await MockMediaService(artificialDelay: .zero)
            .titleDetails(id: "tmdb:movie:1", region: "US")

        #expect(details == nil)
    }
}
