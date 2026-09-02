import AppKit
import SwiftUI

private enum LiveActivityPalette {
    static let recordRed = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let airDropBlue = Color(nsColor: .systemBlue)
    static let compactRecordBlue = Color(red: 0.22, green: 0.62, blue: 1.0)
}

struct CompactLiveActivityRow: View {
    var showAirDrop: Bool
    var isRecording: Bool
    var isSelectingRecord: Bool = false

    var body: some View {
        HStack {
            if showAirDrop {
                AirDropRadar(size: 16)
            } else if isRecording || isSelectingRecord {
                RecordingPulseDot(size: 8, blinks: isRecording)
            }
            Spacer(minLength: 0)
            if showAirDrop, isRecording {
                Image(systemName: "record.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LiveActivityPalette.compactRecordBlue)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScreenRecordingIsland: View {
    var elapsed: TimeInterval
    var onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    RecordingPulseDot(size: 7, color: LiveActivityPalette.recordRed, blinks: false)
                    Text(Self.timestamp(elapsed))
                        .font(.system(size: 12, weight: .regular).monospacedDigit())
                        .foregroundStyle(LiveActivityPalette.recordRed)
                }
                Text("Screen Recording")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 8)
            Button(action: onStop) {
                RecordingStopControl(size: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop screen recording")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static func timestamp(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct AirDropTransferIsland: View {
    var progress: Double
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            AirDropRadar(size: 16)
            Text("AirDrop")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            Button(action: onStop) {
                AirDropProgressStop(progress: progress, size: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AirDropCompleteIsland: View {
    var arrival: AirDropArrival

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                AirDropGlyphBadge(size: 16)
                    .offset(x: 3, y: 3)
            }
            .padding(.trailing, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("AirDrop Complete")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(arrival.subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = arrival.thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12))
        }
    }
}

private struct RecordingStopControl: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white, lineWidth: 1.5)
            RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                .fill(LiveActivityPalette.recordRed)
                .frame(width: size * 0.38, height: size * 0.38)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

private struct RecordingPulseDot: View {
    var size: CGFloat
    var color: Color = LiveActivityPalette.recordRed
    var blinks: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Full ease-in-out cycle: dim → bright → dim.
    private static let period: TimeInterval = 4.0

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { context in
            let opacity: CGFloat = {
                guard !reduceMotion, blinks else { return 1 }
                let t = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.period) / Self.period
                let eased = 0.5 - 0.5 * cos(t * 2 * .pi)
                return 0.5 + 0.5 * eased
            }()
            Circle()
                .fill(color.opacity(opacity))
                .frame(width: size, height: size)
        }
    }
}

enum AirDropCenter {
    case roundedSquare
    case circle
}

/// Latest Apple AirDrop glyph from macOS CoreTypes, tinted system blue.
struct AirDropRadar: View {
    var size: CGFloat
    var tint: Color = LiveActivityPalette.airDropBlue
    var center: AirDropCenter = .circle

    var body: some View {
        ZStack {
            if let icon = Self.systemGlyph {
                Image(nsImage: icon)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                AirDropRadarRings()
                    .stroke(tint, style: StrokeStyle(lineWidth: max(1.15, size * 0.07), lineCap: .round))
                centerMark
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var centerMark: some View {
        let mark = size * 0.16
        switch center {
        case .roundedSquare:
            RoundedRectangle(cornerRadius: mark * 0.28, style: .continuous)
                .fill(tint)
                .frame(width: mark, height: mark)
        case .circle:
            Circle()
                .fill(tint)
                .frame(width: mark, height: mark)
        }
    }

    private static let systemGlyph: NSImage? = {
        let candidates = [
            "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AirDrop.icns",
            "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarAirDrop.icns"
        ]
        for path in candidates {
            if let image = NSImage(contentsOfFile: path) {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }()
}

private struct AirDropRadarRings: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let maxRadius = min(rect.width, rect.height) * 0.46
        let start = Angle.degrees(302)
        let end = Angle.degrees(238)
        for i in 1...4 {
            let radius = maxRadius * CGFloat(i) / 4
            var arc = Path()
            arc.addArc(
                center: center,
                radius: radius,
                startAngle: start,
                endAngle: end,
                clockwise: false
            )
            path.addPath(arc)
        }
        return path
    }
}

private struct AirDropGlyphBadge: View {
    var size: CGFloat

    var body: some View {
        AirDropRadar(size: size * 0.62, tint: .white, center: .circle)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LiveActivityPalette.airDropBlue)
            )
    }
}

private struct AirDropCheck: View {
    var size: CGFloat

    /// Previous SF Symbol `.heavy` stroke measured ~2.6pt at this circle size.
    /// 70% of that thickness, scaled with the circle.
    private var strokeWidth: CGFloat { size * (1.82 / 28) }

    var body: some View {
        ZStack {
            Circle()
                .fill(LiveActivityPalette.airDropBlue)
            AirDropCheckmark()
                .stroke(
                    .white,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                )
                .frame(width: size * 0.46, height: size * 0.46)
        }
        .frame(width: size, height: size)
    }
}

private struct AirDropCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY + rect.height * 0.04))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.06))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.minY + rect.height * 0.12))
        return path
    }
}

private struct AirDropProgressStop: View {
    var progress: Double
    var size: CGFloat

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        if clamped >= 1 {
            AirDropCheck(size: size)
        } else {
            let line = max(2.4, size * 0.1)
            let mark = size * 0.28
            ZStack {
                Circle()
                    .stroke(LiveActivityPalette.airDropBlue.opacity(0.28), lineWidth: line)
                Circle()
                    .trim(from: 0, to: CGFloat(clamped))
                    .stroke(
                        LiveActivityPalette.airDropBlue,
                        style: StrokeStyle(lineWidth: line, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                RoundedRectangle(cornerRadius: mark * 0.28, style: .continuous)
                    .fill(LiveActivityPalette.airDropBlue)
                    .frame(width: mark, height: mark)
            }
            .frame(width: size, height: size)
        }
    }
}
