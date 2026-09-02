import AppKit
import CoreImage
import SwiftUI

/// Fast average color from artwork, clamped so it reads as a tinted drop shadow.
enum AlbumArtShadowColor {
    static let maxSaturation: CGFloat = 0.38
    static let maxBrightness: CGFloat = 0.35

    static func extract(from image: NSImage?) -> Color? {
        guard let image else { return nil }
        guard let average = averageSRGB(from: image) else { return nil }
        return color(fromSRGB: average)
    }

    static func color(fromSRGB rgb: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let clamped = clampHSB(hue: hue, saturation: saturation, brightness: brightness)
        return Color(
            hue: clamped.hue,
            saturation: clamped.saturation,
            brightness: clamped.brightness
        )
    }

    static func clampHSB(
        hue: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat
    ) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        (
            hue: min(max(hue, 0), 1),
            saturation: min(max(saturation, 0), maxSaturation),
            brightness: min(max(brightness, 0), maxBrightness)
        )
    }

    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    private static func averageSRGB(from image: NSImage) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard let tiff = image.tiffRepresentation, let ciImage = CIImage(data: tiff) else {
            return nil
        }
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: ciImage,
                kCIInputExtentKey: CIVector(cgRect: extent)
            ]
        )
        guard let output = filter?.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return (
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255
        )
    }
}
