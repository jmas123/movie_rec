//
//  make-app-icon.swift
//  Binged
//
//  Regenerates the three App Icon variants into the asset catalogue.
//
//  Checked in so the icon is reproducible rather than an opaque binary nobody
//  can adjust. It is not part of any target — the app has no build phase that
//  runs it, and it is outside the synchronized source group.
//
//  Usage:  swift tools/make-app-icon.swift
//
//  The mark is a three-row leaderboard: equal-height rows of decreasing width,
//  which is what a ranked list looks like from across the room. It survives the
//  40pt Settings size, where a trophy or a film reel turns to mush.
//
//  Variants follow the iOS 18 contract. The light icon is fully opaque and
//  paints its own gradient. Dark and tinted are drawn on a *transparent*
//  background, because the system composites those itself — painting our own
//  would double up.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

let side = 1024
let barHeight = 108.0
let barGap = 48.0
let barWidths = [560.0, 440.0, 320.0]
let barX = 232.0

// MARK: - Palette

/// The brand violet, shared with `AccentColor`. Kept in one place so the icon
/// and the app's tint cannot drift apart.
let gradientTop = CGColor(red: 0.169, green: 0.106, blue: 0.420, alpha: 1)   // #2B1B6B
let gradientBottom = CGColor(red: 0.427, green: 0.231, blue: 0.961, alpha: 1) // #6D3BF5

// MARK: - Drawing

enum Variant {
    case light, dark, tinted

    var filename: String {
        switch self {
        case .light:  return "AppIcon-1024.png"
        case .dark:   return "AppIcon-1024-dark.png"
        case .tinted: return "AppIcon-1024-tinted.png"
        }
    }

    /// Only the light variant paints a background; see the file header.
    var paintsBackground: Bool { self == .light }

    /// The primary icon must ship **without** an alpha channel — App Store
    /// validation rejects a transparent primary outright, and "opaque pixels"
    /// is not the same claim as "no alpha channel". Dark and tinted are the
    /// exception: their transparency is the point.
    var bitmapInfo: UInt32 {
        paintsBackground
            ? CGImageAlphaInfo.noneSkipLast.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
    }

    /// Row opacities, brightest first — the descending weight is what reads as
    /// rank rather than as a bar chart.
    var barAlphas: [Double] {
        switch self {
        case .light, .dark: return [1.0, 0.78, 0.56]
        // Tinted is mapped by luminance, so the spread has to be wider or the
        // three rows collapse into one grey block.
        case .tinted:       return [1.0, 0.66, 0.38]
        }
    }
}

func makeContext(for variant: Variant) -> CGContext? {
    CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: variant.bitmapInfo
    )
}

func draw(_ variant: Variant, into context: CGContext) {
    let bounds = CGRect(x: 0, y: 0, width: Double(side), height: Double(side))

    if variant.paintsBackground {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [gradientTop, gradientBottom] as CFArray,
            locations: [0, 1]
        ) else { return }

        context.saveGState()
        context.addRect(bounds)
        context.clip()
        // Top-left to bottom-right: a diagonal reads as lit from above, which
        // is what every other icon on the home screen does.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: Double(side)),
            end: CGPoint(x: Double(side), y: 0),
            options: []
        )
        context.restoreGState()
    }

    let groupHeight = Double(barWidths.count) * barHeight
        + Double(barWidths.count - 1) * barGap
    var y = (Double(side) - groupHeight) / 2 + groupHeight - barHeight

    for (width, alpha) in zip(barWidths, variant.barAlphas) {
        let rect = CGRect(x: barX, y: y, width: width, height: barHeight)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: barHeight / 2,
            cornerHeight: barHeight / 2,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        context.fillPath()
        y -= barHeight + barGap
    }
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: side, height: side)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

// MARK: - Main

let iconSet = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Binged/Binged/Assets.xcassets/AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: iconSet.path) else {
    // Fail loudly: a silent no-op here would leave the catalogue empty and the
    // archive would fail much later, with a far less obvious message.
    FileHandle.standardError.write(Data(
        "No AppIcon.appiconset at \(iconSet.path). Run from the repository root.\n".utf8
    ))
    exit(1)
}

for variant in [Variant.light, .dark, .tinted] {
    guard let context = makeContext(for: variant) else {
        FileHandle.standardError.write(Data("Could not create a bitmap context.\n".utf8))
        exit(1)
    }
    draw(variant, into: context)
    guard let image = context.makeImage() else {
        FileHandle.standardError.write(Data("Could not render \(variant.filename).\n".utf8))
        exit(1)
    }
    try write(image, to: iconSet.appendingPathComponent(variant.filename))
    print("wrote \(variant.filename)")
}
