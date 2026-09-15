import Foundation
import Combine
import SwiftUI
import AppKit

/// Shared layout for compact (now playing) and expanded (hover) island states.
/// Widths are locked in points so they match the requested pixel sizes on a
/// 2x Retina display: compact 520px (= 260pt), expanded 670px (= 335pt).
enum IslandMetrics {
    static let expandedHeight: CGFloat = 178
    static let expandedRadius: CGFloat = 48
    /// Fixed expanded width: 670px @2x → 335pt
    static let expandedWidthFixed: CGFloat = 335
    static let expandedHorizontalPadding: CGFloat = 14
    static let expandedVerticalPadding: CGFloat = 14
    /// Hairline around compact and expanded island: #191919
    static let islandStroke = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
    static let islandStrokeWidth: CGFloat = 1
    /// Compact recording: a distinct red rim and soft outer light.
    static let recordingStroke = Color(red: 0.88, green: 0.20, blue: 0.18)
    /// 60% thinner than the previous 1.35pt rim.
    static let recordingStrokeWidth: CGFloat = 0.54
    static let recordingStrokeGlow = Color(red: 1.0, green: 0.16, blue: 0.14).opacity(0.48)
    /// 60% thinner than the previous 2.5pt glow stroke.
    static let recordingStrokeGlowWidth: CGFloat = 1.0

    /// Expanded content starts on the line of the menu bar’s bottom edge
    /// (`notchHeight` == `safeAreaInsets.top`).
    static func expandedContentTopInset(notchHeight: CGFloat) -> CGFloat {
        notchHeight
    }

    /// Fixed compact width: 520px @2x → 260pt
    static let compactWidthFixed: CGFloat = 260
    /// Compact idle content lives only in the visible ears beside the camera.
    /// Under-notch pixels are captured by screenshots but hidden to the eye.
    /// Left ear: weather icon + temperature only (no AQI).
    static let idleGlanceCompactLeftEar: CGFloat = 52
    static let idleGlanceCompactRightEar: CGFloat = 54

    static func idleGlanceCompactWidth(notchWidth: CGFloat) -> CGFloat {
        max(notchWidth, 1) + idleGlanceCompactLeftEar + idleGlanceCompactRightEar
    }
    static let compactArt: CGFloat = 16.94
    /// Dual compact stack uses a larger tile than single-source art so the
    /// second thumbnail is obvious in the notch ears (~34px @2x).
    static let compactDualArtSize: CGFloat = 20
    /// Horizontal fan of the back tile — the primary cue that two sources play.
    static let compactDualArtOverlapX: CGFloat = 9
    static let compactDualArtOverlapY: CGFloat = 4
    /// Extra compact width so the fan does not crowd the camera band.
    static let compactDualWidthBoost: CGFloat = 18
    static let compactBottomRadius: CGFloat = 12

    static let motion = Animation.spring(response: 0.4, dampingFraction: 0.75)
    /// Title, times, and controls scale in from the top with the island spring.
    static let contentReveal = AnyTransition.scale(scale: 0.55, anchor: .top)
        .combined(with: .opacity)
    static let overlayTimeout: TimeInterval = 12
    static let chargingOverlayTimeout: TimeInterval = 4
    static let lowBatteryOverlayTimeout: TimeInterval = 3
    static let levelHUDTimeout: TimeInterval = 2
    /// Wide split layout when music and a chat reply share the island.
    static let dualWidthFixed: CGFloat = 560
    /// Chat-only overlay: 800px @2x → 400pt (matches battery banners).
    static let chatOnlyWidthFixed: CGFloat = 400
    /// Outer inset for chat overlay content — equal left and right (40px @2x).
    static let chatOverlayHorizontalPadding: CGFloat = 20
    /// Inner gap between music and chat columns in the dual layout.
    static let chatOverlayColumnSpacing: CGFloat = 16
    /// Bottom inset below chat overlay content.
    static let chatOverlayBottomPadding: CGFloat = 12
    /// Media | chat column share of the dual island (after the 1pt divider).
    static let dualLeftRatio: CGFloat = 0.35
    static let dualRightRatio: CGFloat = 0.65
    /// Bottom action row in the dual overlay (transport + Check Now).
    static let dualActionRowHeight: CGFloat = 36
    static let dualDivider = Color(red: 0.62, green: 0.86, blue: 1.0)
    static let recordingStopSize: CGFloat = 32
    static let recordingStopTrailingPad: CGFloat = 18
    /// Charging, low battery, sound, brightness: 800px @2x → 400pt
    static let batteryBannerWidth: CGFloat = 400
    /// Muted terracotta tile behind the starburst, per the reference mock.
    static let claudeMarkFill = Color(red: 0.78, green: 0.51, blue: 0.38)

    /// Overlay card hugs its content (reference mock), unlike the tall player.
    static func dualHeight(notchHeight: CGFloat) -> CGFloat {
        max(notchHeight, 28) + 112
    }

    static func chargingBannerHeight(notchHeight: CGFloat) -> CGFloat {
        max(notchHeight, 28) + 18
    }

    /// Charging is a shallow hang, not the music-player radius.
    static let chargingRadius: CGFloat = 18
    static let recordingRadius: CGFloat = 32

    static func recordingBannerHeight(notchHeight: CGFloat) -> CGFloat {
        max(notchHeight, 28) + 66
    }

    static func expandedWidth(notchWidth: CGFloat) -> CGFloat {
        expandedWidthFixed
    }

    static func compactWidth(notchWidth: CGFloat) -> CGFloat {
        compactWidthFixed
    }

    /// Extra drop below the physical notch.
    static let compactHeightExtra: CGFloat = 1

    static func compactHeight(notchHeight: CGFloat) -> CGFloat {
        max(notchHeight, 28) + compactHeightExtra
    }

    static func compactYOffset(notchHeight: CGFloat) -> CGFloat {
        0
    }

    static func compactContentTopInset(notchHeight: CGFloat) -> CGFloat {
        0
    }

    static let shelfThumbSize: CGFloat = 44
    /// Extra hang below the music player for the file tray. Width stays the music island.
    static let shelfRowHeight: CGFloat = 70
    /// Space between the player controls and the drop well so the tray is
    /// not flush with the island content above it.
    static let shelfIslandGap: CGFloat = 12
    /// Player hang plus the gap and drop row.
    static var shelfSectionHeight: CGFloat {
        shelfIslandGap + shelfRowHeight
    }
    /// From the island bottom up through the drop well and its gap.
    static var shelfHangHeight: CGFloat {
        shelfSectionHeight + expandedVerticalPadding
    }

    /// Figma drop shadow (X 0, Y 2, blur 24). YouTube expanded and recording
    /// share this window bleed so the shadow is not clipped.
    static let islandShadowBleed: CGFloat = 28

    /// Recording stays sized to the live island, plus the same shadow bleed
    /// as Now Playing. A full-size elevated window swallowed capture clicks.
    static func liveActivityWindowSize(islandWidth: CGFloat, islandHeight: CGFloat) -> CGSize {
        CGSize(
            width: islandWidth + islandShadowBleed * 2,
            height: islandHeight + islandShadowBleed
        )
    }
}

/// Vertical 1pt separator used by dual layouts (music|chat, recording|chat)
/// and idle glance (weather|shortcuts).
struct IslandGradientDivider: View {
    /// Fixed height for compact strips; `nil` fills the available height.
    var height: CGFloat? = nil

    var body: some View {
        Rectangle()
            .fill(Self.gradient)
            .frame(width: 1)
            .frame(height: height)
            .frame(maxHeight: height == nil ? .infinity : height)
    }

    static let gradient = LinearGradient(
        stops: [
            .init(color: .black, location: 0.0),
            .init(
                color: Color(
                    .sRGB,
                    red: 0.8,
                    green: 0.8,
                    blue: 0.8,
                    opacity: 1
                ),
                location: 0.5
            ),
            .init(color: .black, location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

final class NotchViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var hasPhysicalNotch = true
    /// One-shot first-launch sequence (Siri glow → morph → expand demo → tooltip).
    @Published private(set) var isFTUESequenceRunning = false
    @Published private(set) var ftuePhase: NotchFTUEPhase = .idle
    @Published private(set) var ftueGlowAmount: CGFloat = 0
    @Published private(set) var ftueContentOpacity: Double = 1
    @Published private(set) var showsFTUETooltip = false
    /// Ghost cursor visual only (0…1 travel). Expand uses `expandForFTUEDemo`.
    @Published private(set) var ftueGhostCursorProgress: CGFloat = 0
    @Published private(set) var ftueGhostCursorOpacity: Double = 0
    /// Bumped on every play so SwiftUI restarts observers cleanly.
    @Published private(set) var ftuePlayToken: Int = 0
    private var ftueTask: Task<Void, Never>?
    /// Set when the user expands via real hover after the first ghost-cursor demo.
    private var ftueSawRealHover = false

    /// Real notch geometry set by the window controller at launch and on screen changes.
    @Published var notchWidth:  CGFloat = 180
    @Published var notchHeight: CGFloat = 32

    /// Base island content. Independent of `transientOverlay`.
    @Published var persistentState: PersistentState = .idle
    /// Short-lived layer (e.g. Claude / ChatGPT / Gemini ready). Nil restores `persistentState` only.
    @Published var transientOverlay: TransientOverlay? = nil

    // Live Now Playing (Spotify / Music / YouTube / etc.)
    @Published var isPlaying = false
    @Published var hasMedia = false
    @Published var songTitle = "Not Playing"
    @Published var artistName = "—"
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var artwork: NSImage? = nil
    @Published private(set) var mediaPlatform: StreamingPlatform? = nil
    @Published private(set) var usesPlatformLogo = false
    /// Waveform tint sampled from the current artwork (iPhone-style).
    @Published var waveformGradient: ArtworkTint.Gradient = .fallback
    let waveform = SimulatedWaveform()
    /// Keep the last track while locked — MediaRemote goes silent.
    @Published var holdLastMedia = false

    // MARK: Secondary Now Playing (dual-tile) — additive; never replaces primary.
    @Published private(set) var secondaryHasMedia = false
    @Published private(set) var secondaryIsPlaying = false
    @Published private(set) var secondarySongTitle = ""
    @Published private(set) var secondaryArtistName = ""
    @Published private(set) var secondaryCurrentTime: TimeInterval = 0
    @Published private(set) var secondaryDuration: TimeInterval = 0
    @Published private(set) var secondaryArtwork: NSImage? = nil
    @Published private(set) var secondaryMediaPlatform: StreamingPlatform? = nil
    @Published private(set) var secondaryUsesPlatformLogo = false
    @Published private(set) var secondaryWaveformGradient: ArtworkTint.Gradient = .fallback
    let secondaryWaveform = SimulatedWaveform()
    private var lastSecondaryTintedArtwork: ObjectIdentifier?

    /// While the user drags the timeline, freeze live updates and show this time.
    @Published var isScrubbing = false
    @Published var scrubTime: TimeInterval = 0

    @Published var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var isScreenRecording = false
    /// Cmd+Shift+5 record tool / click-to-choose display, before recording starts.
    @Published var isSelectingScreenToRecord = false
    @Published var recordingElapsed: TimeInterval = 0

    private let nowPlaying = NowPlayingService()
    private let chromeMonitor = ChromeTabMonitor.shared
    private let powerMonitor = PowerMonitor.shared
    private let levelMonitor = VolumeBrightnessMonitor.shared
    private let recordingMonitor = ScreenRecordingMonitor.shared
    private let focusMonitor = FocusMonitor.shared
    private let settings = AppSettings.shared
    private let idleDestinationStore = IslandIdleDestinationStore.shared
    private let weatherService = IslandWeatherService.shared
    private let audioAmplitude = AudioAmplitudeMonitor.shared
    private var cancellables = Set<AnyCancellable>()
    private var overlayTimeout: Timer?
    private var overlayHovering = false
    private var recordingTick: Timer?
    private var recordingStartedAt: Date?
    private let artworkTintQueue = DispatchQueue(label: "island.artwork-tint", qos: .userInitiated)
    private var lastTintedArtwork: ObjectIdentifier?
    /// Temporary holding area for dropped files. References only — never deletes.
    @Published var shelfItems: [ShelfItem] = []
    @Published var isDropTargeted = false
    @Published var isDraggingShelfItem = false
    /// Settings preview can show the shelf even if the feature toggle is off.
    private var shelfPreviewActive = false
    private var shelfDropPreviewTimer: Timer?
    @Published private(set) var idleDestinations: [IslandIdleDestination] = []
    @Published private(set) var idleWeather: IslandWeatherSnapshot?
    private var lastRecordedIdleMediaDestination: IslandIdleDestination?

    /// After opening a chat tab, don't re-expand just because the cursor is still over the island.
    private var suppressHoverExpand = false
    private var lastOpenedChatTabID: Int?
    private var cachedTitle = ""
    private var cachedArtist = ""
    private var cachedArtwork: NSImage?
    private var cachedMediaPlatform: StreamingPlatform?
    private var cachedUsesPlatformLogo = false
    private var cachedDuration: TimeInterval = 0
    private var cachedElapsed: TimeInterval = 0
    private var cachedPlaying = false
    private var hasCachedMedia = false
    /// Keep collapse locked briefly after Check Now so hover / focus races can't reopen the island.
    private var suppressExpandUntil: Date?
    private var shelfExpireTimer: Timer?

    init() {
        bindNowPlaying()
        bindSystemAudioWaveform()
        bindChromeMonitor()
        bindPowerMonitor()
        bindLevelHUD()
        bindFocusMonitor()
        bindLiveActivities()
        bindShelfExpiry()
        bindIdleGlance()
        bindFTUEPreview()
        syncChromeMonitor(denied: settings.automationDenied)
    }

    var isOverlayActive: Bool { transientOverlay != nil }

    /// Weather + ranked destinations — only when nothing else owns the island.
    /// Compact and hover-expanded both use this; live media/chat/recording win.
    var showsIdleGlance: Bool {
        settings.idleGlanceEnabled
            && transientOverlay == nil
            && !hasMedia
            && persistentState == .idle
            && !isScreenRecording
            && !isSelectingScreenToRecord
    }

    var showsExpandedIdleGlance: Bool {
        showsIdleGlance && isExpanded
    }

    var showsCompactIdleGlance: Bool {
        showsIdleGlance && !isExpanded
    }

    var dualActivity: IslandSurfacePolicy.DualActivity {
        IslandSurfacePolicy.dualActivity(
            isScreenRecording: isScreenRecording,
            hasMedia: persistentState == .musicPlaying,
            overlay: transientOverlay
        )
    }

    var showsCompactLiveActivity: Bool {
        transientOverlay == nil
            && !isExpanded
            && (isSelectingScreenToRecord || (isScreenRecording && persistentState != .musicPlaying))
    }

    var showsRecordingExpanded: Bool {
        transientOverlay == nil
            && isScreenRecording
            && isExpanded
            && persistentState != .musicPlaying
    }

    var showsMediaRecordingDual: Bool {
        dualActivity == .mediaAndRecording && isExpanded
    }

    var showsRecordingChatDual: Bool {
        dualActivity == .recordingAndChat
    }

    var islandShapeWidth: CGFloat {
        switch transientOverlay {
        case .charging, .lowBattery, .volume, .brightness, .focusMode:
            return IslandMetrics.batteryBannerWidth
        case .chatReady where dualActivity == .recordingAndChat || persistentState == .musicPlaying:
            return IslandMetrics.dualWidthFixed
        case .chatReady:
            return IslandMetrics.chatOnlyWidthFixed
        case .none:
            break
        }
        if showsMediaRecordingDual {
            return IslandMetrics.dualWidthFixed
        }
        if isScreenRecording && isExpanded {
            return IslandMetrics.batteryBannerWidth
        }
        if showsDualNowPlaying {
            return IslandMetrics.dualWidthFixed
        }
        if isExpanded {
            return IslandMetrics.expandedWidth(notchWidth: notchWidth)
        }
        if showsCompactIdleGlance {
            return IslandMetrics.idleGlanceCompactWidth(notchWidth: notchWidth)
        }
        if showsCompactDualNowPlaying {
            return IslandMetrics.compactWidth(notchWidth: notchWidth)
                + IslandMetrics.compactDualWidthBoost
        }
        return IslandMetrics.compactWidth(notchWidth: notchWidth)
    }

    var islandShapeHeight: CGFloat {
        switch transientOverlay {
        case .charging, .lowBattery, .volume, .brightness, .focusMode:
            return IslandMetrics.chargingBannerHeight(notchHeight: notchHeight)
        case .chatReady:
            return IslandMetrics.dualHeight(notchHeight: notchHeight)
        case .none:
            break
        }
        if showsMediaRecordingDual {
            return IslandMetrics.dualHeight(notchHeight: notchHeight)
        }
        if isScreenRecording && isExpanded {
            return IslandMetrics.recordingBannerHeight(notchHeight: notchHeight)
        }
        if showsDualNowPlaying {
            return IslandMetrics.dualHeight(notchHeight: notchHeight)
        }
        if isExpanded {
            if showsShelfRow {
                return IslandMetrics.expandedHeight + IslandMetrics.shelfSectionHeight
            }
            return IslandMetrics.expandedHeight
        }
        return IslandMetrics.compactHeight(notchHeight: notchHeight)
    }

    var islandTopOffset: CGFloat {
        0
    }

    /// Call from the island view’s `onAppear`. Plays the full FTUE once.
    func noteIslandAppeared(defaults: UserDefaults = .standard) {
        let should = NotchFTUEStore.shouldPlay(defaults: defaults)
        NotchFTUEMetrics.log("noteIslandAppeared shouldPlay=\(should)")
        guard should else { return }
        startFTUESequence(markSeen: true, defaults: defaults)
    }

    /// Settings → Replay Intro. Resets the flag and runs the full sequence again.
    func replayFTUEIntro(defaults: UserDefaults = .standard) {
        NotchFTUEMetrics.log("replayFTUEIntro")
        NotchFTUEStore.reset(defaults: defaults)
        startFTUESequence(markSeen: true, defaults: defaults)
    }

    /// Glow-only preview (no expand/tooltip). Does not change `hasSeenFTUE`.
    func playFTUEGlowPreview() {
        guard !isFTUESequenceRunning else { return }
        NotchFTUEMetrics.log("playFTUEGlowPreview")
        ftueTask?.cancel()
        ftuePlayToken &+= 1
        let token = ftuePlayToken
        isFTUESequenceRunning = true
        ftuePhase = .preparing
        ftueGlowAmount = 0
        ftueContentOpacity = 0
        showsFTUETooltip = false
        ftueGhostCursorProgress = 0
        ftueGhostCursorOpacity = 0
        ftueTask = Task { @MainActor [weak self] in
            await self?.runGlowOnlyPreview(token: token)
        }
    }

    private func startFTUESequence(markSeen: Bool, defaults: UserDefaults) {
        if markSeen {
            NotchFTUEStore.markSeen(defaults: defaults)
        }
        ftueTask?.cancel()
        ftuePlayToken &+= 1
        let token = ftuePlayToken

        // Fully black pill first: glow mounted at 0, no content inside.
        isFTUESequenceRunning = true
        ftuePhase = .preparing
        ftueGlowAmount = 0
        ftueContentOpacity = 0
        showsFTUETooltip = false
        ftueGhostCursorProgress = 0
        ftueGhostCursorOpacity = 0
        ftueSawRealHover = false
        suppressHoverExpand = true
        suppressExpandUntil = nil
        if isExpanded { isExpanded = false }

        NotchFTUEMetrics.log("sequence start token=\(token) phase=preparing glow=0 content=0")
        NotificationCenter.default.post(name: .ftueSequenceStarted, object: nil)

        ftueTask = Task { @MainActor [weak self] in
            await self?.runFullFTUESequence(token: token)
        }
    }

    @MainActor
    private func runFullFTUESequence(token: Int) async {
        // Let SwiftUI commit the preparing frame (glow at 0, content hidden)
        // before ease-out starts — otherwise 0→1 coalesces into an instant cut.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 16_000_000)
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        // 1. Glow-in: opacity + hue travel red→…→green (same screen point changes hue)
        ftuePhase = .glowIn
        NotchFTUEMetrics.logGradientStopsAtRender()
        NotchFTUEMetrics.log("glow-in begin duration=\(NotchFTUEMetrics.glowInDuration)")
        withAnimation(NotchFTUEMetrics.glowInAnimation) {
            ftueGlowAmount = 1
        }
        NotchFTUEMetrics.log("glow amount → 1 (opacity only; 6-stop spatial gradient static)")
        try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.glowInDuration))
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        // 2. Hold at green end of the gradient
        ftuePhase = .hold
        NotchFTUEMetrics.log("hold begin")
        try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.holdDuration))
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        // 3. Morph → content fades in; glow contracts away
        ftuePhase = .morph
        NotchFTUEMetrics.log("morph begin duration=\(NotchFTUEMetrics.morphDuration)")
        withAnimation(NotchFTUEMetrics.morphAnimation) {
            ftueGlowAmount = 0
            ftueContentOpacity = 1
        }
        NotchFTUEMetrics.log("glow amount → 0, content → 1 (animated)")
        try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.morphDuration))
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        // 4. Ghost-cursor: demo hover, then repeating nudge until real hover.
        try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.pauseBeforeExpand))
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        await runGhostCursorDemoCycle(token: token)
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        ftuePhase = .awaitingHover
        suppressHoverExpand = false
        isFTUESequenceRunning = false
        withAnimation(NotchFTUEMetrics.tooltipAnimation) {
            showsFTUETooltip = true
        }
        NotchFTUEMetrics.log("ghost nudge loop — awaiting real hover")

        await runGhostCursorNudgeLoop(token: token)
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        // Hover already cleared these instantly; snap any leftover without fade.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            ftueGhostCursorOpacity = 0
            showsFTUETooltip = false
            ftueGhostCursorProgress = 0
        }
        ftuePhase = .idle
        NotchFTUEMetrics.log("sequence complete (ghost dismissed by real hover)")
    }

    /// One full demo: onto right of pill → expand; away → collapse.
    @MainActor
    private func runGhostCursorDemoCycle(token: Int) async {
        ftuePhase = .demoExpand
        ftueSawRealHover = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            ftueGhostCursorProgress = 0
            ftueGhostCursorOpacity = 0
            showsFTUETooltip = false
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 16_000_000)
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        NotchFTUEMetrics.log("ghost demo: fade in off-notch")
        withAnimation(NotchFTUEMetrics.tooltipAnimation) {
            showsFTUETooltip = true
        }
        // Fade in and start the glide together so the approach doesn’t hitch.
        withAnimation(NotchFTUEMetrics.ghostCursorFadeAnimation) {
            ftueGhostCursorOpacity = 1
        }
        withAnimation(NotchFTUEMetrics.ghostCursorApproachAnimation) {
            ftueGhostCursorProgress = 1
        }
        try? await Task.sleep(nanoseconds: Self.ftueNanos(
            max(NotchFTUEMetrics.ghostCursorFadeInDuration, NotchFTUEMetrics.ghostCursorApproachDuration)
        ))
        guard !Task.isCancelled, ftuePlayToken == token else { return }
        expandForFTUEDemo()

        try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.ghostCursorDwellDuration))
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        NotchFTUEMetrics.log("ghost demo: slide away → collapse")
        withAnimation(NotchFTUEMetrics.ghostCursorRetreatAnimation) {
            ftueGhostCursorProgress = 0
        }
        collapseForFTUEDemo()
        try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.ghostCursorRetreatDuration))
        guard !Task.isCancelled, ftuePlayToken == token else { return }
        NotchFTUEMetrics.log("ghost demo cycle complete")
    }

    /// Soft double upward nudge until the user hovers for real.
    /// Starts from wherever the demo left the cursor (away / progress 0) — no snap.
    @MainActor
    private func runGhostCursorNudgeLoop(token: Int) async {
        let rest = NotchFTUEMetrics.ghostCursorNudgeRestProgress(
            islandWidth: IslandMetrics.idleGlanceCompactWidth(notchWidth: notchWidth)
        )

        // Demo ends at away (progress 0). Ease up to rest from that same place
        // instead of teleporting onto the ear.
        if abs(ftueGhostCursorProgress - rest) > 0.01 {
            withAnimation(NotchFTUEMetrics.ghostCursorNudgeUpAnimation) {
                ftueGhostCursorProgress = rest
            }
            try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.ghostCursorNudgeUpDuration))
            guard !Task.isCancelled, ftuePlayToken == token else { return }
            if ftueSawRealHover { return }
        }

        while true {
            guard !Task.isCancelled, ftuePlayToken == token else { return }
            if ftueSawRealHover { return }

            for peck in 0..<2 {
                withAnimation(NotchFTUEMetrics.ghostCursorNudgeUpAnimation) {
                    ftueGhostCursorProgress = 1
                }
                try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.ghostCursorNudgeUpDuration))
                guard !Task.isCancelled, ftuePlayToken == token else { return }
                if ftueSawRealHover { return }

                withAnimation(NotchFTUEMetrics.ghostCursorNudgeDownAnimation) {
                    ftueGhostCursorProgress = rest
                }
                try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.ghostCursorNudgeDownDuration))
                guard !Task.isCancelled, ftuePlayToken == token else { return }
                if ftueSawRealHover { return }

                if peck == 0 {
                    try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.ghostCursorNudgeBetweenPecksDuration))
                    guard !Task.isCancelled, ftuePlayToken == token else { return }
                    if ftueSawRealHover { return }
                }
            }

            try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.ghostCursorNudgeLoopPauseDuration))
        }
    }

    @MainActor
    private func runGlowOnlyPreview(token: Int) async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 16_000_000)
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        ftuePhase = .glowIn
        NotchFTUEMetrics.logGradientStopsAtRender()
        NotchFTUEMetrics.log("preview glow-in")
        withAnimation(NotchFTUEMetrics.glowInAnimation) {
            ftueGlowAmount = 1
        }
        try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.glowInDuration))
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        ftuePhase = .hold
        try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.holdDuration))
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        ftuePhase = .morph
        withAnimation(NotchFTUEMetrics.morphAnimation) {
            ftueGlowAmount = 0
        }
        try? await Task.sleep(nanoseconds: Self.ftueNanos(NotchFTUEMetrics.morphDuration))
        guard !Task.isCancelled, ftuePlayToken == token else { return }

        isFTUESequenceRunning = false
        ftuePhase = .idle
        ftueContentOpacity = 1
        NotchFTUEMetrics.log("preview complete")
    }

    private func expandForFTUEDemo() {
        guard !isOverlayActive else { return }
        suppressHoverExpand = false
        suppressExpandUntil = nil
        setExpandedIfNeeded()
        NotificationCenter.default.post(name: .islandIdleGlanceExpanded, object: nil)
    }

    private func collapseForFTUEDemo() {
        guard !isOverlayActive else { return }
        guard !isDropTargeted, !isDraggingShelfItem else { return }
        if isExpanded {
            isExpanded = false
        }
        // Keep hover locked until the tooltip finishes so pointer position
        // cannot bounce the island open mid-demo.
        suppressHoverExpand = true
    }

    private static func ftueNanos(_ interval: TimeInterval) -> UInt64 {
        UInt64(max(interval, 0) * 1_000_000_000)
    }

    /// Idle-glance / media content stays hidden until morph (or sequence idle).
    var showsFTUEInteriorContent: Bool {
        if !isFTUESequenceRunning { return true }
        return ftueContentOpacity > 0.01
    }

    var notchDeadZoneWidth: CGFloat {
        hasPhysicalNotch ? max(notchWidth - 8, 24) : 16
    }

    /// File tray sits under the expanded island (music or idle glance).
    /// Compact island is unchanged.
    var showsShelfRow: Bool {
        (settings.shelfEnabled || shelfPreviewActive)
            && transientOverlay == nil
            && !showsRecordingExpanded
            && !showsMediaRecordingDual
            && isExpanded
            && (isDropTargeted || !shelfItems.isEmpty)
    }

    func expand() {
        if !isFTUESequenceRunning {
            dismissFTUEGhostOnRealHover()
        }
        expandLiveActivity(fromClick: false)
    }

    /// Drop the demo cursor/tip instantly on real hover — do not wait for the
    /// nudge-loop sleep or the old fade-out.
    private func dismissFTUEGhostOnRealHover() {
        ftueSawRealHover = true
        guard ftueGhostCursorOpacity > 0.001 || showsFTUETooltip else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            ftueGhostCursorOpacity = 0
            showsFTUETooltip = false
        }
    }

    /// Deliberate click on the compact recording pill. Clears the Check Now
    /// hover lock so Stop stays reachable after swapping to another app.
    func expandRecordingFromClick() {
        expandLiveActivity(fromClick: true)
    }

    private func expandLiveActivity(fromClick: Bool) {
        if isDropTargeted || isDraggingShelfItem {
            setExpandedIfNeeded()
            return
        }
        // Idle glance expands on hover, but honor the timed lock used after
        // Check Now / idle destination navigation so Chrome under the cursor
        // cannot bounce the island back open immediately.
        if showsIdleGlance || (!hasMedia && persistentState == .idle && settings.idleGlanceEnabled) {
            if let until = suppressExpandUntil, until > Date() { return }
            suppressHoverExpand = false
            setExpandedIfNeeded()
            return
        }
        if IslandSurfacePolicy.shouldAllowRecordingExpand(
            isScreenRecording: isScreenRecording,
            fromClick: fromClick,
            suppressHoverExpand: suppressHoverExpand,
            suppressUntil: suppressExpandUntil
        ) {
            if fromClick {
                suppressHoverExpand = false
                suppressExpandUntil = nil
            }
            setExpandedIfNeeded()
            return
        }
        guard !suppressHoverExpand else { return }
        if let until = suppressExpandUntil, until > Date() { return }
        if isSelectingScreenToRecord && !isScreenRecording { return }
        setExpandedIfNeeded()
    }

    private func setExpandedIfNeeded() {
        guard !isExpanded else { return }
        isExpanded = true
        NotificationCenter.default.post(name: .islandIdleGlanceExpanded, object: nil)
    }

    func collapse() {
        guard !isOverlayActive else { return }
        guard !isDropTargeted, !isDraggingShelfItem else { return }
        guard isExpanded else { return }
        isExpanded = false
    }

    func setDropTargeted(_ targeted: Bool) {
        guard settings.shelfEnabled else {
            isDropTargeted = false
            return
        }
        isDropTargeted = targeted
        if targeted {
            isExpanded = true
        }
    }

    func handleShelfDrop(providers: [NSItemProvider]) -> Bool {
        guard settings.shelfEnabled else { return false }
        for provider in providers {
            ShelfDropIngest.load(provider) { [weak self] item in
                guard let item else { return }
                DispatchQueue.main.async {
                    self?.addShelfItem(item)
                }
            }
        }
        return true
    }

    func addShelfItem(_ item: ShelfItem) {
        guard settings.shelfEnabled else { return }
        shelfItems = ShelfLogic.inserting(item, into: shelfItems)
        if !isOverlayActive {
            isExpanded = true
        }
    }

    func removeShelfItem(id: UUID) {
        shelfItems = ShelfLogic.removing(id: id, from: shelfItems)
        if shelfItems.isEmpty, !isDropTargeted, !isOverlayActive {
            isExpanded = false
        }
    }

    func beginShelfDrag() {
        isDraggingShelfItem = true
        isExpanded = true
    }

    func endShelfDrag(itemID: UUID, completedOutside: Bool) {
        isDraggingShelfItem = false
        if completedOutside {
            removeShelfItem(id: itemID)
        }
    }

    func presentShelfHoldPreview() {
        shelfPreviewActive = true
        clearTransientOverlay(collapseIfNeeded: false)
        shelfItems.removeAll(where: \.isPreview)
        if shelfItems.isEmpty {
            for item in ShelfPreview.sampleItems() {
                shelfItems = ShelfLogic.inserting(item, into: shelfItems)
            }
        }
        isDropTargeted = false
        isExpanded = true
    }

    func presentShelfDropPreview() {
        shelfPreviewActive = true
        clearTransientOverlay(collapseIfNeeded: false)
        isDropTargeted = true
        isExpanded = true
        shelfDropPreviewTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDropTargeted = false
                if self.shelfItems.isEmpty {
                    self.shelfPreviewActive = false
                    self.isExpanded = false
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shelfDropPreviewTimer = timer
    }

    func clearShelfPreview() {
        shelfDropPreviewTimer?.invalidate()
        shelfDropPreviewTimer = nil
        isDropTargeted = false
        shelfItems.removeAll(where: \.isPreview)
        shelfPreviewActive = false
        if shelfItems.isEmpty, !isOverlayActive {
            isExpanded = false
        }
    }

    func setHoldLastMedia(_ hold: Bool) {
        holdLastMedia = hold
        if hold, hasCachedMedia {
            applyCachedMedia()
        } else if !hold {
            // Anything cached before/during lock may refer to a browser tab
            // that was closed while MediaRemote delivery was suspended.
            clearCachedMedia()
            applySnapshot(NowPlayingService.Snapshot())
            nowPlaying.refresh()
        }
    }

    func openPlaybackOutputPicker() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.sound"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func togglePlayPause() { nowPlaying.togglePlayPause() }
    /// Previous item in the queue / YouTube playlist.
    func skipBackward()    { nowPlaying.previousTrack() }
    /// Next item in the queue / YouTube playlist.
    func skipForward()     { nowPlaying.nextTrack() }

    func handleKeyboardTransport(_ key: IslandKeyboardTransport) {
        // Prefer view-model flag; fall back to live snapshot so a brief
        // hasMedia lag cannot swallow F8 after the key was already captured.
        guard hasMedia || nowPlaying.snapshot.hasMedia else { return }
        switch key {
        case .playPause:
            togglePlayPause()
        case .skipBack:
            skipBackward()
        case .skipForward:
            skipForward()
        }
    }

    func openNowPlayingSource() {
        guard hasMedia else { return }
        // Same as opening a chat tab: Chrome comes forward under the cursor,
        // and hover must not bounce the player back open.
        suppressHoverExpand = true
        collapse()
        nowPlaying.revealSource()
    }

    /// Displayed elapsed time (scrub position while dragging).
    var displayedTime: TimeInterval {
        isScrubbing ? scrubTime : currentTime
    }

    func beginScrubbing(at fraction: Double) {
        guard duration > 0 else { return }
        isScrubbing = true
        scrubTime = clampedTime(fraction: fraction)
    }

    func updateScrubbing(fraction: Double) {
        guard isScrubbing, duration > 0 else { return }
        scrubTime = clampedTime(fraction: fraction)
    }

    func endScrubbing(fraction: Double) {
        guard duration > 0 else {
            isScrubbing = false
            return
        }
        let time = clampedTime(fraction: fraction)
        scrubTime = time
        currentTime = time
        isScrubbing = false
        nowPlaying.seek(to: time)
    }

    private func clampedTime(fraction: Double) -> TimeInterval {
        let f = min(max(fraction, 0), 1)
        return f * duration
    }

    private func refreshWaveformTint(from image: NSImage?) {
        guard let image else {
            lastTintedArtwork = nil
            waveformGradient = .fallback
            return
        }
        let identity = ObjectIdentifier(image)
        if identity == lastTintedArtwork { return }
        lastTintedArtwork = identity
        artworkTintQueue.async { [weak self] in
            let gradient = ArtworkTint.waveformGradient(from: image)
            DispatchQueue.main.async {
                guard let self, self.artwork === image else { return }
                self.waveformGradient = gradient
            }
        }
    }

    /// Shared live-session gate for expanded dual tiles and compact stacked art.
    var hasDualLiveNowPlayingSessions: Bool {
        DualNowPlayingSurfacePolicy.hasLiveDualSessions(
            featureEnabled: IslandFeatures.dualNowPlayingEnabled,
            hasMedia: hasMedia,
            isPlaying: isPlaying,
            secondaryHasMedia: secondaryHasMedia,
            secondaryIsPlaying: secondaryIsPlaying,
            overlayActive: transientOverlay != nil,
            isScreenRecording: isScreenRecording,
            isSelectingScreenToRecord: isSelectingScreenToRecord
        )
    }

    /// True only when *both* tiles are actively playing. Pausing either side
    /// collapses back to the single-tile player of the session that is still live.
    var showsDualNowPlaying: Bool {
        DualNowPlayingSurfacePolicy.showsExpandedSplit(
            hasLiveDualSessions: hasDualLiveNowPlayingSessions,
            isExpanded: isExpanded
        )
    }

    /// Compact (collapsed) island: both sessions live → stacked overlapping art.
    var showsCompactDualNowPlaying: Bool {
        DualNowPlayingSurfacePolicy.showsCompactStackedArt(
            hasLiveDualSessions: hasDualLiveNowPlayingSessions,
            isExpanded: isExpanded
        )
    }

    /// MediaRemote often keeps audio (Spotify / YT Music) as primary while a
    /// video tab is secondary. Product layout is video left / audio right —
    /// swap tiles (and click routing) when that happens so pause-on-left stops
    /// the video. Same swap decides which thumbnail sits in front of the
    /// compact stack. Video+video and audio+audio keep MediaRemote primary left.
    var dualNowPlayingSwapsTiles: Bool {
        DualNowPlayingSurfacePolicy.swapsTiles(
            hasLiveDualSessions: hasDualLiveNowPlayingSessions,
            primaryKind: mediaPlatform?.mediaKind,
            secondaryKind: secondaryMediaPlatform?.mediaKind
        )
    }

    // MARK: Secondary controls — routed to the second browser tab only.
    func toggleSecondaryPlayPause() { nowPlaying.secondaryTogglePlayPause() }
    func skipSecondaryBackward()    { nowPlaying.secondarySkipBackward() }
    func skipSecondaryForward()     { nowPlaying.secondarySkipForward() }
    func openSecondaryNowPlayingSource() {
        guard secondaryHasMedia else { return }
        suppressHoverExpand = true
        collapse()
        nowPlaying.secondaryRevealSource()
    }

    private func applySecondarySnapshot(_ snap: NowPlayingService.Snapshot) {
        let isBrowser = MediaClient.isBrowserBundle(snap.bundleIdentifier)
        let live = PlaybackPlayingPolicy.islandHasMedia(
            isBrowser: isBrowser,
            payloadHasMedia: snap.hasMedia,
            isPlaying: snap.isPlaying,
            sourceURL: snap.sourceURL
        )
        secondaryHasMedia = live
        secondaryIsPlaying = live && snap.isPlaying
        secondaryWaveform.setPlaying(secondaryIsPlaying)
        if !secondaryIsPlaying {
            secondaryWaveform.setUsesLiveCapture(false)
        }
        defer { refreshSystemAudioCapture() }
        guard live else {
            secondarySongTitle = ""
            secondaryArtistName = ""
            secondaryCurrentTime = 0
            secondaryDuration = 0
            secondaryArtwork = nil
            secondaryMediaPlatform = nil
            secondaryUsesPlatformLogo = false
            secondaryWaveformGradient = .fallback
            lastSecondaryTintedArtwork = nil
            return
        }
        let platform = StreamingPlatform.resolve(
            bundleID: snap.bundleIdentifier,
            appName: snap.appName,
            artist: snap.artist,
            title: snap.title,
            url: snap.sourceURL
        )
        let displayTitle = StreamingPlatform.displayTitle(
            mediaTitle: snap.title,
            pageTitle: snap.sourcePageTitle,
            metadataTitle: snap.album,
            platform: platform
        )
        secondarySongTitle = displayTitle.isEmpty ? "Now Playing" : displayTitle
        secondaryArtistName = snap.artist.isEmpty ? "—" : snap.artist
        secondaryCurrentTime = snap.elapsed
        secondaryDuration = snap.duration
        secondaryArtwork = snap.artwork
        secondaryMediaPlatform = platform
        secondaryUsesPlatformLogo = DualNowPlayingSurfacePolicy.usesPlatformLogoForDualTile(
            artworkToken: snap.artworkToken
        )
        refreshSecondaryTint(from: snap.artwork)
    }

    private func refreshSecondaryTint(from image: NSImage?) {
        guard let image else {
            lastSecondaryTintedArtwork = nil
            secondaryWaveformGradient = .fallback
            return
        }
        let identity = ObjectIdentifier(image)
        if identity == lastSecondaryTintedArtwork { return }
        lastSecondaryTintedArtwork = identity
        artworkTintQueue.async { [weak self] in
            let gradient = ArtworkTint.waveformGradient(from: image)
            DispatchQueue.main.async {
                guard let self, self.secondaryArtwork === image else { return }
                self.secondaryWaveformGradient = gradient
            }
        }
    }

    private func bindNowPlaying() {
        nowPlaying.$secondarySnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                self?.applySecondarySnapshot(snap)
            }
            .store(in: &cancellables)

        nowPlaying.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                guard let self else { return }
                let isBrowser = MediaClient.isBrowserBundle(snap.bundleIdentifier)
                let showMedia = PlaybackPlayingPolicy.islandHasMedia(
                    isBrowser: isBrowser,
                    payloadHasMedia: snap.hasMedia,
                    isPlaying: snap.isPlaying,
                    sourceURL: snap.sourceURL
                )
                if showMedia {
                    let platform = StreamingPlatform.resolve(
                        bundleID: snap.bundleIdentifier,
                        appName: snap.appName,
                        artist: snap.artist,
                        title: snap.title,
                        url: snap.sourceURL
                    )
                    let displayTitle = StreamingPlatform.displayTitle(
                        mediaTitle: snap.title,
                        pageTitle: snap.sourcePageTitle,
                        metadataTitle: snap.album,
                        platform: platform
                    )
                    self.cachedTitle = displayTitle.isEmpty ? "Now Playing" : displayTitle
                    self.cachedArtist = snap.artist.isEmpty ? "—" : snap.artist
                    if snap.artwork != nil {
                        self.cachedArtwork = snap.artwork
                    }
                    self.cachedMediaPlatform = platform
                    self.cachedUsesPlatformLogo = DualNowPlayingSurfacePolicy.usesPlatformLogoForDualTile(
                        artworkToken: snap.artworkToken
                    )
                    self.cachedDuration = snap.duration
                    self.cachedElapsed = snap.elapsed
                    self.cachedPlaying = snap.isPlaying
                    self.hasCachedMedia = true
                    self.applySnapshot(snap)
                    return
                }
                if self.holdLastMedia, self.hasCachedMedia {
                    self.applyCachedMedia()
                    return
                }
                self.clearCachedMedia()
                self.applySnapshot(snap)
            }
            .store(in: &cancellables)
    }

    /// System-output spectrum (Core Audio process tap). YouTube pages expose no
    /// audio tracks via `captureStream`, so in-tab JS spectrum cannot work.
    /// Dual video+audio: only the audio tile follows the mix (usually music);
    /// the video tile stays near idle so quiet Watch does not dance to Music.
    private func bindSystemAudioWaveform() {
        audioAmplitude.$bands
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bands in
                self?.applySystemBands(bands)
            }
            .store(in: &cancellables)

        audioAmplitude.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let self else { return }
                if !running {
                    self.waveform.setUsesLiveCapture(false)
                    self.secondaryWaveform.setUsesLiveCapture(false)
                } else {
                    self.applySystemBands(self.audioAmplitude.bands)
                }
            }
            .store(in: &cancellables)
    }

    private func refreshSystemAudioCapture() {
        let anyPlaying = isPlaying || secondaryIsPlaying
        if anyPlaying {
            audioAmplitude.start()
            applySystemBands(audioAmplitude.bands)
        } else {
            audioAmplitude.stop()
            waveform.setUsesLiveCapture(false)
            secondaryWaveform.setUsesLiveCapture(false)
        }
    }

    private func applySystemBands(_ bands: [CGFloat]) {
        let hasEnergy = audioAmplitude.isRunning
            || audioAmplitude.amplitude > 0
            || bands.contains(where: { $0 > 0.02 })
        guard hasEnergy else { return }
        guard isPlaying || secondaryIsPlaying else {
            waveform.setUsesLiveCapture(false)
            secondaryWaveform.setUsesLiveCapture(false)
            return
        }

        let idle = Array(repeating: CGFloat(0), count: SimulatedWaveform.barCount)
        let live = bands.count == SimulatedWaveform.barCount ? bands : idle

        let dual = hasDualLiveNowPlayingSessions
        let primaryKind = mediaPlatform?.mediaKind
        let secondaryKind = secondaryMediaPlatform?.mediaKind

        if dual, primaryKind == .video, secondaryKind == .audio {
            waveform.setUsesLiveCapture(true)
            waveform.setLiveBands(idle)
            secondaryWaveform.setUsesLiveCapture(true)
            secondaryWaveform.setLiveBands(live)
            return
        }
        if dual, primaryKind == .audio, secondaryKind == .video {
            waveform.setUsesLiveCapture(true)
            waveform.setLiveBands(live)
            secondaryWaveform.setUsesLiveCapture(true)
            secondaryWaveform.setLiveBands(idle)
            return
        }

        if isPlaying {
            waveform.setUsesLiveCapture(true)
            waveform.setLiveBands(live)
        } else {
            waveform.setUsesLiveCapture(false)
        }

        if secondaryIsPlaying {
            secondaryWaveform.setUsesLiveCapture(true)
            secondaryWaveform.setLiveBands(live)
        } else {
            secondaryWaveform.setUsesLiveCapture(false)
        }
    }

    private func clearCachedMedia() {
        cachedTitle = ""
        cachedArtist = ""
        cachedArtwork = nil
        cachedMediaPlatform = nil
        cachedUsesPlatformLogo = false
        cachedDuration = 0
        cachedElapsed = 0
        cachedPlaying = false
        hasCachedMedia = false
    }

    private func applyCachedMedia() {
        isPlaying = cachedPlaying
        waveform.setPlaying(cachedPlaying)
        hasMedia = true
        songTitle = cachedTitle
        artistName = cachedArtist
        if !isScrubbing {
            currentTime = cachedElapsed
        }
        duration = cachedDuration
        artwork = cachedArtwork
        mediaPlatform = cachedMediaPlatform
        usesPlatformLogo = cachedUsesPlatformLogo
        refreshWaveformTint(from: cachedArtwork)
        persistentState = .musicPlaying
        refreshSystemAudioCapture()
    }

    private func applySnapshot(_ snap: NowPlayingService.Snapshot) {
        // Sync secondary UI before primary so compact dual can turn on in the
        // same turn when the service published secondarySnapshot first.
        let sec = nowPlaying.secondarySnapshot
        if sec.hasMedia, sec.isPlaying {
            let needsSecondarySync = !secondaryHasMedia
                || !secondaryIsPlaying
                || secondarySongTitle != sec.title
                || secondaryArtwork !== sec.artwork
            if needsSecondarySync {
                applySecondarySnapshot(sec)
            }
        }

        isPlaying = snap.isPlaying
        waveform.setPlaying(snap.isPlaying)
        if !snap.isPlaying {
            waveform.setUsesLiveCapture(false)
        }
        let isBrowser = MediaClient.isBrowserBundle(snap.bundleIdentifier)
        hasMedia = PlaybackPlayingPolicy.islandHasMedia(
            isBrowser: isBrowser,
            payloadHasMedia: snap.hasMedia,
            isPlaying: snap.isPlaying,
            sourceURL: snap.sourceURL
        )
        defer { refreshSystemAudioCapture() }
        let platform = hasMedia
            ? StreamingPlatform.resolve(
                bundleID: snap.bundleIdentifier,
                appName: snap.appName,
                artist: snap.artist,
                title: snap.title,
                url: snap.sourceURL
            )
            : nil
        // Demote→Music often lands with youtubeMusic / pending token before URL
        // bind; prefer that so Watch-left / Music-right swap (and dual stack
        // front tile) is correct immediately — never treat pending Music as
        // Watch (that painted a YouTube logo via CompactDual fallback).
        let resolvedPlatform: StreamingPlatform? = {
            if snap.artworkToken.contains("youtubeMusic") { return .youtubeMusic }
            if snap.sourceURL.contains("music.youtube.com") { return .youtubeMusic }
            return platform
        }()
        let displayTitle = StreamingPlatform.displayTitle(
            mediaTitle: snap.title,
            pageTitle: snap.sourcePageTitle,
            metadataTitle: snap.album,
            platform: resolvedPlatform ?? platform
        )
        let nextTitle = hasMedia
            ? (displayTitle.isEmpty ? "Now Playing" : displayTitle)
            : "Not Playing"
        let trackIdentityChanged = hasMedia
            && nextTitle != songTitle
            && !songTitle.isEmpty
            && songTitle != "Not Playing"
        songTitle = nextTitle
        artistName = hasMedia
            ? (snap.artist.isEmpty ? "—" : snap.artist)
            : "—"
        if !isScrubbing {
            currentTime = snap.elapsed
        }
        duration = snap.duration
        let pendingArtwork = snap.artworkToken.hasPrefix("pending:")
        let platformChanged = (resolvedPlatform ?? platform) != mediaPlatform
            && (resolvedPlatform ?? platform) != nil
            && mediaPlatform != nil
        if let image = snap.artwork {
            artwork = image
        } else if !pendingArtwork || trackIdentityChanged || platformChanged {
            artwork = nil
        }
        mediaPlatform = resolvedPlatform ?? platform
        usesPlatformLogo = DualNowPlayingSurfacePolicy.usesPlatformLogoForDualTile(
            artworkToken: snap.artworkToken
        )
        refreshWaveformTint(from: snap.artwork)
        persistentState = hasMedia ? .musicPlaying : .idle
        if hasMedia, let destination = IslandIdleDestination.from(platform: mediaPlatform) {
            noteIdleDestinationUsage(destination)
        } else if !hasMedia {
            lastRecordedIdleMediaDestination = nil
        }
    }

    private func bindIdleGlance() {
        idleDestinations = idleDestinationStore.ranked
        idleDestinationStore.$ranked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ranked in
                self?.idleDestinations = ranked
            }
            .store(in: &cancellables)

        idleWeather = weatherService.snapshot
        weatherService.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.idleWeather = snapshot
            }
            .store(in: &cancellables)

        settings.$idleGlanceEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.weatherService.start()
                } else {
                    self.weatherService.stop()
                }
            }
            .store(in: &cancellables)

        if settings.idleGlanceEnabled {
            weatherService.start()
        }
    }

    private func noteIdleDestinationUsage(_ destination: IslandIdleDestination) {
        if destination == lastRecordedIdleMediaDestination {
            return
        }
        // Avoid double-counting continuous Now Playing polls for the same session.
        if destination == .youtube || destination == .youtubeMusic {
            lastRecordedIdleMediaDestination = destination
        }
        idleDestinationStore.record(destination)
    }

    func openIdleDestination(at index: Int) {
        guard idleDestinations.indices.contains(index) else { return }
        let destination = idleDestinations[index]
        idleDestinationStore.record(destination)
        if destination == .youtube || destination == .youtubeMusic {
            lastRecordedIdleMediaDestination = destination
        }
        // Same as Check Now / open Now Playing source: collapse first and lock
        // hover briefly so Chrome activating under the cursor cannot re-expand.
        suppressHoverExpand = true
        suppressExpandUntil = Date().addingTimeInterval(2.5)
        collapse()
        // Fast path — never enqueue AppleScript tab scans on the media queue.
        IslandIdleNavigator.open(destination)
    }

    private func bindPowerMonitor() {
        powerMonitor.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.presentPowerEvent(event)
            }
        }
        powerMonitor.onLowBatteryProximity = {
            SystemHUDSuppressor.shared.suppressNativeLowBatteryAlert()
        }
        powerMonitor.start()

        NotificationCenter.default.publisher(for: .previewCharging)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.presentPowerEvent(.chargingStarted(percent: 75))
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .previewLowBattery)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.presentPowerEvent(.lowBattery(percent: 10))
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("NSProcessInfoPowerStateDidChange"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .store(in: &cancellables)
    }

    private func bindLevelHUD() {
        levelMonitor.onEvent = { [weak self] event in
            self?.presentLevelHUD(event)
        }
        levelMonitor.onTransport = { [weak self] key in
            self?.handleKeyboardTransport(key)
        }
        levelMonitor.start()

        NotificationCenter.default.publisher(for: .previewSound)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.presentLevelHUD(LevelHUDEvent(kind: .volume, percent: 65, muted: false))
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .previewBrightness)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.presentLevelHUD(LevelHUDEvent(kind: .brightness, percent: 55, muted: false))
            }
            .store(in: &cancellables)
    }

    private func bindFocusMonitor() {
        focusMonitor.onEvent = { [weak self] isOn in
            DispatchQueue.main.async {
                self?.presentOverlay(.focusMode(isOn: isOn))
            }
        }
        focusMonitor.start()

        NotificationCenter.default.publisher(for: .previewFocusMode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let isOn = (note.userInfo?["isOn"] as? Bool) ?? true
                self?.presentOverlay(.focusMode(isOn: isOn))
            }
            .store(in: &cancellables)
    }

    private func bindLiveActivities() {
        guard IslandFeatures.screenRecordingEnabled else { return }
        recordingMonitor.onPhaseChange = { [weak self] phase in
            DispatchQueue.main.async {
                self?.setCapturePhase(phase)
            }
        }
        recordingMonitor.start()

        NotificationCenter.default.publisher(for: .previewScreenRecording)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recordingMonitor.setPreview(true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .previewRecordingChat)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let raw = note.userInfo?["provider"] as? String
                let provider = raw.flatMap(ChatProvider.init(rawValue:)) ?? .claude
                self?.presentRecordingChatPreview(provider: provider)
            }
            .store(in: &cancellables)
    }

    private func bindFTUEPreview() {
        NotificationCenter.default.publisher(for: .previewFTUEGlow)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.playFTUEGlowPreview()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .replayFTUEIntro)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.replayFTUEIntro()
            }
            .store(in: &cancellables)
    }

    private func bindShelfExpiry() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.expireShelfItemsIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        shelfExpireTimer = timer

        settings.$shelfEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self, !enabled else { return }
                if !self.shelfPreviewActive {
                    self.isDropTargeted = false
                    self.isDraggingShelfItem = false
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .previewShelfHold)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.presentShelfHoldPreview()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .previewShelfDrop)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.presentShelfDropPreview()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .previewShelfClear)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.clearShelfPreview()
            }
            .store(in: &cancellables)
    }

    private func expireShelfItemsIfNeeded() {
        guard settings.shelfEnabled, settings.shelfAutoExpireEnabled else { return }
        let ids = ShelfLogic.expiredIDs(
            in: shelfItems,
            now: Date(),
            interval: settings.shelfAutoExpireInterval
        )
        guard !ids.isEmpty else { return }
        for id in ids {
            shelfItems = ShelfLogic.removing(id: id, from: shelfItems)
        }
        if shelfItems.isEmpty, !isDropTargeted, !isOverlayActive {
            isExpanded = false
        }
    }

    private func setCapturePhase(_ phase: ScreenCapturePhase) {
        let selecting = phase == .selecting
        if isSelectingScreenToRecord != selecting {
            isSelectingScreenToRecord = selecting
            if selecting {
                isExpanded = false
            }
        }
        setScreenRecording(phase == .recording)
    }

    private func setScreenRecording(_ recording: Bool) {
        guard isScreenRecording != recording else { return }
        isScreenRecording = recording
        if recording {
            recordingStartedAt = Date()
            recordingElapsed = 0
            startRecordingTick()
        } else {
            recordingTick?.invalidate()
            recordingTick = nil
            recordingStartedAt = nil
            recordingElapsed = 0
            if isExpanded, transientOverlay == nil {
                isExpanded = false
            }
        }
    }

    private func startRecordingTick() {
        recordingTick?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let started = self.recordingStartedAt else { return }
            self.recordingElapsed = Date().timeIntervalSince(started)
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTick = timer
    }

    func stopScreenRecording() {
        NSLog("[ScreenRecording] island stop action invoked")
        recordingMonitor.stopSystemRecording()
        setScreenRecording(false)
    }

    private func presentLevelHUD(_ event: LevelHUDEvent) {
        switch event.kind {
        case .volume:
            presentOverlay(.volume(percent: event.percent, muted: event.muted))
        case .brightness:
            presentOverlay(.brightness(percent: event.percent))
        }
    }

    private func presentPowerEvent(_ event: PowerAlertState.Event) {
        switch event {
        case .chargingStarted(let percent):
            presentOverlay(.charging(percent: percent))
        case .lowBattery(let percent):
            presentOverlay(.lowBattery(percent: percent))
        }
    }

    private func presentOverlay(_ overlay: TransientOverlay) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.presentOverlay(overlay)
            }
            return
        }
        if overlay.replacesSystemHUD {
            SystemHUDSuppressor.shared.suppressNativeHUD()
        }
        if case .lowBattery = overlay {
            SystemHUDSuppressor.shared.suppressNativeLowBatteryAlert()
        }
        transientOverlay = overlay
        isExpanded = true
        NotificationCenter.default.post(name: .overlayActivated, object: nil)
        restartOverlayTimer()
    }

    private func bindChromeMonitor() {
        chromeMonitor.onResponseReady = { [weak self] snapshot in
            self?.presentChatReady(snapshot)
        }

        ChromePushBridge.shared.onReplyReady = { [weak self] snapshot, pageVisible, tabActive in
            guard let self else { return }
            // Deduplicate via tracker, then present.
            self.chromeMonitor.handlePushReply(
                snapshot,
                pageVisible: pageVisible,
                tabActive: tabActive
            )
        }

        NotificationCenter.default.publisher(for: .previewClaudeReady)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.presentChatReadyPreview(provider: .claude)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .previewChatReady)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let raw = note.userInfo?["provider"] as? String
                let provider = raw.flatMap(ChatProvider.init(rawValue:)) ?? .claude
                self?.presentChatReadyPreview(provider: provider)
            }
            .store(in: &cancellables)

        settings.$automationDenied
            .receive(on: DispatchQueue.main)
            .sink { [weak self] denied in
                self?.syncChromeMonitor(denied: denied)
            }
            .store(in: &cancellables)
    }

    private func syncChromeMonitor(denied: Bool) {
        if denied {
            chromeMonitor.stop()
            if transientOverlay?.isChat == true {
                clearTransientOverlay(collapseIfNeeded: false)
            }
        } else {
            chromeMonitor.start()
        }
    }

    func recheckChromeAutomation() {
        chromeMonitor.recheckPermissionsAndResume()
    }

    private func presentChatReadyPreview(provider: ChatProvider) {
        presentChatReady(
            ClaudeTabSnapshot(
                tab: ClaudeTabInfo(tabID: 0, windowIndex: 1, tabIndex: 1, provider: provider),
                isGenerating: false,
                preview: "Response ready",
                foundDOM: true,
                textLength: 0,
                assistantCount: 1
            )
        )
    }

    /// Settings preview: recording column on the left, chat reply on the right.
    private func presentRecordingChatPreview(provider: ChatProvider) {
        recordingMonitor.setPreview(true)
        setScreenRecording(true)
        presentChatReadyPreview(provider: provider)
    }

    private func presentChatReady(_ snapshot: ClaudeTabSnapshot) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.presentChatReady(snapshot)
            }
            return
        }
        let cleaned = ClaudeTabTracker.cleanedPreview(snapshot.preview)
        guard !ClaudeTabTracker.isProcessStage(cleaned) else {
            NSLog("[ChatTabs] skipped process-stage preview")
            return
        }
        guard cleaned.count >= 2 else {
            NSLog("[ChatTabs] skipped empty cleaned preview")
            return
        }
        NSLog("[ChatTabs] showing expanded overlay for %@", snapshot.tab.provider.rawValue)
        if shouldSuppressChatReopen(for: snapshot.tab.tabID) {
            chromeMonitor.acknowledge(
                tab: snapshot.tab,
                preview: cleaned,
                assistantCount: snapshot.assistantCount
            )
            return
        }
        noteIdleDestinationUsage(IslandIdleDestination.from(provider: snapshot.tab.provider))
        presentOverlay(.chatReady(preview: cleaned, tab: snapshot.tab))
    }

    private func shouldSuppressChatReopen(for tabID: Int) -> Bool {
        // Only the 2.5s Check Now grace window suppresses same-tab reopens.
        // `suppressHoverExpand` is a hover-to-player guard (see `expand()`);
        // it can stay `true` indefinitely if the cursor never re-enters the
        // island after activation, which was swallowing every follow-up
        // reply on the same chat tab.
        guard tabID == lastOpenedChatTabID else { return false }
        if let until = suppressExpandUntil, until > Date() {
            return true
        }
        return false
    }

    func clearTransientOverlay(collapseIfNeeded: Bool = true) {
        overlayTimeout?.invalidate()
        overlayTimeout = nil
        transientOverlay = nil
        NotificationCenter.default.post(name: .overlayCleared, object: nil)
        if collapseIfNeeded {
            // Always leave the notification fully — back to compact default,
            // even if the cursor is still over the island.
            overlayHovering = false
            isExpanded = false
        }
    }

    func noteOverlayHover(_ hovering: Bool) {
        overlayHovering = hovering
        if hovering {
            overlayTimeout?.invalidate()
        } else {
            releaseHoverExpandLockIfExpired()
            if isOverlayActive {
                restartOverlayTimer()
            }
        }
    }

    func releaseHoverExpandLockIfExpired() {
        if let until = suppressExpandUntil, until > Date() { return }
        suppressHoverExpand = false
    }

    /// Album-art side of a compressed overlay — expand the full player, keep music state.
    func revealExpandedPlayerFromOverlay() {
        clearTransientOverlay(collapseIfNeeded: false)
        expand()
    }

    func openChatTabFromOverlay() {
        guard case .chatReady(let preview, let tab) = transientOverlay else { return }

        // Lock collapse first so hover / Chrome focus races can't keep or reopen the island.
        suppressHoverExpand = true
        suppressExpandUntil = Date().addingTimeInterval(2.5)
        lastOpenedChatTabID = tab.tabID
        overlayHovering = false

        chromeMonitor.acknowledge(
            tab: tab,
            preview: preview,
            assistantCount: 99,
            replyFingerprint: ClaudeTabTracker.makeContentFingerprint(preview)
        )

        // Dismiss this notification immediately — only a *new* reply should reopen later.
        clearTransientOverlay(collapseIfNeeded: true)
        isExpanded = false

        // Navigate after UI dismiss so the island isn't left expanded under Chrome.
        let tabToOpen = tab
        DispatchQueue.main.async { [weak self] in
            self?.chromeMonitor.activate(tab: tabToOpen)
        }
    }

    func openBatterySettingsFromOverlay() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.settings.Battery",
            "x-apple.systempreferences:com.apple.preference.battery"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func restartOverlayTimer() {
        overlayTimeout?.invalidate()
        let duration: TimeInterval
        switch transientOverlay {
        case .charging:
            duration = IslandMetrics.chargingOverlayTimeout
        case .lowBattery:
            duration = IslandMetrics.lowBatteryOverlayTimeout
        case .volume, .brightness:
            duration = IslandMetrics.levelHUDTimeout
        case .focusMode:
            duration = IslandMetrics.chargingOverlayTimeout
        case .chatReady, .none:
            duration = IslandMetrics.overlayTimeout
        }
        overlayTimeout = Timer.scheduledTimer(
            withTimeInterval: duration,
            repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.clearTransientOverlay(collapseIfNeeded: true)
            }
        }
    }

    deinit {
        overlayTimeout?.invalidate()
        recordingTick?.invalidate()
        shelfExpireTimer?.invalidate()
        shelfDropPreviewTimer?.invalidate()
    }
}
