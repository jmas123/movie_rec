//
//  RecommendationRow.swift
//  Binged
//
//  One recommendation. Speaks `MediaRow`'s visual language — poster, title,
//  year and type — with two things `MediaRow` has no concept of: a **predicted**
//  badge, and a line saying why.
//
//  The badge is deliberately not `MediaRow`'s filled score pill. A prediction
//  and an earned score sit on the same 0–10 scale and mean very different
//  things: one is derived from the user's own comparisons, the other is a guess
//  about a title they have never seen. Rendering them identically would let the
//  app borrow credibility the ranking system spent eighteen phases earning, so
//  the predicted badge is outlined rather than filled and VoiceOver always says
//  the word "predicted".
//

import SwiftUI

// MARK: - RecommendationRow

struct RecommendationRow: View {

    let recommendation: Recommendation
    var onQueue: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var display: PredictionDisplay {
        PredictionDisplay(predicted: recommendation.predicted, lift: recommendation.lift)
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            PosterView(title: recommendation.item.title, posterURL: recommendation.item.posterURL)
                .frame(width: 48, height: 72)

            VStack(alignment: .leading, spacing: 3) {
                Text(recommendation.item.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)

                Text("\(String(recommendation.item.year)) · \(recommendation.item.type.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let rationale {
                    Text(rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if recommendation.isQueued {
                    Label("In your list", systemImage: "bookmark.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: Spacing.sm)

            PredictedBadge(display: display)
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onQueue, !recommendation.isQueued {
                Button {
                    onQueue()
                } label: {
                    Label("Want to Watch", systemImage: "bookmark")
                }
                .tint(.accentColor)
            }
            if let onDismiss {
                // The only negative signal available without asking the user to
                // rate something they have not seen. Destructive styling because
                // it removes the row, not because it is dangerous.
                Button(role: .destructive) {
                    onDismiss()
                } label: {
                    Label("Not for me", systemImage: "hand.thumbsdown")
                }
            }
        }
    }

    // MARK: Rationale

    /// "Because you rate crime thrillers highly."
    ///
    /// Built from the contributions that actually moved the number, so the
    /// sentence and the score cannot drift apart — a rationale generated
    /// separately from the arithmetic is a rationalisation.
    ///
    /// `nil` when nothing contributed positively, which is the honest outcome
    /// for a title recommended on mood alone. An invented reason would be worse
    /// than no reason.
    private var rationale: String? {
        let names = recommendation.predicted.topContributingFeatures
            .prefix(2)
            .map(\.feature.displayName)

        guard !names.isEmpty else { return nil }
        return "Because you like \(names.joined(separator: " and "))"
    }

    // MARK: Accessibility

    private var accessibilityLabel: String {
        var label = "\(recommendation.item.title), \(String(recommendation.item.year)), "
            + "\(recommendation.item.type.displayName), \(display.accessibilityDescription)"
        if let rationale { label += ". \(rationale)" }
        if recommendation.isQueued { label += ". Already in your list" }
        return label
    }
}

// MARK: - PredictedBadge

/// The trailing badge. Outlined, never filled — see this file's header.
private struct PredictedBadge: View {

    let display: PredictionDisplay

    /// The badge's floor width, scaled with the type inside it — a fixed 64pt
    /// would clip "Probably not for you" the moment the text grew.
    @ScaledMetric(relativeTo: .caption2) private var minimumWidth: CGFloat = 64

    var body: some View {
        VStack(spacing: 2) {
            switch display {
            case .score(let value):
                Text(ScoreDisplay.formatter.string(from: value as NSNumber) ?? "—")
                    .font(.callout.weight(.bold).monospacedDigit())
                Text("predicted")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

            case .band(let band):
                Image(systemName: band.symbolName)
                    .font(.callout.weight(.semibold))
                Text(band.label)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .frame(minWidth: minimumWidth)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
        }
        // Capped, unusually — a trailing badge that keeps growing eats the
        // title it belongs to. Nothing is lost by it: the badge is hidden from
        // VoiceOver and every word in it is already spoken by the row's own
        // label, so a user who needs the largest sizes reads the content in
        // the row, not the pill.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#if DEBUG
private func previewRecommendation(
    title: String,
    confidence: Double,
    lift: Double,
    queued: Bool = false
) -> Recommendation {
    Recommendation(
        item: MediaItem(title: title, year: 2021, type: .movie),
        predicted: PredictedScore(
            value: 6.4 + lift,
            confidence: confidence,
            evidence: 6,
            familiesPresent: [.genre],
            topContributingFeatures: [
                FeatureContribution(feature: .genre("Crime"), amount: 0.3, support: 8),
                FeatureContribution(feature: .genre("Thriller"), amount: 0.2, support: 6),
            ],
            displayValue: 9.1
        ),
        moodWeight: 1,
        isQueued: queued,
        lift: lift
    )
}

#Preview("Confident") {
    List {
        RecommendationRow(recommendation: previewRecommendation(
            title: "Sicario", confidence: 0.8, lift: 0.6
        ))
        RecommendationRow(recommendation: previewRecommendation(
            title: "Prisoners", confidence: 0.9, lift: 0.4, queued: true
        ))
    }
}

#Preview("Below the confidence floor") {
    List {
        RecommendationRow(recommendation: previewRecommendation(
            title: "Likely a hit", confidence: 0.1, lift: 0.5
        ))
        RecommendationRow(recommendation: previewRecommendation(
            title: "Worth a shot", confidence: 0.1, lift: 0.0
        ))
        RecommendationRow(recommendation: previewRecommendation(
            title: "Probably not", confidence: 0.1, lift: -0.5
        ))
    }
}
#endif
