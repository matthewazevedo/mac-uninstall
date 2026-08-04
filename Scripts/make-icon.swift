#!/usr/bin/env swift
//
// Draws the app icon — direction "A · Lifted" from the Mac Uninstall design system.
//
// The app tile with one piece pulled clear of it: extraction, not destruction. The
// dark ground is deliberate — a utility that runs occasionally should sit quietly
// next to the apps it removes, and the amber dot is the only thing that catches the
// eye at Dock size.
//
// Geometry is transcribed from the system's own size ladder, which hints the mark as
// it shrinks: below 128 the proportions get chunkier, and at 16 the gradient flattens
// to a single grey and the ring stroke is dropped, leaving two shapes and one accent
// dot — all that survives at that size.
//
// Usage: swift Scripts/make-icon.swift <output.iconset>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let groundTop = rgb(0x4A5260)
let groundBottom = rgb(0x2E3440)
let groundFlat = rgb(0x3A414E)
let tileColor = rgb(0xE9ECF1)
let dotColor = rgb(0xDCA34A)
let ringColor = rgb(0x2E3440)

// MARK: - Geometry

/// Proportions relative to the icon body, taken from one rung of the size ladder.
struct Profile {
    var corner: CGFloat
    var tile: CGFloat
    var tileCorner: CGFloat
    /// Outer diameter of the dot, border included — the spec uses border-box sizing.
    var dot: CGFloat
    /// Distance from the body's top and right edges to the dot.
    var dotInset: CGFloat
    /// Ring thickness; zero drops the stroke entirely.
    var ring: CGFloat
    var usesGradient: Bool

    /// 128 and 256 share one set of ratios.
    static let large = Profile(
        corner: 29.0 / 128, tile: 58.0 / 128, tileCorner: 14.0 / 128,
        dot: 26.0 / 128, dotInset: 24.0 / 128, ring: 4.0 / 128, usesGradient: true
    )
    static let medium = Profile(
        corner: 7.0 / 32, tile: 15.0 / 32, tileCorner: 4.0 / 32,
        dot: 8.0 / 32, dotInset: 6.0 / 32, ring: 1.5 / 32, usesGradient: true
    )
    static let small = Profile(
        corner: 4.0 / 16, tile: 8.0 / 16, tileCorner: 2.0 / 16,
        dot: 5.0 / 16, dotInset: 2.0 / 16, ring: 0, usesGradient: false
    )

    static func forPixelSize(_ size: Int) -> Profile {
        switch size {
        case ..<20: .small
        case ..<128: .medium
        default: .large
        }
    }
}

/// macOS reserves a margin around the icon body so apps sit consistently in the Dock.
/// Apple's grid puts an 824pt body inside a 1024pt canvas.
let bodyRatio: CGFloat = 824.0 / 1024.0

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Drawing

func drawIcon(pixelSize: Int) -> CGImage? {
    let size = CGFloat(pixelSize)
    let profile = Profile.forPixelSize(pixelSize)

    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)

    let body = size * bodyRatio
    let origin = (size - body) / 2
    let bodyRect = CGRect(x: origin, y: origin, width: body, height: body)
    let bodyPath = roundedRect(bodyRect, radius: profile.corner * body)

    // Ground. The shadow is only worth drawing where there are pixels to carry it.
    context.saveGState()
    if pixelSize >= 128 {
        context.setShadow(
            offset: CGSize(width: 0, height: -(6.0 / 128) * body),
            blur: (18.0 / 128) * body,
            color: CGColor(srgbRed: 20 / 255, green: 24 / 255, blue: 32 / 255, alpha: 0.28)
        )
    }
    context.addPath(bodyPath)
    if profile.usesGradient {
        // Clip to the squircle, then run the gradient top to bottom.
        context.saveGState()
        context.clip()
        // Painting the flat colour first gives the shadow something to attach to.
        context.setFillColor(groundBottom)
        context.fill(bodyRect)
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [groundTop, groundBottom] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: bodyRect.maxY),
            end: CGPoint(x: 0, y: bodyRect.minY),
            options: []
        )
        context.restoreGState()
    } else {
        context.setFillColor(groundFlat)
        context.fillPath()
    }
    context.restoreGState()

    // The app tile, centred.
    let tile = profile.tile * body
    let tileRect = CGRect(
        x: bodyRect.midX - tile / 2,
        y: bodyRect.midY - tile / 2,
        width: tile,
        height: tile
    )
    context.setFillColor(tileColor)
    context.addPath(roundedRect(tileRect, radius: profile.tileCorner * body))
    context.fillPath()

    // The piece lifted clear of it, at the top-right. Coordinates in the spec are
    // measured from the top, so they are flipped into Core Graphics' bottom-left space.
    let dot = profile.dot * body
    let inset = profile.dotInset * body
    let dotRect = CGRect(
        x: bodyRect.maxX - inset - dot,
        y: bodyRect.maxY - inset - dot,
        width: dot,
        height: dot
    )

    if profile.ring > 0 {
        let ring = profile.ring * body
        context.setFillColor(ringColor)
        context.fillEllipse(in: dotRect)
        context.setFillColor(dotColor)
        context.fillEllipse(in: dotRect.insetBy(dx: ring, dy: ring))
    } else {
        context.setFillColor(dotColor)
        context.fillEllipse(in: dotRect)
    }

    return context.makeImage()
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}

let iconset = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The complete ladder iconutil expects for a Retina-ready .icns.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = drawIcon(pixelSize: variant.pixels) else {
        FileHandle.standardError.write(Data("failed to draw \(variant.name)\n".utf8))
        exit(1)
    }
    try write(image, to: iconset.appending(path: "\(variant.name).png"))
}

print("wrote \(variants.count) images to \(iconset.path)")
