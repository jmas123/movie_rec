//
//  FlowLayout.swift
//  Binged
//

import SwiftUI

// MARK: - FlowLayout

/// Lays subviews out left to right, wrapping to a new line when the next one
/// would not fit.
///
/// Exists because `HStack` overflows and `ScrollView(.horizontal)` hides. Both
/// are wrong for a handful of short chips whose combined width depends on the
/// user's text size: at the largest Dynamic Type setting two chips already fill
/// a phone, and a layout that cannot wrap either clips them or scrolls them out
/// of sight with nothing to say so.
struct FlowLayout: Layout {

    var spacing: CGFloat = Spacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layout(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = layout(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
        }
    }

    /// One line of the result: which subviews are on it, where it starts, and
    /// how tall it is.
    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var height: CGFloat = 0
        var width: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            // A subview wider than the whole container still gets its own line
            // rather than an infinite loop of empty ones.
            if !current.indices.isEmpty, x + size.width > width {
                current.width = x - spacing
                rows.append(current)
                let nextY = current.y + current.height + spacing
                current = Row(y: nextY)
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }

        if !current.indices.isEmpty {
            current.width = x - spacing
            rows.append(current)
        }
        return rows
    }
}
