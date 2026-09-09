import CoreGraphics
import Foundation

/// Maps a click on the island to an action without relying on SwiftUI buttons.
/// The desktop island is a nonactivating panel, so play/pause and “open tab”
/// clicks often never reach SwiftUI — the same reason recording Stop is AppKit.
enum IslandClickPolicy {
    enum Action: Equatable {
        /// Progress, shelf, charging — leave for existing views.
        case passthrough
        case revealNowPlaying
        case openChat
        case openBatterySettings
        case playPause
        case skipBack
        case skipForward
        /// Scrub the timeline — SwiftUI drag never fires in this panel.
        case seek
        /// Compact recording pill — expand so Stop is reachable.
        case expandRecording
        /// Behavior-ranked idle destination icon.
        case openIdleDestination(Int)
    }

    /// Bottom band reserved for play/pause, scrubbing, and the file shelf.
    static let expandedTransportBand: CGFloat = 82
    /// Play/pause/skip sit in the lower part of that band; the progress bar is above.
    /// 40pt buttons + 8pt row padding + 14pt island padding.
    static let expandedControlBand: CGFloat = 62
    /// Hit height of the elapsed/duration row above the transport buttons.
    static let expandedProgressBand: CGFloat = 32
    static let progressLeadingTimeWidth: CGFloat = 48
    static let progressTrailingTimeWidth: CGFloat = 54
    static let progressTimeSpacing: CGFloat = 10

    static func action(
        pointFromTopLeft: CGPoint,
        islandSize: CGSize,
        notchHeight: CGFloat,
        isExpanded: Bool,
        overlay: TransientOverlay?,
        hasMedia: Bool,
        persistentIsMusic: Bool,
        showsShelf: Bool = false,
        isScreenRecording: Bool = false,
        showsIdleGlance: Bool = false,
        idleDestinationCount: Int = 0
    ) -> Action {
        let bounds = CGRect(origin: .zero, size: islandSize)
        guard bounds.width > 1, bounds.height > 1, bounds.contains(pointFromTopLeft) else {
            return .passthrough
        }

        switch overlay {
        case .lowBattery:
            return .openBatterySettings
        case .chatReady:
            let dual = IslandSurfacePolicy.dualActivity(
                isScreenRecording: isScreenRecording,
                hasMedia: persistentIsMusic,
                overlay: overlay
            )
            if dual == .recordingAndChat {
                let pad = IslandMetrics.chatOverlayHorizontalPadding
                let innerWidth = max(0, islandSize.width - pad * 2)
                let recordingRight = pad + innerWidth * IslandMetrics.dualLeftRatio
                if pointFromTopLeft.x >= recordingRight {
                    return .openChat
                }
                return .passthrough
            }
            if persistentIsMusic {
                let pad = IslandMetrics.chatOverlayHorizontalPadding
                let innerWidth = max(0, islandSize.width - pad * 2)
                let musicWidth = innerWidth * IslandMetrics.dualLeftRatio
                let musicRight = pad + musicWidth
                if pointFromTopLeft.x >= musicRight {
                    return .openChat
                }
                return musicAction(
                    point: pointFromTopLeft,
                    islandSize: islandSize,
                    notchHeight: notchHeight,
                    isExpanded: true,
                    hasMedia: hasMedia,
                    showsShelf: false,
                    bandLeft: pad,
                    bandWidth: musicWidth
                )
            }
            return .openChat
        case .charging, .volume, .brightness, .focusMode:
            return .passthrough
        case .none:
            break
        }

        // Compact recording is a live activity. Clicks must expand it even
        // after Check Now locked hover (that lock is for player/chat bounce).
        if isScreenRecording, !isExpanded {
            return .expandRecording
        }

        if isScreenRecording, persistentIsMusic, isExpanded {
            let pad = IslandMetrics.chatOverlayHorizontalPadding
            let innerWidth = max(0, islandSize.width - pad * 2)
            let musicWidth = innerWidth * IslandMetrics.dualLeftRatio
            let musicRight = pad + musicWidth
            if pointFromTopLeft.x >= musicRight {
                return .passthrough
            }
            return musicAction(
                point: pointFromTopLeft,
                islandSize: islandSize,
                notchHeight: notchHeight,
                isExpanded: true,
                hasMedia: hasMedia,
                showsShelf: false,
                bandLeft: pad,
                bandWidth: musicWidth
            )
        }

        if isScreenRecording, isExpanded {
            return .passthrough
        }

        if showsIdleGlance, !hasMedia, idleDestinationCount > 0 {
            // Shelf hang is below the standard expanded shell — leave it to AppKit.
            if showsShelf, isExpanded, pointFromTopLeft.y >= IslandMetrics.expandedHeight {
                return .passthrough
            }
            return idleGlanceAction(
                point: pointFromTopLeft,
                islandSize: islandSize,
                notchHeight: notchHeight,
                destinationCount: idleDestinationCount,
                isExpanded: isExpanded,
                showsShelf: showsShelf
            )
        }

        return musicAction(
            point: pointFromTopLeft,
            islandSize: islandSize,
            notchHeight: notchHeight,
            isExpanded: isExpanded,
            hasMedia: hasMedia,
            showsShelf: showsShelf,
            bandLeft: 0,
            bandWidth: islandSize.width
        )
    }

    /// Right side hosts destination icons; left (weather) is non-interactive.
    static func idleGlanceAction(
        point: CGPoint,
        islandSize: CGSize,
        notchHeight: CGFloat,
        destinationCount: Int,
        isExpanded: Bool,
        showsShelf: Bool = false
    ) -> Action {
        guard destinationCount > 0 else { return .passthrough }
        if isExpanded {
            return expandedIdleGlanceAction(
                point: point,
                islandSize: islandSize,
                notchHeight: notchHeight,
                destinationCount: destinationCount,
                showsShelf: showsShelf
            )
        }
        let stripLeft = islandSize.width - IslandMetrics.idleGlanceCompactRightEar
        guard point.x >= stripLeft else { return .passthrough }
        let stripWidth = max(IslandMetrics.idleGlanceCompactRightEar - 8, 1)
        let visible = min(destinationCount, 2)
        let slot = stripWidth / CGFloat(visible)
        let index = Int((point.x - stripLeft) / slot)
        let clamped = min(max(index, 0), visible - 1)
        return .openIdleDestination(clamped)
    }

    /// 1pt divider + `.padding(.horizontal, 10)` on each side in `IdleGlanceContent`.
    static let idleGlanceExpandedDividerReserve: CGFloat = 21

    /// Equal left/right columns inside the expanded shell (after outer padding).
    static func idleGlanceExpandedColumnWidth(islandWidth: CGFloat) -> CGFloat {
        let content = islandWidth - IslandMetrics.expandedHorizontalPadding * 2
        return max((content - idleGlanceExpandedDividerReserve) / 2, 1)
    }

    /// Leading edge of the shortcut column — mirrors the flexible right half.
    static func idleGlanceExpandedGridLeadingX(islandWidth: CGFloat) -> CGFloat {
        IslandMetrics.expandedHorizontalPadding
            + idleGlanceExpandedColumnWidth(islandWidth: islandWidth)
            + idleGlanceExpandedDividerReserve
    }

    /// Matches `IdleGlanceContent` expanded grid on the trailing half.
    static func expandedIdleGlanceAction(
        point: CGPoint,
        islandSize: CGSize,
        notchHeight: CGFloat,
        destinationCount: Int,
        showsShelf: Bool = false
    ) -> Action {
        let gridWidth = idleGlanceExpandedColumnWidth(islandWidth: islandSize.width)
        let stripLeft = idleGlanceExpandedGridLeadingX(islandWidth: islandSize.width)
        let stripTop = IslandMetrics.expandedContentTopInset(notchHeight: notchHeight)
        // When the file tray hangs below, destination hits stay in the 178pt shell.
        let stripBottom = showsShelf
            ? IslandMetrics.expandedHeight
            : islandSize.height - IslandMetrics.expandedVerticalPadding
        guard point.x >= stripLeft,
              point.y >= stripTop,
              point.y <= stripBottom
        else {
            return .passthrough
        }
        let visible = min(max(destinationCount, 1), 4)
        let columns = 2
        let rows = (visible + columns - 1) / columns
        let relX = point.x - stripLeft
        let relY = point.y - stripTop
        let cellWidth = gridWidth / CGFloat(columns)
        let cellHeight = max(stripBottom - stripTop, 1) / CGFloat(rows)
        let col = min(max(Int(relX / cellWidth), 0), columns - 1)
        let row = min(max(Int(relY / cellHeight), 0), rows - 1)
        let index = row * columns + col
        guard index < visible else { return .passthrough }
        return .openIdleDestination(index)
    }

    /// Back-compat for tests that only pass width.
    static func idleGlanceAction(
        point: CGPoint,
        islandWidth: CGFloat,
        destinationCount: Int
    ) -> Action {
        idleGlanceAction(
            point: point,
            islandSize: CGSize(width: islandWidth, height: 33),
            notchHeight: 32,
            destinationCount: destinationCount,
            isExpanded: false
        )
    }

    private static func musicAction(
        point: CGPoint,
        islandSize: CGSize,
        notchHeight: CGFloat,
        isExpanded: Bool,
        hasMedia: Bool,
        showsShelf: Bool,
        bandLeft: CGFloat,
        bandWidth: CGFloat
    ) -> Action {
        guard hasMedia else { return .passthrough }
        if !isExpanded {
            return .revealNowPlaying
        }
        if showsShelf, point.y >= islandSize.height - IslandMetrics.shelfHangHeight {
            return .passthrough
        }
        var transportTop = islandSize.height - expandedTransportBand
        var controlTop = islandSize.height - expandedControlBand
        if showsShelf {
            transportTop -= IslandMetrics.shelfHangHeight
            controlTop -= IslandMetrics.shelfHangHeight
        }
        let headerFloor = IslandMetrics.expandedContentTopInset(notchHeight: notchHeight) + 40
        transportTop = max(transportTop, headerFloor)
        controlTop = max(controlTop, transportTop)
        var progressTop = controlTop - expandedProgressBand
        progressTop = max(progressTop, headerFloor)
        if point.y < progressTop {
            return .revealNowPlaying
        }
        if point.y < controlTop {
            return .seek
        }
        let third = max(bandWidth / 3, 1)
        let rel = point.x - bandLeft
        guard rel >= 0, rel <= bandWidth else {
            return .passthrough
        }
        if rel < third { return .skipBack }
        if rel < third * 2 { return .playPause }
        return .skipForward
    }

    /// Horizontal position along the 4pt bar, ignoring the time labels.
    static func seekFraction(
        x: CGFloat,
        islandWidth: CGFloat,
        bandLeft: CGFloat = 0,
        bandWidth: CGFloat? = nil
    ) -> Double {
        let width = bandWidth ?? islandWidth
        let pad = IslandMetrics.expandedHorizontalPadding
        let barLeft = bandLeft + pad + progressLeadingTimeWidth + progressTimeSpacing
        let barRight = bandLeft + width - pad - progressTrailingTimeWidth - progressTimeSpacing
        let span = max(barRight - barLeft, 1)
        return min(max(Double((x - barLeft) / span), 0), 1)
    }
}
