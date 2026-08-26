//
//  recommender_eval.swift
//  Binged — dev tooling, not app code.
//
//  Offline evaluation of the recommender against real ratings. See
//  docs/RECOMMENDER-EVALUATION.md for what it measures and what it does not.
//
//  It compiles **the app's own engines** and calls them; nothing here
//  reimplements a model. The sweep recombines the same layers so a constant can
//  be varied without editing the app, and every run asserts that recombination
//  agrees with `HybridRecommendationEngine.predict` to 1e-9 — that check is what
//  keeps the harness honest as the engine changes.
//
//  Build and run through scripts/eval/run.sh.
//

import Foundation

// MARK: - Fixture

struct RatingRow: Decodable {
    let user: Int
    let ratings: [[Double]]   // [tmdbId, stars]
}

let evalDir = ProcessInfo.processInfo.environment["EVAL_DIR"]
    ?? FileManager.default.currentDirectoryPath
let splitSeed = UInt64(ProcessInfo.processInfo.environment["SPLIT_SEED"] ?? "1") ?? 1
let outputName = ProcessInfo.processInfo.environment["OUT_NAME"] ?? "results.json"

func load<T: Decodable>(_ name: String, as type: T.Type) -> T {
    let url = URL(fileURLWithPath: evalDir).appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url) else {
        fatalError("missing \(name) — run scripts/eval/fetch_movielens_fixture.py first")
    }
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { fatalError("decode \(name): \(error)") }
}

let rawTitles = load("titles.json", as: [String: TMDBDetailDTO].self)
let userRows = load("users.json", as: [RatingRow].self)

// MARK: - Catalog

/// One title, reduced to what a library entry needs. Features come from the
/// app's own extraction, so the evaluation sees the production key space.
struct CatalogEntry {
    let title: String
    let year: Int
    let overview: String
    let featureKeys: [String]
    let voteAverage: Double?
    let voteCount: Int?
}

let catalog: [Int: CatalogEntry] = {
    var out: [Int: CatalogEntry] = [:]
    for (key, dto) in rawTitles {
        guard let id = Int(key) else { continue }
        out[id] = CatalogEntry(
            title: dto.title ?? dto.name ?? "",
            year: Int((dto.releaseDate ?? "").prefix(4)) ?? 0,
            overview: dto.overview ?? "",
            featureKeys: dto.features(type: .movie, vocabulary: .empty).keys,
            voteAverage: dto.voteAverage,
            voteCount: dto.voteCount
        )
    }
    return out
}()

// MARK: - Library construction

/// MovieLens stars to a Binged sentiment. Applied identically to every model
/// under test, so a different reading of the scale moves all of them together.
func sentiment(forStars stars: Double) -> Sentiment {
    if stars >= 4.0 { return .liked }
    if stars >= 3.0 { return .fine }
    return .disliked
}

struct Entry {
    let tmdbId: Int
    let stars: Double
    let entry: CatalogEntry
}

/// Deterministic split, seeded per user, so a re-run measures the same thing.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func makeItem(_ e: Entry, sentiment: Sentiment?, score: Double?) -> MediaItem {
    MediaItem(
        externalId: "tmdb:movie:\(e.tmdbId)",
        title: e.entry.title,
        year: e.entry.year,
        type: .movie,
        overview: e.entry.overview,
        features: e.entry.featureKeys,
        tmdbVoteAverage: e.entry.voteAverage,
        tmdbVoteCount: e.entry.voteCount,
        watchedStatus: score == nil ? .wantToWatch : .watched,
        sentiment: sentiment,
        score: score
    )
}

/// Ranks rated titles the way the app would: one bucket per sentiment, ordered
/// by the user's own preference, scores derived from position.
func rank(_ entries: [Entry]) -> [(Entry, Sentiment, Double)] {
    var out: [(Entry, Sentiment, Double)] = []
    for (bucket, members) in Dictionary(grouping: entries, by: { sentiment(forStars: $0.stars) }) {
        let ordered = members.sorted {
            $0.stars != $1.stars ? $0.stars > $1.stars : $0.tmdbId < $1.tmdbId
        }
        let scores = RankingEngine.scores(count: ordered.count, range: bucket.scoreRange)
        for (index, member) in ordered.enumerated() { out.append((member, bucket, scores[index])) }
    }
    return out
}

// MARK: - Metrics

func spearman(_ a: [Double], _ b: [Double]) -> Double? {
    guard a.count == b.count, a.count >= 5 else { return nil }
    return Ranks.spearman(a, b)
}

func ndcg(predicted: [Double], truth: [Double], k: Int = 10) -> Double? {
    guard predicted.count == truth.count, predicted.count >= k else { return nil }
    // Gain is stars above the "it was fine" line: a good evening, not merely a
    // title the user finished.
    let gains = truth.map { max(0, $0 - 3.0) }
    guard gains.reduce(0, +) > 0 else { return nil }
    func dcg(_ order: [Int]) -> Double {
        order.prefix(k).enumerated().reduce(0) { $0 + gains[$1.element] / log2(Double($1.offset + 2)) }
    }
    let byPrediction = predicted.enumerated().sorted { $0.element > $1.element }.map(\.offset)
    let ideal = gains.enumerated().sorted { $0.element > $1.element }.map(\.offset)
    let best = dcg(ideal)
    return best > 0 ? dcg(byPrediction) / best : nil
}

func precisionAtK(predicted: [Double], truth: [Double], k: Int = 10) -> Double? {
    guard predicted.count >= k else { return nil }
    let top = predicted.enumerated().sorted { $0.element > $1.element }.prefix(k).map(\.offset)
    return Double(top.filter { truth[$0] >= 4.0 }.count) / Double(k)
}

func mae(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
}

// MARK: - Configurations

struct Config {
    let name: String
    /// Ceiling on the crowd term. With `adaptiveCrowd`, the effective weight is
    /// this times the user's agreement with the crowd.
    let crowdWeight: Double
    let crowdPriorVotes: Double
    let adaptiveCrowd: Bool
    /// `false` drops the sentiment layer and predicts from the content model
    /// alone — the v1 model.
    let usesSentimentLayer: Bool
    /// Weight on the content model's residual from its type baseline.
    let contentGain: Double
}

func makeConfigs() -> [Config] {
    var out: [Config] = []
    func add(_ name: String, crowd: Double = 0, prior: Double = 500,
             adaptive: Bool = false, sentimentLayer: Bool = true, contentGain: Double = 1) {
        out.append(Config(name: name, crowdWeight: crowd, crowdPriorVotes: prior,
                          adaptiveCrowd: adaptive, usesSentimentLayer: sentimentLayer,
                          contentGain: contentGain))
    }
    add("content", sentimentLayer: false)
    add("sentiment", contentGain: 0)
    for crowd in [0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.50, 0.60] {
        add("content+crowd\(crowd)", crowd: crowd, sentimentLayer: false)
        add("sent+content+crowd\(crowd)", crowd: crowd)
    }
    for maximum in [0.35, 0.50, 0.70, 1.00] {
        add("adaptive content w=\(maximum)", crowd: maximum, adaptive: true, sentimentLayer: false)
        add("adaptive sent+content w=\(maximum)", crowd: maximum, adaptive: true)
    }
    for prior in [0.0, 100.0, 2000.0] {
        add("final prior=\(prior)", crowd: 1.0, prior: prior, adaptive: true)
    }
    return out
}

let configs = makeConfigs()

// MARK: - Evaluation

struct UserResult: Encodable {
    let user: Int
    let library: Int
    let held: Int
    let likedShare: Double
    var agreement: Double = 0
    var metrics: [String: [String: Double]] = [:]
}

let contentEngine = RecommendationEngine()
let sentimentEngine = SentimentRecommendationEngine()
let engine = HybridRecommendationEngine()

func evaluate(_ row: RatingRow) -> (UserResult, Int)? {
    let entries: [Entry] = row.ratings.compactMap { pair in
        guard let entry = catalog[Int(pair[0])] else { return nil }
        return Entry(tmdbId: Int(pair[0]), stars: pair[1], entry: entry)
    }
    guard entries.count >= 30 else { return nil }

    var rng = SplitMix(seed: UInt64(row.user) &* splitSeed &+ splitSeed)
    let shuffled = entries.shuffled(using: &rng)
    let heldCount = max(10, shuffled.count / 4)
    let held = Array(shuffled.prefix(heldCount))
    let train = Array(shuffled.dropFirst(heldCount))
    guard train.count >= 20, held.count >= 10 else { return nil }

    let trainItems = rank(train).map { makeItem($0.0, sentiment: $0.1, score: $0.2) }
    // Truth for a held-out title: the score the app would derive for it once the
    // whole library is ranked.
    let fullScores = Dictionary(uniqueKeysWithValues: rank(entries).map { ($0.0.tmdbId, $0.2) })

    let profile = engine.buildProfile(from: trainItems)
    let agreementPairs = trainItems.compactMap { item -> (Double, Double)? in
        guard let score = item.score, let average = item.tmdbVoteAverage, average > 0
        else { return nil }
        return (score, average)
    }
    let agreement = Ranks.spearman(agreementPairs.map(\.0), agreementPairs.map(\.1)) ?? 0

    let truthStars = held.map(\.stars)
    let truthScores = held.map { fullScores[$0.tmdbId] ?? 5 }
    let heldItems = held.map { makeItem($0, sentiment: nil, score: nil) }
    let heldFeatures = heldItems.map(CandidateFeatures.init)

    var failures = 0
    var result = UserResult(
        user: row.user,
        library: train.count,
        held: held.count,
        likedShare: Double(held.filter { $0.stars >= 4 }.count) / Double(held.count)
    )
    result.agreement = agreement

    func record(_ name: String, _ predictions: [Double]) {
        var metrics: [String: Double] = [
            "mae": mae(predictions, truthScores),
            "spread": (predictions.max() ?? 0) - (predictions.min() ?? 0),
        ]
        if let rho = spearman(predictions, truthStars) { metrics["spearman"] = rho }
        if let value = ndcg(predicted: predictions, truth: truthStars) { metrics["ndcg10"] = value }
        if let value = precisionAtK(predicted: predictions, truth: truthStars) { metrics["p10"] = value }
        let liked = truthStars.indices.filter { truthStars[$0] >= 4 }
        if liked.count >= 8,
           let rho = spearman(liked.map { predictions[$0] }, liked.map { truthStars[$0] }) {
            metrics["likedRho"] = rho
        }
        result.metrics[name] = metrics
    }

    // Nulls.
    let modal = Sentiment.allCases.max { first, second in
        train.filter { sentiment(forStars: $0.stars) == first }.count
            < train.filter { sentiment(forStars: $0.stars) == second }.count
    } ?? .liked
    let midpoint = (modal.scoreRange.lowerBound + modal.scoreRange.upperBound) / 2
    record("null(modal)", Array(repeating: midpoint, count: held.count))
    record("crowd only", held.map { $0.entry.voteAverage ?? 5 })

    // The shipped engine, called exactly as the app calls it.
    let shipped = zip(heldItems, heldFeatures).map { item, features in
        engine.predict(item: item, features: features, using: profile).value
    }
    record("engine", shipped)

    for config in configs {
        var predictions: [Double] = []
        predictions.reserveCapacity(held.count)
        for (offset, item) in heldItems.enumerated() {
            let features = heldFeatures[offset]
            let content = contentEngine.predict(features, using: profile.content)
            var personal: Double
            if config.usesSentimentLayer {
                personal = sentimentEngine.predict(features, using: profile.sentiment).score
                    + config.contentGain
                    * (content.value - profile.content.baseline(for: item.type))
            } else {
                personal = content.value
            }

            var weight = config.crowdWeight
            if config.adaptiveCrowd { weight *= min(1, max(0, agreement)) }

            var value = personal
            if weight > 0,
               let average = item.tmdbVoteAverage, average > 0,
               let count = item.tmdbVoteCount, count > 0 {
                let prior = profile.crowdMeanByType[item.type] ?? average
                let n = Double(count)
                let adjusted = (n * average + config.crowdPriorVotes * prior)
                    / (n + config.crowdPriorVotes)
                value = (1 - weight) * personal + weight * adjusted
            }
            predictions.append(min(10, max(0, value)))
        }
        record(config.name, predictions)

        // The production model is `adaptive sent+content w=1.0`. If the two ever
        // disagree, the sweep is measuring something the app does not do.
        if config.name == "adaptive sent+content w=1.0",
           agreementPairs.count >= CrowdAgreement.minimumSample {
            for (a, b) in zip(predictions, shipped) where abs(a - b) > 1e-9 { failures += 1 }
        }
    }
    return (result, failures)
}

let lock = NSLock()
nonisolated(unsafe) var results: [UserResult] = []
nonisolated(unsafe) var parityFailures = 0
nonisolated(unsafe) var evaluated = 0

DispatchQueue.concurrentPerform(iterations: userRows.count) { index in
    guard let (result, failures) = evaluate(userRows[index]) else { return }
    lock.lock()
    results.append(result)
    parityFailures += failures
    evaluated += 1
    if evaluated % 50 == 0 {
        FileHandle.standardError.write("  \(evaluated) users\n".data(using: .utf8) ?? Data())
    }
    lock.unlock()
}
results.sort { $0.user < $1.user }

// MARK: - Output

struct Output: Encodable {
    let titles: Int
    let users: Int
    let parityFailures: Int
    let results: [UserResult]
}

let data = try JSONEncoder().encode(Output(
    titles: catalog.count, users: results.count,
    parityFailures: parityFailures, results: results
))
try data.write(to: URL(fileURLWithPath: evalDir).appendingPathComponent(outputName))
print("users \(results.count)  titles \(catalog.count)  parity failures \(parityFailures)")
