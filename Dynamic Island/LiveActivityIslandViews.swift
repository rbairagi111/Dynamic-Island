import SwiftUI

private enum LiveActivityPalette {
    static let recordRed = Color(red: 1.0, green: 0.27, blue: 0.23)
}

struct CompactLiveActivityRow: View {
    var isRecording: Bool
    var isSelectingRecord: Bool = false

    var body: some View {
        HStack {
            if isRecording || isSelectingRecord {
                RecordingPulseDot(size: 8, blinks: isRecording)
            }
            Spacer(minLength: 0)
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
                RecordingStopControl(size: IslandMetrics.recordingStopSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop screen recording")
        }
        .padding(.horizontal, IslandMetrics.recordingStopTrailingPad)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func timestamp(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct ScreenRecordingSplitColumn: View {
    var elapsed: TimeInterval
    var onStop: () -> Void
    /// When true, use the YouTube | AI column: header at the top, action on
    /// the bottom row. Otherwise keep the compact centered cluster used when
    /// recording sits beside Now Playing.
    var usesChatDualPadding: Bool = false

    var body: some View {
        if usesChatDualPadding {
            overlayColumn
        } else {
            centeredCluster
        }
    }

    private var overlayColumn: some View {
        header
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                Button(action: onStop) {
                    RecordingStopControl(size: IslandMetrics.recordingStopSize)
                }
                .buttonStyle(.plain)
                .frame(height: IslandMetrics.dualActionRowHeight)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Stop screen recording")
            }
    }

    private var centeredCluster: some View {
        HStack(alignment: .center, spacing: 12) {
            header
            Spacer(minLength: 8)
            Button(action: onStop) {
                RecordingStopControl(size: IslandMetrics.recordingStopSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop screen recording")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RecordingPulseDot(size: 7, color: LiveActivityPalette.recordRed, blinks: false)
                Text(ScreenRecordingIsland.timestamp(elapsed))
                    .font(.system(size: 12, weight: .regular).monospacedDigit())
                    .foregroundStyle(LiveActivityPalette.recordRed)
            }
            Text("Screen Recording")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct RecordingStopControl: View {
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

struct RecordingPulseDot: View {
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
