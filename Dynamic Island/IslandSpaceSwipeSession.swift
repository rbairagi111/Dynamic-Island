import CoreGraphics
import Foundation

/// Live Space-swipe follow + park-above / drop-in after a committed switch.
///
/// WindowServer slides `CGWindow` bounds during a swipe; `NSWindow.frame` does
/// not. The compositor offset is `visualX - appKitX`. That value stays correct
/// after we pin (visual returns to the notch, AppKit moves the opposite way).
/// When the compositor stops, the offset goes to ~0 — if AppKit is still
/// pinned, the island is off-screen until we restore the resting frame.
struct IslandSpaceSwipeSession {
    enum Phase: Equatable {
        case idle
        case tracking
        case hidden
        case entering
    }

    enum TickAction: Equatable {
        /// Compositor idle. Restore the resting frame.
        case rest
        /// Finger / keyboard swipe in progress. Pin X; lift Y.
        case follow(deltaX: CGFloat, offsetY: CGFloat)
        /// Swipe released before a Space change. Restore X; drop current lift.
        case cancel
        /// Swipe committed (or snapped). Restore X; keep island parked above.
        case park
        /// Arrival animation owns the window.
        case ignore
    }

    private(set) var phase: Phase = .idle
    private(set) var offsetY: CGFloat = 0
    private(set) var arrivalStarts = 0
    private(set) var lastDeltaX: CGFloat = 0
    private(set) var peakProgress: CGFloat = 0
    private var idleTicks: Int = 0

    mutating func spaceDidChange(islandHeight: CGFloat) {
        // Drop-in is already running for this landing. Restarting would park
        // at rest, then play "from above" a second time.
        if phase == .entering { return }
        arrivalStarts += 1
        offsetY = IslandSpaceTransitionMotion.hiddenOffset(islandHeight: islandHeight)
        lastDeltaX = 0
        peakProgress = 0
        idleTicks = 0
        phase = .hidden
    }

    mutating func markEntering() {
        phase = .entering
    }

    mutating func setEnterOffset(_ y: CGFloat) {
        offsetY = max(0, y)
    }

    mutating func finishEnter(now: TimeInterval) {
        offsetY = 0
        lastDeltaX = 0
        peakProgress = 0
        idleTicks = 0
        phase = .idle
        _ = now
    }

    mutating func reset() {
        self = IslandSpaceSwipeSession()
    }

    mutating func tick(
        compositorDeltaX: CGFloat,
        screenWidth: CGFloat,
        islandHeight: CGFloat,
        smoothing: CGFloat = 1,
        compositorSnapped: Bool = false
    ) -> TickAction {
        // The arrival animation exclusively owns Y until it completes. Space
        // compositor samples can continue for a few frames after the active
        // Space changes; treating those as a new swipe cancels and restarts
        // the drop-in, which visibly flashes on slow transitions.
        if phase == .entering {
            return .ignore
        }

        if compositorSnapped, phase == .tracking || phase == .hidden {
            return park(islandHeight: islandHeight)
        }

        let dead = IslandSpaceTransitionMotion.swipeDeadZone
        let width = max(screenWidth, 1)
        let clampedDelta = min(max(compositorDeltaX, -width), width)
        let progress = IslandSpaceTransitionMotion.swipeProgress(
            deltaX: clampedDelta,
            screenWidth: width
        )

        if abs(clampedDelta) >= dead {
            idleTicks = 0
            if phase == .hidden {
                phase = .tracking
            }
        }

        switch phase {
        case .entering:
            return .ignore
        case .hidden:
            if abs(clampedDelta) < dead {
                return .ignore
            }
        case .idle, .tracking:
            break
        }

        if abs(clampedDelta) < dead {
            lastDeltaX = 0
            switch phase {
            case .idle:
                offsetY = 0
                peakProgress = 0
                idleTicks = 0
                return .rest
            case .tracking:
                idleTicks += 1
                if idleTicks < IslandSpaceTransitionMotion.idleConfirmTicks {
                    return .follow(deltaX: lastDeltaX, offsetY: offsetY)
                }
                idleTicks = 0
                if peakProgress >= IslandSpaceTransitionMotion.commitProgress {
                    return park(islandHeight: islandHeight)
                }
                phase = .hidden
                peakProgress = 0
                return .cancel
            case .hidden, .entering:
                return .ignore
            }
        }

        phase = .tracking
        lastDeltaX = clampedDelta
        peakProgress = max(peakProgress, progress)
        let target = IslandSpaceTransitionMotion.liftOffsetY(
            deltaX: clampedDelta,
            screenWidth: width,
            islandHeight: islandHeight
        )
        offsetY = IslandSpaceTransitionMotion.smoothedLift(
            current: offsetY,
            target: target,
            alpha: smoothing
        )
        return .follow(deltaX: clampedDelta, offsetY: offsetY)
    }

    private mutating func park(islandHeight: CGFloat) -> TickAction {
        offsetY = IslandSpaceTransitionMotion.hiddenOffset(islandHeight: islandHeight)
        lastDeltaX = 0
        peakProgress = 0
        idleTicks = 0
        phase = .hidden
        return .park
    }
}

extension IslandSpaceTransitionMotion {
    static let swipeDeadZone: CGFloat = 8
    static let commitProgress: CGFloat = 0.85
    static let parkTimeout: TimeInterval = 0.08
    /// Wait this many idle compositor ticks before parking / dropping in.
    /// A single 0-delta frame during a fast swipe used to flicker the island.
    static let idleConfirmTicks: Int = 8
    /// After `activeSpaceDidChange` the new desktop is already on screen.
    /// Zero = start drop-in immediately. A longer wait was empty-notch time;
    /// joining during an in-flight morph can still paint the island on the
    /// incoming plate — retry a small buffer if that shows up.
    static let arrivalSettle: TimeInterval = 0
    /// `isOnActiveSpace` lags after `canJoinAllSpaces`. Pinning before this
    /// leaves the island on the previous Space until a later swipe.
    static let onActiveSpaceWait: TimeInterval = 0.35
    static let onActiveSpacePoll: TimeInterval = 0.016
    /// Follow the finger closely without snapping to a noisy compositor sample.
    static let liftSmoothing: CGFloat = 0.42
    /// Pin toward the notch without jumping a full correction each frame.
    static let pinSmoothing: CGFloat = 0.38

    static func compositorDeltaX(visualX: CGFloat, appKitX: CGFloat) -> CGFloat {
        visualX - appKitX
    }

    /// After `setFrame`, `CGWindow` can lag one tick. Reuse the previous delta
    /// when visual X has not moved but AppKit has.
    static func stableCompositorDeltaX(
        visualX: CGFloat,
        appKitX: CGFloat,
        lastVisualX: CGFloat?,
        lastAppKitX: CGFloat?,
        lastDeltaX: CGFloat
    ) -> CGFloat {
        if let lastVisualX, let lastAppKitX,
           abs(visualX - lastVisualX) < 1,
           abs(appKitX - lastAppKitX) > 2 {
            return lastDeltaX
        }
        return compositorDeltaX(visualX: visualX, appKitX: appKitX)
    }

    static func swipeProgress(deltaX: CGFloat, screenWidth: CGFloat) -> CGFloat {
        min(1, abs(deltaX) / max(screenWidth, 1))
    }

    /// Ease-out so the island tucks behind on the first part of the swipe,
    /// then slows as it clears the top — instead of a linear 1:1 lift.
    static func liftOffsetY(
        deltaX: CGFloat,
        screenWidth: CGFloat,
        islandHeight: CGFloat
    ) -> CGFloat {
        easeOut(swipeProgress(deltaX: deltaX, screenWidth: screenWidth))
            * hiddenOffset(islandHeight: islandHeight)
    }

    static func smoothedLift(current: CGFloat, target: CGFloat, alpha: CGFloat) -> CGFloat {
        let a = min(max(alpha, 0), 1)
        return current + (target - current) * a
    }

    static func blendedOriginX(current: CGFloat, target: CGFloat, alpha: CGFloat) -> CGFloat {
        let a = min(max(alpha, 0), 1)
        return current + (target - current) * a
    }

    static func nudgedOriginX(appKitX: CGFloat, visualX: CGFloat, restX: CGFloat) -> CGFloat {
        appKitX + (restX - visualX)
    }

    static func clampedOriginX(x: CGFloat, restX: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let limit = max(screenWidth, 1)
        return min(max(x, restX - limit), restX + limit)
    }

    /// Counter the WindowServer Space slide so the island stays on the notch.
    static func pinnedFrame(resting: NSRect, compositorDeltaX: CGFloat) -> NSRect {
        NSRect(
            x: resting.origin.x - compositorDeltaX,
            y: resting.origin.y,
            width: resting.width,
            height: resting.height
        )
    }

    static func composedBounds(fromWindowInfo info: [[String: Any]]) -> CGRect? {
        guard let raw = info.first?[kCGWindowBounds as String] else { return nil }
        let dict: CFDictionary
        if let ns = raw as? NSDictionary {
            dict = ns
        } else if let swift = raw as? [AnyHashable: Any] {
            dict = swift as CFDictionary
        } else {
            return nil
        }
        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(dict, &rect) else { return nil }
        return rect
    }
}
