import SwiftUI

enum IslandBatteryPalette {
    static let chargingFill = Color(red: 135 / 255, green: 224 / 255, blue: 138 / 255)
    static let chargingEmpty = Color(red: 0.27, green: 0.34, blue: 0.16)
    static let lowRed = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let lowEmpty = Color(red: 0.35, green: 0.12, blue: 0.10)
    static let lowPowerAmber = Color(red: 1.0, green: 0.72, blue: 0.29)
    static let soundFill = Color.white
    static let soundEmpty = Color.white.opacity(0.22)
    static let brightnessFill = Color.white
    static let brightnessEmpty = Color.white.opacity(0.22)
    /// Focus On label / moon: #5853D7
    static let focusOn = Color(red: 88 / 255, green: 83 / 255, blue: 215 / 255)
}

private enum IslandBatteryMetrics {
    static let percentSize: CGFloat = 12
    /// 24px @2x → 12pt. Width stays 62px / 31pt.
    static let pillHeight: CGFloat = 12
    /// 62px @2x → 31pt.
    static let pillWidth: CGFloat = 31
    static let pillRadius: CGFloat = 4
    static let pillFillMinWidth: CGFloat = 5
    /// Sound / brightness track: white capsule bar.
    static let barWidth: CGFloat = 72
    static let barHeight: CGFloat = 5
}

/// Charging / battery bar. Radius is 4pt (not a full capsule).
struct IslandBatteryCapsule: View {
    var percent: Double
    var fill: Color
    var empty: Color

    var body: some View {
        let clamped = min(max(percent, 0), 1)
        let shape = RoundedRectangle(
            cornerRadius: IslandBatteryMetrics.pillRadius,
            style: .continuous
        )
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                shape.fill(empty)
                shape
                    .fill(
                        LinearGradient(
                            colors: [fill, fill.opacity(0.82)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(geo.size.width * CGFloat(clamped), clamped > 0 ? IslandBatteryMetrics.pillFillMinWidth : 0))
            }
        }
        .frame(width: IslandBatteryMetrics.pillWidth, height: IslandBatteryMetrics.pillHeight)
        .clipShape(shape)
    }
}

struct IslandLevelBar: View {
    var percent: Double
    var fill: Color
    var empty: Color

    var body: some View {
        let clamped = min(max(percent, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(empty)
                Capsule()
                    .fill(fill)
                    .frame(width: max(geo.size.width * CGFloat(clamped), clamped > 0 ? 2 : 0))
            }
        }
        .frame(width: IslandBatteryMetrics.barWidth, height: IslandBatteryMetrics.barHeight)
    }
}

/// Video reference: soft red halo breathes behind the same capsule.
struct LowBatteryCapsule: View {
    var percent: Double
    var reduceMotion: Bool

    var body: some View {
        let pillW = IslandBatteryMetrics.pillWidth
        let pillH = IslandBatteryMetrics.pillHeight
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { context in
            let wave = reduceMotion
                ? 0.45
                : (sin(context.date.timeIntervalSinceReferenceDate * .pi / 0.9) + 1) / 2
            ZStack {
                RoundedRectangle(
                    cornerRadius: IslandBatteryMetrics.pillRadius,
                    style: .continuous
                )
                    .fill(IslandBatteryPalette.lowRed.opacity(0.18 + 0.42 * wave))
                    .blur(radius: 5)
                    .frame(width: pillW * (38.0 / 27.0), height: pillH * (20.0 / 10.0))
                    .scaleEffect(0.92 + 0.22 * wave)
                    .allowsHitTesting(false)
                RoundedRectangle(
                    cornerRadius: IslandBatteryMetrics.pillRadius,
                    style: .continuous
                )
                    .stroke(IslandBatteryPalette.lowRed.opacity(0.15 + 0.35 * wave), lineWidth: 0.5)
                    .frame(width: pillW * (33.0 / 27.0), height: pillH * (15.0 / 10.0))
                    .scaleEffect(0.96 + 0.1 * wave)
                    .allowsHitTesting(false)
                IslandBatteryCapsule(
                    percent: percent,
                    fill: IslandBatteryPalette.lowRed,
                    empty: IslandBatteryPalette.lowEmpty
                )
            }
            .frame(width: pillW, height: pillH)
        }
    }
}

struct BatteryIslandOverlay: View {
    var overlay: TransientOverlay
    var onLowBatteryClick: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch overlay {
            case .charging(let percent):
                levelHUDRow(
                    title: "Charging",
                    percent: percent,
                    percentColor: IslandBatteryPalette.chargingFill,
                    leading: {
                        IOSLevelIcon(
                            systemName: "bolt.fill",
                            value: 1
                        )
                    }
                ) {
                    IslandBatteryCapsule(
                        percent: Double(percent) / 100,
                        fill: IslandBatteryPalette.chargingFill,
                        empty: IslandBatteryPalette.chargingEmpty
                    )
                }
            case .lowBattery(let percent):
                Button(action: onLowBatteryClick) {
                    levelHUDRow(
                        title: "Low Battery",
                        percent: percent,
                        percentColor: IslandBatteryPalette.lowRed,
                        leading: {
                            IOSLevelIcon(
                                systemName: "bolt.fill",
                                value: 1,
                                tint: Color.white.opacity(0.45)
                            )
                        }
                    ) {
                        LowBatteryCapsule(
                            percent: Double(percent) / 100,
                            reduceMotion: reduceMotion
                        )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .volume(let percent, let muted):
                let shown = muted ? 0 : percent
                levelHUDRow(
                    title: muted ? "Muted" : "Sound",
                    percent: shown,
                    showsPercent: false,
                    leading: {
                        IOSLevelIcon(
                            systemName: muted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                            value: Double(shown) / 100
                        )
                    }
                ) {
                    IslandLevelBar(
                        percent: Double(shown) / 100,
                        fill: IslandBatteryPalette.soundFill,
                        empty: IslandBatteryPalette.soundEmpty
                    )
                }
            case .brightness(let percent):
                levelHUDRow(
                    title: "Brightness",
                    percent: percent,
                    showsPercent: false,
                    leading: {
                        IOSLevelIcon(
                            systemName: "sun.max.fill",
                            value: Double(percent) / 100
                        )
                    }
                ) {
                    IslandLevelBar(
                        percent: Double(percent) / 100,
                        fill: IslandBatteryPalette.brightnessFill,
                        empty: IslandBatteryPalette.brightnessEmpty
                    )
                }
            case .focusMode(let isOn):
                HStack(spacing: 7) {
                    IOSLevelIcon(
                        systemName: "moon.fill",
                        value: isOn ? 1 : 0,
                        tint: isOn ? IslandBatteryPalette.focusOn : Color.white
                    )
                    Text("Focus mode")
                        .font(.system(size: IslandBatteryMetrics.percentSize, weight: .regular))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    Text(isOn ? "On" : "Off")
                        .font(.system(size: IslandBatteryMetrics.percentSize, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.55))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .chatReady:
                EmptyView()
            }
        }
    }

    private func levelHUDRow<Leading: View, Trailing: View>(
        title: String,
        percent: Int,
        percentColor: Color = .white,
        showsPercent: Bool = true,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 7) {
            leading()
            Text(title)
                .font(.system(size: IslandBatteryMetrics.percentSize, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            if showsPercent {
                Text("\(percent)%")
                    .font(.system(size: IslandBatteryMetrics.percentSize, weight: .regular).monospacedDigit())
                    .foregroundStyle(percentColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            trailing()
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// iOS SF Symbols: speaker, sun, and battery glyphs with level-aware fill.
private struct IOSLevelIcon: View {
    var systemName: String
    var value: Double
    var tint: Color = .white
    var width: CGFloat = 16

    var body: some View {
        Image(systemName: systemName, variableValue: min(max(value, 0), 1))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: width, height: 14)
    }
}
