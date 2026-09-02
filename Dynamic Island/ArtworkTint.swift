import AppKit
import SwiftUI

/// Picks a Now Playing–style bar color from artwork: a vivid hue lifted so it
/// stays readable on the black island, matching iPhone Dynamic Island waves.
enum ArtworkTint {
    static let fallbackTop = NSColor(
        calibratedHue: 0.55,
        saturation: 0.12,
        brightness: 0.82,
        alpha: 1
    )
    static let fallbackBottom = NSColor(
        calibratedHue: 0.07,
        saturation: 0.28,
        brightness: 0.38,
        alpha: 1
    )
    static let fallback = fallbackTop

    struct Gradient {
        let top: Color
        let bottom: Color

        static let idle = Gradient(
            top: Color.white.opacity(0.45),
            bottom: Color.white.opacity(0.18)
        )

        static let fallback = Gradient(
            top: Color(nsColor: fallbackTop),
            bottom: Color(nsColor: fallbackBottom)
        )
    }

    static func waveformGradient(from image: NSImage) -> Gradient {
        let base = waveformNSColor(from: image)
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Cooler, lighter frost at the top; warmer, deeper shade at the bottom.
        let top = NSColor(
            calibratedHue: fmod(h + 0.06, 1),
            saturation: max(0.08, s * 0.42),
            brightness: min(1, b * 1.12 + 0.1),
            alpha: 1
        )
        let bottom = NSColor(
            calibratedHue: fmod(h + 0.97, 1),
            saturation: min(0.85, s * 1.15 + 0.08),
            brightness: max(0.22, b * 0.42),
            alpha: 1
        )
        return Gradient(top: Color(nsColor: top), bottom: Color(nsColor: bottom))
    }

    static func waveformNSColor(from image: NSImage) -> NSColor {
        guard let sampled = prominentHSB(from: image) else {
            return fallback
        }
        // Push toward a lit, saturated tint so dark thumbnails still read on black.
        let saturation = min(0.78, max(sampled.s * 1.15, sampled.s > 0.08 ? 0.42 : 0.08))
        let brightness = min(0.96, max(sampled.b, 0.72))
        return NSColor(
            calibratedHue: sampled.h,
            saturation: saturation,
            brightness: brightness,
            alpha: 1
        )
    }

    private static func prominentHSB(
        from image: NSImage
    ) -> (h: CGFloat, s: CGFloat, b: CGFloat)? {
        let size = 24
        guard let pixels = rgbaPixels(from: image, width: size, height: size) else {
            return nil
        }

        var bestScore: CGFloat = -1
        var best: (h: CGFloat, s: CGFloat, b: CGFloat)?

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = CGFloat(pixels[i + 3]) / 255
            if alpha < 0.4 { continue }

            let r = CGFloat(pixels[i]) / 255
            let g = CGFloat(pixels[i + 1]) / 255
            let b = CGFloat(pixels[i + 2]) / 255
            var h: CGFloat = 0
            var s: CGFloat = 0
            var v: CGFloat = 0
            NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
                .getHue(&h, saturation: &s, brightness: &v, alpha: nil)

            // Skip near-black and near-white; those wash out the bars.
            if v < 0.12 { continue }
            if v > 0.94 && s < 0.1 { continue }

            let colorfulness = s * (0.45 + 0.55 * v)
            let score = colorfulness + (s > 0.25 ? 0.2 : 0)
            if score > bestScore {
                bestScore = score
                best = (h, s, v)
            }
        }
        return best
    }

    private static func rgbaPixels(
        from image: NSImage,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        guard let cgImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}
