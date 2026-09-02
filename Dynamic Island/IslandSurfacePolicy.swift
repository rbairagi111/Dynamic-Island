import AppKit
import Foundation

/// Hard gates so a new surface (lock screen, recording, helper, …) cannot
/// swallow banners that already work: Claude / ChatGPT / Gemini, charging,
/// volume, AirDrop, Focus.
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
}
