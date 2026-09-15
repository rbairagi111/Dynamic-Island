import AppKit
import SwiftUI

/// Collapsed-island dual artwork: two tiles fanned so a second live session is
/// obvious next to the waveform. Used by `NotchView` and covered by a bitmap
/// unit test so we do not ship an invisible 1–2pt peek again.
struct CompactDualNowPlayingArtwork: View {
    let frontImage: NSImage?
    let frontUsesPlatformLogo: Bool
    let frontPlatform: StreamingPlatform?
    let backImage: NSImage?
    let backUsesPlatformLogo: Bool
    let backPlatform: StreamingPlatform?

    var body: some View {
        let size = IslandMetrics.compactDualArtSize
        let radius: CGFloat = 5
        let dx = IslandMetrics.compactDualArtOverlapX
        let dy = IslandMetrics.compactDualArtOverlapY
        let frame = DualNowPlayingSurfacePolicy.compactStackSize(
            art: size,
            overlapX: dx,
            overlapY: dy
        )

        return ZStack(alignment: .topLeading) {
            tile(
                image: backImage,
                usesPlatformLogo: backUsesPlatformLogo,
                platform: backPlatform,
                size: size,
                cornerRadius: radius
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
            .offset(x: dx, y: dy)

            tile(
                image: frontImage,
                usesPlatformLogo: frontUsesPlatformLogo,
                platform: frontPlatform,
                size: size,
                cornerRadius: radius
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1.25)
            }
            .shadow(color: .black.opacity(0.55), radius: 1.5, x: -0.5, y: 0.5)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .accessibilityLabel("Now Playing — two sources")
    }

    private func tile(
        image: NSImage?,
        usesPlatformLogo: Bool,
        platform: StreamingPlatform?,
        size: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        let resolved = image
            ?? (usesPlatformLogo ? platform.flatMap { StreamingPlatformArtwork.image(for: $0) } : nil)
        let fitLogo = usesPlatformLogo

        return Group {
            if let resolved {
                Color.clear
                    .overlay {
                        Image(nsImage: resolved)
                            .resizable()
                            .aspectRatio(contentMode: fitLogo ? .fit : .fill)
                            .transaction { $0.animation = nil }
                            .id(ObjectIdentifier(resolved))
                    }
                    .clipped()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white.opacity(0.18))
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .frame(width: size, height: size)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
