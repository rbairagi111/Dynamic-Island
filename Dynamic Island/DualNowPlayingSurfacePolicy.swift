import CoreGraphics
import Foundation

/// Pure layout gates for dual Now Playing (expanded split + compact stack).
/// Kept free of AppKit/SwiftUI so unit tests can pin the compact dual signal
/// without spinning up MediaRemote or a live window.
enum DualNowPlayingSurfacePolicy {
    /// Both browser sessions are live and no transient surface is stealing the island.
    static func hasLiveDualSessions(
        featureEnabled: Bool,
        hasMedia: Bool,
        isPlaying: Bool,
        secondaryHasMedia: Bool,
        secondaryIsPlaying: Bool,
        overlayActive: Bool,
        isScreenRecording: Bool,
        isSelectingScreenToRecord: Bool
    ) -> Bool {
        featureEnabled
            && hasMedia
            && isPlaying
            && secondaryHasMedia
            && secondaryIsPlaying
            && !overlayActive
            && !isScreenRecording
            && !isSelectingScreenToRecord
    }

    static func showsExpandedSplit(hasLiveDualSessions: Bool, isExpanded: Bool) -> Bool {
        hasLiveDualSessions && isExpanded
    }

    static func showsCompactStackedArt(hasLiveDualSessions: Bool, isExpanded: Bool) -> Bool {
        hasLiveDualSessions && !isExpanded
    }

    /// Watch sits in front (and expanded-left) when MediaRemote holds Music.
    static func swapsTiles(
        hasLiveDualSessions: Bool,
        primaryIsYouTubeMusic: Bool,
        secondaryIsYouTubeWatch: Bool
    ) -> Bool {
        hasLiveDualSessions && primaryIsYouTubeMusic && secondaryIsYouTubeWatch
    }

    /// Compact stack frame — must be clearly larger than a single `compactArt`
    /// tile so the second thumbnail is visible in the physical notch ears.
    static func compactStackSize(art: CGFloat, overlapX: CGFloat, overlapY: CGFloat) -> CGSize {
        CGSize(width: art + overlapX, height: art + overlapY)
    }

    /// Hunt fast until a second live tab is found; refresh slowly once dual is up.
    static func secondaryScanInterval(hasSecondarySession: Bool) -> TimeInterval {
        hasSecondarySession ? 2.5 : 0.15
    }

    /// When MediaRemote hands primary from Watch→Music (or Music→Watch) while
    /// the outgoing session is still live, park it as secondary immediately so
    /// compact dual art does not wait on the AppleScript probe.
    static func shouldDemoteOutgoingToSecondary(
        featureEnabled: Bool,
        outgoingHasMedia: Bool,
        outgoingIsPlaying: Bool,
        outgoingIsYouTubeWatch: Bool,
        outgoingIsYouTubeMusic: Bool,
        incomingIsPlaying: Bool,
        incomingIsYouTubeWatch: Bool,
        incomingIsYouTubeMusic: Bool
    ) -> Bool {
        guard featureEnabled else { return false }
        guard outgoingHasMedia, outgoingIsPlaying, incomingIsPlaying else { return false }
        let watchToMusic = outgoingIsYouTubeWatch && incomingIsYouTubeMusic
        let musicToWatch = outgoingIsYouTubeMusic && incomingIsYouTubeWatch
        return watchToMusic || musicToWatch
    }

    /// After a positive secondary seed/apply, ignore empty-hunt clears for this
    /// long. A racing failed probe was wiping Watch right after Music bound
    /// (debug-6ca0b4: seed @6167 → secHas false @6299 → dual only @7730).
    static func secondaryHoldDuration() -> TimeInterval { 3.0 }

    /// Keep an opposite-format secondary through a failed hunt (Watch while
    /// primary is Music, or the reverse). Only a positive pause should clear it.
    /// `holdActive` alone is enough: MediaRemote often nils primary for a tick
    /// during rebind (debug-6ca0b4: clear with holdActive true + primaryPlat nil
    /// after ~6s of healthy dual).
    static func shouldPreserveSecondaryOnMissedHunt(
        primaryIsYouTubeWatch: Bool,
        primaryIsYouTubeMusic: Bool,
        secondaryIsYouTubeWatch: Bool,
        secondaryIsYouTubeMusic: Bool,
        secondaryIsPlaying: Bool,
        holdActive: Bool
    ) -> Bool {
        let secondaryYouTubeFamily = secondaryIsYouTubeWatch || secondaryIsYouTubeMusic
        if holdActive, secondaryYouTubeFamily { return true }
        guard secondaryIsPlaying else { return false }
        return (primaryIsYouTubeMusic && secondaryIsYouTubeWatch)
            || (primaryIsYouTubeWatch && secondaryIsYouTubeMusic)
    }

    /// MediaRemote titles for YouTube Music almost never contain "YouTube Music",
    /// so `StreamingPlatform.resolve` returns nil. When primary is Watch and the
    /// incoming title is a different track (or album-shaped art), treat it as Music
    /// so demote can park Watch as secondary immediately.
    static func inferredIncomingYouTubeFormat(
        outgoingIsYouTubeWatch: Bool,
        outgoingIsYouTubeMusic: Bool,
        incomingResolvedIsWatch: Bool,
        incomingResolvedIsMusic: Bool,
        titlesMatchOutgoing: Bool,
        incomingIsPlaying: Bool,
        incomingLooksLikeAlbumArt: Bool
    ) -> (isWatch: Bool, isMusic: Bool) {
        if incomingResolvedIsWatch || incomingResolvedIsMusic {
            return (incomingResolvedIsWatch, incomingResolvedIsMusic)
        }
        guard incomingIsPlaying else { return (false, false) }
        if outgoingIsYouTubeWatch {
            if !titlesMatchOutgoing || incomingLooksLikeAlbumArt {
                return (false, true)
            }
        } else if outgoingIsYouTubeMusic {
            if !titlesMatchOutgoing && !incomingLooksLikeAlbumArt {
                return (true, false)
            }
            if !titlesMatchOutgoing {
                return (true, false)
            }
        }
        return (false, false)
    }

    /// Compact dual must never paint Watch+Watch or Music+Music. Latch the
    /// opposite secondary, but only publish it once primary is the other format.
    static func shouldPublishOppositeSecondaryToUI(
        primaryIsYouTubeWatch: Bool,
        primaryIsYouTubeMusic: Bool,
        secondaryIsYouTubeWatch: Bool,
        secondaryIsYouTubeMusic: Bool
    ) -> Bool {
        (primaryIsYouTubeMusic && secondaryIsYouTubeWatch)
            || (primaryIsYouTubeWatch && secondaryIsYouTubeMusic)
    }

    /// MediaRemote often blips primary to paused while both tabs still play.
    /// Only promote secondary after HTML confirms primary actually stopped
    /// (or the user paused from the island). A nil HTML result means "unknown"
    /// — do not promote on unknown.
    static func shouldPromoteSecondaryAfterPrimaryPause(
        mediaRemoteSaysPrimaryPlaying: Bool,
        htmlSaysPrimaryPlaying: Bool?
    ) -> Bool {
        guard !mediaRemoteSaysPrimaryPlaying else { return false }
        guard let htmlSaysPrimaryPlaying else { return false }
        return !htmlSaysPrimaryPlaying
    }
}
