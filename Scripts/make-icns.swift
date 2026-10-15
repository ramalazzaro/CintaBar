// Builds Support/AppIcon.icns, the icon the SwiftPM bundle ships, from the layers in
// Support/CintaBar.icon. Icon Composer renders that package with Liquid Glass; this draws the
// classic macOS icon from the same artwork: a rounded square on a gradient, with the layers
// inside. Run from the repository root:
//
//     swift Scripts/make-icns.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let assets = URL(fileURLWithPath: "Support/CintaBar.icon/Assets")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue

func load(_ name: String) -> CGImage {
    let source = CGImageSourceCreateWithURL(assets.appendingPathComponent(name) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

func context(_ size: Int) -> CGContext {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
        bitmapInfo: info)!
    context.interpolationQuality = .high
    return context
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// Back to front. The artwork sits within the central three quarters of each 1024 pt layer.
let layers = [load("belt.png"), load("figure.png")]

/// The pre-Liquid Glass macOS icon: an 824 pt rounded square centred on a 1024 pt canvas.
func classicIcon(_ size: Int) -> CGImage {
    let context = context(size)
    let scale = CGFloat(size) / 1024
    let square = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    context.addPath(CGPath(roundedRect: square, cornerWidth: 184 * scale, cornerHeight: 184 * scale, transform: nil))
    context.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 0x4A / 255, green: 0x55 / 255, blue: 0x63 / 255, alpha: 1),
            CGColor(srgbRed: 0x1F / 255, green: 0x29 / 255, blue: 0x37 / 255, alpha: 1),
        ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: square.maxY), end: CGPoint(x: 0, y: square.minY), options: [])
    // Shrink the layers so the artwork takes up about 600 of the 824 pt.
    let side = 1024 * scale * 600 / 760
    let origin = (CGFloat(size) - side) / 2
    for layer in layers {
        context.draw(layer, in: CGRect(x: origin, y: origin, width: side, height: side))
    }
    return context.makeImage()!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let full = classicIcon(1024)
for (name, size) in [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
    ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
] {
    let context = context(size)
    context.draw(full, in: CGRect(x: 0, y: 0, width: size, height: size))
    write(context.makeImage()!, to: iconset.appendingPathComponent("icon_\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Support/AppIcon.icns" : "iconutil failed")
