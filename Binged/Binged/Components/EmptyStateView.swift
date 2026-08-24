//
//  EmptyStateView.swift
//  Binged
//
//  The standard "nothing here yet" surface. Per SPEC, every empty list, rail,
//  and screen uses this: an SF Symbol, one line of copy, and an optional CTA.
//

import SwiftUI

// MARK: - EmptyStateView

/// An empty state. Pass a `systemImage`, a short `message`, and — optionally —
/// a call-to-action title plus closure to render a button.
///
/// Two styles, so that every empty surface in the app can share this one
/// component rather than hand-rolling its own:
/// - `.prominent` fills a whole screen or tab (large centered symbol).
/// - `.inline` sits inside a populated screen, such as a single empty rail on
///   Home, where a full-screen treatment would overwhelm the layout.
struct EmptyStateView: View {

    /// The symbol scales with Dynamic Type like everything else on the screen.
    /// It is decorative and hidden from VoiceOver, but an empty state is
    /// precisely where a sighted user at a large text size is being asked to
    /// read an explanation, so the illustration should not stay 44pt while the
    /// copy beside it grows.
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 44

    /// How much room the empty state should command.
    enum Style {
        /// Large, centered — for an entire screen or tab with nothing in it.
        case prominent
        /// Compact card — for one empty section inside an otherwise full screen.
        case inline
    }

    let systemImage: String
    let message: String
    var style: Style = .prominent
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        switch style {
        case .prominent: prominentBody
        case .inline: inlineBody
        }
    }

    // MARK: Styles

    private var prominentBody: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.section)
    }

    private var inlineBody: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .font(.footnote)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

// MARK: - Previews

#Preview("With CTA", traits: .sizeThatFitsLayout) {
    EmptyStateView(
        systemImage: "film.stack",
        message: "You haven't ranked anything yet.",
        actionTitle: "Find something to watch",
        action: {}
    )
}

#Preview("Message only", traits: .sizeThatFitsLayout) {
    EmptyStateView(
        systemImage: "magnifyingglass",
        message: "Search for a movie or show to get started."
    )
}

#Preview("Inline with CTA", traits: .sizeThatFitsLayout) {
    EmptyStateView(
        systemImage: "bookmark",
        message: "Your watchlist is empty.",
        style: .inline,
        actionTitle: "Browse",
        action: {}
    )
    .padding()
}
