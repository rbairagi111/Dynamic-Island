import CoreGraphics
import Foundation

/// Maps a click on the island to an action without relying on SwiftUI buttons.
/// The desktop island is a nonactivating panel, so play/pause and “open tab”
/// clicks often never reach SwiftUI — the same reason recording Stop is AppKit.
enum IslandClickPolicy {
    enum Action: Equatable {
        /// Progress, transport, shelf, charging — leave for existing views.
        case passthrough
        case revealNowPlaying
        case openChat
        case openBatterySettings
    }

    /// Bottom band reserved for play/pause, scrubbing, and the file shelf.
    static let expandedTransportBand: CGFloat = 82

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
                let musicRight = pad + innerWidth * IslandMetrics.dualLeftRatio
                if pointFromTopLeft.x >= musicRight {
                    return .openChat
                }
                return musicAction(
                    yFromTop: pointFromTopLeft.y,
                    islandHeight: islandSize.height,
                    notchHeight: notchHeight,
                    isExpanded: true,
                    hasMedia: hasMedia,
                    showsShelf: false
                )
            }
            return .openChat
        case .charging, .volume, .brightness, .focusMode:
            return .passthrough
        case .none:
            break
        }

        return musicAction(
            yFromTop: pointFromTopLeft.y,
            islandHeight: islandSize.height,
            notchHeight: notchHeight,
            isExpanded: isExpanded,
            hasMedia: hasMedia,
            showsShelf: showsShelf
        )
    }

    private static func musicAction(
        yFromTop: CGFloat,
        islandHeight: CGFloat,
        notchHeight: CGFloat,
        isExpanded: Bool,
        hasMedia: Bool,
        showsShelf: Bool
    ) -> Action {
        guard hasMedia else { return .passthrough }
        if !isExpanded {
            return .revealNowPlaying
        }
        var transportTop = islandHeight - expandedTransportBand
        if showsShelf {
            transportTop -= IslandMetrics.shelfRowHeight
        }
        let headerFloor = IslandMetrics.expandedContentTopInset(notchHeight: notchHeight) + 40
        transportTop = max(transportTop, headerFloor)
        if yFromTop < transportTop {
            return .revealNowPlaying
        }
        return .passthrough
    }
}
