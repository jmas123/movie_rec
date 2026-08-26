//
//  CastStrip.swift
//  Binged
//
//  Who is in it, and who made it.
//
//  The single biggest omission on the old detail screen. "Is that the one with
//  Tilda Swinton?" is the question people actually ask about a film they half
//  remember, and the app could not answer it — even though the cast was already
//  being fetched for the predictor and thrown away after the feature keys were
//  extracted.
//
//  Horizontal rather than a wrapped grid: a cast list is *ordered* — billing
//  order for film, episode count for television — and a scroll strip keeps the
//  leads first and in view, while a wrapping grid gives the eighth-billed actor
//  the same prominence as the lead.
//

import SwiftUI

// MARK: - CastStrip

struct CastStrip: View {

    let people: [TitleDetails.Person]

    /// "Cast", "Director", "Creators" — supplied rather than inferred, because
    /// this view draws crew and cast with the same shape.
    let title: String

    /// The crew credit, when there is one: "Directed by Bong Joon-ho".
    ///
    /// A line rather than a second strip. One director is one circle floating
    /// on its own, which reads as a strip that failed to load rather than as a
    /// complete answer — and the name is the whole of what is being said.
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.lg) {
                    ForEach(people) { person in
                        personView(person)
                    }
                }
                .padding(.horizontal, 1) // keeps shadows from clipping
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: One person

    private func personView(_ person: TitleDetails.Person) -> some View {
        VStack(spacing: Spacing.sm) {
            // `PosterView` clipped to a circle, matching how the social layer
            // draws an avatar — a headshot missing from TMDB falls back to the
            // same initial-on-a-gradient as a missing poster.
            PosterView(title: person.name, posterURL: person.imageURL)
                .frame(width: Self.headshotSize, height: Self.headshotSize)
                .clipShape(Circle())

            VStack(spacing: 1) {
                Text(person.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.center)
            // Wide enough for "Chiwetel Ejiofor" on two lines, narrow enough
            // that four faces are visible at once on the smallest phone.
            .frame(width: Self.columnWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            person.role.map { "\(person.name), \($0)" } ?? person.name
        )
    }

    private static let headshotSize: CGFloat = 68
    private static let columnWidth: CGFloat = 84
}

// MARK: - Previews

#if DEBUG
#Preview("Cast", traits: .sizeThatFitsLayout) {
    CastStrip(
        people: [
            TitleDetails.Person(id: "1", name: "Song Kang-ho", role: "Ki-taek"),
            TitleDetails.Person(id: "2", name: "Lee Sun-kyun", role: "Mr. Park"),
            TitleDetails.Person(id: "3", name: "Cho Yeo-jeong", role: "Yeon-kyo"),
            TitleDetails.Person(id: "4", name: "Choi Woo-shik", role: "Ki-woo"),
        ],
        title: "Cast",
        subtitle: "Directed by Bong Joon-ho"
    )
    .padding()
}
#endif
