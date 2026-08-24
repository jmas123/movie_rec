//
//  Spacing.swift
//  Binged
//
//  The app's spacing scale. SPEC asks for "generous spacing" and a "clean,
//  premium feel" but names no numbers, so values drifted apart per-screen
//  (28 here, 24 there). These constants are the shared vocabulary.
//

import Foundation

// MARK: - Spacing

/// Layout rhythm, in points. A 4-point scale: every step is a multiple of 4,
/// so stacked elements line up on a common grid.
///
/// Use these for *structural* layout — gaps between sections, screen padding,
/// spacing between cards. Deliberately does **not** cover typographic
/// fine-tuning inside a component (the 3-point gap between a title and its
/// subtitle, say), where the right value follows the type, not the grid.
enum Spacing {

    /// 4 — hairline gaps inside a control.
    static let xs: CGFloat = 4

    /// 8 — related elements that read as one unit.
    static let sm: CGFloat = 8

    /// 12 — default gap between sibling controls.
    static let md: CGFloat = 12

    /// 16 — standard screen padding; matches SwiftUI's default `.padding()`.
    static let lg: CGFloat = 16

    /// 24 — gap between distinct sections of a screen.
    static let section: CGFloat = 24

    /// 72 — bottom inset that clears the floating add button.
    static let floatingButtonClearance: CGFloat = 72
}
