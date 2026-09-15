import CoreGraphics
import Foundation

/// Pure layout gates for dual Now Playing (expanded split + compact stack).
/// Kept free of AppKit/SwiftUI so unit tests can pin the compact dual signal
/// without spinning up MediaRemote or a live window.
///
/// Eligible pairs: two distinct browser streaming platforms (video+video,
/// video+audio, or audio+audio). Same-platform pairs never dual. Native apps
/// are out of scope — discovery stays browser-tab based.
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

    /// Distinct platforms only. Video+video, video+audio, and audio+audio OK.
    static func isEligibleDualPair(
        primary: StreamingPlatform?,
        secondary: StreamingPlatform?
    ) -> Bool {
        guard let primary, let secondary else { return false }
        return primary != secondary
    }

    /// Video sits in front (and expanded-left) when MediaRemote holds audio.
    /// Video+video and audio+audio keep MediaRemote primary on the left (no swap).
    static func swapsTiles(
        hasLiveDualSessions: Bool,
        primaryKind: StreamingPlatform.MediaKind?,
        secondaryKind: StreamingPlatform.MediaKind?
    ) -> Bool {
        hasLiveDualSessions
            && primaryKind == .audio
            && secondaryKind == .video
    }

    /// Dual tiles must never paint a platform logo when real session art exists.
    /// Prefer the bitmap; only treat `platform:` tokens as logo fallbacks.
    static func usesPlatformLogoForDualTile(artworkToken: String) -> Bool {
        artworkToken.hasPrefix("platform:")
    }

    /// When flushing dual, upgrade a logo/empty tile to cached real art when available.
    static func preferredDualArtworkToken(
        currentToken: String,
        hasCachedRealArt: Bool
    ) -> String? {
        guard hasCachedRealArt else { return nil }
        if currentToken.hasPrefix("platform:") || currentToken.hasPrefix("pending:") {
            return "held:cached"
        }
        return nil
    }

    /// Compact stack frame — must be clearly larger than a single `compactArt`
    /// tile so the second thumbnail is visible in the physical notch ears.
    static func compactStackSize(art: CGFloat, overlapX: CGFloat, overlapY: CGFloat) -> CGSize {
        CGSize(width: art + overlapX, height: art + overlapY)
    }

    /// Hunt fast until a second live tab is found. Once dual is up, rediscovery
    /// can be slower — known-tab playback refresh handles pause/collapse.
    static func secondaryScanInterval(hasSecondarySession: Bool) -> TimeInterval {
        hasSecondarySession ? 1.0 : 0.15
    }

    /// When MediaRemote hands primary between two dual-eligible sessions while
    /// the outgoing session is still live, park it as secondary immediately so
    /// compact dual art does not wait on the AppleScript probe.
    static func shouldDemoteOutgoingToSecondary(
        featureEnabled: Bool,
        outgoingHasMedia: Bool,
        outgoingIsPlaying: Bool,
        outgoing: StreamingPlatform?,
        incomingIsPlaying: Bool,
        incoming: StreamingPlatform?
    ) -> Bool {
        guard featureEnabled else { return false }
        guard outgoingHasMedia, outgoingIsPlaying, incomingIsPlaying else { return false }
        // Incoming becomes primary; outgoing becomes secondary.
        return isEligibleDualPair(primary: incoming, secondary: outgoing)
    }

    /// After a positive secondary seed/apply, ignore empty-hunt clears for this
    /// long. A racing failed probe was wiping Watch right after Music bound
    /// (debug-6ca0b4: seed @6167 → secHas false @6299 → dual only @7730).
    static func secondaryHoldDuration() -> TimeInterval { 1.0 }

    /// Keep a dual-eligible *playing* secondary through a failed hunt.
    /// A positively paused secondary must not stay dual via hold alone.
    static func shouldPreserveSecondaryOnMissedHunt(
        primary: StreamingPlatform?,
        secondary: StreamingPlatform?,
        secondaryIsPlaying: Bool,
        holdActive: Bool
    ) -> Bool {
        guard secondaryIsPlaying else { return false }
        if holdActive, secondary != nil { return true }
        return isEligibleDualPair(primary: primary, secondary: secondary)
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

    /// Compact dual must never paint same-platform pairs.
    static func shouldPublishDualSecondaryToUI(
        primary: StreamingPlatform?,
        secondary: StreamingPlatform?
    ) -> Bool {
        isEligibleDualPair(primary: primary, secondary: secondary)
    }

    /// Resolve primary platform from a bound URL, then title hint.
    /// Music handoff often keeps a stale `youtube.com/watch` URL for a tick
    /// while the title/platform hint already says Music — prefer the hint so
    /// demoted Watch secondary can flush in the same turn.
    static func resolvedPlatform(
        url: String,
        titleHint: StreamingPlatform? = nil
    ) -> StreamingPlatform? {
        if titleHint == .youtubeMusic {
            return .youtubeMusic
        }
        if let fromURL = StreamingPlatform.from(url: url) {
            if fromURL == .youtube,
               titleHint?.mediaKind == .audio {
                return titleHint
            }
            return fromURL
        }
        return titleHint
    }

    /// True when a latched/demoted secondary may be shown with this primary.
    /// Accepts URL or title-hint so dual can land in the same main-queue tick.
    static func primaryAllowsDualSecondaryPublish(
        primaryURL: String,
        primaryTitleHint: StreamingPlatform?,
        secondary: StreamingPlatform?
    ) -> Bool {
        let primary = resolvedPlatform(url: primaryURL, titleHint: primaryTitleHint)
        return shouldPublishDualSecondaryToUI(primary: primary, secondary: secondary)
    }

    /// MediaRemote often blips primary to paused while both tabs still play.
    /// Promote when HTML positively says primary stopped. `nil` HTML while a
    /// dual secondary is live is treated as a false MediaRemote pause so the
    /// overlapping dual stack does not collapse and restore in a loop.
    static func shouldPromoteSecondaryAfterPrimaryPause(
        mediaRemoteSaysPrimaryPlaying: Bool,
        htmlSaysPrimaryPlaying: Bool?,
        hasLiveDualSecondary: Bool = false
    ) -> Bool {
        guard !mediaRemoteSaysPrimaryPlaying else { return false }
        if htmlSaysPrimaryPlaying == true { return false }
        if htmlSaysPrimaryPlaying == false { return true }
        // nil HTML: promote only when there is no live dual partner to keep.
        return !hasLiveDualSecondary
    }

    /// After dual collapses to the still-playing tile, MediaRemote keeps
    /// advertising the paused opposite (YT Music titles often omit
    /// "YouTube Music") and can also blip the promoted session to paused.
    /// Ignore *all* MediaRemote rows during the suppress window so
    /// pause-music → video (and pause-video → music) stick with real art.
    static func shouldIgnoreMediaRemoteAfterDualPromote(
        suppressActive: Bool
    ) -> Bool {
        suppressActive
    }

    /// Back-compat name used by older call sites / docs.
    static func shouldIgnorePausedMediaRemoteAfterDualPromote(
        suppressActive: Bool,
        remotePlaying: Bool
    ) -> Bool {
        _ = remotePlaying
        return shouldIgnoreMediaRemoteAfterDualPromote(suppressActive: suppressActive)
    }

    /// Closing the primary dual partner (e.g. YT Music tab) must not wipe the
    /// island to idle when the other session's tab is still open — even paused.
    /// Compact single layout (art + waveform) stays for that remaining tab.
    static func shouldAdoptSecondaryWhenPrimaryTabClosed(
        secondaryHasMedia: Bool
    ) -> Bool {
        secondaryHasMedia
    }
}
