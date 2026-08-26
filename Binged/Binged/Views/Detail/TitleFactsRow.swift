//
//  TitleFactsRow.swift
//  Binged
//
//  The strip of small facts under the header: how long it runs, what the crowd
//  thought, how many seasons there are, what language it is in, whether it has
//  finished airing.
//
//  Each fact is present only when the catalog supplied it. That is the whole
//  design rule here — a row of labels with dashes under half of them reads as a
//  broken screen, whereas three facts and no gaps reads as a complete one, and
//  TMDB's coverage of anything outside the popular tail guarantees the choice
//  comes up constantly.
//

import SwiftUI

// MARK: - TitleFactsRow

struct TitleFactsRow: View {

    let details: TitleDetails
    let type: MediaType

    var body: some View {
        // Wraps rather than scrolls: these are four short labels, and a
        // horizontal scroll view would hide the fourth one off-screen with no
        // affordance saying so.
        FlowLayout(spacing: Spacing.sm) {
            ForEach(Self.facts(for: details, type: type)) { fact in
                factView(fact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Facts

    /// A fact worth a chip. `symbol` is SF Symbols; `spoken` exists because
    /// "2h 12m" is read aloud as "two h twelve m".
    struct Fact: Identifiable {
        let id: String
        let symbol: String
        let text: String
        let spoken: String
    }

    /// Whether this row would draw anything.
    ///
    /// Asked by the caller *before* building the row rather than answered with
    /// an `EmptyView` inside it: a zero-height child still collects the
    /// stack's spacing on both sides, so a title with no facts would leave a
    /// 48-point hole where a row never was.
    static func hasFacts(_ details: TitleDetails, type: MediaType) -> Bool {
        !facts(for: details, type: type).isEmpty
    }

    static func facts(for details: TitleDetails, type: MediaType) -> [Fact] {
        var out: [Fact] = []

        if let runtime = details.runtimeText, let spoken = spokenRuntime(details) {
            out.append(Fact(
                id: "runtime",
                symbol: type == .movie ? "clock" : "clock.badge.checkmark",
                text: runtime,
                spoken: type == .movie ? spoken : "\(spoken) per episode"
            ))
        }

        if let seasons = details.seasonText {
            out.append(Fact(id: "seasons", symbol: "rectangle.stack", text: seasons, spoken: seasons))
        }

        if let average = details.voteAverage {
            let formatted = String(format: "%.1f", average)
            let votes = details.voteCountText
            out.append(Fact(
                id: "tmdb",
                symbol: "star.fill",
                text: votes.map { "\(formatted) · \($0)" } ?? formatted,
                // Named as TMDB's, out loud as well as on screen. The app's own
                // score is the one the user earned, and a bare "7.4" beside it
                // would be read as a second opinion of equal standing.
                spoken: votes.map { "TMDB rating \(formatted) out of 10, from \($0) votes" }
                    ?? "TMDB rating \(formatted) out of 10"
            ))
        }

        if let language = details.languageName {
            out.append(Fact(id: "lang", symbol: "globe", text: language, spoken: "In \(language)"))
        }

        if let status = displayStatus(details) {
            out.append(Fact(id: "status", symbol: "dot.radiowaves.up.forward", text: status, spoken: status))
        }

        return out
    }

    /// "Released" on a film from 1994 tells the user nothing they cannot see
    /// from the year beside it, so only the states that carry news survive:
    /// a series still running, one that has ended, something not out yet.
    private static func displayStatus(_ details: TitleDetails) -> String? {
        guard let status = details.status else { return nil }
        switch status {
        case "Returning Series": return "Ongoing"
        case "Ended": return "Ended"
        case "Canceled", "Cancelled": return "Cancelled"
        case "In Production", "Post Production", "Planned": return "Not out yet"
        default: return nil
        }
    }

    private static func spokenRuntime(_ details: TitleDetails) -> String? {
        guard let minutes = details.runtimeMinutes, minutes > 0 else { return nil }
        let hours = minutes / 60
        let remainder = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if remainder > 0 { parts.append("\(remainder) minute\(remainder == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }

    private func factView(_ fact: Fact) -> some View {
        Label {
            Text(fact.text)
        } icon: {
            Image(systemName: fact.symbol)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fact.spoken)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Film", traits: .sizeThatFitsLayout) {
    TitleFactsRow(
        details: TitleDetails(
            runtimeMinutes: 132,
            voteAverage: 8.5,
            voteCount: 17_402,
            status: "Released",
            originalLanguage: "ko"
        ),
        type: .movie
    )
    .padding()
}

#Preview("Series", traits: .sizeThatFitsLayout) {
    TitleFactsRow(
        details: TitleDetails(
            runtimeMinutes: 49,
            voteAverage: 8.9,
            voteCount: 1_204,
            status: "Returning Series",
            originalLanguage: "en",
            seasonCount: 3,
            episodeCount: 28
        ),
        type: .tvShow
    )
    .padding()
}
#endif
