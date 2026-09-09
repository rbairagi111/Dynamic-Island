import SwiftUI

// MARK: - Figma shadow spec: X 0, Y 2, Blur 24, Color #000 55%
// SwiftUI radius ≈ Figma blur ÷ 2

private extension View {
    func notchShadow(compact _: Bool, expanded: Bool) -> some View {
        shadow(
            color: expanded ? .black.opacity(0.55) : .clear,
            radius: expanded ? 12 : 0,
            x: 0,
            y: expanded ? 2 : 0
        )
    }
}

// MARK: - Root view

struct NotchView: View {
    @EnvironmentObject var model: NotchViewModel
    @Namespace private var island

    private var shapeWidth: CGFloat { model.islandShapeWidth }
    private var shapeHeight: CGFloat { model.islandShapeHeight }
    private var islandTopOffset: CGFloat { model.islandTopOffset }
    private var bottomRadius: CGFloat {
        switch model.transientOverlay {
        case .charging, .lowBattery, .volume, .brightness, .focusMode:
            return IslandMetrics.chargingRadius
        default:
            if model.showsRecordingExpanded {
                return IslandMetrics.recordingRadius
            }
            return model.isExpanded || model.isOverlayActive
                ? IslandMetrics.expandedRadius
                : IslandMetrics.compactBottomRadius
        }
    }

    private var showsRecordingCompactStroke: Bool {
        (model.isScreenRecording || model.isSelectingScreenToRecord)
            && !model.isExpanded
            && !model.isOverlayActive
    }

    private var showsRecordingCompactGlow: Bool {
        model.isScreenRecording && !model.isExpanded && !model.isOverlayActive
    }

    /// Compact Now Playing + recording: artwork and waveform stay together on
    /// the leading edge; the recording pulse stays on the trailing edge.
    private var showsCompactRecordingMedia: Bool {
        !model.isExpanded && model.isScreenRecording && model.persistentState == .musicPlaying
    }

    /// YouTube Music metadata is already on the view model in compact; watch
    /// compact stays art + waveform only.
    private var showsCompactMusicText: Bool {
        !model.isExpanded
            && !model.isOverlayActive
            && model.hasMedia
            && model.mediaPlatform == .youtubeMusic
    }

    private var compactRecordingMediaSpacing: CGFloat {
        if model.isExpanded { return 12 }
        if showsCompactRecordingMedia || showsCompactMusicText { return 8 }
        return 0
    }

    private var islandStrokeColor: Color {
        showsRecordingCompactStroke
            ? IslandMetrics.recordingStroke
            : IslandMetrics.islandStroke
    }

    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: 0
        )
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .overlay(alignment: .top) {
                islandCard
            }
    }

    private var islandCard: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                islandShape
                    .fill(Color.black)

                if model.isOverlayActive {
                    overlayContent
                } else if model.showsMediaRecordingDual {
                    mediaRecordingDual
                } else if model.showsRecordingExpanded {
                    ScreenRecordingIsland(
                        elapsed: model.recordingElapsed,
                        onStop: model.stopScreenRecording
                    )
                    .padding(.top, IslandMetrics.expandedContentTopInset(notchHeight: model.notchHeight))
                    .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
                } else if model.showsCompactLiveActivity {
                    CompactLiveActivityRow(
                        isRecording: model.isScreenRecording,
                        isSelectingRecord: model.isSelectingScreenToRecord
                    )
                    .frame(width: shapeWidth, height: shapeHeight)
                } else if model.showsIdleGlance {
                    IdleGlanceContent(
                        isExpanded: model.isExpanded,
                        notchWidth: model.notchWidth,
                        notchHeight: model.notchHeight,
                        weather: model.idleWeather,
                        destinations: model.idleDestinations
                    )
                    .frame(width: shapeWidth, height: shapeHeight)
                } else {
                    nowPlayingContent
                }
            }
            .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
            .clipShape(islandShape)

            // Drawn outside clipShape so the hairline isn’t cropped to 0.5pt on black.
            if showsRecordingCompactGlow {
                // The active recording state gets both a soft light and a
                // crisp red rim. Keeping them separate prevents the glow from
                // washing out the thin silhouette shown in the reference.
                IslandUStroke(
                    bottomLeadingRadius: bottomRadius,
                    bottomTrailingRadius: bottomRadius
                )
                .stroke(
                    IslandMetrics.recordingStrokeGlow,
                    lineWidth: IslandMetrics.recordingStrokeGlowWidth
                )
                .blur(radius: 1.2)
                .allowsHitTesting(false)
            }

            IslandUStroke(
                bottomLeadingRadius: bottomRadius,
                bottomTrailingRadius: bottomRadius
            )
            .stroke(
                islandStrokeColor,
                lineWidth: showsRecordingCompactStroke
                    ? IslandMetrics.recordingStrokeWidth
                    : IslandMetrics.islandStrokeWidth
            )
            .allowsHitTesting(false)
        }
        .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
        .background {
            islandShape
                .fill(Color.black)
                .notchShadow(
                    compact: !model.isExpanded && !model.isOverlayActive,
                    expanded: model.isExpanded || model.isOverlayActive
                )
        }
        .padding(.top, islandTopOffset)
        .contentShape(islandShape)
        .modifier(IslandFileDrop())
        .onHover { hovering in
            // Overlay hover is SwiftUI-only. Music expand/collapse is AppKit
            // (`updateClickThrough`) so a control hover cannot collapse the island.
            guard model.isOverlayActive else { return }
            model.noteOverlayHover(hovering)
        }
        .animation(IslandMetrics.motion, value: model.isExpanded)
        .animation(IslandMetrics.motion, value: model.isOverlayActive)
        .animation(IslandMetrics.motion, value: model.transientOverlay)
        .animation(IslandMetrics.motion, value: model.isScreenRecording)
        .animation(IslandMetrics.motion, value: model.isSelectingScreenToRecord)
        .animation(IslandMetrics.motion, value: model.persistentState)
        .animation(IslandMetrics.motion, value: model.showsShelfRow)
        .animation(IslandMetrics.motion, value: model.shelfItems.count)
        .notchFTUEGlow(
            isActive: model.isFTUEGlowActive,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            onFinished: model.noteFTUEGlowFinished
        )
        .onAppear {
            model.noteIslandAppeared()
        }
    }

    // MARK: Compact ↔ expanded now playing (same tree so text can spring in)

    private var nowPlayingContent: some View {
        VStack(spacing: 0) {
            if model.isExpanded {
                Color.clear
                    .frame(height: IslandMetrics.expandedContentTopInset(notchHeight: model.notchHeight))
            }

            VStack(spacing: model.isExpanded ? 12 : 0) {
                HStack(alignment: .center, spacing: compactRecordingMediaSpacing) {
                    albumArtwork(
                        size: model.isExpanded ? 48 : IslandMetrics.compactArt,
                        cornerRadius: model.isExpanded ? 12 : 5
                    )
                    .matchedGeometryEffect(id: "artwork", in: island)
                    .padding(.leading, model.isExpanded ? 0 : 8)

                    if model.isExpanded {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.songTitle)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .allowsHitTesting(false)
                            Text(model.artistName)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                                .allowsHitTesting(false)
                        }
                        .transition(IslandMetrics.contentReveal)
                    } else if showsCompactMusicText {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.songTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .allowsHitTesting(false)
                            Text(model.artistName)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                                .allowsHitTesting(false)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if showsCompactRecordingMedia {
                        waveformIndicator(
                            barHeight: 13,
                            barWidth: 1.5125,
                            spacing: 1.5125
                        )
                        .matchedGeometryEffect(id: "waveform", in: island)
                    }

                    Spacer(minLength: model.isExpanded || showsCompactRecordingMedia || showsCompactMusicText ? 8 : 0)

                    if !showsCompactRecordingMedia {
                        waveformIndicator(
                            barHeight: model.isExpanded ? 22 : 13,
                            barWidth: model.isExpanded ? 2 : 1.5125,
                            spacing: model.isExpanded ? 2 : 1.5125
                        )
                        .matchedGeometryEffect(id: "waveform", in: island)
                        .padding(.trailing, model.isExpanded ? 0 : 8)
                    }

                    if showsCompactRecordingMedia {
                        RecordingPulseDot(size: 8, blinks: true)
                            .padding(.trailing, 10)
                    }
                }
                .frame(maxHeight: model.isExpanded ? nil : .infinity)

                if model.isExpanded {
                    HStack(spacing: IslandClickPolicy.progressTimeSpacing) {
                        Text(timeString(from: model.displayedTime))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(
                                width: IslandClickPolicy.progressLeadingTimeWidth,
                                alignment: .leading
                            )
                            .allowsHitTesting(false)

                        progressBar

                        Text(totalDurationLabel)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(
                                width: IslandClickPolicy.progressTrailingTimeWidth,
                                alignment: .trailing
                            )
                            .minimumScaleFactor(0.85)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    .transition(IslandMetrics.contentReveal)

                    HStack(spacing: 20) {
                        controlButton(system: "backward.fill", iconSize: 18, action: model.skipBackward)
                        controlButton(
                            system: model.isPlaying ? "pause.fill" : "play.fill",
                            iconSize: 24,
                            action: model.togglePlayPause
                        )
                        controlButton(system: "forward.fill", iconSize: 18, action: model.skipForward)
                    }
                    .frame(height: 40)
                    .padding(.top, 8)
                    .transition(IslandMetrics.contentReveal)
                }
            }
            .padding(.horizontal, model.isExpanded ? IslandMetrics.expandedHorizontalPadding : 0)
            .padding(
                .bottom,
                model.isExpanded && !model.showsShelfRow
                    ? IslandMetrics.expandedVerticalPadding
                    : 0
            )

            if model.isExpanded, model.showsShelfRow {
                ShelfTray(
                    items: model.shelfItems,
                    isDropTargeted: model.isDropTargeted,
                    onTargeted: { model.setDropTargeted($0) },
                    onDrop: { model.handleShelfDrop(providers: $0) },
                    onRemove: model.removeShelfItem,
                    onDragBegan: model.beginShelfDrag,
                    onDragEnded: { id, completed in
                        model.endShelfDrag(itemID: id, completedOutside: completed)
                    }
                )
                .frame(height: IslandMetrics.shelfRowHeight)
                .padding(.top, IslandMetrics.shelfIslandGap)
                .padding(.horizontal, IslandMetrics.expandedHorizontalPadding)
                .padding(.bottom, IslandMetrics.expandedVerticalPadding)
            }
        }
        .frame(
            width: shapeWidth,
            height: shapeHeight,
            alignment: model.isExpanded ? .top : .center
        )
    }

    // MARK: Dual overlay — music | divider | chat (matches the split mock)

    @ViewBuilder
    private var overlayContent: some View {
        switch model.transientOverlay {
        case .charging, .lowBattery, .volume, .brightness, .focusMode:
            if let overlay = model.transientOverlay {
                BatteryIslandOverlay(
                    overlay: overlay,
                    onLowBatteryClick: model.openBatterySettingsFromOverlay
                )
                .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
            }
        case .chatReady, .none:
            chatOverlayView
        }
    }

    private var chatOverlayView: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: IslandMetrics.expandedContentTopInset(notchHeight: model.notchHeight))

            if model.showsRecordingChatDual {
                dualActivitySplit(
                    left: recordingSplitColumn,
                    right: chatSplitColumn
                )
            } else if model.persistentState == .musicPlaying {
                dualActivitySplit(
                    left: musicSplitColumn,
                    right: chatSplitColumn
                )
            } else {
                chatOnlyColumn
                    .padding(.horizontal, IslandMetrics.chatOverlayHorizontalPadding)
            }
        }
        .padding(.bottom, IslandMetrics.chatOverlayBottomPadding)
        .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
    }

    private var mediaRecordingDual: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: IslandMetrics.expandedContentTopInset(notchHeight: model.notchHeight))

            dualActivitySplit(
                left: musicSplitColumn,
                right: recordingSplitColumn
            )
        }
        .padding(.bottom, IslandMetrics.chatOverlayBottomPadding)
        .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
    }

    private func dualActivitySplit<Left: View, Right: View>(
        left: Left,
        right: Right
    ) -> some View {
        GeometryReader { geo in
            let dividerWidth: CGFloat = 1
            let usableWidth = max(0, geo.size.width - dividerWidth)
            let leftWidth = usableWidth * IslandMetrics.dualLeftRatio
            let rightWidth = usableWidth * IslandMetrics.dualRightRatio

            HStack(alignment: .top, spacing: 0) {
                left
                    .frame(width: leftWidth)
                    .frame(maxHeight: .infinity)

                Rectangle()
                    .fill(IslandGradientDivider.gradient)
                    .frame(width: dividerWidth)
                    .frame(maxHeight: .infinity)

                right
                    .frame(width: rightWidth)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .padding(.horizontal, IslandMetrics.chatOverlayHorizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var musicSplitColumn: some View {
        musicSplitHeader
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                musicSplitControls
                    .frame(height: IslandMetrics.dualActionRowHeight)
                    .frame(maxWidth: .infinity)
            }
            .padding(.trailing, IslandMetrics.chatOverlayColumnSpacing)
    }

    private var musicSplitHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            albumArtwork(size: 40, cornerRadius: 10)
                .matchedGeometryEffect(id: "artwork", in: island)
                .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                Text(model.songTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsHitTesting(false)
                Text(model.artistName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            waveformIndicator(
                barHeight: 15,
                barWidth: 1.5,
                spacing: 1.5,
                barCount: 6
            )
            .matchedGeometryEffect(id: "waveform", in: island)
            .fixedSize()
        }
    }

    private var musicSplitControls: some View {
        HStack(spacing: 20) {
            controlButton(system: "backward.fill", iconSize: 15, side: 36, action: model.skipBackward)
            controlButton(
                system: model.isPlaying ? "pause.fill" : "play.fill",
                iconSize: 19,
                side: 36,
                action: model.togglePlayPause
            )
            controlButton(system: "forward.fill", iconSize: 15, side: 36, action: model.skipForward)
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingSplitColumn: some View {
        ScreenRecordingSplitColumn(
            elapsed: model.recordingElapsed,
            onStop: model.stopScreenRecording,
            usesChatDualPadding: model.showsRecordingChatDual
        )
        .padding(.leading, model.showsRecordingChatDual ? 0 : IslandMetrics.chatOverlayColumnSpacing)
        .padding(.trailing, model.showsRecordingChatDual ? IslandMetrics.chatOverlayColumnSpacing : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatSplitColumn: some View {
        chatOverlayButton
            .padding(.leading, IslandMetrics.chatOverlayColumnSpacing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatOnlyColumn: some View {
        chatOverlayButton
    }

    private var chatOverlayButton: some View {
        Button(action: model.openChatTabFromOverlay) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    chatMark
                    Text(model.transientOverlay?.provider.displayName ?? "Chat")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(chatResponseCopy)
                    .font(.system(size: 12.5, weight: .light))
                    .foregroundStyle(Color(red: 0xED / 255, green: 0xED / 255, blue: 0xED / 255))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                HStack(spacing: 6) {
                    Text("Check Now")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .frame(height: IslandMetrics.dualActionRowHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatMark: some View {
        Image(model.transientOverlay?.provider.logoAssetName ?? "ClaudeLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var chatResponseCopy: String {
        let cleaned = Self.strippedChatPreview(
            model.transientOverlay?.preview ?? ""
        )
        if cleaned.isEmpty {
            return "Response ready"
        }
        return cleaned
    }

    /// DOM / a11y text often already includes this phrase — keep a single prefix.
    private static func strippedChatPreview(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "Show message actions for ",
            "Claude responded: ",
            "ChatGPT said: ",
            "ChatGPT responded: ",
            "Gemini said: ",
            "You said: "
        ]
        var keepGoing = true
        while keepGoing {
            keepGoing = false
            for prefix in prefixes {
                if text.lowercased().hasPrefix(prefix.lowercased()) {
                    text = String(text.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    keepGoing = true
                }
            }
        }
        return text
    }

    private func controlButton(
        system: String,
        iconSize: CGFloat,
        side: CGFloat = 40,
        action: @escaping () -> Void
    ) -> some View {
        IslandTransportButton(system: system, iconSize: iconSize, side: side, action: action)
    }

    // MARK: Album Artwork

    private func albumArtwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Group {
            if let artwork = model.artwork {
                // Color.clear owns the layout size so the image never
                // first-layouts at its intrinsic (fit) size then jumps to fill.
                Color.clear
                    .overlay {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: model.usesPlatformLogo ? .fit : .fill)
                            .transaction { $0.animation = nil }
                            .id(ObjectIdentifier(artwork))
                    }
                    .clipped()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white.opacity(0.12))
                    Image(systemName: model.hasMedia ? "music.note" : "music.note.list")
                        .font(.system(size: size * 0.45, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityLabel(model.mediaPlatform?.displayName ?? "Now Playing artwork")
        .accessibilityValue(model.usesPlatformLogo ? "Official platform logo" : "Video thumbnail")
    }

    // MARK: Waveform Indicator

    private func waveformIndicator(
        barHeight: CGFloat,
        barWidth: CGFloat,
        spacing: CGFloat,
        barCount: Int = 7
    ) -> some View {
        SimulatedWaveformBars(
            waveform: model.waveform,
            gradient: model.hasMedia ? model.waveformGradient : .idle,
            barHeight: barHeight,
            barWidth: barWidth,
            spacing: spacing,
            barCount: barCount
        )
    }

    // MARK: Progress Bar

    private var progressBar: some View {
        GeometryReader { geo in
            let progress = model.duration > 0
                ? CGFloat(model.displayedTime / model.duration)
                : 0
            let clamped = min(max(progress, 0), 1)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.45))
                    .frame(width: geo.size.width * clamped, height: 4)

                // Scrub knob — a bit larger while dragging.
                Circle()
                    .fill(Color.white.opacity(0.7))
                    .frame(
                        width: model.isScrubbing ? 10 : 8,
                        height: model.isScrubbing ? 10 : 8
                    )
                    .offset(x: max(0, geo.size.width * clamped - (model.isScrubbing ? 5 : 4)))
                    .opacity(model.hasMedia ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = Double(value.location.x / max(geo.size.width, 1))
                        if model.isScrubbing {
                            model.updateScrubbing(fraction: fraction)
                        } else {
                            model.beginScrubbing(at: fraction)
                        }
                    }
                    .onEnded { value in
                        let fraction = Double(value.location.x / max(geo.size.width, 1))
                        model.endScrubbing(fraction: fraction)
                    }
            )
        }
        .frame(height: 16) // taller hit target; bar itself stays 4pt
    }

    // MARK: Helpers

    private var totalDurationLabel: String {
        guard model.duration > 0 else { return "0:00" }
        return timeString(from: model.duration)
    }

    /// Elapsed / total labels: `m:ss`, or `h:mm:ss` once past one hour.
    private func timeString(from seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

private struct IslandTransportButton: View {
    let system: String
    let iconSize: CGFloat
    var side: CGFloat = 40
    let action: () -> Void
    @State private var isHovered = false

    private var hoverRadius: CGFloat { 8 }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: hoverRadius, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.10) : Color.clear)
                Image(systemName: system)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: side, height: side)
            .contentShape(RoundedRectangle(cornerRadius: hoverRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(system)
    }
}

private struct IslandFileDrop: ViewModifier {
    @EnvironmentObject var model: NotchViewModel

    func body(content: Content) -> some View {
        content.onDrop(
            of: ShelfDropIngest.acceptedTypes,
            isTargeted: Binding(
                get: { model.isDropTargeted },
                set: { model.setDropTargeted($0) }
            )
        ) { providers in
            model.handleShelfDrop(providers: providers)
        }
    }
}

/// Left, bottom, and right edge only — no stroke along the screen’s top.
private struct IslandUStroke: Shape {
    var bottomLeadingRadius: CGFloat
    var bottomTrailingRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomLeadingRadius, bottomTrailingRadius) }
        set {
            bottomLeadingRadius = newValue.first
            bottomTrailingRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Center the 1pt stroke on the silhouette so half sits on the desktop
        // (visible) instead of entirely inside the black fill.
        let inset = IslandMetrics.islandStrokeWidth / 2
        let bounds = rect.insetBy(dx: inset, dy: 0)
        let maxCorner = min(bounds.height - inset, bounds.width / 2)
        let bl = min(max(bottomLeadingRadius, 0), maxCorner)
        let br = min(max(bottomTrailingRadius, 0), maxCorner)

        var path = Path()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY - bl))
        if bl > 0 {
            path.addArc(
                tangent1End: CGPoint(x: bounds.minX, y: bounds.maxY),
                tangent2End: CGPoint(x: bounds.minX + bl, y: bounds.maxY),
                radius: bl
            )
        }
        path.addLine(to: CGPoint(x: bounds.maxX - br, y: bounds.maxY))
        if br > 0 {
            path.addArc(
                tangent1End: CGPoint(x: bounds.maxX, y: bounds.maxY),
                tangent2End: CGPoint(x: bounds.maxX, y: bounds.maxY - br),
                radius: br
            )
        }
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        return path
    }
}

/// Isolated so 30 fps level updates don’t redraw the whole island.
private struct SimulatedWaveformBars: View {
    @ObservedObject var waveform: SimulatedWaveform
    var gradient: ArtworkTint.Gradient
    var barHeight: CGFloat
    var barWidth: CGFloat
    var spacing: CGFloat
    var barCount: Int

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let amplitude = WaveformLayout.level(
                    at: i,
                    displayCount: barCount,
                    stored: waveform.levels
                )
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(
                        LinearGradient(
                            colors: [gradient.top, gradient.bottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(
                        width: barWidth,
                        height: max(2, amplitude * barHeight)
                    )
            }
        }
        .frame(height: barHeight)
        .animation(nil, value: waveform.levels)
    }
}
