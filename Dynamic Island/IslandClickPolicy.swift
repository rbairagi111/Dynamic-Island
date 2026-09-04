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
    }

    /// Bottom band reserved for play/pause, scrubbing, and the file shelf.
    static let expandedTransportBand: CGFloat = 82
    /// Play/pause/skip sit in the lower part of that band; the progress bar is above.
    /// 40pt buttons + 8pt row padding + 14pt island padding.
    static let expandedControlBand: CGFloat = 62

    static func action(
        pointFromTopLeft: CGPoint,
        islandSize: CGSize,
        notchHeight: CGFloat,
        isExpanded: Bool,
        overlay: TransientOverlay?,
        hasMedia: Bool,
        persistentIsMusic: Bool,
        showsShelf: Bool = false
    ) -> Action {
        let bounds = CGRect(origin: .zero, size: islandSize)
        guard bounds.width > 1, bounds.height > 1, bounds.contains(pointFromTopLeft) else {
            return .passthrough
        }

        switch overlay {
        case .lowBattery:
            return .openBatterySettings
        case .chatReady:
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
        if showsShelf, point.y >= islandSize.height - IslandMetrics.shelfRowHeight {
            return .passthrough
        }
        var transportTop = islandSize.height - expandedTransportBand
        var controlTop = islandSize.height - expandedControlBand
        if showsShelf {
            transportTop -= IslandMetrics.shelfRowHeight
            controlTop -= IslandMetrics.shelfRowHeight
        }
        let headerFloor = IslandMetrics.expandedContentTopInset(notchHeight: notchHeight) + 40
        transportTop = max(transportTop, headerFloor)
        controlTop = max(controlTop, transportTop)
        if point.y < transportTop {
            return .revealNowPlaying
        }
        if point.y < controlTop {
            return .passthrough
        }
        let buttonSide: CGFloat = bandWidth + 1 < islandSize.width ? 36 : 40
        let spacing: CGFloat = 20
        let cluster = buttonSide * 3 + spacing * 2
        let clusterLeft = bandLeft + max((bandWidth - cluster) / 2, 0)
        let rel = point.x - clusterLeft
        guard rel >= 0, rel <= cluster else {
            return .passthrough
        }
        let prevEnd = buttonSide + spacing / 2
        let playEnd = buttonSide + spacing + buttonSide + spacing / 2
        if rel < prevEnd { return .skipBack }
        if rel < playEnd { return .playPause }
        return .skipForward
    }
}
