import AppKit
import Foundation

/// Hard gates so a new surface (lock screen, recording, helper, …) cannot
/// swallow banners that already work: Claude / ChatGPT / Gemini, charging,
/// volume, Focus.
enum IslandSurfacePolicy {
    /// Desktop island only — never loginwindow / shielding tags.
    ///
    /// Do **not** keep `canJoinAllSpaces` or `stationary` at rest. WindowServer
    /// snapshots every all-spaces window onto **both** Space plates at swipe
    /// start. The island lives on one Space. After the morph settles, briefly
    /// apply `spaceArrivalCollectionBehavior` (`canJoinAllSpaces`) so the
    /// window appears on the Space the user landed on, then strip it so the
    /// window pins there. `orderFront` and `moveToActiveSpace` cannot do this
    /// for an accessory app. `canJoinAllApplications` covers Stage Manager.
    static var desktopIslandCollectionBehavior: NSWindow.CollectionBehavior {
        [
            .fullScreenAuxiliary,
            .ignoresCycle,
            .canJoinAllApplications
        ]
    }

    /// One-shot: appear on the Space that is already active, then strip.
    /// `stationary` stays off so this is not baked into a later swipe snapshot.
    static var spaceArrivalCollectionBehavior: NSWindow.CollectionBehavior {
        [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .canJoinAllApplications
        ]
    }

    /// Flags that put a rest-position copy on the incoming Space plate.
    static var spaceSwipeSnapshotBehaviors: NSWindow.CollectionBehavior {
        [.canJoinAllSpaces, .stationary]
    }

    /// Incoming Space plates only include windows assigned to that Space.
    static func windowWouldAppearOnIncomingSpacePlate(joinsAllSpaces: Bool) -> Bool {
        joinsAllSpaces
    }

    /// Lock UI is a separate window. Hide the desktop island only when locked
    /// *and* nothing is currently announcing.
    static func shouldHideDesktopIsland(lockActive: Bool, overlayActive: Bool) -> Bool {
        lockActive && !overlayActive
    }

    /// Recording uses a tight elevated window so capture UI stays clickable.
    /// Shadow bleed around that island must not skip Space reattachment.
    static func shouldHandleSpaceSwipe(usesTightLiveActivityWindow: Bool) -> Bool {
        _ = usesTightLiveActivityWindow
        return true
    }

    /// A selected Chrome tab stays `document.visibilityState === visible`
    /// even when Cursor is frontmost. Never treat that as "user is looking."
    static func shouldSuppressChatBanner(chromeFrontmost: Bool, thisTabVisible: Bool) -> Bool {
        chromeFrontmost && thisTabVisible
    }

    /// Native-messaging is faster, AppleScript is the fallback. Connecting
    /// the helper must not pause polling.
    static func shouldPollChromeTabs(automationDenied: Bool, helperConnected: Bool) -> Bool {
        _ = helperConnected
        return !automationDenied
    }

    /// Claude leaves `data-is-streaming="false"` on finished turns.
    /// Only `"true"` means a reply is still writing.
    static func isClaudeActivelyStreaming(attributeValues: [String]) -> Bool {
        attributeValues.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" }
    }

    /// Volume-key swallowing and recording-stop can use Accessibility.
    /// `AXIsProcessTrustedWithOptions` with a prompt, or hammering
    /// `CGEvent.tapCreate`, shows Apple's "would like to control this
    /// computer" sheet on every Deny and every Xcode rebuild. Open
    /// System Settings instead; never show that sheet from launch,
    /// timers, or feature fallbacks.
    static var shouldShowSystemAccessibilityPrompt: Bool { false }

    /// Launch must not call `CGEvent.tapCreate` while untrusted. That call is
    /// enough for macOS to show the Accessibility sheet.
    static var shouldCreateHIDEventTapOnLaunch: Bool { false }

    /// If Accessibility is already granted, install the media-key tap from
    /// `start()` and the volume poll. `shouldCreateHIDEventTap` still refuses
    /// `tapCreate` until trusted, so this cannot show Apple's sheet.
    static var shouldAttemptMediaKeyTapWhenAlreadyTrusted: Bool { true }

    /// Remapping volume / brightness to F16–F20 hides the Tahoe HUD, but it
    /// also kills the keys whenever this binary is not the one swallowing
    /// those F-keys (Xcode rebuilds, `.tmp` test apps, Chrome native-host
    /// copies). Never rewrite `UserKeyMapping` from the island.
    static var shouldRemapMediaKeysToFunctionKeys: Bool { false }

    /// Keep trying after launch so enabling Accessibility in Settings is
    /// enough — Recheck is not required on every start.
    static var shouldRetryMediaKeyTapWhileRunning: Bool { true }

    /// `NSEvent.addGlobalMonitorForEvents` can also request Accessibility.
    /// Click-through uses mouse-location polling plus a local monitor.
    static var shouldInstallGlobalPointerMonitor: Bool { false }

    /// Create the media-key HID tap once the process is trusted. Never while
    /// untrusted, and never again after a failed `tapCreate` (that re-prompts).
    static func shouldCreateHIDEventTap(
        isTrusted: Bool,
        alreadyAttempted: Bool,
        previousCreateFailed: Bool
    ) -> Bool {
        isTrusted && !alreadyAttempted && !previousCreateFailed
    }

    /// Split layouts when two live activities share the island.
    /// Charging / volume / Focus keep the full-width banner and are never dualed.
    enum DualActivity: Equatable {
        case none
        /// Now Playing left, Claude / ChatGPT / Gemini right.
        case mediaAndChat
        /// Now Playing left, screen recording right.
        case mediaAndRecording
        /// Screen recording left, Claude / ChatGPT / Gemini right.
        case recordingAndChat
    }

    /// Recording must not swallow Now Playing or a chat banner — compose them.
    static func dualActivity(
        isScreenRecording: Bool,
        hasMedia: Bool,
        overlay: TransientOverlay?
    ) -> DualActivity {
        switch overlay {
        case .charging, .lowBattery, .volume, .brightness, .focusMode:
            return .none
        case .chatReady:
            if isScreenRecording { return .recordingAndChat }
            if hasMedia { return .mediaAndChat }
            return .none
        case .none:
            if isScreenRecording && hasMedia { return .mediaAndRecording }
            return .none
        }
    }

    /// Check Now sets `suppressHoverExpand` so the player/chat banner cannot
    /// bounce back. That flag can stick forever because overlay `onHover` never
    /// fires again. Recording is a live activity — hover/click must still work.
    static func shouldAllowRecordingExpand(
        isScreenRecording: Bool,
        fromClick: Bool,
        suppressHoverExpand: Bool,
        suppressUntil: Date?,
        now: Date = Date()
    ) -> Bool {
        guard isScreenRecording else { return false }
        _ = suppressHoverExpand
        if fromClick { return true }
        if let until = suppressUntil, until > now { return false }
        return true
    }

    /// Island-local stop control, top-left origin (same as `IslandClickPolicy`).
    static func recordingStopRect(
        islandSize: CGSize,
        notchHeight: CGFloat,
        isScreenRecording: Bool,
        isExpanded: Bool,
        dual: DualActivity
    ) -> CGRect {
        guard isScreenRecording, isExpanded, islandSize.width > 1, islandSize.height > 1 else {
            return .zero
        }
        let stop = IslandMetrics.recordingStopSize
        switch dual {
        case .mediaAndChat:
            return .zero
        case .none:
            let x = islandSize.width - IslandMetrics.recordingStopTrailingPad - stop
            let y = IslandMetrics.expandedContentTopInset(notchHeight: notchHeight)
            return CGRect(x: x, y: y, width: stop, height: stop)
        case .mediaAndRecording:
            let pad = IslandMetrics.chatOverlayHorizontalPadding
            let columnTrailing = islandSize.width - pad
            let contentTop = IslandMetrics.expandedContentTopInset(notchHeight: notchHeight)
            let contentBottom = islandSize.height - IslandMetrics.chatOverlayBottomPadding
            let y = contentTop + (contentBottom - contentTop - stop) / 2
            return CGRect(x: columnTrailing - stop, y: y, width: stop, height: stop)
        case .recordingAndChat:
            let pad = IslandMetrics.chatOverlayHorizontalPadding
            let inner = max(0, islandSize.width - pad * 2)
            let leftWidth = inner * IslandMetrics.dualLeftRatio
            let contentWidth = max(0, leftWidth - IslandMetrics.chatOverlayColumnSpacing)
            let x = pad + (contentWidth - stop) / 2
            let rowTop = islandSize.height
                - IslandMetrics.chatOverlayBottomPadding
                - IslandMetrics.dualActionRowHeight
            let y = rowTop + (IslandMetrics.dualActionRowHeight - stop) / 2
            return CGRect(x: x, y: y, width: stop, height: stop)
        }
    }

    /// 0.1% of the island radius, floored at 1pt so a pointer on the
    /// exclusive `CGRect` max edge still counts as hover.
    static func islandHoverSlop(radius: CGFloat) -> CGFloat {
        max(radius * 0.001, 1)
    }

    static func islandHoverRadius(islandSize: CGSize) -> CGFloat {
        max(min(islandSize.width, islandSize.height) / 2, 1)
    }

    /// Distance to a closed rectangle (min and max edges count as inside).
    static func distanceToClosedRect(_ rect: CGRect, point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// Expand when the pointer is on the island, within the radius slop, or
    /// tunneled through it between samples. Leaving below still misses so
    /// collapse keeps working.
    static func pointerIsOverIsland(
        point: CGPoint,
        island: CGRect,
        previous: CGPoint?,
        radius: CGFloat
    ) -> Bool {
        guard island.width > 0, island.height > 0 else { return false }
        let slop = islandHoverSlop(radius: radius)
        if distanceToClosedRect(island, point: point) <= slop {
            return true
        }
        guard let previous else { return false }
        let previousOutside = distanceToClosedRect(island, point: previous) > slop
        let currentOutside = distanceToClosedRect(island, point: point) > slop
        guard previousOutside, currentOutside else { return false }
        return segmentIntersectsRect(previous, point, rect: island.insetBy(dx: -slop, dy: -slop))
    }

    static func segmentIntersectsRect(_ a: CGPoint, _ b: CGPoint, rect: CGRect) -> Bool {
        if rect.contains(a) || rect.contains(b) { return true }
        let edges: [(CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY))
        ]
        for (c, d) in edges where segmentsIntersect(a, b, c, d) {
            return true
        }
        return false
    }

    static func segmentsIntersect(_ p1: CGPoint, _ q1: CGPoint, _ p2: CGPoint, _ q2: CGPoint) -> Bool {
        func orient(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.y - a.y) * (c.x - b.x) - (b.x - a.x) * (c.y - b.y)
        }
        func onSeg(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
            min(a.x, c.x) <= b.x && b.x <= max(a.x, c.x)
                && min(a.y, c.y) <= b.y && b.y <= max(a.y, c.y)
        }
        let o1 = orient(p1, q1, p2)
        let o2 = orient(p1, q1, q2)
        let o3 = orient(p2, q2, p1)
        let o4 = orient(p2, q2, q1)
        if o1 * o2 < 0 && o3 * o4 < 0 { return true }
        if o1 == 0 && onSeg(p1, p2, q1) { return true }
        if o2 == 0 && onSeg(p1, q2, q1) { return true }
        if o3 == 0 && onSeg(p2, p1, q2) { return true }
        if o4 == 0 && onSeg(p2, q1, q2) { return true }
        return false
    }
}
