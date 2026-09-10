import AppKit
import Combine
import Foundation

/// Reads macOS system Now Playing (Spotify, Music, YouTube in browser, etc.).
///
/// Direct `MediaRemote` calls return nil on macOS 15.4+ for third-party apps
/// (entitlement check in `mediaremoted`). We use the standard workaround:
/// `/usr/bin/perl` (Apple-signed, entitled) loads our helper dylib. We keep
/// one `loop` process alive and send commands on its stdin — spawning `get`
/// every second was the hitch. Direct in-process MediaRemote is still blank
/// for third-party apps on macOS 15.4+.
///
/// Transport is routed by the active Now Playing bundle:
/// - Browsers (YouTube in Chrome, etc.): in-tab JavaScript only
/// - Native players (Music, Spotify, …): MediaRemote adapter only
/// Never mix media keys across clients — that woke the wrong app.
final class NowPlayingService: ObservableObject {
    struct Snapshot: Equatable {
        var title: String = ""
        var artist: String = ""
        var album: String = ""
        var appName: String = ""
        var bundleIdentifier: String = ""
        var isPlaying: Bool = false
        var elapsed: TimeInterval = 0
        var duration: TimeInterval = 0
        var artwork: NSImage? = nil
        var hasMedia: Bool = false
        var sourceURL: String = ""
        var sourcePageTitle: String = ""
        var sourceTab: BrowserMediaNavigator.Tab? = nil
        var artworkToken: String = ""

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.title == rhs.title
                && lhs.artist == rhs.artist
                && lhs.album == rhs.album
                && lhs.appName == rhs.appName
                && lhs.bundleIdentifier == rhs.bundleIdentifier
                && lhs.isPlaying == rhs.isPlaying
                && abs(lhs.elapsed - rhs.elapsed) < 0.35
                && abs(lhs.duration - rhs.duration) < 0.35
                && lhs.hasMedia == rhs.hasMedia
                && lhs.sourceURL == rhs.sourceURL
                && lhs.sourcePageTitle == rhs.sourcePageTitle
                && lhs.sourceTab == rhs.sourceTab
                && lhs.artworkToken == rhs.artworkToken
                && (lhs.artwork == nil) == (rhs.artwork == nil)
        }
    }

    @Published private(set) var snapshot = Snapshot()

    /// Second concurrent browser session (e.g. YouTube Music while the primary
    /// snapshot holds a YouTube video). Additive: primary `snapshot` is never
    /// altered by the secondary reader. Empty `Snapshot()` when only one
    /// source is playing — the split UI hides in that case.
    @Published private(set) var secondarySnapshot = Snapshot()

    // Secondary reader — kept parallel to primary state so nothing here can
    // mutate MediaRemote arbitration (`preferSpotifyUntil`, `htmlPlaybackOverride`, …).
    private var secondaryScanInFlight = false
    private var lastSecondaryScanAt: TimeInterval = 0
    /// Bumped when secondary is cleared/promoted so an in-flight probe cannot
    /// rewrite `secondarySnapshot` after the dual layout has already collapsed.
    private var secondaryScanGeneration = 0
    /// Cached poster/art for the secondary tile so we don't refetch every tick.
    private var secondaryArtworkURL: String = ""
    private var secondaryArtwork: NSImage?
    private var secondaryPosterID: String = ""
    private var secondaryPosterImage: NSImage?
    private var lastSecondaryElapsedWallTime: TimeInterval?
    /// Wall-clock until which a missed secondary hunt must not wipe dual art.
    private var secondaryHoldUntil: TimeInterval = 0
    /// mediaQueue-visible copy of the live secondary session. `@Published`
    /// `secondarySnapshot` is applied on main, so a racing empty hunt must not
    /// read a stale empty value and clear dual art.
    private var secondaryLatch: Snapshot = Snapshot()
    private var lastPrimaryDualPlayingRecheckAt: TimeInterval = 0
    /// After promoting Watch over paused Music (or the reverse), ignore MediaRemote
    /// updates for the paused opposite format so the island does not snap back to
    /// Music metadata without art while Watch keeps playing.
    private var ignoreOppositePausedUntil: TimeInterval = 0
    private var ignoreOppositePausedIsMusic: Bool = false
    /// Demote just parked Watch as secondary because Music is incoming. Force
    /// the next primary main publish to flush dual even when the Music URL/title
    /// hint is not bound yet — otherwise one Music-only YouTube logo frame shows
    /// before overlapping art.
    private var pendingDualMusicPrimaryAfterDemote = false

    private static let mediaQueueKey = DispatchSpecificKey<UInt8>()
    private let mediaQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "island.mediaremote", qos: .userInitiated)
        queue.setSpecific(key: NowPlayingService.mediaQueueKey, value: 1)
        return queue
    }()
    private var lastArtworkKey: String = ""
    private var lastArtwork: NSImage?

    /// Last known Now Playing client on `mediaQueue` (authoritative for controls).
    private var activeBundleID: String = ""
    private var activeIsPlaying: Bool = false
    private var activeDuration: TimeInterval = 0
    private var activeElapsed: TimeInterval = 0
    private var activeTitle: String = ""
    private var activeArtist: String = ""
    private var activeAppName: String = ""
    /// Last YouTube tab we last paused/seeked so Play resumes that session, not another tab.
    private var lastYouTubeControlURL: String = ""
    /// Watch-tab title last bound while YouTube (not Music) was Now Playing.
    /// MediaRemote often keeps reporting that video after Music starts.
    private var lastBoundWatchTitle: String = ""
    /// Last browser tab URL that matched this Now Playing session (any platform).
    private var lastMediaSourceURL: String = ""
    private var lastMediaSourcePageTitle: String = ""
    private var lastMediaSourceTab: BrowserMediaNavigator.Tab?
    private var lastListedIdentity: String = ""
    private var lastBrowserScanAt: TimeInterval = 0
    private var lastYouTubePosterID: String = ""
    private var lastYouTubePosterImage: NSImage?
    private var lastYouTubeMusicArtURL: String = ""
    private var lastYouTubeMusicArtImage: NSImage?
    /// After skip/autoplay, MediaRemote title updates before Chrome's href.
    /// Keep rescanning the same tab until `v=` is no longer this ID.
    private var staleYouTubeVideoIDAwaitingRefresh: String = ""
    /// In-tab HTML5 pause/play. Chrome MediaRemote often never sends pause for
    /// browser video, so the simulated waveform kept running.
    private var htmlPlaybackOverride: Bool?
    private var lastHTMLPlaybackProbeAt: TimeInterval = 0
    private var ignoreHTMLProbeUntil: TimeInterval = 0
    private var htmlProbeInFlight = false
    private let probeGate = NSLock()
    private var sourceResolveDepth = 0
    /// MediaRemote keeps the closed tab's title; ignore it until a live tab binds.
    private var staleClosedBrowserSessionKey: String = ""
    private var transportGeneration = 0
    private let transportLock = NSLock()
    private var lastSpotifyProbeAt: TimeInterval = 0
    private var preferSpotifyUntil: TimeInterval = 0
    private var lastSpotifyPlayAt: TimeInterval = 0
    private var lastBrowserPlayAt: TimeInterval = 0
    private var lastChromeFallbackAt: TimeInterval = 0
    private var chromeFallbackInFlight = false
    private var spotifyProbeWasPlaying = false
    private let spotifyProbeQueue = DispatchQueue(label: "island.spotify-probe")
    private static let htmlPlaybackProbeInterval: TimeInterval = 0.35
    private static let spotifyBundleID = "com.spotify.client"

    private var listenerProcess: Process?
    private var listenerStdin: Pipe?
    private var listenerBuffer = Data()
    private var elapsedTicker: DispatchSourceTimer?
    private var lastElapsedWallTime: TimeInterval?
    private var lastEndedAdvanceAt: TimeInterval = 0
    private var listenerRestartScheduled = false
    private var revealInFlight = false
    private let posterQueue = DispatchQueue(label: "island.youtube-poster")
    private var posterFetchGeneration = 0
    /// True while the machine is asleep; pauses elapsed ticking and probes.
    private var macIsAsleep = false
    /// Brief grace period after wake: ignore empty MediaRemote until adapter recovers.
    private var wakeGraceUntil: TimeInterval = 0
    private var sleepWakeObservers: [NSObjectProtocol] = []

    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private struct AdapterEnvelope: Decodable {
        let payload: AdapterPayload?
    }

    private struct AdapterPayload: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let isPlaying: Bool?
        let playbackRate: Double?
        let durationMicros: Double?
        let elapsedTimeMicros: Double?
        let timestampEpochMicros: Double?
        let applicationName: String?
        let bundleIdentifier: String?
        let artworkDataBase64: String?
        let artworkMimeType: String?

        enum CodingKeys: String, CodingKey {
            case title, artist, album, isPlaying, playbackRate
            case durationMicros, elapsedTimeMicros, timestampEpochMicros
            case applicationName, bundleIdentifier
            case artworkDataBase64, artworkMimeType
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            artist = try c.decodeIfPresent(String.self, forKey: .artist)
            album = try c.decodeIfPresent(String.self, forKey: .album)
            playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate)
            durationMicros = try c.decodeIfPresent(Double.self, forKey: .durationMicros)
            elapsedTimeMicros = try c.decodeIfPresent(Double.self, forKey: .elapsedTimeMicros)
            timestampEpochMicros = try c.decodeIfPresent(Double.self, forKey: .timestampEpochMicros)
            applicationName = try c.decodeIfPresent(String.self, forKey: .applicationName)
            bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
            artworkDataBase64 = try c.decodeIfPresent(String.self, forKey: .artworkDataBase64)
            artworkMimeType = try c.decodeIfPresent(String.self, forKey: .artworkMimeType)

            if let b = try? c.decode(Bool.self, forKey: .isPlaying) {
                isPlaying = b
            } else if let i = try? c.decode(Int.self, forKey: .isPlaying) {
                isPlaying = i != 0
            } else {
                isPlaying = nil
            }
        }

        init(
            title: String,
            artist: String,
            album: String,
            isPlaying: Bool,
            durationMicros: Double,
            elapsedTimeMicros: Double,
            applicationName: String,
            bundleIdentifier: String
        ) {
            self.title = title
            self.artist = artist
            self.album = album
            self.isPlaying = isPlaying
            playbackRate = isPlaying ? 1 : 0
            self.durationMicros = durationMicros
            self.elapsedTimeMicros = elapsedTimeMicros
            timestampEpochMicros = Date().timeIntervalSince1970 * 1_000_000
            self.applicationName = applicationName
            self.bundleIdentifier = bundleIdentifier
            artworkDataBase64 = nil
            artworkMimeType = nil
        }
    }

    init() {
        _ = Self.ignoreSIGPIPE
        startElapsedTicker()
        mediaQueue.async { [weak self] in
            self?.startAdapterListener()
        }
        observeSleepWake()
    }

    deinit {
        elapsedTicker?.cancel()
        stopAdapterListener()
        for observer in sleepWakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Sleep / Wake lifecycle

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepHandler: (Notification) -> Void = { [weak self] _ in
            self?.handleSystemSleep()
        }
        let wakeHandler: (Notification) -> Void = { [weak self] _ in
            self?.handleSystemWake()
        }
        sleepWakeObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil, using: sleepHandler),
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil, using: sleepHandler),
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil, using: wakeHandler),
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil, using: wakeHandler),
        ]
    }

    private func handleSystemSleep() {
        mediaQueue.async { [weak self] in
            guard let self else { return }
            self.macIsAsleep = true
            // Freeze the wall-clock baseline so elapsed doesn't jump on wake.
            self.lastElapsedWallTime = nil
            NSLog("[NowPlaying] system sleep — paused elapsed ticker, adapter stays alive")
        }
    }

    private func handleSystemWake() {
        mediaQueue.async { [weak self] in
            guard let self else { return }
            self.macIsAsleep = false
            // Reset wall-clock so the first post-wake tick doesn't jump elapsed.
            self.lastElapsedWallTime = Date().timeIntervalSince1970
            // Grace period: ignore empty adapter lines for 3s while mediaremoted recovers.
            self.wakeGraceUntil = Date().timeIntervalSince1970 + 3.0
            // Force-restart the adapter to ensure fresh MediaRemote subscription.
            self.stopAdapterListener()
            self.startAdapterListener()
            // Send a `get` command to immediately fetch current Now Playing state.
            self.mediaQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.runAdapterCommand("get")
            }
            // Reset Chrome fallback cooldown so YouTube probe runs immediately.
            self.lastChromeFallbackAt = 0
            self.lastBrowserScanAt = 0
            self.lastSpotifyProbeAt = 0
            NSLog("[NowPlaying] system wake — adapter restarted, probes reset")
        }
    }

    /// Bring the Now Playing app — or the matching browser tab — to the front.
    /// Runs immediately on click: never wait behind MediaRemote / tab scans.
    func revealSource() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.revealSource() }
            return
        }
        let snap = snapshot
        NSLog(
            "[NowPlaying] revealSource requested bundle=%@ title=%@ url=%@ tab=%d",
            snap.bundleIdentifier,
            snap.title,
            snap.sourceURL,
            snap.sourceTab?.tabID ?? 0
        )
        guard snap.hasMedia, !snap.bundleIdentifier.isEmpty else { return }
        // Raising Chrome first keeps whichever window was already front.
        // Select the Now Playing tab, then bring that window forward.
        if !MediaClient.isBrowserBundle(snap.bundleIdentifier) {
            BrowserMediaNavigator.activateApplication(bundleID: snap.bundleIdentifier)
            return
        }
        guard !revealInFlight else { return }
        revealInFlight = true
        let bundleID = snap.bundleIdentifier
        let tab = snap.sourceTab
        let url = snap.sourceURL
        AppleScriptRunLoop.media.async { [weak self] in
            var switched = false
            // Fast path: activate the cached Now Playing tab immediately.
            // listTabs was doubling Chrome AppleScript cost (1–6s+) and almost
            // always resolved to the same tab ID we already had.
            if let tab {
                switched = BrowserMediaNavigator.activateTab(tab, bundleID: bundleID)
            }
            if !switched, let tab {
                let tabs = BrowserMediaNavigator.listTabs(bundleID: bundleID)
                let live = BrowserMediaNavigator.resolveLiveTab(tab, from: tabs) ?? tab
                if live.tabID != tab.tabID || live.url != tab.url {
                    switched = BrowserMediaNavigator.activateTab(live, bundleID: bundleID)
                }
            }
            if !switched, !url.isEmpty {
                let fallback = BrowserMediaNavigator.Tab(
                    windowIndex: 1,
                    tabIndex: 1,
                    tabID: 0,
                    title: "",
                    url: url
                )
                switched = BrowserMediaNavigator.activateTab(fallback, bundleID: bundleID)
            }
            if !switched, let page = URL(string: url), !url.isEmpty {
                DispatchQueue.main.async { NSWorkspace.shared.open(page) }
            }
            DispatchQueue.main.async { self?.revealInFlight = false }
        }
    }

    @discardableResult
    private func noteUserTransport() -> Int {
        transportLock.lock()
        transportGeneration += 1
        ignoreHTMLProbeUntil = Date().timeIntervalSince1970 + 1.6
        let generation = transportGeneration
        transportLock.unlock()
        return generation
    }

    private func currentTransportGeneration() -> Int {
        transportLock.lock()
        defer { transportLock.unlock() }
        return transportGeneration
    }

    private func isIgnoringHTMLProbe(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        transportLock.lock()
        defer { transportLock.unlock() }
        return now < ignoreHTMLProbeUntil
    }

    func togglePlayPause() {
        let snap = snapshot
        let wasPlaying = snap.isPlaying
        let tab = snap.sourceTab
        let bundleID = snap.bundleIdentifier
        let target = Self.controlTarget(
            bundleID: bundleID,
            appName: snap.appName,
            artist: snap.artist,
            title: snap.title,
            url: snap.sourceURL
        )
        NSLog(
            "[NowPlaying] togglePlayPause target=%@ playing=%@ bundle=%@",
            target.logName,
            wasPlaying ? "YES" : "NO",
            bundleID
        )
        let generation = noteUserTransport()
        // Pause of the primary tile while a second tab is still playing should
        // hand the single-tile island to that still-playing session (YT Music)
        // instead of sitting on the paused video. Play (wasPlaying == false)
        // never promotes — dual can come back when both tabs play again.
        let promoteSecondary = wasPlaying
            && IslandFeatures.dualNowPlayingEnabled
            && (
                (secondarySnapshot.hasMedia && secondarySnapshot.isPlaying)
                    || (secondaryLatch.hasMedia && secondaryLatch.isPlaying)
            )
        let secondaryToPromote: Snapshot? = {
            guard promoteSecondary else { return nil }
            if secondarySnapshot.hasMedia, secondarySnapshot.isPlaying {
                return secondarySnapshot
            }
            return secondaryLatch
        }()
        mediaQueue.async { [weak self] in
            if let secondaryToPromote, secondaryToPromote.hasMedia {
                self?.promoteSecondaryAfterPrimaryPause(secondaryToPromote)
            } else {
                self?.publishOptimisticPlaying(!wasPlaying)
            }
            if target == .nativeMediaRemote {
                self?.runAdapterCommand(wasPlaying ? "pause" : "play")
            }
        }
        guard target != .nativeMediaRemote else { return }
        AppleScriptRunLoop.media.async { [weak self] in
            guard let self, generation == self.currentTransportGeneration() else { return }
            self.applyBrowserPlayPause(
                shouldPause: wasPlaying,
                target: target,
                tab: tab,
                bundleID: bundleID
            )
        }
    }

    /// Seek the current track/video to `seconds` (clamped to duration when known).
    func seek(to seconds: TimeInterval) {
        let snap = snapshot
        let tab = snap.sourceTab
        let bundleID = snap.bundleIdentifier
        let duration = snap.duration > 0 ? snap.duration : activeDuration
        let targetTime: TimeInterval
        if duration > 0 {
            targetTime = min(max(0, seconds), max(duration - 0.25, 0))
        } else {
            targetTime = max(0, seconds)
        }
        let target = Self.controlTarget(
            bundleID: bundleID,
            appName: snap.appName,
            artist: snap.artist,
            title: snap.title,
            url: snap.sourceURL
        )
        NSLog(
            "[NowPlaying] seek to %.2fs target=%@ bundle=%@",
            targetTime,
            target.logName,
            bundleID
        )
        let generation = noteUserTransport()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = self.snapshot
            next.elapsed = targetTime
            self.snapshot = next
        }
        mediaQueue.async { [weak self] in
            self?.activeElapsed = targetTime
            self?.lastElapsedWallTime = Date().timeIntervalSince1970
        }
        if target == .nativeMediaRemote {
            mediaQueue.async { [weak self] in
                self?.runAdapterCommand("set_time", arguments: [String(targetTime)])
            }
            return
        }
        AppleScriptRunLoop.media.async { [weak self] in
            guard let self, generation == self.currentTransportGeneration() else { return }
            switch target {
            case .youtubeBrowser:
                let js = self.trySilentYouTubeSeek(to: targetTime, tab: tab, bundleID: bundleID)
                switch js {
                case .ok:
                    break
                case .needsPermission:
                    if self.ensureChromeJavaScriptFromAppleEventsEnabled() {
                        _ = self.trySilentYouTubeSeek(to: targetTime, tab: tab, bundleID: bundleID)
                    }
                case .failed:
                    self.mediaQueue.async {
                        self.runAdapterCommand("set_time", arguments: [String(targetTime)])
                    }
                }
            case .browserMedia:
                let ok = self.trySilentBrowserSeek(to: targetTime)
                if !ok {
                    self.mediaQueue.async {
                        self.runAdapterCommand("set_time", arguments: [String(targetTime)])
                    }
                }
            case .nativeMediaRemote:
                break
            }
        }
    }

    func skipForward() {
        dispatchSkip(next: true)
    }

    func skipBackward() {
        dispatchSkip(next: false)
    }

    func nextTrack() { skipForward() }
    func previousTrack() { skipBackward() }

    private func dispatchSkip(next: Bool) {
        let snap = snapshot
        let tab = snap.sourceTab
        let bundleID = snap.bundleIdentifier
        let target = Self.controlTarget(
            bundleID: bundleID,
            appName: snap.appName,
            artist: snap.artist,
            title: snap.title,
            url: snap.sourceURL
        )
        NSLog(
            "[NowPlaying] %@ target=%@ bundle=%@",
            next ? "next" : "previous",
            target.logName,
            bundleID
        )
        let generation = noteUserTransport()
        if target == .nativeMediaRemote {
            mediaQueue.async { [weak self] in
                self?.runAdapterCommand(next ? "next_track" : "previous_track")
            }
            return
        }
        AppleScriptRunLoop.media.async { [weak self] in
            guard let self, generation == self.currentTransportGeneration() else { return }
            self.applyBrowserSkip(
                next: next,
                target: target,
                tab: tab,
                bundleID: bundleID
            )
        }
    }

    func refresh() {
        mediaQueue.async { [weak self] in
            guard let self else { return }
            self.stopAdapterListener()
            self.startAdapterListener()
        }
    }

    /// Who should receive transport commands for the *currently displayed* client.
    private enum ControlTarget {
        case youtubeBrowser
        case browserMedia
        case nativeMediaRemote

        var logName: String {
            switch self {
            case .youtubeBrowser: return "youtube"
            case .browserMedia: return "browser-media"
            case .nativeMediaRemote: return "native"
            }
        }
    }

    private var controlTarget: ControlTarget {
        Self.controlTarget(
            bundleID: activeBundleID,
            appName: activeAppName,
            artist: activeArtist,
            title: activeTitle,
            url: lastMediaSourceURL
        )
    }

    private static func controlTarget(
        bundleID: String,
        appName: String,
        artist: String,
        title: String,
        url: String
    ) -> ControlTarget {
        guard MediaClient.isBrowserBundle(bundleID) else { return .nativeMediaRemote }
        let platform = StreamingPlatform.resolve(
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title,
            url: url
        )
        return BrowserMediaControlPolicy.usesYouTubeSpecificControls(
            bundleID: bundleID,
            platform: platform
        )
            ? .youtubeBrowser
            : .browserMedia
    }

    /// True only when the active Now Playing app is a known browser.
    /// Never default unknown/empty to browser — that made Apple Music
    /// controls drive a paused YouTube tab.
    private func isBrowserBundle(_ bundleID: String) -> Bool {
        MediaClient.isBrowserBundle(bundleID)
    }

    private func adapterPaths() -> (script: String, dylib: String)? {
        let bundle = Bundle.main
        guard
            let script = bundle.path(forResource: "run", ofType: "pl"),
            let dylib = bundle.path(forResource: "libMediaRemoteAdapter", ofType: "dylib")
        else {
            NSLog("[NowPlaying] adapter resources missing (run.pl / libMediaRemoteAdapter.dylib)")
            return nil
        }
        return (script, dylib)
    }

    /// One long-lived `perl … loop` process. Direct in-process MediaRemote is
    /// blank for third-party apps on macOS 15.4+; perl is Apple-signed.
    private func startAdapterListener() {
        if let existing = listenerProcess, existing.isRunning { return }
        guard let paths = adapterPaths() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.dylib, "loop"]

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        listenerStdin = stdin
        listenerBuffer.removeAll(keepingCapacity: true)

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.mediaQueue.async {
                self?.consumeListenerData(chunk)
            }
        }
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        process.terminationHandler = { [weak self] _ in
            self?.mediaQueue.async {
                self?.listenerProcess = nil
                self?.listenerStdin = nil
                self?.scheduleListenerRestart()
            }
        }

        do {
            try process.run()
            listenerProcess = process
        } catch {
            NSLog("[NowPlaying] failed to launch adapter loop: %@", error.localizedDescription)
            listenerStdin = nil
        }
    }

    private func stopAdapterListener() {
        listenerProcess?.terminationHandler = nil
        (listenerProcess?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        listenerProcess?.terminate()
        listenerProcess = nil
        listenerStdin = nil
        listenerBuffer.removeAll()
    }

    private func scheduleListenerRestart() {
        guard !listenerRestartScheduled else { return }
        listenerRestartScheduled = true
        mediaQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.listenerRestartScheduled = false
            self.startAdapterListener()
        }
    }

    private func consumeListenerData(_ chunk: Data) {
        if chunk.isEmpty {
            return
        }
        listenerBuffer.append(chunk)
        let newline = Data([0x0A])
        while let range = listenerBuffer.range(of: newline) {
            let line = listenerBuffer.subdata(in: listenerBuffer.startIndex..<range.lowerBound)
            listenerBuffer.removeSubrange(..<range.upperBound)
            handleAdapterLine(line)
        }
    }

    private func handleAdapterLine(_ data: Data) {
        let trimmed = data.trimmingASCIIWhitespace
        if trimmed.isEmpty { return }
        if trimmed == Data("null".utf8) || trimmed == Data("NIL".utf8) {
            // Track changes briefly send null. Clearing here emptied the
            // island (placeholder flash) and dropped the last client before
            // Spotify / the next song could arrive.
            // Also skip during wake grace period: mediaremoted needs time to
            // re-attach its Now Playing subscription.
            return
        }

        do {
            let envelope = try JSONDecoder().decode(AdapterEnvelope.self, from: trimmed)
            guard let payload = envelope.payload, let title = payload.title, !title.isEmpty else {
                return
            }
            apply(payload: payload, title: title)
        } catch {
            if let payload = try? JSONDecoder().decode(AdapterPayload.self, from: trimmed),
               let title = payload.title, !title.isEmpty {
                apply(payload: payload, title: title)
                return
            }
        }
    }

    private func clearNowPlaying() {
        clearActiveClient()
        lastElapsedWallTime = nil
        DispatchQueue.main.async {
            self.lastArtworkKey = ""
            self.lastArtwork = nil
            self.snapshot = Snapshot()
        }
    }

    private func startElapsedTicker() {
        let timer = DispatchSource.makeTimerSource(queue: mediaQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.tickElapsed()
        }
        timer.resume()
        elapsedTicker = timer
    }

    private func tickElapsed() {
        guard !macIsAsleep else {
            lastElapsedWallTime = nil
            return
        }
        probeNativeSpotifyIfNeeded()
        probeBrowserYouTubeIfMediaRemoteMissing()
        probeBrowserPlaybackIfNeeded()
        probeSecondaryPlaybackIfNeeded()
        advanceSecondaryElapsedIfNeeded()
        if activeDuration > 5, activeElapsed >= activeDuration - 0.75 {
            advanceEndedBrowserMediaIfNeeded()
        }
        guard activeIsPlaying, activeDuration > 0 else {
            lastElapsedWallTime = Date().timeIntervalSince1970
            return
        }
        let now = Date().timeIntervalSince1970
        let previous = lastElapsedWallTime ?? now
        lastElapsedWallTime = now
        // Clamp delta to 1s so sleep/wake never jumps elapsed to track end.
        let rawDelta = max(0, now - previous)
        let delta = min(rawDelta, 1.0)
        let nextElapsed = min(activeDuration, activeElapsed + delta)
        if activeDuration > 1, nextElapsed >= activeDuration - 0.6 {
            advanceEndedBrowserMediaIfNeeded()
        }
        guard abs(nextElapsed - activeElapsed) >= 0.2 else { return }
        activeElapsed = nextElapsed
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.snapshot
            guard snap.hasMedia, snap.isPlaying else { return }
            snap.elapsed = nextElapsed
            self.snapshot = snap
        }
    }

    private func advanceEndedBrowserMediaIfNeeded() {
        let now = Date().timeIntervalSince1970
        if now - lastEndedAdvanceAt < 1.25 { return }
        let target = Self.controlTarget(
            bundleID: activeBundleID,
            appName: activeAppName,
            artist: activeArtist,
            title: activeTitle,
            url: lastMediaSourceURL
        )
        guard target != .nativeMediaRemote else { return }
        lastEndedAdvanceAt = now
        let tab = lastMediaSourceTab
        let bundleID = activeBundleID
        AppleScriptRunLoop.media.async { [weak self] in
            _ = self?.runSilentBrowserMediaJavaScript(
                musicJS: BrowserMediaNavigator.youtubeMusicEndedAutoplayJavaScript,
                watchJS: BrowserMediaNavigator.youtubeWatchEndedAutoplayJavaScript,
                tab: tab,
                bundleID: bundleID
            )
        }
    }

    private func clearActiveClient() {
        activeBundleID = ""
        activeIsPlaying = false
        activeDuration = 0
        activeElapsed = 0
        activeTitle = ""
        activeArtist = ""
        activeAppName = ""
        lastYouTubeControlURL = ""
        lastBoundWatchTitle = ""
        lastMediaSourceURL = ""
        lastMediaSourcePageTitle = ""
        lastMediaSourceTab = nil
        lastListedIdentity = ""
        lastBrowserScanAt = 0
        lastYouTubePosterID = ""
        lastYouTubePosterImage = nil
        lastYouTubeMusicArtURL = ""
        lastYouTubeMusicArtImage = nil
        htmlPlaybackOverride = nil
        lastHTMLPlaybackProbeAt = 0
        preferSpotifyUntil = 0
        lastSpotifyProbeAt = 0
        lastBoundWatchTitle = ""
    }

    private func browserSessionKey(bundleID: String, title: String) -> String {
        "\(bundleID)|\(title)"
    }

    private func clearIslandBecauseSourceTabClosed() {
        let key = browserSessionKey(bundleID: activeBundleID, title: activeTitle)
        staleClosedBrowserSessionKey = key
        clearNowPlaying()
    }

    /// Chrome MediaRemote keeps broadcasting a still-playing youtube.com/watch
    /// tab after the user started YouTube Music. Stay on Music until it pauses.
    private func shouldIgnoreStaleYouTubeWatchNowPlaying(title: String, bundleID: String) -> Bool {
        guard isBrowserBundle(bundleID) else { return false }
        guard lastMediaSourceURL.contains("music.youtube.com") else { return false }
        guard htmlPlaybackOverride != false else { return false }
        guard !lastBoundWatchTitle.isEmpty else { return false }
        return YouTubeTabPicker.titlesMatch(title, lastBoundWatchTitle)
    }

    /// After dual collapse promotes Watch over paused Music (or the reverse),
    /// MediaRemote keeps advertising the paused session and would put its
    /// title/artist back on the island without artwork.
    private func shouldIgnoreOppositePausedAfterDualPromote(
        title: String,
        artist: String,
        bundleID: String,
        appName: String,
        remotePlaying: Bool
    ) -> Bool {
        guard IslandFeatures.dualNowPlayingEnabled else { return false }
        guard Date().timeIntervalSince1970 < ignoreOppositePausedUntil else { return false }
        guard !remotePlaying else {
            // A real play of the opposite format ends the suppress window.
            ignoreOppositePausedUntil = 0
            return false
        }
        guard isBrowserBundle(bundleID) else { return false }
        let hint = StreamingPlatform.titleHint(
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title
        )
        let incomingMusic = hint == .youtubeMusic
            || title.localizedCaseInsensitiveContains("youtube music")
        let incomingWatch = hint == .youtube && !incomingMusic
        if ignoreOppositePausedIsMusic {
            return incomingMusic
        }
        return incomingWatch
    }

    /// MediaRemote only reports one session. When primary flips Watch↔Music,
    /// immediately park the outgoing snapshot as secondary so compact dual art
    /// appears in the same tick — do not wait for the AppleScript secondary probe.
    private func demoteOutgoingPrimaryToSecondaryIfNeeded(
        incomingTitle: String,
        incomingArtist: String,
        incomingAppName: String,
        incomingBundleID: String,
        incomingIsPlaying: Bool,
        incomingLooksLikeAlbumArt: Bool = false
    ) {
        guard isBrowserBundle(incomingBundleID), isBrowserBundle(activeBundleID) else {
            return
        }
        let outgoingURL = snapshot.sourceURL.isEmpty ? lastMediaSourceURL : snapshot.sourceURL
        let outgoingPlatform = StreamingPlatform.from(url: outgoingURL)
            ?? StreamingPlatform.resolve(
                bundleID: activeBundleID,
                appName: activeAppName,
                artist: activeArtist,
                title: activeTitle,
                url: outgoingURL
            )
        let incomingPlatform = StreamingPlatform.resolve(
            bundleID: incomingBundleID,
            appName: incomingAppName,
            artist: incomingArtist,
            title: incomingTitle,
            url: ""
        ) ?? StreamingPlatform.titleHint(
            bundleID: incomingBundleID,
            appName: incomingAppName,
            artist: incomingArtist,
            title: incomingTitle
        )
        let titlesMatchOutgoing = YouTubeTabPicker.titlesMatch(incomingTitle, activeTitle)
            || YouTubeTabPicker.titlesMatch(incomingTitle, snapshot.title)
            || (!lastBoundWatchTitle.isEmpty
                && YouTubeTabPicker.titlesMatch(incomingTitle, lastBoundWatchTitle)
                && outgoingPlatform == .youtube)
        let inferred = DualNowPlayingSurfacePolicy.inferredIncomingYouTubeFormat(
            outgoingIsYouTubeWatch: outgoingPlatform == .youtube,
            outgoingIsYouTubeMusic: outgoingPlatform == .youtubeMusic,
            incomingResolvedIsWatch: incomingPlatform == .youtube,
            incomingResolvedIsMusic: incomingPlatform == .youtubeMusic,
            titlesMatchOutgoing: titlesMatchOutgoing,
            incomingIsPlaying: incomingIsPlaying,
            incomingLooksLikeAlbumArt: incomingLooksLikeAlbumArt
        )
        let shouldDemote = DualNowPlayingSurfacePolicy.shouldDemoteOutgoingToSecondary(
            featureEnabled: IslandFeatures.dualNowPlayingEnabled,
            outgoingHasMedia: snapshot.hasMedia || !activeTitle.isEmpty,
            outgoingIsPlaying: activeIsPlaying || snapshot.isPlaying,
            outgoingIsYouTubeWatch: outgoingPlatform == .youtube,
            outgoingIsYouTubeMusic: outgoingPlatform == .youtubeMusic,
            incomingIsPlaying: incomingIsPlaying,
            incomingIsYouTubeWatch: inferred.isWatch,
            incomingIsYouTubeMusic: inferred.isMusic
        )
        guard shouldDemote else { return }

        // Already showing this session as secondary — keep it.
        if secondarySnapshot.hasMedia,
           secondarySnapshot.isPlaying,
           !secondarySnapshot.sourceURL.isEmpty,
           YouTubeTabPicker.urlsMatch(secondarySnapshot.sourceURL, outgoingURL)
            || YouTubeTabPicker.titlesMatch(secondarySnapshot.title, snapshot.title) {
            lastSecondaryScanAt = 0
            return
        }

        var demoted = snapshot
        if demoted.title.isEmpty { demoted.title = activeTitle }
        if demoted.artist.isEmpty { demoted.artist = activeArtist }
        if demoted.sourceURL.isEmpty { demoted.sourceURL = outgoingURL }
        if demoted.sourceTab == nil { demoted.sourceTab = lastMediaSourceTab }
        if demoted.sourcePageTitle.isEmpty {
            demoted.sourcePageTitle = lastMediaSourcePageTitle
        }
        if demoted.bundleIdentifier.isEmpty { demoted.bundleIdentifier = activeBundleID }
        demoted.isPlaying = true
        demoted.hasMedia = true
        if demoted.artwork == nil {
            demoted.artwork = lastArtwork ?? lastYouTubePosterImage ?? lastYouTubeMusicArtImage
            if demoted.artwork != nil, demoted.artworkToken.isEmpty {
                demoted.artworkToken = "held:demoted"
            }
        }
        if demoted.artwork == nil,
           let platform = outgoingPlatform,
           let logo = StreamingPlatformArtwork.image(for: platform) {
            demoted.artwork = logo
            demoted.artworkToken = "platform:\(platform.rawValue)"
        }
        if outgoingPlatform == .youtube, !demoted.title.isEmpty {
            lastBoundWatchTitle = demoted.title
        }
        lastSecondaryScanAt = 0
        secondaryTransportGraceUntil = 0
        secondaryHoldUntil = Date().timeIntervalSince1970
            + DualNowPlayingSurfacePolicy.secondaryHoldDuration()
        secondaryLatch = demoted
        if inferred.isMusic {
            pendingDualMusicPrimaryAfterDemote = true
        }
        // Latch only on mediaQueue — Watch secondary is published on main in the
        // same turn as Music primary (secondary first) so compact dual never
        // flashes a lone YouTube logo.
        requestImmediateSecondaryHunt()
    }

    /// Bypass the scan throttle and hunt now. Safe from `mediaQueue` only.
    /// Does not wait on primary source-resolve — that gate was delaying dual
    /// art until Music finished binding.
    private func requestImmediateSecondaryHunt() {
        guard IslandFeatures.dualNowPlayingEnabled else { return }
        lastSecondaryScanAt = 0
        probeSecondaryPlaybackIfNeeded()
    }

    /// While resolving the primary tab we already paid for `listTabs`. Use that
    /// list to find the opposite playing Watch/Music tab in the same AppleScript
    /// turn and publish secondary immediately.
    private func seedSecondaryFromListedTabs(
        _ tabs: [BrowserMediaNavigator.Tab],
        primary: BrowserMediaNavigator.Tab,
        bundleID: String
    ) {
        guard IslandFeatures.dualNowPlayingEnabled else { return }
        let preferMusicSecondary = !primary.url.contains("music.youtube.com")
        let candidates = tabs.filter { tab in
            if primary.tabID != 0, tab.tabID == primary.tabID { return false }
            if YouTubeTabPicker.urlsMatch(tab.url, primary.url) { return false }
            let platform = StreamingPlatform.from(url: tab.url)
            guard platform == .youtube || platform == .youtubeMusic else { return false }
            return BrowserMediaNavigator.isLikelyPlaybackURL(tab.url, platform: platform)
        }
        let ordered = candidates.sorted { a, b in
            let aMusic = a.url.contains("music.youtube.com")
            let bMusic = b.url.contains("music.youtube.com")
            if aMusic == bMusic { return false }
            return preferMusicSecondary ? aMusic && !bMusic : !aMusic && bMusic
        }
        for tab in ordered.prefix(6) {
            guard let details = probeSecondaryTabDetails(tab: tab, bundleID: bundleID),
                  details.isPlaying else { continue }
            mediaQueue.async { [weak self] in
                self?.applySecondaryDetails(
                    details,
                    tab: tab,
                    bundleID: bundleID,
                    dualPrimaryURL: primary.url
                )
            }
            return
        }
    }

    private func apply(payload: AdapterPayload, title: String) {
        let rate = payload.playbackRate ?? 0
        let remotePlaying = PlaybackPlayingPolicy.isPlaying(
            reported: payload.isPlaying,
            playbackRate: payload.playbackRate
        )

        let artist = payload.artist ?? ""
        let album = payload.album ?? ""
        let appName = payload.applicationName ?? ""
        let bundleID = payload.bundleIdentifier ?? ""
        let sessionKey = browserSessionKey(bundleID: bundleID, title: title)
        if isBrowserBundle(bundleID),
           !staleClosedBrowserSessionKey.isEmpty,
           staleClosedBrowserSessionKey == sessionKey,
           lastMediaSourceTab == nil {
            return
        }
        if !staleClosedBrowserSessionKey.isEmpty, staleClosedBrowserSessionKey != sessionKey {
            staleClosedBrowserSessionKey = ""
        }
        if Date().timeIntervalSince1970 < preferSpotifyUntil,
           isBrowserBundle(bundleID),
           bundleID != Self.spotifyBundleID {
            if remotePlaying {
                preferSpotifyUntil = 0
            } else {
                return
            }
        }
        if shouldIgnoreStaleYouTubeWatchNowPlaying(title: title, bundleID: bundleID) {
            return
        }
        if shouldIgnoreOppositePausedAfterDualPromote(
            title: title,
            artist: artist,
            bundleID: bundleID,
            appName: appName,
            remotePlaying: remotePlaying
        ) {
            return
        }

        let artKey = payload.artworkDataBase64.map { String($0.prefix(64)) + "|\($0.count)" } ?? ""
        var artwork = lastArtwork
        if artKey != lastArtworkKey {
            if let b64 = payload.artworkDataBase64, let data = Data(base64Encoded: b64) {
                artwork = NSImage(data: data)
                lastArtwork = artwork
                lastArtworkKey = artKey
            } else if artKey.isEmpty {
                artwork = lastArtwork
            }
        }
        let remotePixels = MediaClient.pixelSize(of: artwork)
        let incomingLooksLikeAlbumArt = MediaArtworkPolicy.isLikelyAlbumArtwork(
            pixelWidth: remotePixels.width,
            pixelHeight: remotePixels.height
        )

        let remotePlayingForDual = remotePlaying
        let incomingIsPlayingGuess = PlaybackPlayingPolicy.resolvedPlaying(
            remote: remotePlayingForDual,
            htmlOverride: nil
        )
        demoteOutgoingPrimaryToSecondaryIfNeeded(
            incomingTitle: title,
            incomingArtist: artist,
            incomingAppName: appName,
            incomingBundleID: bundleID,
            incomingIsPlaying: incomingIsPlayingGuess,
            incomingLooksLikeAlbumArt: incomingLooksLikeAlbumArt
        )

        if title != activeTitle || bundleID != activeBundleID || !isBrowserBundle(bundleID) {
            htmlPlaybackOverride = nil
        }
        let isPlaying = PlaybackPlayingPolicy.resolvedPlaying(
            remote: remotePlaying,
            htmlOverride: htmlPlaybackOverride
        )

        let duration = (payload.durationMicros ?? 0) / 1_000_000
        var elapsed = (payload.elapsedTimeMicros ?? 0) / 1_000_000
        if isPlaying, let stamp = payload.timestampEpochMicros {
            let stampSec = stamp / 1_000_000
            let now = Date().timeIntervalSince1970
            elapsed += max(0, (now - stampSec) * max(rate, 1))
        }

        if !isBrowserBundle(bundleID) {
            htmlPlaybackOverride = nil
            clearBrowserSource()
        }

        let primaryWasPlaying = activeIsPlaying || snapshot.isPlaying
        let previousBundleID = activeBundleID
        activeBundleID = bundleID
        activeIsPlaying = isPlaying
        activeDuration = max(0, duration)
        activeElapsed = max(0, elapsed)
        activeTitle = title
        activeArtist = artist
        activeAppName = appName
        lastElapsedWallTime = Date().timeIntervalSince1970

        // MediaRemote often drops Music to paused while Watch secondary is still
        // live. Reassert false pauses; if primary really stopped, promote the
        // still-playing opposite secondary so the island never sits on paused
        // Music metadata while Watch keeps playing.
        if IslandFeatures.dualNowPlayingEnabled,
           !isPlaying,
           primaryWasPlaying {
            reassertPrimaryPlayingForDualIfNeeded()
            schedulePromoteSecondaryIfPrimaryHTMLStopped()
        }

        let identity = "\(bundleID)|\(title)|\(artist)"
        let identityChanged = identity != lastListedIdentity
        let now = Date().timeIntervalSince1970
        let incomingHint = StreamingPlatform.titleHint(
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title
        )
        let cachedStillMatches = YouTubeTabPicker.tabMatchesNowPlaying(
            tabTitle: lastMediaSourceTab?.title ?? lastMediaSourcePageTitle,
            nowPlayingTitle: title,
            nowPlayingArtist: artist,
            tabURL: lastMediaSourceURL,
            nowPlayingHint: incomingHint
        )
        let platformChanged = !StreamingPlatform.sourceURLCompatible(
            lastMediaSourceURL,
            withTitleHint: incomingHint
        )
        if identityChanged {
            lastListedIdentity = identity
            let keepBoundPlaybackTab = isBrowserBundle(bundleID)
                && lastMediaSourceTab != nil
                && !lastMediaSourceURL.isEmpty
                && StreamingPlatform.sourceURLCompatible(
                    lastMediaSourceURL,
                    withTitleHint: incomingHint
                )
                && (StreamingPlatform.from(url: lastMediaSourceURL).map {
                    BrowserMediaNavigator.isLikelyPlaybackURL(lastMediaSourceURL, platform: $0)
                } ?? false)
            if (bundleID != previousBundleID || platformChanged), !keepBoundPlaybackTab {
                clearBrowserSource()
            } else if keepBoundPlaybackTab {
                staleYouTubeVideoIDAwaitingRefresh = ""
            } else if isBrowserBundle(bundleID) {
                let previousID = YouTubeTabPicker.youtubeVideoID(from: lastMediaSourceURL)
                    ?? lastYouTubePosterID
                if !previousID.isEmpty {
                    staleYouTubeVideoIDAwaitingRefresh = previousID
                }
                lastMediaSourceURL = ""
                lastMediaSourcePageTitle = ""
                lastYouTubeControlURL = ""
                lastYouTubePosterID = ""
                lastYouTubePosterImage = nil
                lastYouTubeMusicArtURL = ""
                lastYouTubeMusicArtImage = nil
                if let cached = lastMediaSourceTab {
                    let compatible = StreamingPlatform.sourceURLCompatible(
                        cached.url,
                        withTitleHint: incomingHint
                    )
                    let playback = StreamingPlatform.from(url: cached.url).map {
                        BrowserMediaNavigator.isLikelyPlaybackURL(cached.url, platform: $0)
                    } ?? false
                    if !compatible || !playback {
                        lastMediaSourceTab = nil
                    }
                }
            } else if !cachedStillMatches {
                lastMediaSourceURL = ""
                lastMediaSourcePageTitle = ""
                lastYouTubeControlURL = ""
                if let cached = lastMediaSourceTab,
                   !YouTubeTabPicker.cachedFamilyTabCanServeNowPlaying(
                    tabTitle: cached.title,
                    tabURL: cached.url,
                    nowPlayingTitle: title
                   ) {
                    lastMediaSourceTab = nil
                }
            }
        }
        let currentPlatform = StreamingPlatform.resolve(
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title,
            url: lastMediaSourceURL
        )
        let needsOTTContentTitle = StreamingPlatform.needsContentTitleRefresh(
            mediaTitle: title,
            pageTitle: lastMediaSourcePageTitle,
            metadataTitle: album,
            platform: currentPlatform
        )
        let awaitingYouTubeURLRefresh = isBrowserBundle(bundleID)
            && !staleYouTubeVideoIDAwaitingRefresh.isEmpty
        let needsRescanForNewIdentity = identityChanged && (
            lastMediaSourceURL.isEmpty
                || !cachedStillMatches
                || platformChanged
                || bundleID != previousBundleID
                || awaitingYouTubeURLRefresh
        )
        let shouldScanBrowser = isBrowserBundle(bundleID)
            && (
                needsRescanForNewIdentity
                    || (
                        awaitingYouTubeURLRefresh
                            && now - lastBrowserScanAt >= 0.35
                    )
                    || (
                        !identityChanged
                            && !awaitingYouTubeURLRefresh
                            && (lastMediaSourceURL.isEmpty || needsOTTContentTitle)
                            && now - lastBrowserScanAt >= 2
                    )
            )
        if shouldScanBrowser, !isSourceResolveInFlight() {
            lastBrowserScanAt = now
            let remote = artwork
            let key = artKey
            let cachedTab = lastMediaSourceTab
                ?? (snapshot.bundleIdentifier == bundleID ? snapshot.sourceTab : nil)
            let reusableCachedTab: BrowserMediaNavigator.Tab?
            if let cached = cachedTab {
                let familyOK = YouTubeTabPicker.cachedFamilyTabCanServeNowPlaying(
                    tabTitle: cached.title,
                    tabURL: cached.url,
                    nowPlayingTitle: title
                )
                let playbackRefresh = awaitingYouTubeURLRefresh
                    && StreamingPlatform.sourceURLCompatible(
                        cached.url,
                        withTitleHint: incomingHint
                    )
                    && (StreamingPlatform.from(url: cached.url).map {
                        BrowserMediaNavigator.isLikelyPlaybackURL(cached.url, platform: $0)
                    } ?? false)
                reusableCachedTab = (familyOK || playbackRefresh) ? cached : nil
            } else {
                reusableCachedTab = nil
            }
            beginSourceResolve()
            // Tab listing and poster downloads must not sit on mediaQueue —
            // play/pause/skip wait there and stall for seconds. Keep this off
            // the chat AppleScript thread too — listTabs contends with polling.
            AppleScriptRunLoop.media.async { [weak self] in
                defer { self?.endSourceResolve() }
                self?.resolveBrowserSourceIfNeeded(
                    title: title,
                    artist: artist,
                    bundleID: bundleID,
                    appName: appName,
                    remoteArtwork: remote,
                    artKey: key,
                    cachedTab: reusableCachedTab
                )
            }
        }

        let artworkURL = lastMediaSourceURL.isEmpty ? lastYouTubeControlURL : lastMediaSourceURL
        var prepared = preparedArtwork(
            remote: artwork,
            artKey: artKey,
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title,
            url: artworkURL
        )
        let policyToken = prepared.token
        let sameYouTubeVideo = YouTubeTabPicker.videoIDsMatch(
            snapshot.sourceURL.isEmpty ? lastMediaSourceURL : snapshot.sourceURL,
            artworkURL.isEmpty ? snapshot.sourceURL : artworkURL
        )
        let dropHeldArtwork = MediaArtworkPolicy.shouldDropHeldYouTubeArtwork(
            identityChanged: identityChanged,
            sameYouTubeVideo: sameYouTubeVideo,
            previousTitle: snapshot.title,
            nextTitle: title
        )
        if prepared.image == nil,
           !dropHeldArtwork,
           snapshot.bundleIdentifier == bundleID,
           let held = snapshot.artwork,
           MediaArtworkPolicy.shouldHoldArtworkWhilePosterLoads(
            previousToken: snapshot.artworkToken,
            policyToken: policyToken,
            identityChanged: dropHeldArtwork
           ) {
            prepared = (held, snapshot.artworkToken)
        } else if !dropHeldArtwork,
                  snapshot.bundleIdentifier == bundleID,
                  MediaArtworkPolicy.shouldKeepResolvedYouTubeArtwork(snapshot.artworkToken),
                  !MediaArtworkPolicy.shouldKeepResolvedYouTubeArtwork(prepared.token),
                  (sameYouTubeVideo
                    || (!identityChanged && YouTubeTabPicker.titlesMatch(snapshot.title, title))) {
            prepared = (snapshot.artwork, snapshot.artworkToken)
        }
        // Dropping a watch poster under a stale youtube.com binding must not
        // fall through to Chrome's 16:9 MediaRemote JPEG for the old tab.
        // When Watch was just demoted for incoming Music, never flash the plain
        // YouTube logo alone — use Music logo (dual back tile) or keep pending.
        if dropHeldArtwork,
           StreamingPlatform.from(url: artworkURL) == .youtube,
           !MediaArtworkPolicy.shouldKeepResolvedYouTubeArtwork(prepared.token) {
            let latchWatch = StreamingPlatform.from(url: secondaryLatch.sourceURL) == .youtube
                && secondaryLatch.hasMedia
                && secondaryLatch.isPlaying
            if pendingDualMusicPrimaryAfterDemote || latchWatch {
                if let logo = StreamingPlatformArtwork.image(for: .youtubeMusic) {
                    prepared = (logo, "platform:youtubeMusic")
                } else {
                    prepared = (nil, "pending:youtubeMusic")
                }
            } else if let logo = StreamingPlatformArtwork.image(for: .youtube) {
                prepared = (logo, "platform:youtube")
            } else {
                prepared = (nil, "pending:youtube")
            }
        }
        if prepared.image == nil, let held = artwork,
           MediaArtworkPolicy.allowsRemoteArtworkFallback(
            isBrowser: isBrowserBundle(bundleID),
            policyToken: prepared.token.hasPrefix("pending:") ? prepared.token : policyToken
           ) {
            prepared = (held, artKey.isEmpty ? "remote:held" : "remote:\(artKey)")
        }
        prepared = islandDisplayArtwork(prepared)

        let next = Snapshot(
            title: title,
            artist: artist.isEmpty ? "—" : artist,
            album: album,
            appName: appName,
            bundleIdentifier: bundleID,
            isPlaying: isPlaying,
            elapsed: max(0, elapsed),
            duration: max(0, duration),
            artwork: prepared.image,
            hasMedia: true,
            sourceURL: artworkURL.isEmpty
                ? (lastYouTubeControlURL.isEmpty && snapshot.bundleIdentifier == bundleID
                    ? snapshot.sourceURL
                    : lastYouTubeControlURL)
                : artworkURL,
            sourcePageTitle: lastMediaSourcePageTitle.isEmpty && snapshot.bundleIdentifier == bundleID
                ? snapshot.sourcePageTitle
                : lastMediaSourcePageTitle,
            sourceTab: lastMediaSourceTab
                ?? (snapshot.bundleIdentifier == bundleID ? snapshot.sourceTab : nil),
            artworkToken: prepared.token
        )
        let latchForMain = secondaryLatch
        let forceMusicPrimaryDual = pendingDualMusicPrimaryAfterDemote
            && latchForMain.hasMedia
            && latchForMain.isPlaying
        if forceMusicPrimaryDual {
            pendingDualMusicPrimaryAfterDemote = false
        }
        DispatchQueue.main.async {
            var merged = next
            if merged.sourceTab == nil,
               self.snapshot.bundleIdentifier == next.bundleIdentifier {
                merged.sourceTab = self.snapshot.sourceTab
                if merged.sourceURL.isEmpty {
                    merged.sourceURL = self.snapshot.sourceURL
                }
                if merged.sourcePageTitle.isEmpty {
                    merged.sourcePageTitle = self.snapshot.sourcePageTitle
                }
            }
            if merged.artwork == nil,
               !merged.artworkToken.hasPrefix("pending:"),
               MediaArtworkPolicy.shouldKeepResolvedYouTubeArtwork(self.snapshot.artworkToken),
               YouTubeTabPicker.snapshotCanAcceptYouTubePoster(
                snapshotTitle: self.snapshot.title,
                snapshotURL: self.snapshot.sourceURL,
                snapshotBundle: self.snapshot.bundleIdentifier,
                requestedTitle: merged.title,
                requestedURL: merged.sourceURL,
                requestedBundle: merged.bundleIdentifier
               ) {
                merged.artwork = self.snapshot.artwork
                merged.artworkToken = self.snapshot.artworkToken
            }
            // Pausing Music while Watch secondary is live must not leave Music
            // title/artist on the island (often without art). Promote owns UI.
            let hint = StreamingPlatform.titleHint(
                bundleID: merged.bundleIdentifier,
                appName: merged.appName,
                artist: merged.artist,
                title: merged.title
            )
            let treatAsMusicPrimary = hint == .youtubeMusic
                || primaryIsMusic
                || forceMusicPrimaryDual
                || merged.artworkToken == "platform:youtubeMusic"
            if !merged.isPlaying,
               latch.hasMedia,
               latch.isPlaying,
               DualNowPlayingSurfacePolicy.primaryAllowsOppositeSecondaryPublish(
                primaryURL: merged.sourceURL,
                primaryTitleHintIsMusic: treatAsMusicPrimary,
                primaryTitleHintIsWatch: hint == .youtube && !treatAsMusicPrimary,
                secondaryIsYouTubeWatch: latchPlat == .youtube,
                secondaryIsYouTubeMusic: latchPlat == .youtubeMusic
               ) {
                return
            }
            let canFlushDual = DualNowPlayingSurfacePolicy.primaryAllowsOppositeSecondaryPublish(
                primaryURL: merged.sourceURL,
                primaryTitleHintIsMusic: treatAsMusicPrimary,
                primaryTitleHintIsWatch: hint == .youtube && !treatAsMusicPrimary,
                secondaryIsYouTubeWatch: latchPlat == .youtube,
                secondaryIsYouTubeMusic: latchPlat == .youtubeMusic
            ) && latch.hasMedia && latch.isPlaying
            // Secondary BEFORE primary so Combine applies secondaryHasMedia first
            // and compact dual turns on in the same turn — no lone logo frame.
            if canFlushDual {
                if !self.secondarySnapshot.hasMedia
                    || self.secondarySnapshot.sourceURL != latch.sourceURL
                    || self.secondarySnapshot.isPlaying != latch.isPlaying {
                    self.secondarySnapshot = latch
                }
            }
            self.snapshot = merged
            if !canFlushDual {
                self.flushSecondaryLatchOntoMainIfNeeded(
                    primaryURL: merged.sourceURL,
                    primaryTitle: merged.title,
                    primaryArtist: merged.artist,
                    primaryAppName: merged.appName,
                    primaryBundleID: merged.bundleIdentifier
                )
            }
        }
    }

    /// Main-queue: publish a latched opposite secondary once primary is the
    /// other YouTube format (URL or title hint). Same tick as Music primary
    /// bind so compact dual never flashes Watch+Watch then Music-only.
    private func flushSecondaryLatchOntoMainIfNeeded(
        primaryURL: String,
        primaryTitle: String = "",
        primaryArtist: String = "",
        primaryAppName: String = "",
        primaryBundleID: String = ""
    ) {
        let latch = secondaryLatch
        guard latch.hasMedia, latch.isPlaying else { return }
        let title = primaryTitle.isEmpty ? activeTitle : primaryTitle
        let artist = primaryArtist.isEmpty ? activeArtist : primaryArtist
        let appName = primaryAppName.isEmpty ? activeAppName : primaryAppName
        let bundleID = primaryBundleID.isEmpty ? activeBundleID : primaryBundleID
        let hint = StreamingPlatform.titleHint(
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title
        )
        let latchPlat = StreamingPlatform.from(url: latch.sourceURL)
        guard DualNowPlayingSurfacePolicy.primaryAllowsOppositeSecondaryPublish(
            primaryURL: primaryURL,
            primaryTitleHintIsMusic: hint == .youtubeMusic,
            primaryTitleHintIsWatch: hint == .youtube,
            secondaryIsYouTubeWatch: latchPlat == .youtube,
            secondaryIsYouTubeMusic: latchPlat == .youtubeMusic
        ) else { return }
        if !secondarySnapshot.hasMedia || secondarySnapshot.sourceURL != latch.sourceURL {
            secondarySnapshot = latch
        }
    }

    private func preparedArtwork(
        remote: NSImage?,
        artKey: String,
        bundleID: String,
        appName: String,
        artist: String,
        title: String,
        url: String
    ) -> (image: NSImage?, token: String) {
        let platform = StreamingPlatform.resolve(
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title,
            url: url
        )
        let isBrowser = MediaClient.isBrowserBundle(bundleID)
        var resemblesBrowser = false
        if isBrowser, let remote {
            resemblesBrowser = artworkResemblesBrowserIcon(remote, bundleID: bundleID)
        }
        let pixels = MediaClient.pixelSize(of: remote)
        let longest = max(pixels.width, pixels.height)
        let useLogo = MediaArtworkPolicy.shouldUsePlatformLogo(
            hasArtwork: remote != nil,
            longestPixelSide: longest,
            resemblesBrowserIcon: resemblesBrowser,
            isBrowser: isBrowser,
            platform: platform
        )
        let youtubeFamily = platform == .youtube || platform == .youtubeMusic
        let likelyThumb = MediaArtworkPolicy.isLikelyVideoThumbnail(
            pixelWidth: pixels.width,
            pixelHeight: pixels.height
        )
        let showRemote = MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
            platform: platform,
            resemblesBrowserIcon: resemblesBrowser,
            isLikelyVideoThumbnail: likelyThumb,
            hasRemote: remote != nil,
            pixelWidth: pixels.width,
            pixelHeight: pixels.height,
            sourceURL: url
        )
        if isBrowser, platform == nil || youtubeFamily {
            if showRemote {
                return (remote, artKey.isEmpty ? "remote:none" : "remote:\(artKey)")
            }
            // Prefer the service logo over a blank music.note flash while the
            // poster loads — especially when Music just took primary and dual
            // secondary is still latching.
            if let platform,
               let officialLogo = StreamingPlatformArtwork.image(for: platform) {
                return (officialLogo, "platform:\(platform.rawValue)")
            }
            return (nil, youtubeFamily ? "pending:youtube" : "pending:browser")
        }
        if useLogo, let platform,
           let officialLogo = StreamingPlatformArtwork.image(for: platform) {
            return (officialLogo, "platform:\(platform.rawValue)")
        }
        return (remote, artKey.isEmpty ? "remote:none" : "remote:\(artKey)")
    }

    private func artworkResemblesBrowserIcon(_ image: NSImage, bundleID: String) -> Bool {
        let candidates = [bundleID, "com.google.Chrome", "com.apple.Safari"]
        for id in candidates {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                continue
            }
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            if MediaClient.resembles(image, icon, meanAbsDelta: 0.28) {
                return true
            }
        }
        return false
    }

    private func youtubePosterImage(videoID: String) -> NSImage? {
        let id = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if id == lastYouTubePosterID, let cached = lastYouTubePosterImage {
            return cached
        }
        let files = ["mqdefault.jpg", "hqdefault.jpg"]
        for file in files {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(file)") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 1.5)
            request.cachePolicy = .returnCacheDataElseLoad
            let sem = DispatchSemaphore(value: 0)
            var image: NSImage?
            URLSession.shared.dataTask(with: request) { data, _, _ in
                defer { sem.signal() }
                guard let data, let loaded = NSImage(data: data) else { return }
                let px = MediaClient.pixelSize(of: loaded)
                guard px.width >= 240, px.height >= 140 else { return }
                image = loaded
            }.resume()
            _ = sem.wait(timeout: .now() + 1.6)
            if let image {
                lastYouTubePosterID = id
                lastYouTubePosterImage = image
                return image
            }
        }
        return nil
    }

    private func imageFromRemoteArtworkURL(_ raw: String) -> NSImage? {
        let trimmed = MediaArtworkPolicy.upgradedYouTubeMusicArtworkURL(raw)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            return nil
        }
        let host = (url.host ?? "").lowercased()
        guard MediaArtworkPolicy.isAllowedYouTubeMusicArtworkDownloadHost(host) else {
            return nil
        }
        if trimmed == lastYouTubeMusicArtURL, let cached = lastYouTubeMusicArtImage {
            return cached
        }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.cachePolicy = .returnCacheDataElseLoad
        let sem = DispatchSemaphore(value: 0)
        var image: NSImage?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data, let loaded = NSImage(data: data) else { return }
            let px = MediaClient.pixelSize(of: loaded)
            guard MediaArtworkPolicy.shouldAcceptYouTubeMusicRemoteImage(
                pixelWidth: px.width,
                pixelHeight: px.height
            ) else { return }
            image = loaded
        }.resume()
        _ = sem.wait(timeout: .now() + 1.6)
        if let image {
            lastYouTubeMusicArtURL = trimmed
            lastYouTubeMusicArtImage = image
            return image
        }
        return nil
    }

    private func islandDisplayArtwork(
        _ prepared: (image: NSImage?, token: String)
    ) -> (image: NSImage?, token: String) {
        guard let image = prepared.image else { return prepared }
        guard MediaArtworkPolicy.isYouTubePosterToken(prepared.token) else { return prepared }
        return (MediaClient.filledSquareThumbnail(image), prepared.token)
    }

    @discardableResult
    private func applyYouTubePoster(
        from url: String,
        title: String,
        bundleID: String,
        appName: String,
        artist: String,
        tab: BrowserMediaNavigator.Tab,
        allowStaleDocumentTitle: Bool = false,
        allowURLIdentityRefresh: Bool = false
    ) -> Bool {
        let titleHint = StreamingPlatform.titleHint(
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title
        )
        if let titleHint, titleHint != .youtube, titleHint != .youtubeMusic {
            return false
        }
        let isMusic = url.contains("music.youtube.com")
        if !isMusic {
            if url.contains("youtube.com") || url.contains("youtu.be") {
                lastBoundWatchTitle = tab.title
            }
            guard allowURLIdentityRefresh
                || YouTubeTabPicker.chromeTabCanBindToNowPlaying(
                tabTitle: tab.title,
                tabURL: url,
                nowPlayingTitle: title,
                allowStaleDocumentTitle: allowStaleDocumentTitle
            ) else {
                return false
            }
        }
        let videoID = YouTubeTabPicker.youtubeVideoID(from: url)
        if !isMusic {
            lastBoundWatchTitle = title
            if let playing = BrowserMediaNavigator.probePlaybackPlaying(on: tab, bundleID: bundleID) {
                htmlPlaybackOverride = playing
                lastHTMLPlaybackProbeAt = Date().timeIntervalSince1970
                activeIsPlaying = playing
            }
        } else {
            htmlPlaybackOverride = true
        }
        let sourceURL: String
        if let id = videoID, url.contains("music.youtube.com") {
            sourceURL = "https://music.youtube.com/watch?v=\(id)"
        } else {
            sourceURL = url
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.snapshot
            guard YouTubeTabPicker.snapshotCanAcceptYouTubePoster(
                snapshotTitle: snap.title,
                snapshotURL: snap.sourceURL,
                snapshotBundle: snap.bundleIdentifier,
                requestedTitle: title,
                requestedURL: sourceURL,
                requestedBundle: bundleID
            ) else { return }
            let previousURL = snap.sourceURL
            snap.sourceURL = sourceURL
            snap.sourcePageTitle = tab.title
            snap.sourceTab = tab
            snap.isPlaying = self.activeIsPlaying
            if MediaArtworkPolicy.isYouTubePosterToken(snap.artworkToken),
               isMusic
                || !YouTubeTabPicker.videoIDsMatch(previousURL, sourceURL) {
                snap.artwork = nil
                snap.artworkToken = "pending:youtube"
            }
            self.snapshot = snap
        }
        requestYouTubePoster(
            videoID: videoID,
            url: url,
            title: title,
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            tab: tab,
            sourceURL: sourceURL
        )
        return true
    }

    private func requestYouTubePoster(
        videoID: String?,
        url: String,
        title: String,
        bundleID: String,
        appName: String,
        artist: String,
        tab: BrowserMediaNavigator.Tab,
        sourceURL: String,
        musicArtworkURL: String? = nil
    ) {
        posterFetchGeneration += 1
        let generation = posterFetchGeneration
        posterQueue.async { [weak self] in
            guard let self else { return }
            var id = videoID
            var poster: NSImage?
            var artKey = id.map { "ytimg:\($0)" } ?? ""
            if url.contains("music.youtube.com") {
                var barURL = (musicArtworkURL ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Probe even when `watch?v=` is already known — otherwise we
                // skip the player-bar cover and flash the 16:9 YouTube poster.
                if barURL.isEmpty {
                    let probe = BrowserMediaNavigator.probeYouTubeMusicPlayback(
                        on: tab,
                        bundleID: bundleID
                    )
                    if id == nil { id = probe?.videoID }
                    if barURL.isEmpty { barURL = probe?.artworkURL ?? "" }
                }
                if !barURL.isEmpty {
                    poster = self.imageFromRemoteArtworkURL(barURL)
                    if poster != nil {
                        artKey = "ytmimg:\(barURL.prefix(64))"
                    }
                }
                // Player-bar cover is preferred, but a track poster is better
                // than keeping the previous YouTube watch thumbnail.
                if poster == nil, let id {
                    poster = self.youtubePosterImage(videoID: id)
                    if poster != nil {
                        artKey = "ytimg:\(id)"
                    }
                }
            } else {
                poster = id.flatMap { self.youtubePosterImage(videoID: $0) }
            }
            guard let poster else { return }
            self.mediaQueue.async {
                guard generation == self.posterFetchGeneration else { return }
                let prepared = self.preparedArtwork(
                    remote: poster,
                    artKey: artKey.isEmpty ? "ytmimg:probed" : artKey,
                    bundleID: bundleID,
                    appName: appName,
                    artist: artist,
                    title: title,
                    url: sourceURL
                )
                guard prepared.image != nil else { return }
                let display = self.islandDisplayArtwork(prepared)
                DispatchQueue.main.async {
                    var snap = self.snapshot
                    guard YouTubeTabPicker.snapshotCanAcceptYouTubePoster(
                        snapshotTitle: snap.title,
                        snapshotURL: snap.sourceURL,
                        snapshotBundle: snap.bundleIdentifier,
                        requestedTitle: title,
                        requestedURL: sourceURL,
                        requestedBundle: bundleID
                    ) else { return }
                    snap.sourceURL = sourceURL
                    snap.sourcePageTitle = tab.title
                    snap.sourceTab = tab
                    snap.artwork = display.image
                    snap.artworkToken = display.token
                    snap.isPlaying = self.activeIsPlaying
                    self.snapshot = snap
                }
            }
        }
    }

    @discardableResult
    private func bindFastBrowserTab(
        _ candidate: BrowserMediaNavigator.Tab,
        title: String,
        artist: String,
        bundleID: String,
        appName: String,
        remoteArtwork: NSImage?,
        artKey: String,
        titleHint: StreamingPlatform?,
        allowStaleDocumentTitle: Bool = false
    ) -> Bool {
        guard StreamingPlatform.sourceURLCompatible(candidate.url, withTitleHint: titleHint) else {
            return false
        }
        let tabPlatform = StreamingPlatform.from(url: candidate.url)
        if tabPlatform == .youtube || tabPlatform == .youtubeMusic {
            let liveID = YouTubeTabPicker.youtubeVideoID(from: candidate.url)
            if let liveID,
               !staleYouTubeVideoIDAwaitingRefresh.isEmpty,
               liveID.caseInsensitiveCompare(staleYouTubeVideoIDAwaitingRefresh) == .orderedSame {
                return false
            }
            let staleOK = allowStaleDocumentTitle
                && tabPlatform == .youtube
                && YouTubeTabPicker.isGenericYouTubeDocumentTitle(candidate.title)
            let familyOK = YouTubeTabPicker.cachedFamilyTabCanServeNowPlaying(
                tabTitle: candidate.title,
                tabURL: candidate.url,
                nowPlayingTitle: title,
                allowStaleDocumentTitle: staleOK
            )
            let sameBoundTab: Bool = {
                guard let cached = lastMediaSourceTab else { return false }
                if cached.tabID != 0, candidate.tabID != 0 {
                    return cached.tabID == candidate.tabID
                }
                return cached.windowIndex == candidate.windowIndex
                    && cached.tabIndex == candidate.tabIndex
            }()
            let urlRefresh = sameBoundTab
                && !staleYouTubeVideoIDAwaitingRefresh.isEmpty
                && (tabPlatform.map {
                    BrowserMediaNavigator.isLikelyPlaybackURL(candidate.url, platform: $0)
                } ?? false)
            guard familyOK || urlRefresh else {
                return false
            }
            guard applyYouTubePoster(
                from: candidate.url,
                title: title,
                bundleID: bundleID,
                appName: appName,
                artist: artist,
                tab: candidate,
                allowStaleDocumentTitle: staleOK,
                allowURLIdentityRefresh: urlRefresh
            ) else {
                return false
            }
            lastMediaSourceURL = candidate.url.contains("music.youtube.com")
                ? (YouTubeTabPicker.youtubeVideoID(from: candidate.url).map {
                    "https://music.youtube.com/watch?v=\($0)"
                } ?? candidate.url)
                : candidate.url
            lastMediaSourcePageTitle = candidate.title
            lastMediaSourceTab = candidate
            lastYouTubeControlURL = candidate.url
            staleClosedBrowserSessionKey = ""
            if let boundID = YouTubeTabPicker.youtubeVideoID(from: lastMediaSourceURL),
               boundID.caseInsensitiveCompare(staleYouTubeVideoIDAwaitingRefresh) != .orderedSame {
                staleYouTubeVideoIDAwaitingRefresh = ""
            }
            rememberBrowserSourceOnMediaQueue(
                tab: candidate,
                url: lastMediaSourceURL,
                pageTitle: candidate.title,
                youtubeControlURL: candidate.url
            )
            return true
        }
        let titleHit = YouTubeTabPicker.titlesMatchSameTrack(candidate.title, title)
        let playback = tabPlatform.map {
            BrowserMediaNavigator.isLikelyPlaybackURL(candidate.url, platform: $0)
        } ?? false
        guard titleHit || playback else { return false }
        var pageTitle = candidate.title
        if StreamingPlatform.needsContentTitleRefresh(
            mediaTitle: title,
            pageTitle: pageTitle,
            platform: tabPlatform
        ),
           let scraped = BrowserMediaNavigator.playbackTitle(
            on: candidate,
            platform: tabPlatform,
            bundleID: bundleID
           ) {
            pageTitle = scraped
        }
        lastMediaSourceURL = candidate.url
        lastMediaSourcePageTitle = pageTitle
        lastMediaSourceTab = candidate
        lastYouTubeControlURL = ""
        staleClosedBrowserSessionKey = ""
        rememberBrowserSourceOnMediaQueue(
            tab: candidate,
            url: candidate.url,
            pageTitle: pageTitle,
            youtubeControlURL: ""
        )
        let prepared = preparedArtwork(
            remote: remoteArtwork,
            artKey: artKey,
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title,
            url: candidate.url
        )
        let display = islandDisplayArtwork(prepared)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.snapshot
            guard snap.title == title, snap.bundleIdentifier == bundleID else { return }
            snap.sourceURL = candidate.url
            snap.sourcePageTitle = pageTitle
            snap.sourceTab = candidate
            snap.artwork = display.image
            snap.artworkToken = display.token
            snap.isPlaying = self.activeIsPlaying
            self.snapshot = snap
        }
        return true
    }

    private func clearBrowserSource() {
        lastMediaSourceURL = ""
        lastMediaSourcePageTitle = ""
        lastMediaSourceTab = nil
        lastYouTubeControlURL = ""
        staleYouTubeVideoIDAwaitingRefresh = ""
    }

    private func rememberBrowserSourceOnMediaQueue(
        tab: BrowserMediaNavigator.Tab,
        url: String,
        pageTitle: String,
        youtubeControlURL: String
    ) {
        let apply = { [self] in
            lastMediaSourceTab = tab
            lastMediaSourceURL = url
            lastMediaSourcePageTitle = pageTitle
            lastYouTubeControlURL = youtubeControlURL
            staleClosedBrowserSessionKey = ""
        }
        if DispatchQueue.getSpecific(key: Self.mediaQueueKey) != nil {
            apply()
        } else {
            mediaQueue.sync(execute: apply)
        }
    }

    private func resolveBrowserSourceIfNeeded(
        title: String,
        artist: String,
        bundleID: String,
        appName: String,
        remoteArtwork: NSImage?,
        artKey: String,
        cachedTab: BrowserMediaNavigator.Tab?
    ) {
        // Whenever primary rebinds (Watch↔Music handoff), immediately hunt the
        // other live tab — do not wait for the next elapsed tick.
        defer {
            mediaQueue.async { [weak self] in
                self?.requestImmediateSecondaryHunt()
            }
        }
        let metadataHint = StreamingPlatform.titleHint(
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title
        )
        let titleHint = metadataHint
            ?? cachedTab.flatMap { StreamingPlatform.from(url: $0.url) }
            ?? StreamingPlatform.from(url: lastMediaSourceURL)
        let tryCached: () -> BrowserMediaNavigator.Tab? = {
            cachedTab.flatMap {
                BrowserMediaNavigator.tab(
                    bundleID: bundleID,
                    windowIndex: $0.windowIndex,
                    tabIndex: $0.tabIndex
                )
            }
        }
        let sameTab: (BrowserMediaNavigator.Tab) -> Bool = { candidate in
            guard let cachedTab else { return false }
            if cachedTab.tabID != 0, candidate.tabID != 0 {
                return cachedTab.tabID == candidate.tabID
            }
            return cachedTab.windowIndex == candidate.windowIndex
                && cachedTab.tabIndex == candidate.tabIndex
        }
        if let cached = tryCached(),
           bindFastBrowserTab(
            cached,
            title: title,
            artist: artist,
            bundleID: bundleID,
            appName: appName,
            remoteArtwork: remoteArtwork,
            artKey: artKey,
            titleHint: titleHint,
            allowStaleDocumentTitle: true
           ) {
            return
        }
        if let active = BrowserMediaNavigator.activeTab(bundleID: bundleID),
           BrowserMediaNavigator.canFastBindActiveTab(active, titleHint: titleHint) {
            if bindFastBrowserTab(
                active,
                title: title,
                artist: artist,
                bundleID: bundleID,
                appName: appName,
                remoteArtwork: remoteArtwork,
                artKey: artKey,
                titleHint: titleHint,
                allowStaleDocumentTitle: sameTab(active)
            ) {
                return
            }
        }
        let tabs = BrowserMediaNavigator.listTabs(bundleID: bundleID)
        let hinted = titleHint ?? StreamingPlatform.from(url: lastMediaSourceURL)
        guard let tab = BrowserMediaNavigator.pick(
            from: tabs,
            nowPlayingTitle: title,
            nowPlayingArtist: artist,
            preferredURL: lastMediaSourceURL,
            platform: hinted
        ) else {
            NSLog(
                "[BrowserMedia] no source match title=%@ artist=%@ hint=%@ tabs=%d",
                title,
                artist,
                hinted?.rawValue ?? "none",
                tabs.count
            )
            return
        }
        // Bind primary source URL before seeding dual secondary. Seeding used to
        // run first, so applySecondaryDetails saw an empty/unbound primary and
        // deferred the opposite Music/Watch latch (debug-6ca0b4: primaryWatch
        // false + seedMusic true → latchHas false → no compact dual).
        lastMediaSourceURL = tab.url
        lastMediaSourcePageTitle = tab.title
        lastMediaSourceTab = tab
        seedSecondaryFromListedTabs(tabs, primary: tab, bundleID: bundleID)

        let urlPlatform = StreamingPlatform.from(url: tab.url)
        let tabPlatform = urlPlatform ?? hinted
        let remotePixels = MediaClient.pixelSize(of: remoteArtwork)
        if urlPlatform == .youtubeMusic,
           MediaArtworkPolicy.remoteArtworkAlreadyMatchesBoundTab(
            tabPlatform: urlPlatform,
            pixelWidth: remotePixels.width,
            pixelHeight: remotePixels.height
           ) {
            lastMediaSourceURL = tab.url
            lastMediaSourcePageTitle = tab.title
            lastMediaSourceTab = tab
            lastYouTubeControlURL = tab.url
            staleClosedBrowserSessionKey = ""
            rememberBrowserSourceOnMediaQueue(
                tab: tab,
                url: tab.url,
                pageTitle: tab.title,
                youtubeControlURL: tab.url
            )
            let prepared = preparedArtwork(
                remote: remoteArtwork,
                artKey: artKey,
                bundleID: bundleID,
                appName: appName,
                artist: artist,
                title: title,
                url: tab.url
            )
            let display = islandDisplayArtwork(prepared)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var snap = self.snapshot
                guard snap.title == title, snap.bundleIdentifier == bundleID else { return }
                snap.sourceURL = tab.url
                snap.sourcePageTitle = tab.title
                snap.sourceTab = tab
                snap.artwork = display.image
                snap.artworkToken = display.token
                snap.isPlaying = self.activeIsPlaying
                self.snapshot = snap
                self.flushSecondaryLatchOntoMainIfNeeded(primaryURL: tab.url)
            }
            return
        }
        let sourcePageTitle = BrowserMediaNavigator.playbackTitle(
            on: tab,
            platform: tabPlatform,
            bundleID: bundleID
        ) ?? tab.title
        let pickedMusic = urlPlatform == .youtubeMusic
        let pickedTitle = YouTubeTabPicker.titlesMatchSameTrack(tab.title, title)
        if let liveID = YouTubeTabPicker.youtubeVideoID(from: tab.url),
           !staleYouTubeVideoIDAwaitingRefresh.isEmpty,
           liveID.caseInsensitiveCompare(staleYouTubeVideoIDAwaitingRefresh) == .orderedSame {
            return
        }
        if urlPlatform == .youtube, !pickedTitle,
           !YouTubeTabPicker.chromeTabCanBindToNowPlaying(
            tabTitle: tab.title,
            tabURL: tab.url,
            nowPlayingTitle: title
           ) {
            lastBoundWatchTitle = tab.title
            return
        }
        lastMediaSourceURL = tab.url
        lastMediaSourcePageTitle = sourcePageTitle
        lastMediaSourceTab = tab
        staleClosedBrowserSessionKey = ""
        if let boundID = YouTubeTabPicker.youtubeVideoID(from: tab.url),
           boundID.caseInsensitiveCompare(staleYouTubeVideoIDAwaitingRefresh) != .orderedSame {
            staleYouTubeVideoIDAwaitingRefresh = ""
        }
        rememberBrowserSourceOnMediaQueue(
            tab: tab,
            url: tab.url,
            pageTitle: sourcePageTitle,
            youtubeControlURL: tab.url.contains("youtube.com") || tab.url.contains("youtu.be")
                ? tab.url
                : ""
        )
        if !pickedMusic, StreamingPlatform.from(url: tab.url) == .youtube {
            lastBoundWatchTitle = title
        }
        if let playing = BrowserMediaNavigator.probePlaybackPlaying(on: tab, bundleID: bundleID) {
            htmlPlaybackOverride = playing
            lastHTMLPlaybackProbeAt = Date().timeIntervalSince1970
            activeIsPlaying = playing
        }
        NSLog(
            "[BrowserMedia] matched source platform=%@ title=%@ pageTitle=%@ url=%@ htmlPlaying=%@",
            StreamingPlatform.from(url: tab.url)?.rawValue ?? "unknown",
            title,
            sourcePageTitle,
            tab.url,
            htmlPlaybackOverride.map { $0 ? "YES" : "NO" } ?? "unknown"
        )
        if tab.url.contains("youtube.com") || tab.url.contains("youtu.be") {
            lastYouTubeControlURL = tab.url
        } else {
            lastYouTubeControlURL = ""
        }
        var remote = remoteArtwork
        var key = artKey
        var videoID = YouTubeTabPicker.youtubeVideoID(from: tab.url)
        var musicProbe: BrowserMediaNavigator.YouTubeMusicPlayback?
        if videoID == nil, tab.url.contains("music.youtube.com") {
            musicProbe = BrowserMediaNavigator.probeYouTubeMusicPlayback(
                on: tab,
                bundleID: bundleID
            )
            videoID = musicProbe?.videoID
        }
        if let videoID {
            lastMediaSourceURL = tab.url.contains("music.youtube.com")
                ? "https://music.youtube.com/watch?v=\(videoID)"
                : tab.url
            lastYouTubeControlURL = lastMediaSourceURL
            rememberBrowserSourceOnMediaQueue(
                tab: tab,
                url: lastMediaSourceURL,
                pageTitle: sourcePageTitle,
                youtubeControlURL: lastYouTubeControlURL
            )
        }
        let pixels = MediaClient.pixelSize(of: remote)
        let alreadyThumb = MediaArtworkPolicy.remoteArtworkAlreadyMatchesBoundTab(
            tabPlatform: StreamingPlatform.from(url: tab.url),
            pixelWidth: pixels.width,
            pixelHeight: pixels.height
        )
        if alreadyThumb {
            let prepared = preparedArtwork(
                remote: remote,
                artKey: key,
                bundleID: bundleID,
                appName: appName,
                artist: artist,
                title: title,
                url: tab.url
            )
            let display = islandDisplayArtwork(prepared)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var snap = self.snapshot
                guard snap.title == title, snap.bundleIdentifier == bundleID else { return }
                snap.sourceURL = tab.url
                snap.sourcePageTitle = sourcePageTitle
                snap.sourceTab = tab
                snap.artwork = display.image
                snap.artworkToken = display.token
                snap.isPlaying = self.activeIsPlaying
                self.snapshot = snap
                self.flushSecondaryLatchOntoMainIfNeeded(primaryURL: tab.url)
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.snapshot
            guard snap.title == title, snap.bundleIdentifier == bundleID else { return }
            let previousURL = snap.sourceURL
            snap.sourceURL = tab.url
            snap.sourcePageTitle = sourcePageTitle
            snap.sourceTab = tab
            snap.isPlaying = self.activeIsPlaying
            // Watch posters must not linger after binding Music (or another
            // video) while the new cover is still downloading.
            if MediaArtworkPolicy.isYouTubePosterToken(snap.artworkToken),
               StreamingPlatform.from(url: tab.url) == .youtubeMusic
                || !YouTubeTabPicker.videoIDsMatch(previousURL, tab.url) {
                snap.artwork = nil
                snap.artworkToken = "pending:youtube"
            }
            self.snapshot = snap
            self.flushSecondaryLatchOntoMainIfNeeded(primaryURL: tab.url)
        }
        if StreamingPlatform.from(url: tab.url) == .youtube
            || StreamingPlatform.from(url: tab.url) == .youtubeMusic {
            requestYouTubePoster(
                videoID: videoID,
                url: tab.url,
                title: title,
                bundleID: bundleID,
                appName: appName,
                artist: artist,
                tab: tab,
                sourceURL: lastMediaSourceURL.isEmpty ? tab.url : lastMediaSourceURL,
                musicArtworkURL: musicProbe?.artworkURL
            )
            return
        }
        let prepared = preparedArtwork(
            remote: remote,
            artKey: key,
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title,
            url: tab.url
        )
        let display = islandDisplayArtwork(prepared)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.snapshot
            guard snap.title == title, snap.bundleIdentifier == bundleID else { return }
            snap.sourceURL = tab.url
            snap.sourcePageTitle = sourcePageTitle
            snap.sourceTab = tab
            if !(MediaArtworkPolicy.isYouTubePosterToken(snap.artworkToken)
                    && !MediaArtworkPolicy.isYouTubePosterToken(display.token)) {
                snap.artwork = display.image
                snap.artworkToken = display.token
            }
            snap.isPlaying = self.activeIsPlaying
            self.snapshot = snap
            self.flushSecondaryLatchOntoMainIfNeeded(primaryURL: tab.url)
        }
    }

    @discardableResult
    private func runAdapterCommand(_ command: String, arguments: [String] = []) -> Bool {
        startAdapterListener()
        let line = ([command] + arguments).joined(separator: " ") + "\n"
        guard let data = line.data(using: .utf8) else { return false }
        if let handle = listenerStdin?.fileHandleForWriting,
           listenerProcess?.isRunning == true {
            do {
                try handle.write(contentsOf: data)
                return true
            } catch {
                NSLog("[NowPlaying] stdin write failed for %@: %@", command, error.localizedDescription)
            }
        }

        guard let paths = adapterPaths() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.dylib, command] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("[NowPlaying] send %@ failed: %@", command, error.localizedDescription)
            return false
        }
    }

    private func trySilentBrowserPlayPause(
        tab: BrowserMediaNavigator.Tab? = nil,
        bundleID: String? = nil
    ) -> Bool {
        return runJavaScriptOnCachedBrowserTab(
            BrowserMediaNavigator.playPauseJavaScript,
            tab: tab,
            bundleID: bundleID
        )
    }

    private func trySilentBrowserSeek(to seconds: TimeInterval) -> Bool {
        return runJavaScriptOnCachedBrowserTab(BrowserMediaNavigator.seekJavaScript(to: seconds))
    }

    private func runJavaScriptOnCachedBrowserTab(
        _ javascript: String,
        tab: BrowserMediaNavigator.Tab? = nil,
        bundleID: String? = nil
    ) -> Bool {
        let resolvedTab = tab ?? lastMediaSourceTab ?? snapshot.sourceTab
        let resolvedBundle = bundleID ?? activeBundleID
        guard let resolvedTab else { return false }
        switch BrowserMediaNavigator.executeJavaScript(
            javascript,
            on: resolvedTab,
            bundleID: resolvedBundle
        ) {
        case .success:
            return true
        case .needsPermission:
            // MediaRemote is immediate and does not require changing browser
            // settings or briefly activating the browser.
            NSLog("[NowPlaying] browser JS permission unavailable; using MediaRemote")
            return false
        case .failed, .missingTab:
            return false
        }
    }

    private func applyBrowserPlayPause(
        shouldPause: Bool,
        target: ControlTarget,
        tab: BrowserMediaNavigator.Tab?,
        bundleID: String
    ) {
        switch target {
        case .youtubeBrowser:
            var applied = false
            switch trySilentYouTubePlayPause(shouldPause: shouldPause, tab: tab, bundleID: bundleID) {
            case .ok:
                applied = true
            case .needsPermission:
                if ensureChromeJavaScriptFromAppleEventsEnabled() {
                    Thread.sleep(forTimeInterval: 0.25)
                    if case .ok = trySilentYouTubePlayPause(
                        shouldPause: shouldPause,
                        tab: tab,
                        bundleID: bundleID
                    ) {
                        applied = true
                    }
                }
            case .failed:
                if shouldPause {
                    NSLog("[NowPlaying] skip MediaRemote pause; YouTube tab JS missed")
                } else {
                    NSLog("[NowPlaying] skip MediaRemote play; no matching YouTube tab")
                }
            }
            if !applied {
                mediaQueue.async { self.publishOptimisticPlaying(shouldPause) }
            }
        case .browserMedia:
            if !trySilentBrowserPlayPause(tab: tab, bundleID: bundleID) {
                mediaQueue.async {
                    self.runAdapterCommand(shouldPause ? "pause" : "play")
                }
            }
        case .nativeMediaRemote:
            break
        }
    }

    private func applyBrowserSkip(
        next: Bool,
        target: ControlTarget,
        tab: BrowserMediaNavigator.Tab?,
        bundleID: String
    ) {
        switch target {
        case .youtubeBrowser:
            let result = trySilentYouTubeJavaScript(next: next, tab: tab, bundleID: bundleID)
            switch result {
            case .ok:
                return
            case .needsPermission:
                if ensureChromeJavaScriptFromAppleEventsEnabled() {
                    Thread.sleep(forTimeInterval: 0.25)
                    if case .ok = trySilentYouTubeJavaScript(
                        next: next,
                        tab: tab,
                        bundleID: bundleID
                    ) {
                        return
                    }
                }
                showChromeJavaScriptHintIfNeeded()
            case .failed:
                NSLog("[NowPlaying] YouTube next/prev JS missed; not using MediaRemote")
            }
        case .browserMedia:
            seekBrowserVideo(by: next ? 10 : -10)
        case .nativeMediaRemote:
            break
        }
    }

    private func seekBrowserVideo(by delta: TimeInterval) {
        let target: TimeInterval
        if activeDuration > 0 {
            target = min(max(0, activeElapsed + delta), max(activeDuration - 0.25, 0))
        } else {
            target = max(0, activeElapsed + delta)
        }
        if !trySilentBrowserSeek(to: target) {
            runAdapterCommand("set_time", arguments: [String(target)])
        }
        activeElapsed = target
        lastElapsedWallTime = Date().timeIntervalSince1970
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.snapshot
            snap.elapsed = target
            self.snapshot = snap
        }
    }

    private func publishOptimisticPlaying(_ playing: Bool) {
        activeIsPlaying = playing
        if isBrowserBundle(activeBundleID) {
            htmlPlaybackOverride = playing
            if playing {
                lastBrowserPlayAt = Date().timeIntervalSince1970
                preferSpotifyUntil = 0
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.snapshot
            snap.isPlaying = playing
            self.snapshot = snap
        }
    }

    /// MediaRemote reports NIL for Chrome YouTube on some macOS builds.
    /// If nothing is Now Playing, pick a live YouTube tab the same way
    /// Spotify is probed when Chrome holds a stale session.
    private func probeBrowserYouTubeIfMediaRemoteMissing() {
        guard !macIsAsleep else { return }
        guard activeTitle.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        guard now >= preferSpotifyUntil else { return }
        guard now - lastChromeFallbackAt >= 2.0 else { return }
        guard !chromeFallbackInFlight, !isSourceResolveInFlight() else { return }
        let bundleID = ChromeTabMonitor.chromeBundleID
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == bundleID
        }) else { return }
        lastChromeFallbackAt = now
        chromeFallbackInFlight = true
        AppleScriptRunLoop.media.async { [weak self] in
            defer {
                self?.mediaQueue.async { self?.chromeFallbackInFlight = false }
            }
            guard let self else { return }
            let tabs = BrowserMediaNavigator.listTabs(bundleID: bundleID)
            let candidates = tabs.filter { tab in
                let platform = StreamingPlatform.from(url: tab.url)
                guard platform == .youtube || platform == .youtubeMusic else { return false }
                return BrowserMediaNavigator.isLikelyPlaybackURL(tab.url, platform: platform)
            }
            for tab in candidates.prefix(8) {
                guard BrowserMediaNavigator.probePlaybackPlaying(on: tab, bundleID: bundleID) == true else {
                    continue
                }
                var title = YouTubeTabPicker.strippingChromeNotificationBadge(tab.title)
                if title.isEmpty || YouTubeTabPicker.isGenericYouTubeDocumentTitle(title) {
                    title = BrowserMediaNavigator.playbackTitle(
                        on: tab,
                        platform: StreamingPlatform.from(url: tab.url),
                        bundleID: bundleID
                    ) ?? (title.isEmpty ? "YouTube" : title)
                }
                if title.isEmpty { title = "YouTube" }
                let artist = StreamingPlatform.from(url: tab.url) == .youtubeMusic
                    ? "YouTube Music"
                    : "YouTube"
                let timing = BrowserMediaNavigator.probePlaybackTiming(on: tab, bundleID: bundleID)
                self.mediaQueue.async {
                    self.lastBrowserPlayAt = Date().timeIntervalSince1970
                    self.lastMediaSourceTab = tab
                    self.lastMediaSourceURL = tab.url
                    self.lastMediaSourcePageTitle = title
                    self.lastYouTubeControlURL = tab.url
                    self.apply(
                        payload: AdapterPayload(
                            title: title,
                            artist: artist,
                            album: "",
                            isPlaying: true,
                            durationMicros: (timing?.duration ?? 0) * 1_000_000,
                            elapsedTimeMicros: (timing?.elapsed ?? 0) * 1_000_000,
                            applicationName: "Google Chrome",
                            bundleIdentifier: bundleID
                        ),
                        title: title
                    )
                }
                return
            }
        }
    }

    /// MediaRemote often keeps a paused Chrome tab as Now Playing after Spotify
    /// starts. Poll Spotify directly in that case so the island can switch.
    private func probeNativeSpotifyIfNeeded() {
        guard !macIsAsleep else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastSpotifyProbeAt >= 1.0 else { return }
        lastSpotifyProbeAt = now
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.spotifyBundleID
        }
        guard running else {
            if activeBundleID == Self.spotifyBundleID {
                preferSpotifyUntil = 0
            }
            spotifyProbeWasPlaying = false
            lastSpotifyPlayAt = 0
            return
        }

        spotifyProbeQueue.async { [weak self] in
            let script = """
            tell application "Spotify"
              if player state is playing then
                set t to current track
                return (name of t) & "\t" & (artist of t) & "\t" & (album of t) & "\t" & (player position as text) & "\t" & ((duration of t) as text)
              end if
              return "paused"
            end tell
            """
            var error: NSDictionary?
            let value = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue ?? "paused"
            self?.mediaQueue.async {
                self?.handleSpotifyProbeResult(value)
            }
        }
    }

    private func handleSpotifyProbeResult(_ value: String) {
        let now = Date().timeIntervalSince1970
        if value == "paused" || value.isEmpty {
            spotifyProbeWasPlaying = false
            lastSpotifyPlayAt = 0
            if activeBundleID == Self.spotifyBundleID {
                preferSpotifyUntil = 0
            }
            return
        }
        if !spotifyProbeWasPlaying {
            lastSpotifyPlayAt = now
        }
        spotifyProbeWasPlaying = true
        guard lastSpotifyPlayAt >= lastBrowserPlayAt else { return }
        let parts = value.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return }
        let title = parts[0]
        let artist = parts.count > 1 ? parts[1] : ""
        let album = parts.count > 2 ? parts[2] : ""
        let elapsed = Double(parts.count > 3 ? parts[3] : "") ?? 0
        let durationRaw = Double(parts.count > 4 ? parts[4] : "") ?? 0
        let duration = durationRaw > 10_000 ? durationRaw / 1000 : durationRaw
        preferSpotifyUntil = now + 30
        apply(
            payload: AdapterPayload(
                title: title,
                artist: artist,
                album: album,
                isPlaying: true,
                durationMicros: duration * 1_000_000,
                elapsedTimeMicros: elapsed * 1_000_000,
                applicationName: "Spotify",
                bundleIdentifier: Self.spotifyBundleID
            ),
            title: title
        )
    }

    private func beginSourceResolve() {
        probeGate.lock()
        sourceResolveDepth += 1
        probeGate.unlock()
    }

    private func endSourceResolve() {
        probeGate.lock()
        sourceResolveDepth = max(0, sourceResolveDepth - 1)
        probeGate.unlock()
    }

    private func isSourceResolveInFlight() -> Bool {
        probeGate.lock()
        defer { probeGate.unlock() }
        return sourceResolveDepth > 0
    }

    /// Chrome often leaves MediaRemote on "playing" after the page pauses.
    /// Sample the matched tab's real video/audio so the waveform can freeze.
    private func probeBrowserPlaybackIfNeeded() {
        guard !macIsAsleep else { return }
        guard isBrowserBundle(activeBundleID), let tab = lastMediaSourceTab else { return }
        let now = Date().timeIntervalSince1970
        guard !isIgnoringHTMLProbe(at: now) else { return }
        guard now - lastHTMLPlaybackProbeAt >= Self.htmlPlaybackProbeInterval else { return }
        guard !htmlProbeInFlight else { return }
        guard !isSourceResolveInFlight() else { return }
        lastHTMLPlaybackProbeAt = now
        htmlProbeInFlight = true
        let bundleID = activeBundleID
        AppleScriptRunLoop.probe.async { [weak self] in
            if self?.isSourceResolveInFlight() == true {
                self?.mediaQueue.async { self?.htmlProbeInFlight = false }
                return
            }
            let probe = BrowserMediaNavigator.probePlayback(
                on: tab,
                bundleID: bundleID
            )
            self?.mediaQueue.async {
                guard let self else { return }
                self.htmlProbeInFlight = false
                switch probe {
                case .missingTab:
                    self.clearIslandBecauseSourceTabClosed()
                    return
                case .unknown:
                    return
                case .playing(let playing):
                    if self.isIgnoringHTMLProbe() { return }
                    if playing {
                        if !self.activeIsPlaying {
                            self.lastBrowserPlayAt = Date().timeIntervalSince1970
                        }
                        self.preferSpotifyUntil = 0
                    }
                    self.htmlPlaybackOverride = playing
                    guard playing != self.activeIsPlaying else { return }
                    NSLog(
                        "[NowPlaying] HTML playback %@ (MediaRemote was %@)",
                        playing ? "playing" : "paused",
                        self.activeIsPlaying ? "playing" : "paused"
                    )
                    self.publishOptimisticPlaying(playing)
                }
            }
        }
    }

    // MARK: - Secondary reader (dual Now Playing)

    /// Emit `secondarySnapshot` for a *second* browser tab that is playing at
    /// the same time as the primary Now Playing session. Runs only when the
    /// dual feature flag is on and the primary session is a browser bundle —
    /// so MediaRemote / native-app arbitration is never touched.
    private func probeSecondaryPlaybackIfNeeded() {
        guard IslandFeatures.dualNowPlayingEnabled else { return }
        guard !macIsAsleep else { return }
        let primaryBundle = activeBundleID
        let primaryHasMedia = !activeTitle.isEmpty
        let primaryPlaying = activeIsPlaying
        // Only kick in when the primary tile is a live browser playback —
        // that's the only case where a second concurrent browser tab is a
        // realistic scenario. Native apps + browser second is out of scope.
        guard isBrowserBundle(primaryBundle), primaryHasMedia else {
            publishEmptySecondaryIfNeeded()
            return
        }
        if !primaryPlaying {
            // MediaRemote often reports Music paused while the Music tab and a
            // Watch secondary are both live. Recheck HTML before treating
            // primary as dead; only promote secondary when HTML confirms stop.
            reassertPrimaryPlayingForDualIfNeeded()
            schedulePromoteSecondaryIfPrimaryHTMLStopped()
            return
        }
        let now = Date().timeIntervalSince1970
        let interval = DualNowPlayingSurfacePolicy.secondaryScanInterval(
            hasSecondarySession: (secondaryLatch.hasMedia && secondaryLatch.isPlaying)
                || (secondarySnapshot.hasMedia && secondarySnapshot.isPlaying)
        )
        guard now - lastSecondaryScanAt >= interval else { return }
        // Don't overwrite the optimistic UI while a user pause/play is landing.
        guard now >= secondaryTransportGraceUntil else { return }
        // Never wait on primary source-resolve: Music/Watch binding was blocking
        // this hunt for a second+, which showed a lone Music tile first.
        guard !secondaryScanInFlight else { return }
        lastSecondaryScanAt = now
        secondaryScanInFlight = true
        let scanGeneration = secondaryScanGeneration
        let primaryTab = lastMediaSourceTab
        let primaryURL = lastMediaSourceURL
        let preferMusicSecondary = !primaryURL.contains("music.youtube.com")
        AppleScriptRunLoop.probe.async { [weak self] in
            defer {
                self?.mediaQueue.async { self?.secondaryScanInFlight = false }
            }
            guard let self else { return }
            let tabs = BrowserMediaNavigator.listTabs(bundleID: primaryBundle)
            let candidates = tabs.filter { tab in
                if let ptab = primaryTab, ptab.tabID != 0, tab.tabID == ptab.tabID { return false }
                if !primaryURL.isEmpty,
                   YouTubeTabPicker.urlsMatch(tab.url, primaryURL) { return false }
                let platform = StreamingPlatform.from(url: tab.url)
                guard platform == .youtube || platform == .youtubeMusic else { return false }
                return BrowserMediaNavigator.isLikelyPlaybackURL(tab.url, platform: platform)
            }
            // Probe the opposite format first (Watch vs Music) so the second
            // session is found in one JS call instead of walking idle tabs.
            let ordered = candidates.sorted { a, b in
                let aMusic = a.url.contains("music.youtube.com")
                let bMusic = b.url.contains("music.youtube.com")
                if aMusic == bMusic { return false }
                return preferMusicSecondary ? aMusic && !bMusic : !aMusic && bMusic
            }
            for tab in ordered.prefix(8) {
                guard let details = self.probeSecondaryTabDetails(tab: tab, bundleID: primaryBundle),
                      details.isPlaying else {
                    continue
                }
                self.mediaQueue.async {
                    guard self.secondaryScanGeneration == scanGeneration else { return }
                    guard Date().timeIntervalSince1970 >= self.secondaryTransportGraceUntil else { return }
                    self.applySecondaryDetails(details, tab: tab, bundleID: primaryBundle)
                }
                return
            }
            // No second live tab — clear.
            self.mediaQueue.async {
                guard self.secondaryScanGeneration == scanGeneration else { return }
                self.publishEmptySecondaryIfNeeded()
            }
        }
    }

    private struct SecondaryDetails {
        var isPlaying: Bool
        var elapsed: TimeInterval
        var duration: TimeInterval
        var title: String
        var artist: String
        var artworkURL: String
        var videoID: String
    }

    /// Reads playback state + minimal metadata from ONE tab in one AppleScript
    /// call. Runs on the probe thread only.
    private func probeSecondaryTabDetails(
        tab: BrowserMediaNavigator.Tab,
        bundleID: String
    ) -> SecondaryDetails? {
        let js = """
        (() => {
          const trim = (v) => String(v || '').replace(/\\s+/g, ' ').trim();
          const seen = [];
          const addMedia = (root) => {
            if (!root) return;
            try {
              const list = root.querySelectorAll('video, audio');
              for (let i = 0; i < list.length; i++) seen.push(list[i]);
            } catch (e) {}
            let frames;
            try { frames = root.querySelectorAll('iframe'); } catch (e) { return; }
            for (let i = 0; i < frames.length; i++) {
              try {
                const doc = frames[i].contentDocument;
                if (doc) addMedia(doc);
              } catch (e) {}
            }
          };
          addMedia(document);
          const active = seen.find(m => m && !m.paused && !m.ended);
          const anyone = active || seen.find(m => m && m.readyState > 0) || seen[0];
          const isPlaying = active ? '1' : '0';
          const elapsed = anyone && Number.isFinite(anyone.currentTime) ? anyone.currentTime : 0;
          const duration = anyone && Number.isFinite(anyone.duration) ? anyone.duration : 0;
          const md = (navigator.mediaSession && navigator.mediaSession.metadata) || null;
          let title = md ? trim(md.title) : '';
          let artist = md ? trim(md.artist) : '';
          let artworkURL = '';
          if (md && md.artwork) {
            let best = 0;
            for (const item of md.artwork) {
              const src = String((item && item.src) || '');
              if (!src) continue;
              const dim = String(item.sizes || '').match(/(\\d+)\\s*x\\s*(\\d+)/i);
              const area = dim ? (Number(dim[1]) * Number(dim[2])) : 0;
              if (area >= best) { best = area; artworkURL = src; }
            }
          }
          if (!artworkURL) {
            const img = document.querySelector(
              'ytmusic-player-bar img, #song-image img, .thumbnail-image-wrapper img, ytmusic-player img'
            );
            if (img) artworkURL = trim(img.currentSrc || img.src);
          }
          if (!title) title = trim(document.title);
          let videoID = '';
          try {
            const u = new URL(location.href);
            videoID = u.searchParams.get('v') || '';
          } catch (e) {}
          return [isPlaying, elapsed, duration, title, artist, artworkURL, videoID].join('\\t');
        })()
        """
        let result = BrowserMediaNavigator.executeJavaScript(js, on: tab, bundleID: bundleID)
        guard case .success(let value) = result else { return nil }
        let parts = value.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 7 else { return nil }
        let isPlaying = parts[0].trimmingCharacters(in: .whitespaces) == "1"
        let elapsed = Double(parts[1]) ?? 0
        let duration = Double(parts[2]) ?? 0
        let title = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkURL = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)
        let videoID = parts[6].trimmingCharacters(in: .whitespacesAndNewlines)
        return SecondaryDetails(
            isPlaying: isPlaying,
            elapsed: max(0, elapsed),
            duration: max(0, duration),
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            videoID: videoID
        )
    }

    private func applySecondaryDetails(
        _ details: SecondaryDetails,
        tab: BrowserMediaNavigator.Tab,
        bundleID: String,
        dualPrimaryURL: String? = nil
    ) {
        let platform = StreamingPlatform.from(url: tab.url)
        var displayTitle = details.title
        if displayTitle.isEmpty {
            displayTitle = tab.title
        }
        displayTitle = YouTubeTabPicker.strippingChromeNotificationBadge(displayTitle)
        var artist = details.artist
        if artist.isEmpty {
            artist = platform == .youtubeMusic ? "YouTube Music" : "YouTube"
        }
        let appName = BrowserMediaNavigator.appleScriptName(for: bundleID)

        let normalizedURL: String
        if platform == .youtubeMusic, !details.videoID.isEmpty {
            normalizedURL = "https://music.youtube.com/watch?v=\(details.videoID)"
        } else if platform == .youtube, !details.videoID.isEmpty {
            normalizedURL = "https://www.youtube.com/watch?v=\(details.videoID)"
        } else {
            normalizedURL = tab.url
        }

        // Publish immediately with cached art / platform logo so compact dual
        // stack appears the moment the second tab is detected — never wait on
        // a network poster download before flipping `secondaryHasMedia`.
        let instantArt = resolveSecondaryArtworkInstant(
            platform: platform,
            details: details
        )
        let next = Snapshot(
            title: displayTitle.isEmpty ? "Now Playing" : displayTitle,
            artist: artist,
            album: "",
            appName: appName,
            bundleIdentifier: bundleID,
            isPlaying: details.isPlaying,
            elapsed: details.elapsed,
            duration: details.duration,
            artwork: instantArt.image,
            hasMedia: true,
            sourceURL: normalizedURL,
            sourcePageTitle: tab.title,
            sourceTab: tab,
            artworkToken: instantArt.token
        )
        if secondarySnapshot != next {
            lastSecondaryElapsedWallTime = Date().timeIntervalSince1970
            if details.isPlaying {
                secondaryHoldUntil = Date().timeIntervalSince1970
                    + DualNowPlayingSurfacePolicy.secondaryHoldDuration()
            }
            let primaryURL = {
                if let dualPrimaryURL, !dualPrimaryURL.isEmpty { return dualPrimaryURL }
                return lastMediaSourceURL.isEmpty ? snapshot.sourceURL : lastMediaSourceURL
            }()
            let primaryIsMusic = primaryURL.contains("music.youtube.com")
                || StreamingPlatform.from(url: primaryURL) == .youtubeMusic
            let primaryIsWatch = !primaryIsMusic
                && (primaryURL.contains("youtube.com/watch")
                    || primaryURL.contains("youtu.be/")
                    || StreamingPlatform.from(url: primaryURL) == .youtube)
            let publishOpposite = DualNowPlayingSurfacePolicy.shouldPublishOppositeSecondaryToUI(
                primaryIsYouTubeWatch: primaryIsWatch,
                primaryIsYouTubeMusic: primaryIsMusic,
                secondaryIsYouTubeWatch: platform == .youtube,
                secondaryIsYouTubeMusic: platform == .youtubeMusic
            )
            // Never replace a demoted opposite latch with a same-format probe.
            guard publishOpposite else { return }
            secondaryLatch = next
            // Only paint secondary once primary UI is the opposite format
            // (bound URL or Music/Watch title hint). Publishing earlier causes
            // Watch+Watch placeholder stacks, then Music replacing the front tile.
            let publishedURL = snapshot.sourceURL
            let publishedHint = StreamingPlatform.titleHint(
                bundleID: snapshot.bundleIdentifier.isEmpty ? activeBundleID : snapshot.bundleIdentifier,
                appName: snapshot.appName.isEmpty ? activeAppName : snapshot.appName,
                artist: snapshot.artist.isEmpty ? activeArtist : snapshot.artist,
                title: snapshot.title.isEmpty ? activeTitle : snapshot.title
            )
            let uiReady = DualNowPlayingSurfacePolicy.primaryAllowsOppositeSecondaryPublish(
                primaryURL: publishedURL.isEmpty ? primaryURL : publishedURL,
                primaryTitleHintIsMusic: publishedHint == .youtubeMusic || primaryIsMusic,
                primaryTitleHintIsWatch: publishedHint == .youtube || primaryIsWatch,
                secondaryIsYouTubeWatch: platform == .youtube,
                secondaryIsYouTubeMusic: platform == .youtubeMusic
            )
            guard uiReady else { return }
            DispatchQueue.main.async { [weak self] in
                self?.secondarySnapshot = next
            }
        }

        // Already have real remote/poster art from cache — nothing to fetch.
        if instantArt.token.hasPrefix("remote:") || instantArt.token.hasPrefix("youtube:") {
            return
        }

        let artDetails = details
        let artGeneration = secondaryScanGeneration
        let artTabID = tab.tabID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fetched = self.downloadSecondaryArtworkOffQueue(
                platform: platform,
                details: artDetails
            )
            guard let image = fetched.image else { return }
            self.mediaQueue.async {
                guard self.secondaryScanGeneration == artGeneration else { return }
                let latchMatches = self.secondaryLatch.sourceTab?.tabID == artTabID
                let snapMatches = self.secondarySnapshot.sourceTab?.tabID == artTabID
                guard latchMatches || snapMatches else { return }
                if fetched.token.hasPrefix("remote:") {
                    let raw = String(fetched.token.dropFirst("remote:".count))
                    self.secondaryArtworkURL = raw
                    self.secondaryArtwork = image
                } else if fetched.token.hasPrefix("youtube:") {
                    let id = String(fetched.token.dropFirst("youtube:".count))
                    self.secondaryPosterID = id
                    self.secondaryPosterImage = image
                }
                DispatchQueue.main.async {
                    guard self.secondarySnapshot.sourceTab?.tabID == artTabID else { return }
                    var updated = self.secondarySnapshot
                    updated.artwork = image
                    updated.artworkToken = fetched.token
                    self.secondarySnapshot = updated
                }
                if self.secondaryLatch.sourceTab?.tabID == artTabID {
                    var latch = self.secondaryLatch
                    latch.artwork = image
                    latch.artworkToken = fetched.token
                    self.secondaryLatch = latch
                }
            }
        }
    }

    /// Cache / bundled logo only — never hits the network.
    private func resolveSecondaryArtworkInstant(
        platform: StreamingPlatform?,
        details: SecondaryDetails
    ) -> (image: NSImage?, token: String) {
        let url = MediaArtworkPolicy.preferredYouTubeMusicArtworkURL(
            playerBarURL: details.artworkURL
        )
        if !url.isEmpty, url == secondaryArtworkURL, let cached = secondaryArtwork {
            return (cached, "remote:\(url)")
        }
        if let platform, platform == .youtube || platform == .youtubeMusic,
           !details.videoID.isEmpty,
           details.videoID == secondaryPosterID,
           let cached = secondaryPosterImage {
            return (cached, "youtube:\(details.videoID)")
        }
        if let platform, let logo = StreamingPlatformArtwork.image(for: platform) {
            return (logo, "platform:\(platform.rawValue)")
        }
        return (nil, "pending:secondary")
    }

    /// Network art fetch for the secondary tile. Safe to call off `mediaQueue`
    /// — does not touch instance cache fields.
    private func downloadSecondaryArtworkOffQueue(
        platform: StreamingPlatform?,
        details: SecondaryDetails
    ) -> (image: NSImage?, token: String) {
        let url = MediaArtworkPolicy.preferredYouTubeMusicArtworkURL(
            playerBarURL: details.artworkURL
        )
        if !url.isEmpty,
           let host = URL(string: url)?.host?.lowercased(),
           MediaArtworkPolicy.isAllowedYouTubeMusicArtworkDownloadHost(host),
           let image = downloadSecondaryArtwork(from: url) {
            return (image, "remote:\(url)")
        }
        if let platform, platform == .youtube || platform == .youtubeMusic,
           !details.videoID.isEmpty,
           let image = fetchSecondaryPoster(videoID: details.videoID) {
            return (image, "youtube:\(details.videoID)")
        }
        return (nil, "pending:secondary")
    }

    private func downloadSecondaryArtwork(from raw: String) -> NSImage? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.cachePolicy = .returnCacheDataElseLoad
        let sem = DispatchSemaphore(value: 0)
        var image: NSImage?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            if let data { image = NSImage(data: data) }
        }.resume()
        _ = sem.wait(timeout: .now() + 1.6)
        return image
    }

    private func fetchSecondaryPoster(videoID: String) -> NSImage? {
        let files = ["mqdefault.jpg", "hqdefault.jpg"]
        for file in files {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(file)") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 1.5)
            request.cachePolicy = .returnCacheDataElseLoad
            let sem = DispatchSemaphore(value: 0)
            var image: NSImage?
            URLSession.shared.dataTask(with: request) { data, _, _ in
                defer { sem.signal() }
                if let data { image = NSImage(data: data) }
            }.resume()
            _ = sem.wait(timeout: .now() + 1.6)
            if let image {
                return MediaClient.filledSquareThumbnail(image)
            }
        }
        return nil
    }

    private func publishEmptySecondaryIfNeeded() {
        let snap = secondaryLatch.hasMedia || !secondaryLatch.title.isEmpty
            ? secondaryLatch
            : secondarySnapshot
        guard snap.hasMedia || !snap.title.isEmpty else { return }

        let primaryURL = lastMediaSourceURL.isEmpty ? snapshot.sourceURL : lastMediaSourceURL
        let primaryPlat = StreamingPlatform.from(url: primaryURL)
            ?? StreamingPlatform.resolve(
                bundleID: activeBundleID,
                appName: activeAppName,
                artist: activeArtist,
                title: activeTitle,
                url: primaryURL
            )
            ?? StreamingPlatform.titleHint(
                bundleID: activeBundleID,
                appName: activeAppName,
                artist: activeArtist,
                title: activeTitle
            )
        let secondaryPlat = StreamingPlatform.from(url: snap.sourceURL)
            ?? StreamingPlatform.resolve(
                bundleID: snap.bundleIdentifier,
                appName: snap.appName,
                artist: snap.artist,
                title: snap.title,
                url: snap.sourceURL
            )
            ?? StreamingPlatform.titleHint(
                bundleID: snap.bundleIdentifier,
                appName: snap.appName,
                artist: snap.artist,
                title: snap.title
            )
        let primaryIsWatch = primaryPlat == .youtube
            || (!primaryURL.contains("music.youtube.com")
                && (primaryURL.contains("youtube.com/watch") || primaryURL.contains("youtu.be/")))
        let primaryIsMusic = primaryPlat == .youtubeMusic
            || primaryURL.contains("music.youtube.com")
        let secondaryIsWatch = secondaryPlat == .youtube
            || (!snap.sourceURL.contains("music.youtube.com")
                && (snap.sourceURL.contains("youtube.com/watch") || snap.sourceURL.contains("youtu.be/")))
        let secondaryIsMusic = secondaryPlat == .youtubeMusic
            || snap.sourceURL.contains("music.youtube.com")
        let holdActive = Date().timeIntervalSince1970 < secondaryHoldUntil
        if DualNowPlayingSurfacePolicy.shouldPreserveSecondaryOnMissedHunt(
            primaryIsYouTubeWatch: primaryIsWatch,
            primaryIsYouTubeMusic: primaryIsMusic,
            secondaryIsYouTubeWatch: secondaryIsWatch,
            secondaryIsYouTubeMusic: secondaryIsMusic,
            secondaryIsPlaying: snap.isPlaying,
            holdActive: holdActive
        ) {
            if snap.isPlaying {
                secondaryHoldUntil = Date().timeIntervalSince1970
                    + DualNowPlayingSurfacePolicy.secondaryHoldDuration()
            }
            reassertPrimaryPlayingForDualIfNeeded()
            return
        }

        secondaryHoldUntil = 0
        secondaryLatch = Snapshot()
        secondaryArtworkURL = ""
        secondaryArtwork = nil
        secondaryPosterID = ""
        secondaryPosterImage = nil
        lastSecondaryElapsedWallTime = nil
        DispatchQueue.main.async { [weak self] in
            self?.secondarySnapshot = Snapshot()
        }
    }

    /// When dual latch says Music+Watch (or reverse) but MediaRemote marked
    /// primary paused, confirm the primary tab is still playing in-page and
    /// republish so `showsCompactDualNowPlaying` can turn on.
    private func reassertPrimaryPlayingForDualIfNeeded() {
        guard IslandFeatures.dualNowPlayingEnabled else { return }
        guard !activeIsPlaying else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastPrimaryDualPlayingRecheckAt >= 0.45 else { return }
        lastPrimaryDualPlayingRecheckAt = now

        let latch = secondaryLatch.hasMedia ? secondaryLatch : secondarySnapshot
        guard latch.hasMedia, latch.isPlaying else { return }
        let primaryURL = lastMediaSourceURL.isEmpty ? snapshot.sourceURL : lastMediaSourceURL
        let primaryIsMusic = primaryURL.contains("music.youtube.com")
        let primaryIsWatch = !primaryIsMusic
            && (primaryURL.contains("youtube.com/watch") || primaryURL.contains("youtu.be/"))
        let latchPlat = StreamingPlatform.from(url: latch.sourceURL)
        let opposite = DualNowPlayingSurfacePolicy.shouldPublishOppositeSecondaryToUI(
            primaryIsYouTubeWatch: primaryIsWatch,
            primaryIsYouTubeMusic: primaryIsMusic,
            secondaryIsYouTubeWatch: latchPlat == .youtube,
            secondaryIsYouTubeMusic: latchPlat == .youtubeMusic
        )
        guard opposite else { return }
        guard let tab = lastMediaSourceTab ?? snapshot.sourceTab else { return }
        let bundleID = activeBundleID
        guard isBrowserBundle(bundleID) else { return }

        AppleScriptRunLoop.probe.async { [weak self] in
            let playing = BrowserMediaNavigator.probePlaybackPlaying(on: tab, bundleID: bundleID)
            self?.mediaQueue.async {
                guard let self else { return }
                guard playing == true else { return }
                guard !self.activeIsPlaying else { return }
                self.htmlPlaybackOverride = true
                self.lastHTMLPlaybackProbeAt = Date().timeIntervalSince1970
                let latchToFlush = self.secondaryLatch
                self.publishOptimisticPlaying(true)
                if DualNowPlayingSurfacePolicy.shouldPublishOppositeSecondaryToUI(
                    primaryIsYouTubeWatch: primaryIsWatch,
                    primaryIsYouTubeMusic: primaryIsMusic,
                    secondaryIsYouTubeWatch: latchPlat == .youtube,
                    secondaryIsYouTubeMusic: latchPlat == .youtubeMusic
                ), latchToFlush.hasMedia {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if !self.secondarySnapshot.hasMedia
                            || self.secondarySnapshot.sourceURL != latchToFlush.sourceURL {
                            self.secondarySnapshot = latchToFlush
                        }
                    }
                }
            }
        }
    }

    private func advanceSecondaryElapsedIfNeeded() {
        guard IslandFeatures.dualNowPlayingEnabled else { return }
        let snap = secondarySnapshot
        guard snap.hasMedia, snap.isPlaying, snap.duration > 0 else {
            lastSecondaryElapsedWallTime = Date().timeIntervalSince1970
            return
        }
        let now = Date().timeIntervalSince1970
        let previous = lastSecondaryElapsedWallTime ?? now
        lastSecondaryElapsedWallTime = now
        let delta = min(max(0, now - previous), 1.0)
        let next = min(snap.duration, snap.elapsed + delta)
        guard abs(next - snap.elapsed) >= 0.25 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var s = self.secondarySnapshot
            guard s.hasMedia, s.isPlaying else { return }
            s.elapsed = next
            self.secondarySnapshot = s
        }
    }

    // MARK: Secondary transport controls
    //
    // Isolated from primary MediaRemote pipeline: these NEVER call
    // `applyBrowserPlayPause` / `applyBrowserSkip` / `trySilentYouTubeSeek`,
    // because `executeYouTubeJavaScript` writes to `lastMediaSourceTab` /
    // `lastYouTubeControlURL` (primary state). Instead we run tab-scoped JS
    // directly and update only `secondarySnapshot`. When the user's Chrome
    // has "Allow JavaScript from Apple Events" off, we surface the same
    // one-time hint the primary path uses.

    /// After a user click, ignore the next probe cycle for this long so the
    /// live media state doesn't overwrite the optimistic UI while the JS
    /// takes effect.
    private var secondaryTransportGraceUntil: TimeInterval = 0

    /// When primary stops (MR / HTML) but the opposite secondary tab is still
    /// playing, promote that secondary to the single-tile primary immediately.
    /// Must run on `mediaQueue`. Returns true if promotion ran.
    /// Callers that only have MediaRemote must use
    /// `schedulePromoteSecondaryIfPrimaryHTMLStopped` instead — MR false
    /// pauses must not wipe dual.
    @discardableResult
    private func promoteOppositeSecondaryIfPrimaryStopped() -> Bool {
        let sec = (secondaryLatch.hasMedia && secondaryLatch.isPlaying)
            ? secondaryLatch
            : secondarySnapshot
        guard sec.hasMedia, sec.isPlaying else { return false }
        // Prefer a bound tab; resolve from URL on promote if demote lost tabID.
        if sec.sourceTab == nil, sec.sourceURL.isEmpty { return false }
        let primaryURL = lastMediaSourceURL.isEmpty ? snapshot.sourceURL : lastMediaSourceURL
        let primaryIsMusic = primaryURL.contains("music.youtube.com")
            || StreamingPlatform.from(url: primaryURL) == .youtubeMusic
        let primaryIsWatch = !primaryIsMusic
            && (primaryURL.contains("youtube.com/watch")
                || primaryURL.contains("youtu.be/")
                || StreamingPlatform.from(url: primaryURL) == .youtube)
        let secPlat = StreamingPlatform.from(url: sec.sourceURL)
        guard DualNowPlayingSurfacePolicy.shouldPublishOppositeSecondaryToUI(
            primaryIsYouTubeWatch: primaryIsWatch,
            primaryIsYouTubeMusic: primaryIsMusic,
            secondaryIsYouTubeWatch: secPlat == .youtube,
            secondaryIsYouTubeMusic: secPlat == .youtubeMusic
        ) else { return false }
        var toPromote = sec
        if toPromote.sourceTab == nil {
            // Promote still works if we only have a URL — rememberBrowserSource
            // will rebind on the next scan; snapshot keeps hasMedia.
            toPromote.sourceTab = secondaryLatch.sourceTab ?? secondarySnapshot.sourceTab
        }
        promoteSecondaryAfterPrimaryPause(toPromote)
        return true
    }

    /// HTML-confirm primary is actually stopped before collapsing dual by
    /// promoting the opposite secondary. Must be called from `mediaQueue`.
    private func schedulePromoteSecondaryIfPrimaryHTMLStopped() {
        guard IslandFeatures.dualNowPlayingEnabled else { return }
        let sec = (secondaryLatch.hasMedia && secondaryLatch.isPlaying)
            ? secondaryLatch
            : secondarySnapshot
        guard sec.hasMedia, sec.isPlaying else {
            publishEmptySecondaryIfNeeded()
            return
        }
        guard let tab = lastMediaSourceTab ?? snapshot.sourceTab else {
            publishEmptySecondaryIfNeeded()
            return
        }
        let bundleID = activeBundleID
        guard isBrowserBundle(bundleID) else {
            publishEmptySecondaryIfNeeded()
            return
        }
        AppleScriptRunLoop.probe.async { [weak self] in
            let playing = BrowserMediaNavigator.probePlaybackPlaying(on: tab, bundleID: bundleID)
            self?.mediaQueue.async {
                guard let self else { return }
                let shouldPromote = DualNowPlayingSurfacePolicy.shouldPromoteSecondaryAfterPrimaryPause(
                    mediaRemoteSaysPrimaryPlaying: self.activeIsPlaying,
                    htmlSaysPrimaryPlaying: playing
                )
                if shouldPromote {
                    _ = self.promoteOppositeSecondaryIfPrimaryStopped()
                    return
                }
                if playing == true {
                    self.htmlPlaybackOverride = true
                    self.publishOptimisticPlaying(true)
                    return
                }
                // HTML nil + MR paused: policy already allows promote above.
                // If we did not promote (no opposite secondary), clear empty secondary.
                self.publishEmptySecondaryIfNeeded()
            }
        }
    }

    /// Hand the single-tile island to the still-playing secondary tab after
    /// the user paused primary. Reuses `shouldIgnoreStaleYouTubeWatchNowPlaying`
    /// so MediaRemote's leftover watch session cannot steal the tile back.
    /// Must run on `mediaQueue`. The original primary tab is paused separately
    /// via `applyBrowserPlayPause` using the tab captured before this swap.
    private func promoteSecondaryAfterPrimaryPause(_ secondary: Snapshot) {
        guard secondary.hasMedia else { return }
        guard let tab = secondary.sourceTab else {
            // Demote sometimes loses tabID; resolve then promote.
            let bundleID = secondary.bundleIdentifier.isEmpty ? activeBundleID : secondary.bundleIdentifier
            let url = secondary.sourceURL
            guard isBrowserBundle(bundleID), !url.isEmpty else { return }
            AppleScriptRunLoop.media.async { [weak self] in
                let tabs = BrowserMediaNavigator.listTabs(bundleID: bundleID)
                guard let live = tabs.first(where: { YouTubeTabPicker.urlsMatch($0.url, url) }) else {
                    return
                }
                self?.mediaQueue.async {
                    var resolved = secondary
                    resolved.sourceTab = live
                    self?.promoteSecondaryAfterPrimaryPause(resolved)
                }
            }
            return
        }
        if lastBoundWatchTitle.isEmpty, !activeTitle.isEmpty {
            lastBoundWatchTitle = activeTitle
        }
        rememberBrowserSourceOnMediaQueue(
            tab: tab,
            url: secondary.sourceURL,
            pageTitle: secondary.sourcePageTitle.isEmpty ? tab.title : secondary.sourcePageTitle,
            youtubeControlURL: secondary.sourceURL
        )
        activeBundleID = secondary.bundleIdentifier
        activeIsPlaying = true
        activeDuration = secondary.duration
        activeElapsed = secondary.elapsed
        activeTitle = secondary.title
        activeArtist = secondary.artist
        activeAppName = secondary.appName
        htmlPlaybackOverride = true
        lastBrowserPlayAt = Date().timeIntervalSince1970
        lastElapsedWallTime = Date().timeIntervalSince1970
        if let art = secondary.artwork {
            lastYouTubeMusicArtImage = art
            lastArtwork = art
        }
        secondaryArtworkURL = ""
        secondaryArtwork = nil
        secondaryPosterID = ""
        secondaryPosterImage = nil
        lastSecondaryElapsedWallTime = nil
        secondaryLatch = Snapshot()
        secondaryHoldUntil = 0
        // Invalidate any in-flight secondary probe that still holds the old
        // primary/secondary pairing — otherwise it rewrites dual layout a
        // moment after collapse.
        secondaryScanGeneration += 1
        secondaryTransportGraceUntil = Date().timeIntervalSince1970 + 2.5
        lastSecondaryScanAt = Date().timeIntervalSince1970
        // Suppress MediaRemote's paused opposite session (usually Music) so the
        // island keeps the promoted Watch title/art instead of Music-without-thumbnail.
        let promotedIsWatch = StreamingPlatform.from(url: secondary.sourceURL) == .youtube
            || (!secondary.sourceURL.contains("music.youtube.com")
                && (secondary.sourceURL.contains("youtube.com/watch")
                    || secondary.sourceURL.contains("youtu.be/")))
        ignoreOppositePausedIsMusic = promotedIsWatch
        ignoreOppositePausedUntil = Date().timeIntervalSince1970 + 8.0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = secondary
            next.isPlaying = true
            self.snapshot = next
            self.secondarySnapshot = Snapshot()
        }
    }

    func secondaryTogglePlayPause() {
        let snap = secondarySnapshot.hasMedia ? secondarySnapshot : secondaryLatch
        guard snap.hasMedia else {
            NSLog("[NowPlaying] secondary toggle skipped — no snapshot (hasMedia=NO)")
            return
        }
        let wasPlaying = snap.isPlaying
        let bundleID = snap.bundleIdentifier.isEmpty ? activeBundleID : snap.bundleIdentifier
        let tab = snap.sourceTab
        NSLog(
            "[NowPlaying] secondary toggle playing=%@ tab=%@ url=%@",
            wasPlaying ? "YES" : "NO",
            tab.map { String($0.tabID) } ?? "nil",
            snap.sourceURL
        )
        secondaryTransportGraceUntil = Date().timeIntervalSince1970 + 1.6
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var s = self.secondarySnapshot.hasMedia ? self.secondarySnapshot : snap
            s.isPlaying = !wasPlaying
            s.hasMedia = true
            self.secondarySnapshot = s
            // Pausing secondary collapses dual immediately; keep snapshot so
            // play can resume the same tile without waiting for a hunt.
        }
        mediaQueue.async { [weak self] in
            guard let self else { return }
            var latch = self.secondaryLatch.hasMedia ? self.secondaryLatch : snap
            latch.isPlaying = !wasPlaying
            self.secondaryLatch = latch
        }
        let js = wasPlaying
            ? secondaryPauseJavaScript(for: snap.sourceURL)
            : secondaryPlayJavaScript(for: snap.sourceURL)
        runSecondaryJavaScript(
            js,
            tab: tab,
            sourceURL: snap.sourceURL,
            bundleID: bundleID,
            label: wasPlaying ? "pause" : "play"
        )
    }

    func secondarySkipForward() { dispatchSecondarySkip(next: true) }
    func secondarySkipBackward() { dispatchSecondarySkip(next: false) }

    private func dispatchSecondarySkip(next: Bool) {
        let snap = secondarySnapshot.hasMedia ? secondarySnapshot : secondaryLatch
        guard snap.hasMedia else {
            NSLog("[NowPlaying] secondary skip skipped — no snapshot")
            return
        }
        let bundleID = snap.bundleIdentifier.isEmpty ? activeBundleID : snap.bundleIdentifier
        let tab = snap.sourceTab
        secondaryTransportGraceUntil = Date().timeIntervalSince1970 + 1.6
        NSLog(
            "[NowPlaying] secondary %@ tab=%@ url=%@",
            next ? "next" : "prev",
            tab.map { String($0.tabID) } ?? "nil",
            snap.sourceURL
        )
        let isMusic = snap.sourceURL.contains("music.youtube.com")
        let js: String
        if next {
            js = isMusic
                ? BrowserMediaNavigator.youtubeMusicNextJavaScript
                : BrowserMediaNavigator.youtubeWatchNextJavaScript
        } else {
            js = isMusic
                ? BrowserMediaNavigator.youtubeMusicPreviousJavaScript
                : BrowserMediaNavigator.youtubeWatchPreviousJavaScript
        }
        runSecondaryJavaScript(
            js,
            tab: tab,
            sourceURL: snap.sourceURL,
            bundleID: bundleID,
            label: next ? "next" : "prev"
        )
    }

    func secondarySeek(to seconds: TimeInterval) {
        let snap = secondarySnapshot.hasMedia ? secondarySnapshot : secondaryLatch
        guard snap.hasMedia else { return }
        let bundleID = snap.bundleIdentifier.isEmpty ? activeBundleID : snap.bundleIdentifier
        let tab = snap.sourceTab
        let target: TimeInterval
        if snap.duration > 0 {
            target = min(max(0, seconds), max(snap.duration - 0.25, 0))
        } else {
            target = max(0, seconds)
        }
        secondaryTransportGraceUntil = Date().timeIntervalSince1970 + 1.6
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var s = self.secondarySnapshot.hasMedia ? self.secondarySnapshot : snap
            s.elapsed = target
            self.secondarySnapshot = s
        }
        let js = BrowserMediaNavigator.seekJavaScript(to: target)
        runSecondaryJavaScript(
            js,
            tab: tab,
            sourceURL: snap.sourceURL,
            bundleID: bundleID,
            label: "seek"
        )
    }

    func secondaryRevealSource() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.secondaryRevealSource() }
            return
        }
        let snap = secondarySnapshot.hasMedia ? secondarySnapshot : secondaryLatch
        guard snap.hasMedia else { return }
        let bundleID = snap.bundleIdentifier.isEmpty ? activeBundleID : snap.bundleIdentifier
        if let tab = snap.sourceTab {
            AppleScriptRunLoop.media.async {
                _ = BrowserMediaNavigator.activateTab(tab, bundleID: bundleID)
            }
            return
        }
        let url = snap.sourceURL
        AppleScriptRunLoop.media.async {
            let tabs = BrowserMediaNavigator.listTabs(bundleID: bundleID)
            if let live = tabs.first(where: { YouTubeTabPicker.urlsMatch($0.url, url) }) {
                _ = BrowserMediaNavigator.activateTab(live, bundleID: bundleID)
            } else if let page = URL(string: url), !url.isEmpty {
                DispatchQueue.main.async { NSWorkspace.shared.open(page) }
            }
        }
    }

    /// Runs a single tab-scoped JS payload for the secondary tile. Falls back
    /// to the live-tab lookup once if the cached tabID is stale or missing.
    /// Never touches primary state.
    private func runSecondaryJavaScript(
        _ javascript: String,
        tab: BrowserMediaNavigator.Tab?,
        sourceURL: String,
        bundleID: String,
        label: String
    ) {
        AppleScriptRunLoop.media.async { [weak self] in
            guard let self else { return }
            if let tab {
                let result = BrowserMediaNavigator.executeJavaScript(
                    javascript,
                    on: tab,
                    bundleID: bundleID
                )
                switch result {
                case .success(let value):
                    NSLog("[NowPlaying] secondary %@ -> %@ tab=%d", label, value, tab.tabID)
                    return
                case .needsPermission:
                    NSLog("[NowPlaying] secondary %@ needs Apple Events JS", label)
                    if self.ensureChromeJavaScriptFromAppleEventsEnabled() {
                        let retry = BrowserMediaNavigator.executeJavaScript(
                            javascript,
                            on: tab,
                            bundleID: bundleID
                        )
                        if case .success(let value) = retry {
                            NSLog("[NowPlaying] secondary %@ retry -> %@", label, value)
                            return
                        }
                    }
                    self.showChromeJavaScriptHintIfNeeded()
                case .failed, .missingTab:
                    NSLog(
                        "[NowPlaying] secondary %@ missed tab=%d — retrying with live tab lookup",
                        label,
                        tab.tabID
                    )
                }
            } else {
                NSLog("[NowPlaying] secondary %@ — no cached tab; live lookup url=%@", label, sourceURL)
            }
            // One retry via live-tab resolution — the tab may have new indices.
            let tabs = BrowserMediaNavigator.listTabs(bundleID: bundleID)
            let live: BrowserMediaNavigator.Tab?
            if let tab {
                live = BrowserMediaNavigator.resolveLiveTab(tab, from: tabs)
                    ?? tabs.first(where: { YouTubeTabPicker.urlsMatch($0.url, sourceURL) })
            } else {
                live = tabs.first(where: { YouTubeTabPicker.urlsMatch($0.url, sourceURL) })
            }
            guard let live else {
                NSLog("[NowPlaying] secondary %@ retry — live tab not found", label)
                return
            }
            let retry = BrowserMediaNavigator.executeJavaScript(
                javascript,
                on: live,
                bundleID: bundleID
            )
            if case .success(let value) = retry {
                NSLog("[NowPlaying] secondary %@ retry(live) -> %@", label, value)
                // Refresh bound tab so the next click does not miss again.
                self.mediaQueue.async {
                    if self.secondaryLatch.sourceURL.isEmpty
                        || YouTubeTabPicker.urlsMatch(self.secondaryLatch.sourceURL, sourceURL) {
                        var latch = self.secondaryLatch
                        latch.sourceTab = live
                        if latch.sourceURL.isEmpty { latch.sourceURL = sourceURL }
                        self.secondaryLatch = latch
                    }
                    DispatchQueue.main.async {
                        guard self.secondarySnapshot.hasMedia,
                              YouTubeTabPicker.urlsMatch(self.secondarySnapshot.sourceURL, sourceURL)
                                || self.secondarySnapshot.sourceURL.isEmpty
                        else { return }
                        var s = self.secondarySnapshot
                        s.sourceTab = live
                        if s.sourceURL.isEmpty { s.sourceURL = sourceURL }
                        self.secondarySnapshot = s
                    }
                }
            } else {
                NSLog("[NowPlaying] secondary %@ retry(live) failed", label)
            }
        }
    }

    private func secondaryPauseJavaScript(for tabURL: String) -> String {
        if tabURL.contains("music.youtube.com") {
            return """
            (() => {
              const v = document.querySelector('#song-video video, video');
              const btn = document.querySelector('#play-pause-button');
              const label = ((btn && (btn.getAttribute('aria-label') || btn.getAttribute('title'))) || '').toLowerCase();
              if (v && !v.paused) { v.pause(); return 'ytm-paused'; }
              if (btn && label.indexOf('pause') !== -1) { btn.click(); return 'ytm-btn-pause'; }
              return 'already-paused';
            })()
            """
        }
        return """
        (() => {
          const p = document.querySelector('#movie_player, .html5-video-player');
          const v = document.querySelector('#movie_player video.html5-main-video, #movie_player video, video.html5-main-video, video');
          const state = p && typeof p.getPlayerState === 'function' ? p.getPlayerState() : null;
          if (state === 1 && typeof p.pauseVideo === 'function') { p.pauseVideo(); return 'paused-api'; }
          if (v && !v.paused) { v.pause(); return 'paused-video'; }
          return 'already-paused';
        })()
        """
    }

    private func secondaryPlayJavaScript(for tabURL: String) -> String {
        if tabURL.contains("music.youtube.com") {
            return """
            (() => {
              const v = document.querySelector('#song-video video, video');
              const btn = document.querySelector('#play-pause-button');
              const label = ((btn && (btn.getAttribute('aria-label') || btn.getAttribute('title'))) || '').toLowerCase();
              if (btn && label.indexOf('play') !== -1) { btn.click(); }
              if (v && v.paused) {
                const pr = v.play();
                if (pr && typeof pr.catch === 'function') pr.catch(function(){});
              }
              if (v && !v.paused) return 'ytm-played';
              if (btn && label.indexOf('play') !== -1) return 'ytm-btn-play';
              return v && v.paused ? 'play-blocked' : 'already-playing';
            })()
            """
        }
        return """
        (() => {
          const p = document.querySelector('#movie_player, .html5-video-player');
          const v = document.querySelector('#movie_player video.html5-main-video, #movie_player video, video.html5-main-video, video');
          const btn = document.querySelector('.ytp-play-button');
          const large = document.querySelector('.ytp-large-play-button');
          if (p && typeof p.playVideo === 'function') { p.playVideo(); }
          const label = ((btn && (btn.getAttribute('aria-label') || btn.getAttribute('title'))) || '').toLowerCase();
          if (btn && (label.indexOf('play') !== -1 || label === '')) { btn.click(); }
          if (large) { large.click(); }
          if (v && v.paused) {
            const pr = v.play();
            if (pr && typeof pr.catch === 'function') pr.catch(function(){});
          }
          const state = p && typeof p.getPlayerState === 'function' ? p.getPlayerState() : null;
          if (state === 1 || (v && !v.paused)) return 'played';
          return v ? 'play-blocked' : 'no-player';
        })()
        """
    }

    private enum YouTubeJSResult: Equatable {
        case ok
        case needsPermission
        case failed
    }

    /// Pause/play the Now Playing tab only — never the first YouTube tab in Chrome.
    private func trySilentYouTubePlayPause(
        shouldPause: Bool,
        tab: BrowserMediaNavigator.Tab? = nil,
        bundleID: String? = nil
    ) -> YouTubeJSResult {
        if shouldPause {
            let musicJS = """
            (() => {
              const v = document.querySelector('#song-video video');
              const btn = document.querySelector('#play-pause-button');
              const label = ((btn && (btn.getAttribute('aria-label') || btn.getAttribute('title'))) || '').toLowerCase();
              if (v && !v.paused) { v.pause(); return 'ytm-paused'; }
              if (btn && label.indexOf('pause') !== -1) { btn.click(); return 'ytm-btn-pause'; }
              return 'already-paused';
            })()
            """
            let watchJS = """
            (() => {
              const p = document.querySelector('#movie_player, .html5-video-player');
              const v = document.querySelector('#movie_player video.html5-main-video, #movie_player video, video.html5-main-video');
              const state = p && typeof p.getPlayerState === 'function' ? p.getPlayerState() : null;
              if (state === 1 && typeof p.pauseVideo === 'function') { p.pauseVideo(); return 'paused-api'; }
              if (v && !v.paused) { v.pause(); return 'paused-video'; }
              return 'already-paused';
            })()
            """
            return runSilentBrowserMediaJavaScript(
                musicJS: musicJS,
                watchJS: watchJS,
                tab: tab,
                bundleID: bundleID
            )
        }

        let musicJS = """
        (() => {
          const v = document.querySelector('#song-video video');
          const btn = document.querySelector('#play-pause-button');
          const label = ((btn && (btn.getAttribute('aria-label') || btn.getAttribute('title'))) || '').toLowerCase();
          if (btn && label.indexOf('play') !== -1) { btn.click(); }
          if (v && v.paused) {
            const pr = v.play();
            if (pr && typeof pr.catch === 'function') pr.catch(function(){});
          }
          if (v && !v.paused) return 'ytm-played';
          if (btn && label.indexOf('play') !== -1) return 'ytm-btn-play';
          return v && v.paused ? 'play-blocked' : 'already-playing';
        })()
        """
        let watchJS = """
        (() => {
          const p = document.querySelector('#movie_player, .html5-video-player');
          const v = document.querySelector('#movie_player video.html5-main-video, #movie_player video, video.html5-main-video');
          const btn = document.querySelector('.ytp-play-button');
          const large = document.querySelector('.ytp-large-play-button');
          if (p && typeof p.playVideo === 'function') { p.playVideo(); }
          const label = ((btn && (btn.getAttribute('aria-label') || btn.getAttribute('title'))) || '').toLowerCase();
          if (btn && (label.indexOf('play') !== -1 || label === '')) { btn.click(); }
          if (large) { large.click(); }
          if (v && v.paused) {
            const pr = v.play();
            if (pr && typeof pr.catch === 'function') pr.catch(function(){});
          }
          const state = p && typeof p.getPlayerState === 'function' ? p.getPlayerState() : null;
          if (state === 1 || (v && !v.paused)) return 'played';
          return v ? 'play-blocked' : 'no-player';
        })()
        """
        return runSilentBrowserMediaJavaScript(
            musicJS: musicJS,
            watchJS: watchJS,
            tab: tab,
            bundleID: bundleID
        )
    }

    private func trySilentYouTubeSeek(
        to seconds: TimeInterval,
        tab: BrowserMediaNavigator.Tab? = nil,
        bundleID: String? = nil
    ) -> YouTubeJSResult {
        let safe = String(format: "%.3f", seconds)
        let musicJS = """
        (() => {
          const seconds = \(safe);
          const v = document.querySelector('#song-video video, video');
          if (!v) return 'no-player';
          const dur = Number.isFinite(v.duration) ? v.duration : seconds;
          v.currentTime = Math.min(Math.max(0, seconds), Math.max(dur - 0.05, 0));
          return 'ytm-seek';
        })()
        """
        let watchJS = """
        (() => {
          const seconds = \(safe);
          const p = document.querySelector('#movie_player, .html5-video-player');
          if (p && typeof p.seekTo === 'function') {
            p.seekTo(seconds, true);
          }
          const v = document.querySelector('#movie_player video.html5-main-video, #movie_player video, video');
          if (v) {
            const dur = Number.isFinite(v.duration) ? v.duration : seconds;
            v.currentTime = Math.min(Math.max(0, seconds), Math.max(dur - 0.05, 0));
          }
          if (p && typeof p.seekTo === 'function') { return 'seekTo'; }
          if (v) { return 'video'; }
          return 'no-video';
        })()
        """
        return runSilentBrowserMediaJavaScript(
            musicJS: musicJS,
            watchJS: watchJS,
            tab: tab,
            bundleID: bundleID
        )
    }

    /// Next/prev — YouTube Music player-bar buttons first, then classic YouTube.
    /// Previous goes to the prior item on the first click (not restart-then-skip).
    private func trySilentYouTubeJavaScript(
        next: Bool,
        tab: BrowserMediaNavigator.Tab? = nil,
        bundleID: String? = nil
    ) -> YouTubeJSResult {
        if next {
            return runSilentBrowserMediaJavaScript(
                musicJS: BrowserMediaNavigator.youtubeMusicNextJavaScript,
                watchJS: BrowserMediaNavigator.youtubeWatchNextJavaScript,
                tab: tab,
                bundleID: bundleID
            )
        }
        return runSilentBrowserMediaJavaScript(
            musicJS: BrowserMediaNavigator.youtubeMusicPreviousJavaScript,
            watchJS: BrowserMediaNavigator.youtubeWatchPreviousJavaScript,
            tab: tab,
            bundleID: bundleID
        )
    }

    /// Runs JS only on the YouTube tab that matches Now Playing (or the last
    /// tab we controlled). Never the first watch/Music tab in Chrome.
    private func runSilentBrowserMediaJavaScript(
        musicJS: String,
        watchJS: String,
        tab: BrowserMediaNavigator.Tab? = nil,
        bundleID: String? = nil
    ) -> YouTubeJSResult {
        let resolvedBundle = bundleID ?? activeBundleID
        var candidate = tab ?? lastMediaSourceTab ?? snapshot.sourceTab
        let fallbackURL = snapshot.sourceURL.isEmpty ? lastMediaSourceURL : snapshot.sourceURL
        if candidate == nil, !fallbackURL.isEmpty, isBrowserBundle(resolvedBundle) {
            let tabs = BrowserMediaNavigator.listTabs(bundleID: resolvedBundle)
            candidate = tabs.first(where: { YouTubeTabPicker.urlsMatch($0.url, fallbackURL) })
                ?? tabs.first(where: {
                    let plat = StreamingPlatform.from(url: $0.url)
                    let wantMusic = fallbackURL.contains("music.youtube.com")
                    return wantMusic ? plat == .youtubeMusic : plat == .youtube
                })
        }
        if let candidate {
            let result = executeYouTubeJavaScript(
                musicJS: musicJS,
                watchJS: watchJS,
                tab: candidate,
                bundleID: resolvedBundle
            )
            if result == .ok || result == .needsPermission {
                return result
            }
            let tabs = BrowserMediaNavigator.listTabs(bundleID: resolvedBundle)
            if let live = BrowserMediaNavigator.resolveLiveTab(candidate, from: tabs)
                ?? tabs.first(where: { YouTubeTabPicker.urlsMatch($0.url, fallbackURL) }) {
                let retried = executeYouTubeJavaScript(
                    musicJS: musicJS,
                    watchJS: watchJS,
                    tab: live,
                    bundleID: resolvedBundle
                )
                if retried != .failed {
                    return retried
                }
            }
        }
        NSLog("[NowPlaying] YouTube JS missed cached tab url=%@", fallbackURL)
        return .failed
    }

    private func executeYouTubeJavaScript(
        musicJS: String,
        watchJS: String,
        tab: BrowserMediaNavigator.Tab,
        bundleID: String
    ) -> YouTubeJSResult {
        let js = tab.url.contains("music.youtube.com") ? musicJS : watchJS
        switch BrowserMediaNavigator.executeJavaScript(
            js,
            on: tab,
            bundleID: bundleID
        ) {
        case .success(let value):
            if value == "play-blocked" {
                return .failed
            }
            lastYouTubeControlURL = tab.url
            lastMediaSourceTab = tab
            return .ok
        case .needsPermission:
            return .needsPermission
        case .failed, .missingTab:
            return .failed
        }
    }

    /// Enables Chrome's Developer → Allow JavaScript from Apple Events when off.
    /// Restores the previously frontmost app afterward.
    @discardableResult
    private func ensureChromeJavaScriptFromAppleEventsEnabled() -> Bool {
        let previous = NSWorkspace.shared.frontmostApplication
        let appName = browserAppleScriptName(for: activeBundleID)

        let script = """
        try
          tell application "\(appName)" to activate
          delay 0.35
          tell application "System Events"
            tell process "\(appName)"
              set frontmost to true
              set mi to menu item "Allow JavaScript from Apple Events" of menu "Developer" of menu item "Developer" of menu "View" of menu bar 1
              set markChar to ""
              try
                set markChar to value of attribute "AXMenuItemMarkChar" of mi as string
              end try
              if markChar is "" or markChar is "missing value" then
                click mi
                return "enabled"
              else
                return "already-on"
              end if
            end tell
          end tell
        on error errMsg
          return "err:" & errMsg
        end try
        """

        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        let value = result?.stringValue ?? ""
        NSLog("[NowPlaying] enable JS Apple Events: %@", value)

        if let prevName = previous?.localizedName {
            var restoreErr: NSDictionary?
            NSAppleScript(source: "tell application \"\(prevName)\" to activate")?
                .executeAndReturnError(&restoreErr)
        }
        DispatchQueue.main.async {
            previous?.activate()
        }

        if value.hasPrefix("err:") { return false }
        Thread.sleep(forTimeInterval: 0.4)
        return true
    }

    private func browserAppleScriptName(for bundleID: String) -> String {
        BrowserMediaNavigator.appleScriptName(for: bundleID)
    }

    private func showChromeJavaScriptHintIfNeeded() {
        let key = "didShowChromeJSAppleEventsHint"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "One Chrome setting needed"
            alert.informativeText = """
            Next/Previous for YouTube must run in the background (so you aren’t jumped to the Chrome window).

            In Google Chrome, enable:
            View → Developer → Allow JavaScript from Apple Events

            Then try Next again. You only need to do this once.
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

private extension Data {
    var trimmingASCIIWhitespace: Data {
        let ws = CharacterSet.whitespacesAndNewlines
        guard let s = String(data: self, encoding: .utf8) else { return self }
        return Data(s.trimmingCharacters(in: ws).utf8)
    }
}
