import SwiftUI

// MARK: - Tunable FTUE glow (first launch only)

enum NotchFTUEMetrics {
    static let defaultsKey = "hasSeenFTUE"

    /// Full up-then-down pulse. Keep in the 1.5–2.5s range.
    static let totalDuration: TimeInterval = 2.0
    static var halfDuration: TimeInterval { totalDuration / 2 }
    static var timing: Animation { .easeInOut(duration: halfDuration) }

    /// Peak fill/opacity for the left edge glow.
    static let leftPeakOpacity: CGFloat = 0.22
    static let leftPeakBlur: CGFloat = 12
    static let leftRestBlur: CGFloat = 2
    static let leftBandWidth: CGFloat = 10

    /// Slightly quieter than the leading edge so the pair doesn’t read as a flash.
    static let rightPeakOpacity: CGFloat = 0.18
    static let rightPeakBlur: CGFloat = 10
    static let rightRestBlur: CGFloat = 2
    static let rightBandWidth: CGFloat = 10

    /// Bottom uses the same `.shadow(x: 0, y: 2)` recipe as `notchShadow`.
    static let bottomPeakOpacity: CGFloat = 0.20
    static let bottomPeakBlur: CGFloat = 14
    static let bottomRestBlur: CGFloat = 0
    static let bottomBandHeight: CGFloat = 2
    static let bottomShadowY: CGFloat = 2

    /// How far the side bands sit outside the island so the glow reads as edge light.
    static let sideOutwardOffset: CGFloat = 3

    static let glowColor = Color.white
}

enum NotchFTUEStore {
    static func shouldPlay(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: NotchFTUEMetrics.defaultsKey)
    }

    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: NotchFTUEMetrics.defaultsKey)
    }
}

// MARK: - View + modifier

struct NotchFTUEGlowView: View {
    var pulse: CGFloat
    var bottomLeadingRadius: CGFloat
    var bottomTrailingRadius: CGFloat

    var body: some View {
        ZStack {
            sideGlow(
                peakOpacity: NotchFTUEMetrics.leftPeakOpacity,
                peakBlur: NotchFTUEMetrics.leftPeakBlur,
                restBlur: NotchFTUEMetrics.leftRestBlur,
                bandWidth: NotchFTUEMetrics.leftBandWidth,
                alignment: .leading,
                startPoint: .leading,
                endPoint: .trailing
            )
            .offset(x: -NotchFTUEMetrics.sideOutwardOffset)

            sideGlow(
                peakOpacity: NotchFTUEMetrics.rightPeakOpacity,
                peakBlur: NotchFTUEMetrics.rightPeakBlur,
                restBlur: NotchFTUEMetrics.rightRestBlur,
                bandWidth: NotchFTUEMetrics.rightBandWidth,
                alignment: .trailing,
                startPoint: .trailing,
                endPoint: .leading
            )
            .offset(x: NotchFTUEMetrics.sideOutwardOffset)

            bottomShadowGlow
        }
        .allowsHitTesting(false)
    }

    private func sideGlow(
        peakOpacity: CGFloat,
        peakBlur: CGFloat,
        restBlur: CGFloat,
        bandWidth: CGFloat,
        alignment: Alignment,
        startPoint: UnitPoint,
        endPoint: UnitPoint
    ) -> some View {
        let opacity = peakOpacity * pulse
        let blur = restBlur + (peakBlur - restBlur) * pulse
        return LinearGradient(
            colors: [
                NotchFTUEMetrics.glowColor.opacity(opacity),
                NotchFTUEMetrics.glowColor.opacity(0)
            ],
            startPoint: startPoint,
            endPoint: endPoint
        )
        .frame(width: bandWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .blur(radius: blur)
    }

    /// Same drop-shadow API as the island’s expanded music shadow (X 0, Y 2, blur).
    /// A thin bottom band is the caster so this does not replace or drive the visualizer.
    private var bottomShadowGlow: some View {
        let opacity = NotchFTUEMetrics.bottomPeakOpacity * pulse
        let blur = NotchFTUEMetrics.bottomRestBlur
            + (NotchFTUEMetrics.bottomPeakBlur - NotchFTUEMetrics.bottomRestBlur) * pulse
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: bottomLeadingRadius,
                bottomTrailingRadius: bottomTrailingRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(NotchFTUEMetrics.glowColor.opacity(opacity * 0.35))
            .frame(height: NotchFTUEMetrics.bottomBandHeight + bottomLeadingRadius * 0.15)
            .shadow(
                color: NotchFTUEMetrics.glowColor.opacity(opacity),
                radius: blur,
                x: 0,
                y: NotchFTUEMetrics.bottomShadowY
            )
        }
    }
}

struct NotchFTUEGlowModifier: ViewModifier {
    var isActive: Bool
    var bottomLeadingRadius: CGFloat
    var bottomTrailingRadius: CGFloat
    var onFinished: () -> Void

    @State private var pulse: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive || pulse > 0.001 {
                    NotchFTUEGlowView(
                        pulse: pulse,
                        bottomLeadingRadius: bottomLeadingRadius,
                        bottomTrailingRadius: bottomTrailingRadius
                    )
                }
            }
            .task(id: isActive) {
                guard isActive else { return }
                pulse = 0
                withAnimation(NotchFTUEMetrics.timing) {
                    pulse = 1
                }
                try? await Task.sleep(nanoseconds: nanoseconds(NotchFTUEMetrics.halfDuration))
                guard !Task.isCancelled else { return }
                withAnimation(NotchFTUEMetrics.timing) {
                    pulse = 0
                }
                try? await Task.sleep(nanoseconds: nanoseconds(NotchFTUEMetrics.halfDuration))
                guard !Task.isCancelled else { return }
                onFinished()
            }
    }

    private func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(max(interval, 0) * 1_000_000_000)
    }
}

extension View {
    func notchFTUEGlow(
        isActive: Bool,
        bottomLeadingRadius: CGFloat,
        bottomTrailingRadius: CGFloat,
        onFinished: @escaping () -> Void
    ) -> some View {
        modifier(
            NotchFTUEGlowModifier(
                isActive: isActive,
                bottomLeadingRadius: bottomLeadingRadius,
                bottomTrailingRadius: bottomTrailingRadius,
                onFinished: onFinished
            )
        )
    }
}
