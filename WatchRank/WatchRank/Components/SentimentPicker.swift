//
//  SentimentPicker.swift
//  WatchRank
//
//  The three-way sentiment chooser shown right after a title is marked watched.
//  This is the ONLY rating input in the app — the user never types a number;
//  the bucket plus the comparison flow derive the score.
//

import SwiftUI

// MARK: - SentimentPicker

/// Three large buttons over `Sentiment.allCases`, bound to an optional
/// selection. Tapping a button selects it; tapping the selected button again
/// clears the selection.
struct SentimentPicker: View {

    @Binding var selection: Sentiment?

    var body: some View {
        VStack(spacing: Spacing.md) {
            ForEach(Sentiment.allCases) { sentiment in
                Button {
                    selection = (selection == sentiment) ? nil : sentiment
                } label: {
                    SentimentButtonLabel(
                        sentiment: sentiment,
                        isSelected: selection == sentiment
                    )
                }
                .buttonStyle(.plain)
                // Label the button itself: its content is an SF Symbol plus
                // text, and VoiceOver would otherwise announce the raw symbol
                // name. The trait belongs here too, on the control, rather
                // than on the label view inside it.
                .accessibilityLabel(sentiment.displayName)
                .accessibilityAddTraits(selection == sentiment ? .isSelected : [])
                .accessibilityHint(
                    selection == sentiment
                        ? "Selected. Double tap to clear."
                        : "Double tap to choose this rating."
                )
            }
        }
    }
}

// MARK: - SentimentButtonLabel

private struct SentimentButtonLabel: View {
    let sentiment: Sentiment
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: symbolName)
                .font(.title3)
                .accessibilityHidden(true)
            Text(sentiment.displayName)
                .font(.headline)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(isSelected ? .white : Color.primary)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? tint : Color(.secondarySystemBackground))
        )
    }

    private var symbolName: String {
        switch sentiment {
        case .liked:    return "hand.thumbsup.fill"
        case .fine:     return "hand.point.up.left.fill"
        case .disliked: return "hand.thumbsdown.fill"
        }
    }

    /// Selection color per tier — green / amber / red, using system colors so
    /// dark mode is handled automatically.
    private var tint: Color {
        switch sentiment {
        case .liked:    return .green
        case .fine:     return .orange
        case .disliked: return .red
        }
    }
}

// MARK: - Previews

#Preview("None selected") {
    StatefulPreviewWrapper(Sentiment?.none) { binding in
        SentimentPicker(selection: binding)
            .padding()
    }
}

#Preview("Liked selected") {
    StatefulPreviewWrapper(Sentiment?.some(.liked)) { binding in
        SentimentPicker(selection: binding)
            .padding()
    }
}

// MARK: - Preview helper

/// Hosts mutable state so a `Binding`-driven view can be previewed interactively.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }

    var body: some View {
        content($value)
    }
}
