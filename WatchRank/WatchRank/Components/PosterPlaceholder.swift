//
//  PosterPlaceholder.swift
//  WatchRank
//
//  Gradient stand-in for real poster art, plus `PosterView` — the async loader
//  that prefers a real poster and falls back here.
//
//  SPEC's "gradient placeholder" rule is amended rather than abandoned. TMDB now
//  supplies `poster_path`, so a real image is available where one exists — but
//  the gradient stays as the loading state, the failure state, and the offline
//  state. A poster that fails to load must leave a gradient tile, never a blank
//  box.
//

import SwiftUI

// MARK: - PosterPlaceholder

/// A rounded gradient tile showing a title's leading initial. The gradient is
/// stable per-title, so the same movie always renders the same colors.
struct PosterPlaceholder: View {

    let title: String
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            LinearGradient(
                colors: gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initial)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .minimumScaleFactor(0.5)
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Poster for \(title)")
    }

    // MARK: Derived appearance

    /// First non-whitespace character of the title, upper-cased. Falls back to
    /// a film emoji-free dash when the title is empty.
    private var initial: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "—" }
        return String(first).uppercased()
    }

    /// Two hues seeded by a stable hash of the title, so colors are consistent
    /// across launches (Swift's `Hashable` hash is randomized per-process, so
    /// we roll a tiny deterministic hash here instead).
    private var gradientColors: [Color] {
        let seed = Self.stableHash(title)
        let hue1 = Double(seed % 360) / 360.0
        let hue2 = Double((seed / 360) % 360) / 360.0
        return [
            Color(hue: hue1, saturation: 0.55, brightness: 0.75),
            Color(hue: hue2, saturation: 0.65, brightness: 0.55)
        ]
    }

    /// FNV-1a style hash — small, deterministic, and process-stable.
    private static func stableHash(_ string: String) -> Int {
        var hash = 2166136261
        for byte in string.utf8 {
            hash = (hash ^ Int(byte)) &* 16777619
        }
        return abs(hash)
    }
}

// MARK: - Previews

#Preview("Standard", traits: .sizeThatFitsLayout) {
    PosterPlaceholder(title: "Inception")
        .frame(width: 120, height: 180)
        .padding()
}

#Preview("Edge cases", traits: .sizeThatFitsLayout) {
    HStack(spacing: 12) {
        PosterPlaceholder(title: "A")
        PosterPlaceholder(title: "Spider-Man: Into the Spider-Verse")
        PosterPlaceholder(title: "")
    }
    .frame(height: 160)
    .padding()
}


// MARK: - PosterView

/// A poster: the real image where one loads, the gradient placeholder
/// otherwise.
///
/// Every non-success `AsyncImagePhase` — empty, failed, and any future case —
/// resolves to the placeholder, so a slow network shows a gradient rather than
/// a hole and a 404 shows a gradient rather than a broken-image glyph.
struct PosterView: View {

    let title: String
    var posterURL: String?
    var cornerRadius: CGFloat = 12

    var body: some View {
        Group {
            if let url = posterURL.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        PosterPlaceholder(title: title, cornerRadius: cornerRadius)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                PosterPlaceholder(title: title, cornerRadius: cornerRadius)
            }
        }
        // Decorative: the row's own accessibility label already names the
        // title, so announcing the artwork separately is noise.
        .accessibilityHidden(true)
    }
}
