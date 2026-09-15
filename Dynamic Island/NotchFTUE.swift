import SwiftUI
import Foundation

// MARK: - Tunable FTUE constants

enum NotchFTUEMetrics {
    static let defaultsKey = "hasSeenFTUE"

    // Sequence timing (seconds) — also used as Animation durations
    static let glowInDuration: TimeInterval = 1.5
    static let holdDuration: TimeInterval = 0.55
    static let morphDuration: TimeInterval = 0.95
    static let pauseBeforeExpand: TimeInterval = 1.0
    static let expandedHoldDuration: TimeInterval = 1.5
    static let tooltipVisibleDuration: TimeInterval = 3.0

    static var glowInAnimation: Animation { .easeOut(duration: glowInDuration) }
    static var morphAnimation: Animation { .easeInOut(duration: morphDuration) }
    static var tooltipAnimation: Animation { .easeInOut(duration: 0.35) }

    // Siri-sampled gradient stops — spatial, left → right across the glow.
    static let gradientRed = Color(red: 235 / 255, green: 72 / 255, blue: 72 / 255)       // #eb4848
    static let gradientOrange = Color(red: 234 / 255, green: 114 / 255, blue: 81 / 255)   // #ea7251
    static let gradientYellow = Color(red: 248 / 255, green: 216 / 255, blue: 126 / 255)  // #f8d87e
    static let gradientWhite = Color(red: 254 / 255, green: 255 / 255, blue: 252 / 255)   // #fefffc
    static let gradientCyan = Color(red: 150 / 255, green: 249 / 255, blue: 253 / 255)    // #96f9fd
    static let gradientGreen = Color(red: 130 / 255, green: 237 / 255, blue: 149 / 255)   // #82ed95

    static let gradientStopHexes: [String] = [
        "#eb4848", "#ea7251", "#f8d87e", "#fefffc", "#96f9fd", "#82ed95"
    ]

    /// Tight but visible halo: enough blur to escape the pill, not a menu-bar smear.
    static let glowCoreBlur: CGFloat = 9
    static let glowOuterBlur: CGFloat = 13
    /// Keep intensity — do not dim.
    static let glowPeakOpacity: CGFloat = 1.0
    /// Slight oversize so L/R ears read; blur does the rest.
    static let glowWidthFactor: CGFloat = 1.04
    static let glowHeightFactor: CGFloat = 1.02
    /// Small inset only — just enough to hide the hard fill edge under the pill.
    /// (0.88 + blur 5/9 left nothing visible past the silhouette.)
    static let glowFillInsetScale: CGFloat = 0.96

    /// Static spatial gradient — white pinned at mid so the peak isn’t a yellow/cyan mud.
    static var gradientGradientStops: [Gradient.Stop] {
        [
            .init(color: gradientRed, location: 0.00),
            .init(color: gradientOrange, location: 0.16),
            .init(color: gradientYellow, location: 0.32),
            .init(color: gradientWhite, location: 0.50),
            .init(color: gradientCyan, location: 0.68),
            .init(color: gradientGreen, location: 1.00)
        ]
    }

    static var siriGradientLeadingTrailing: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: gradientGradientStops),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    static let tooltipText = "Hover to expand"

    // Ghost cursor demo (post-morph only — does not affect glow timing)
    static let ghostCursorFadeInDuration: TimeInterval = 0.45
    static let ghostCursorApproachDuration: TimeInterval = 1.15
    static let ghostCursorRetreatDuration: TimeInterval = 0.95
    /// Subtle vertical bob — long easeInOut, tiny amplitude.
    static let ghostCursorNudgeUpDuration: TimeInterval = 0.95
    static let ghostCursorNudgeDownDuration: TimeInterval = 0.95
    static let ghostCursorNudgeBetweenPecksDuration: TimeInterval = 0.12
    static let ghostCursorNudgeLoopPauseDuration: TimeInterval = 1.1
    static let ghostCursorDwellDuration: TimeInterval = 1.2
    static let ghostCursorFadeOutDuration: TimeInterval = 0.35
    static let ghostCursorPeakOpacity: Double = 0.65
    static let ghostCursorSize: CGFloat = 22
    static let ghostCursorSymbolName = "hand.point.up.left.fill"
    /// `hand.point.up.left` tip sits left of the glyph center — bias so the tip hits the icons.
    static let ghostCursorTipBiasX: CGFloat = 7
    /// Compact trailing pad + half of (mark + gap + mark) — center of YouTube/Music pair.
    /// Matches `IdleGlanceContent` compact right ear (pad 8, marks 16, spacing 8).
    static let ghostCursorRightEarClusterFromTrailing: CGFloat = 28
    /// How far below settle the soft nudge rests (points). Must clear the
    /// island bottom so the hand sits outside and only enters on the up peck.
    static let ghostCursorNudgeDip: CGFloat = 16
    /// How far below settle the demo approach starts (points).
    static let ghostCursorApproachDip: CGFloat = 16

    static var ghostCursorFadeAnimation: Animation {
        .easeOut(duration: ghostCursorFadeInDuration)
    }
    static var ghostCursorApproachAnimation: Animation {
        .timingCurve(0.33, 0.0, 0.2, 1.0, duration: ghostCursorApproachDuration)
    }
    static var ghostCursorRetreatAnimation: Animation {
        .timingCurve(0.33, 0.0, 0.2, 1.0, duration: ghostCursorRetreatDuration)
    }
    static var ghostCursorNudgeUpAnimation: Animation {
        .easeInOut(duration: ghostCursorNudgeUpDuration)
    }
    static var ghostCursorNudgeDownAnimation: Animation {
        .easeInOut(duration: ghostCursorNudgeDownDuration)
    }
    static var ghostCursorFadeOutAnimation: Animation {
        .easeIn(duration: ghostCursorFadeOutDuration)
    }

    /// YouTube / Music cluster in the compact right ear — same X for compact and expanded.
    static func ghostCursorSettleOffset(islandWidth: CGFloat) -> CGSize {
        CGSize(
            width: max(islandWidth * 0.5 - ghostCursorRightEarClusterFromTrailing + ghostCursorTipBiasX, 36),
            height: 2
        )
    }

    /// Directly below the same X — vertical-only approach (no sideways drift).
    static func ghostCursorAwayOffset(islandWidth: CGFloat) -> CGSize {
        let settle = ghostCursorSettleOffset(islandWidth: islandWidth)
        return CGSize(width: settle.width, height: settle.height + ghostCursorApproachDip)
    }

    static func ghostCursorNudgeRestOffset(islandWidth: CGFloat) -> CGSize {
        let settle = ghostCursorSettleOffset(islandWidth: islandWidth)
        return CGSize(width: settle.width, height: settle.height + ghostCursorNudgeDip)
    }

    static func ghostCursorNudgeRestProgress(islandWidth: CGFloat) -> CGFloat {
        let away = ghostCursorAwayOffset(islandWidth: islandWidth)
        let settle = ghostCursorSettleOffset(islandWidth: islandWidth)
        let rest = ghostCursorNudgeRestOffset(islandWidth: islandWidth)
        let dy = settle.height - away.height
        guard abs(dy) > 0.5 else { return 0.7 }
        return min(max((rest.height - away.height) / dy, 0), 1)
    }

    static func log(_ message: String) {
        NSLog("[FTUE] %@", message)
    }

    static func logGradientStopsAtRender() {
        let listed = zip(
            gradientStopHexes,
            gradientGradientStops.map(\.location)
        )
        .map { hex, loc in "\(hex)@\(String(format: "%.2f", loc))" }
        .joined(separator: ", ")
        log("spatial LinearGradient leading→trailing stopCount=\(gradientGradientStops.count)")
        log("gradient stops = [\(listed)]")
        log(
            "peakOpacity=\(glowPeakOpacity) coreBlur=\(Int(glowCoreBlur)) outerBlur=\(Int(glowOuterBlur)) inset=\(glowFillInsetScale)"
        )
    }
}

enum NotchFTUEStore {
    static func shouldPlay(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: NotchFTUEMetrics.defaultsKey)
    }

    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: NotchFTUEMetrics.defaultsKey)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: NotchFTUEMetrics.defaultsKey)
    }
}

enum NotchFTUEPhase: Equatable {
    case idle
    case preparing
    case glowIn
    case hold
    case morph
    case demoExpand
    /// Ghost cursor settled on the notch; waiting for a real hover to dismiss it.
    case awaitingHover
}

// MARK: - Glow (always behind the black notch pill)

/// Soft bloom filled with a **static** left→right 6-stop `LinearGradient`.
/// Fill is inset under the black pill so the dissolve has no visible seam.
struct NotchFTUESiriGlow: View {
    /// 0 = invisible, 1 = peak bloom opacity.
    var amount: CGFloat
    var islandWidth: CGFloat
    var islandHeight: CGFloat
    var bottomLeadingRadius: CGFloat
    var bottomTrailingRadius: CGFloat

    private var silhouette: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomLeadingRadius,
            bottomTrailingRadius: bottomTrailingRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var glowWidth: CGFloat { islandWidth * NotchFTUEMetrics.glowWidthFactor }
    private var glowHeight: CGFloat { islandHeight * NotchFTUEMetrics.glowHeightFactor }

    var body: some View {
        let peak = Double(amount * NotchFTUEMetrics.glowPeakOpacity)

        ZStack {
            // Outer soft halo — hugs the silhouette with a small visible margin.
            gradientSilhouette(blur: NotchFTUEMetrics.glowOuterBlur)
                .opacity(0.95)

            // Vivid core — same inset; chroma stays high at peak.
            gradientSilhouette(blur: NotchFTUEMetrics.glowCoreBlur)
        }
        .frame(width: glowWidth, height: glowHeight, alignment: .top)
        .opacity(peak)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            NotchFTUEMetrics.logGradientStopsAtRender()
            NotchFTUEMetrics.log(
                "glow mounted amount=\(amount) size=\(Int(glowWidth))x\(Int(glowHeight)) inset=\(NotchFTUEMetrics.glowFillInsetScale)"
            )
        }
        .onChange(of: amount) { _, newValue in
            if newValue > 0.95 {
                NotchFTUEMetrics.logGradientStopsAtRender()
                NotchFTUEMetrics.log("peak bloom — tight halo, seam hidden under pill")
            }
        }
    }

    private func gradientSilhouette(blur: CGFloat) -> some View {
        silhouette
            .fill(NotchFTUEMetrics.siriGradientLeadingTrailing)
            .frame(width: glowWidth, height: glowHeight)
            // Keep the opaque gradient edge under the black pill. Blur alone
            // softens outward; without inset, the pill rim reads as a seam.
            .scaleEffect(NotchFTUEMetrics.glowFillInsetScale, anchor: .top)
            .drawingGroup(opaque: false)
            .blur(radius: blur)
    }
}

// MARK: - Tooltip (attached beside ghost cursor)

struct NotchFTUETooltip: View {
    var body: some View {
        Text(NotchFTUEMetrics.tooltipText)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Ghost cursor (post-morph hover demo)

/// Pointing hand + label. `progress` 0 = approach start, 1 = settle on YouTube ear.
/// Tooltip stays to the **right** of the hand (original placement). Layout always
/// reserves label width so “Hover to expand” isn’t clipped to “H”, and so the
/// hand X does not jump when the tip hides during the expand demo.
struct NotchFTUEGhostCursor: View {
    var progress: CGFloat
    var opacity: Double
    var showsLabel: Bool
    /// Compact island width — settle tracks the trailing icon ear.
    var islandWidth: CGFloat

    /// Enough for “Hover to expand” at 11pt semibold + horizontal padding.
    private static let tooltipLayoutReserve: CGFloat = 118

    var body: some View {
        let hand = NotchFTUEMetrics.ghostCursorSize
        // Always reserve tip width while the ghost is mounted — toggling only
        // visibility would shift the hand when expand hides the label.
        let labelExtra: CGFloat = 6 + Self.tooltipLayoutReserve

        Image(systemName: NotchFTUEMetrics.ghostCursorSymbolName)
            .font(.system(size: hand, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
            .opacity(opacity * NotchFTUEMetrics.ghostCursorPeakOpacity)
            .frame(width: hand, height: hand)
            .overlay(alignment: .leading) {
                if showsLabel {
                    NotchFTUETooltip()
                        .opacity(opacity)
                        .fixedSize()
                        .offset(x: hand + 6, y: 0)
                        .transition(.opacity)
                }
            }
            // Expand layout bounds to the right of the hand (offset alone does not).
            .frame(width: hand + labelExtra, height: hand, alignment: .leading)
            // Wider frame is centered by the parent overlay — nudge so the hand
            // stays on the same settle point as the hand-only layout.
            .offset(
                x: travelOffset.width + labelExtra / 2,
                y: travelOffset.height
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var travelOffset: CGSize {
        let away = NotchFTUEMetrics.ghostCursorAwayOffset(islandWidth: islandWidth)
        let settle = NotchFTUEMetrics.ghostCursorSettleOffset(islandWidth: islandWidth)
        let t = min(max(progress, 0), 1)
        return CGSize(
            width: away.width + (settle.width - away.width) * t,
            height: away.height + (settle.height - away.height) * t
        )
    }
}
