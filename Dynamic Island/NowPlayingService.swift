import AppKit
import Combine
import Darwin
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
    private var lastSpotifyProbeAt: TimeInterval = 0
    private var preferSpotifyUntil: TimeInterval = 0
    private var lastSpotifyPlayAt: TimeInterval = 0
    private var lastBrowserPlayAt: TimeInterval = 0
    private var spotifyProbeWasPlaying = false
    private let spotifyProbeQueue = DispatchQueue(label: "island.spotify-probe")
    private static let htmlPlaybackProbeInterval: TimeInterval = 0.35
    private static let spotifyBundleID = "com.spotify.client"

    private var listenerProcess: Process?
    private var listenerStdin: Pipe?
    private var listenerBuffer = Data()
    private var elapsedTicker: DispatchSourceTimer?
    private var lastElapsedWallTime: TimeInterval?
    private var listenerRestartScheduled = false
    private var revealInFlight = false
    private let posterQueue = DispatchQueue(label: "island.youtube-poster")
    private var posterFetchGeneration = 0

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
    }

    deinit {
        elapsedTicker?.cancel()
        stopAdapterListener()
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
            if let tab {
                switched = BrowserMediaNavigator.activateTab(tab, bundleID: bundleID)
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

    private func noteUserTransport() {
        transportGeneration += 1
        ignoreHTMLProbeUntil = Date().timeIntervalSince1970 + 1.6
    }

    func togglePlayPause() {
        mediaQueue.async { [weak self] in
            guard let self else { return }
            let target = self.controlTarget
            NSLog(
                "[NowPlaying] togglePlayPause target=%@ playing=%@ bundle=%@",
                target.logName,
                self.activeIsPlaying ? "YES" : "NO",
                self.activeBundleID
            )

            switch target {
            case .youtubeBrowser:
                let wasPlaying = self.activeIsPlaying
                self.noteUserTransport()
                let generation = self.transportGeneration
                self.publishOptimisticPlaying(!wasPlaying)
                AppleScriptRunLoop.media.async { [weak self] in
                    guard let self else { return }
                    guard generation == self.transportGeneration else { return }
                    var applied = false
                    switch self.trySilentYouTubePlayPause(shouldPause: wasPlaying) {
                    case .ok:
                        applied = true
                    case .needsPermission:
                        if self.ensureChromeJavaScriptFromAppleEventsEnabled() {
                            Thread.sleep(forTimeInterval: 0.25)
                            if case .ok = self.trySilentYouTubePlayPause(shouldPause: wasPlaying) {
                                applied = true
                            }
                        }
                    case .failed:
                        if wasPlaying {
                            self.mediaQueue.async { self.runAdapterCommand("pause") }
                            applied = true
                        } else {
                            NSLog("[NowPlaying] skip MediaRemote play; no matching YouTube tab")
                        }
                    }
                    if !applied {
                        self.mediaQueue.async { self.publishOptimisticPlaying(wasPlaying) }
                    }
                }

            case .browserMedia:
                let wasPlaying = self.activeIsPlaying
                self.noteUserTransport()
                let generation = self.transportGeneration
                self.publishOptimisticPlaying(!wasPlaying)
                AppleScriptRunLoop.media.async { [weak self] in
                    guard let self, generation == self.transportGeneration else { return }
                    if !self.trySilentBrowserPlayPause() {
                        self.mediaQueue.async {
                            self.runAdapterCommand(wasPlaying ? "pause" : "play")
                        }
                    }
                }

            case .nativeMediaRemote:
                if self.activeIsPlaying {
                    self.runAdapterCommand("pause")
                } else {
                    self.runAdapterCommand("play")
                }
                self.publishOptimisticPlaying(!self.activeIsPlaying)
            }
        }
    }

    /// Seek the current track/video to `seconds` (clamped to duration when known).
    func seek(to seconds: TimeInterval) {
        mediaQueue.async { [weak self] in
            guard let self else { return }
            let duration = self.activeDuration
            let targetTime: TimeInterval
            if duration > 0 {
                targetTime = min(max(0, seconds), max(duration - 0.25, 0))
            } else {
                targetTime = max(0, seconds)
            }

            let target = self.controlTarget
            NSLog(
                "[NowPlaying] seek to %.2fs target=%@ bundle=%@",
                targetTime,
                target.logName,
                self.activeBundleID
            )

            // Optimistic UI update.
            DispatchQueue.main.async {
                var snap = self.snapshot
                snap.elapsed = targetTime
                self.snapshot = snap
            }

            switch target {
            case .youtubeBrowser:
                switch self.trySilentYouTubeSeek(to: targetTime) {
                case .ok:
                    break
                case .needsPermission:
                    if self.ensureChromeJavaScriptFromAppleEventsEnabled() {
                        Thread.sleep(forTimeInterval: 0.25)
                        _ = self.trySilentYouTubeSeek(to: targetTime)
                    }
                case .failed:
                    self.runAdapterCommand("set_time", arguments: [String(targetTime)])
                }

            case .browserMedia:
                if !self.trySilentBrowserSeek(to: targetTime) {
                    self.runAdapterCommand("set_time", arguments: [String(targetTime)])
                }

            case .nativeMediaRemote:
                self.runAdapterCommand("set_time", arguments: [String(targetTime)])
            }

            self.activeElapsed = targetTime
            self.lastElapsedWallTime = Date().timeIntervalSince1970
        }
    }

    func skipForward() {
        mediaQueue.async { [weak self] in
            self?.goNext()
        }
    }

    func skipBackward() {
        mediaQueue.async { [weak self] in
            self?.goPrevious()
        }
    }

    func nextTrack() { skipForward() }
    func previousTrack() { skipBackward() }

    func refresh() {
        mediaQueue.async { [weak self] in
            guard let self else { return }
            self.stopAdapterListener()
            self.startAdapterListener()
        }
    }

    private func goNext() {
        let target = controlTarget
        NSLog("[NowPlaying] next target=%@ bundle=%@", target.logName, activeBundleID)

        switch target {
        case .youtubeBrowser:
            noteUserTransport()
            let generation = transportGeneration
            AppleScriptRunLoop.media.async { [weak self] in
                guard let self, generation == self.transportGeneration else { return }
                self.sendYouTubePlaylistKey(next: true)
            }
        case .browserMedia:
            noteUserTransport()
            let generation = transportGeneration
            AppleScriptRunLoop.media.async { [weak self] in
                guard let self, generation == self.transportGeneration else { return }
                self.seekBrowserVideo(by: 10)
            }
        case .nativeMediaRemote:
            runAdapterCommand("next_track")
        }
    }

    private func goPrevious() {
        let target = controlTarget
        NSLog("[NowPlaying] previous target=%@ bundle=%@", target.logName, activeBundleID)

        switch target {
        case .youtubeBrowser:
            noteUserTransport()
            let generation = transportGeneration
            AppleScriptRunLoop.media.async { [weak self] in
                guard let self, generation == self.transportGeneration else { return }
                self.sendYouTubePlaylistKey(next: false)
            }
        case .browserMedia:
            noteUserTransport()
            let generation = transportGeneration
            AppleScriptRunLoop.media.async { [weak self] in
                guard let self, generation == self.transportGeneration else { return }
                self.seekBrowserVideo(by: -10)
            }
        case .nativeMediaRemote:
            runAdapterCommand("previous_track")
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
        guard isBrowserBundle(activeBundleID) else { return .nativeMediaRemote }
        let platform = StreamingPlatform.resolve(
            bundleID: activeBundleID,
            appName: activeAppName,
            artist: activeArtist,
            title: activeTitle,
            url: lastMediaSourceURL
        )
        return BrowserMediaControlPolicy.usesYouTubeSpecificControls(
            bundleID: activeBundleID,
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
        probeNativeSpotifyIfNeeded()
        probeBrowserPlaybackIfNeeded()
        guard activeIsPlaying, activeDuration > 0 else {
            lastElapsedWallTime = Date().timeIntervalSince1970
            return
        }
        let now = Date().timeIntervalSince1970
        let previous = lastElapsedWallTime ?? now
        lastElapsedWallTime = now
        let nextElapsed = min(activeDuration, activeElapsed + max(0, now - previous))
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

        if !isBrowserBundle(bundleID) {
            htmlPlaybackOverride = nil
            clearBrowserSource()
        }

        let previousBundleID = activeBundleID
        activeBundleID = bundleID
        activeIsPlaying = isPlaying
        activeDuration = max(0, duration)
        activeElapsed = max(0, elapsed)
        activeTitle = title
        activeArtist = artist
        activeAppName = appName
        lastElapsedWallTime = Date().timeIntervalSince1970

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
            if bundleID != previousBundleID || platformChanged {
                clearBrowserSource()
            } else if !cachedStillMatches {
                // Same tab, new video — keep window/tab indices so we can
                // re-read location.href instead of waiting on activeTab.
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
        let needsRescanForNewIdentity = identityChanged && (
            lastMediaSourceURL.isEmpty
                || !cachedStillMatches
                || platformChanged
                || bundleID != previousBundleID
        )
        let shouldScanBrowser = isBrowserBundle(bundleID)
            && (
                needsRescanForNewIdentity
                    || (
                        !identityChanged
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
            if let cached = cachedTab,
               YouTubeTabPicker.cachedFamilyTabCanServeNowPlaying(
                tabTitle: cached.title,
                tabURL: cached.url,
                nowPlayingTitle: title
               ) {
                reusableCachedTab = cached
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
        if prepared.image == nil,
           !identityChanged,
           snapshot.bundleIdentifier == bundleID,
           let held = snapshot.artwork,
           MediaArtworkPolicy.shouldHoldArtworkWhilePosterLoads(
            previousToken: snapshot.artworkToken,
            policyToken: policyToken,
            identityChanged: identityChanged
           ) {
            prepared = (held, snapshot.artworkToken)
        } else if !identityChanged,
                  snapshot.bundleIdentifier == bundleID,
                  YouTubeTabPicker.titlesMatch(snapshot.title, title),
                  MediaArtworkPolicy.isYouTubePosterToken(snapshot.artworkToken),
                  !MediaArtworkPolicy.isYouTubePosterToken(prepared.token) {
            prepared = (snapshot.artwork, snapshot.artworkToken)
        }
        if prepared.image == nil, let held = artwork,
           MediaArtworkPolicy.allowsRemoteArtworkFallback(
            isBrowser: isBrowserBundle(bundleID),
            policyToken: policyToken
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
            self.snapshot = merged
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
            pixelHeight: pixels.height
        )
        if isBrowser, platform == nil || youtubeFamily {
            if showRemote {
                return (remote, artKey.isEmpty ? "remote:none" : "remote:\(artKey)")
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
            if MediaClient.resembles(image, icon) {
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
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            return nil
        }
        let host = (url.host ?? "").lowercased()
        let allowed = host.contains("ytimg.com")
            || host.contains("ggpht.com")
            || host.contains("googleusercontent.com")
            || host.contains("youtube.com")
        guard allowed, let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            return nil
        }
        return image
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
        allowStaleDocumentTitle: Bool = false
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
            guard YouTubeTabPicker.chromeTabCanBindToNowPlaying(
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
            guard snap.title == title, snap.bundleIdentifier == bundleID else { return }
            snap.sourceURL = sourceURL
            snap.sourcePageTitle = tab.title
            snap.sourceTab = tab
            snap.isPlaying = self.activeIsPlaying
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
        sourceURL: String
    ) {
        posterFetchGeneration += 1
        let generation = posterFetchGeneration
        posterQueue.async { [weak self] in
            var id = videoID
            var poster = id.flatMap { self?.youtubePosterImage(videoID: $0) }
            var artKey = id.map { "ytimg:\($0)" } ?? ""
            if poster == nil, url.contains("music.youtube.com"), let self {
                let probe = BrowserMediaNavigator.probeYouTubeMusicPlayback(
                    on: tab,
                    bundleID: bundleID
                )
                if id == nil { id = probe?.videoID }
                if poster == nil, let found = id {
                    poster = self.youtubePosterImage(videoID: found)
                    artKey = "ytimg:\(found)"
                }
                if poster == nil, let artURL = probe?.artworkURL {
                    poster = self.imageFromRemoteArtworkURL(artURL)
                    if artKey.isEmpty { artKey = "ytmimg:\(artURL.prefix(64))" }
                }
            }
            guard let poster, let self else { return }
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
                    guard snap.title == title, snap.bundleIdentifier == bundleID else { return }
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
            let staleOK = allowStaleDocumentTitle
                && tabPlatform == .youtube
                && YouTubeTabPicker.isGenericYouTubeDocumentTitle(candidate.title)
            guard YouTubeTabPicker.cachedFamilyTabCanServeNowPlaying(
                tabTitle: candidate.title,
                tabURL: candidate.url,
                nowPlayingTitle: title,
                allowStaleDocumentTitle: staleOK
            ) else {
                return false
            }
            guard applyYouTubePoster(
                from: candidate.url,
                title: title,
                bundleID: bundleID,
                appName: appName,
                artist: artist,
                tab: candidate,
                allowStaleDocumentTitle: staleOK
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
        let titleHint = StreamingPlatform.titleHint(
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title
        )
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
        if let active = BrowserMediaNavigator.activeTab(bundleID: bundleID) {
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

        let urlPlatform = StreamingPlatform.from(url: tab.url)
        let tabPlatform = urlPlatform ?? hinted
        let sourcePageTitle = BrowserMediaNavigator.playbackTitle(
            on: tab,
            platform: tabPlatform,
            bundleID: bundleID
        ) ?? tab.title
        let pickedMusic = urlPlatform == .youtubeMusic
        let pickedTitle = YouTubeTabPicker.titlesMatchSameTrack(tab.title, title)
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
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.snapshot
            guard snap.title == title, snap.bundleIdentifier == bundleID else { return }
            snap.sourceURL = tab.url
            snap.sourcePageTitle = sourcePageTitle
            snap.sourceTab = tab
            snap.isPlaying = self.activeIsPlaying
            self.snapshot = snap
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
                sourceURL: lastMediaSourceURL.isEmpty ? tab.url : lastMediaSourceURL
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

    private func trySilentBrowserPlayPause() -> Bool {
        return runJavaScriptOnCachedBrowserTab(BrowserMediaNavigator.playPauseJavaScript)
    }

    private func trySilentBrowserSeek(to seconds: TimeInterval) -> Bool {
        return runJavaScriptOnCachedBrowserTab(BrowserMediaNavigator.seekJavaScript(to: seconds))
    }

    private func runJavaScriptOnCachedBrowserTab(_ javascript: String) -> Bool {
        guard let tab = lastMediaSourceTab ?? snapshot.sourceTab else { return false }
        switch BrowserMediaNavigator.executeJavaScript(
            javascript,
            on: tab,
            bundleID: activeBundleID
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

    /// MediaRemote often keeps a paused Chrome tab as Now Playing after Spotify
    /// starts. Poll Spotify directly in that case so the island can switch.
    private func probeNativeSpotifyIfNeeded() {
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
        guard isBrowserBundle(activeBundleID), let tab = lastMediaSourceTab else { return }
        let now = Date().timeIntervalSince1970
        guard now >= ignoreHTMLProbeUntil else { return }
        guard now - lastHTMLPlaybackProbeAt >= Self.htmlPlaybackProbeInterval else { return }
        guard !htmlProbeInFlight else { return }
        guard !isSourceResolveInFlight() else { return }
        lastHTMLPlaybackProbeAt = now
        htmlProbeInFlight = true
        let bundleID = activeBundleID
        AppleScriptRunLoop.media.async { [weak self] in
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
                    if Date().timeIntervalSince1970 < self.ignoreHTMLProbeUntil { return }
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

    /// Advance YouTube without bringing the browser to the front.
    /// Uses Chrome AppleScript JavaScript (`nextVideo` / `previousVideo`).
    /// If needed, enables View → Developer → Allow JavaScript from Apple Events
    /// once (briefly), then restores the previous frontmost app.
    private func sendYouTubePlaylistKey(next: Bool) {
        switch trySilentYouTubeJavaScript(next: next) {
        case .ok:
            return
        case .needsPermission:
            if ensureChromeJavaScriptFromAppleEventsEnabled() {
                Thread.sleep(forTimeInterval: 0.25)
                if case .ok = trySilentYouTubeJavaScript(next: next) {
                    return
                }
            }
            showChromeJavaScriptHintIfNeeded()
        case .failed:
            NSLog("[NowPlaying] YouTube next/prev failed (no tab/player)")
        }
    }

    private enum YouTubeJSResult {
        case ok
        case needsPermission
        case failed
    }

    /// Pause/play the Now Playing tab only — never the first YouTube tab in Chrome.
    private func trySilentYouTubePlayPause(shouldPause: Bool) -> YouTubeJSResult {
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
            return runSilentBrowserMediaJavaScript(musicJS: musicJS, watchJS: watchJS, bias: .pause)
        }

        let musicJS = """
        (() => {
          const v = document.querySelector('#song-video video');
          const btn = document.querySelector('#play-pause-button');
          const label = ((btn && (btn.getAttribute('aria-label') || btn.getAttribute('title'))) || '').toLowerCase();
          if (v && v.paused) {
            const p = v.play();
            if (p && typeof p.catch === 'function') p.catch(function(){});
            return 'ytm-played';
          }
          if (btn && label.indexOf('play') !== -1) { btn.click(); return 'ytm-btn-play'; }
          return 'already-playing';
        })()
        """
        let watchJS = """
        (() => {
          const p = document.querySelector('#movie_player, .html5-video-player');
          const v = document.querySelector('#movie_player video.html5-main-video, #movie_player video, video.html5-main-video');
          const state = p && typeof p.getPlayerState === 'function' ? p.getPlayerState() : null;
          if (v && v.paused) {
            const pr = v.play();
            if (pr && typeof pr.catch === 'function') pr.catch(function(){});
            return 'played-video';
          }
          if (state !== 1 && p && typeof p.playVideo === 'function') { p.playVideo(); return 'played-api'; }
          return 'already-playing';
        })()
        """
        return runSilentBrowserMediaJavaScript(musicJS: musicJS, watchJS: watchJS, bias: .play)
    }

    private func trySilentYouTubeSeek(to seconds: TimeInterval) -> YouTubeJSResult {
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
            return 'seekTo';
          }
          const v = document.querySelector('video');
          if (!v) return 'no-video';
          const dur = Number.isFinite(v.duration) ? v.duration : seconds;
          v.currentTime = Math.min(Math.max(0, seconds), Math.max(dur - 0.05, 0));
          return 'video';
        })()
        """
        return runSilentBrowserMediaJavaScript(musicJS: musicJS, watchJS: watchJS, bias: .sameSession)
    }

    /// Next/prev — YouTube Music player-bar buttons first, then classic YouTube.
    private func trySilentYouTubeJavaScript(next: Bool) -> YouTubeJSResult {
        let musicJS: String
        let watchJS: String
        if next {
            musicJS = """
            (() => {
              const b = document.querySelector('.next-button, ytmusic-player-bar .next-button');
              if (b) { b.click(); return 'ytm-next'; }
              return 'no-player';
            })()
            """
            watchJS = """
            (() => {
              const p = document.querySelector('#movie_player, .html5-video-player');
              if (p && typeof p.nextVideo === 'function') { p.nextVideo(); return 'api'; }
              const b = document.querySelector('.ytp-next-button');
              if (b) { b.click(); return 'click'; }
              return 'no-player';
            })()
            """
        } else {
            musicJS = """
            (() => {
              const b = document.querySelector('.previous-button, ytmusic-player-bar .previous-button');
              if (!b) return 'no-player';
              const v = document.querySelector('#song-video video, video');
              // Mid-track: YT Music prev often restarts; seek to 0 then prev again.
              if (v && v.currentTime > 2.5) {
                v.currentTime = 0;
                setTimeout(() => { try { b.click(); } catch (e) {} }, 120);
                return 'ytm-seek-then-prev';
              }
              b.click();
              return 'ytm-prev';
            })()
            """
            watchJS = """
            (() => {
              const p = document.querySelector('#movie_player, .html5-video-player');
              if (p && typeof p.previousVideo === 'function') { p.previousVideo(); return 'api'; }
              const b = document.querySelector('.ytp-prev-button');
              const disabled = !b || b.getAttribute('aria-disabled') === 'true';
              const v = document.querySelector('video');
              if (!disabled && b) {
                if (v && v.currentTime > 2.5) {
                  v.currentTime = 0;
                  setTimeout(() => { try { b.click(); } catch (e) {} }, 120);
                  return 'seek-then-click';
                }
                b.click();
                return 'click';
              }
              if (history.length > 1) { history.back(); return 'history-back'; }
              return 'no-player';
            })()
            """
        }
        return runSilentBrowserMediaJavaScript(musicJS: musicJS, watchJS: watchJS, bias: .sameSession)
    }

    /// Runs JS only on the YouTube tab that matches Now Playing (or the last
    /// tab we controlled). Never the first watch/Music tab in Chrome.
    private func runSilentBrowserMediaJavaScript(
        musicJS: String,
        watchJS: String,
        bias: YouTubeTabPicker.Bias
    ) -> YouTubeJSResult {
        let tab = lastMediaSourceTab ?? snapshot.sourceTab
        if let tab {
            let js = tab.url.contains("music.youtube.com") ? musicJS : watchJS
            switch BrowserMediaNavigator.executeJavaScript(
                js,
                on: tab,
                bundleID: activeBundleID
            ) {
            case .success:
                lastYouTubeControlURL = tab.url
                return .ok
            case .needsPermission:
                return .needsPermission
            case .failed, .missingTab:
                break
            }
        }
        // A full YouTube tab scan runs JS in every watch/Music tab and blocked
        // skip/play for seconds. Cached-tab failure falls through to MediaRemote.
        NSLog("[NowPlaying] YouTube JS missed cached tab; skipping full tab scan")
        return .failed
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
