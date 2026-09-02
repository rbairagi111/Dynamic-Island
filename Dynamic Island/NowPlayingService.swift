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

    private let mediaQueue = DispatchQueue(label: "island.mediaremote", qos: .userInitiated)
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
    /// Last browser tab URL that matched this Now Playing session (any platform).
    private var lastMediaSourceURL: String = ""
    private var lastMediaSourcePageTitle: String = ""
    private var lastMediaSourceTab: BrowserMediaNavigator.Tab?
    private var lastListedIdentity: String = ""
    private var lastBrowserScanAt: TimeInterval = 0
    /// In-tab HTML5 pause/play. Chrome MediaRemote often never sends pause for
    /// browser video, so the simulated waveform kept running.
    private var htmlPlaybackOverride: Bool?
    private var lastHTMLPlaybackProbeAt: TimeInterval = 0
    private static let htmlPlaybackProbeInterval: TimeInterval = 1.0

    private var listenerProcess: Process?
    private var listenerStdin: Pipe?
    private var listenerBuffer = Data()
    private var elapsedTicker: DispatchSourceTimer?
    private var lastElapsedWallTime: TimeInterval?
    private var listenerRestartScheduled = false
    private var revealInFlight = false

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
        BrowserMediaNavigator.activateApplication(bundleID: snap.bundleIdentifier)
        guard MediaClient.isBrowserBundle(snap.bundleIdentifier) else { return }
        guard !revealInFlight else { return }
        revealInFlight = true
        let bundleID = snap.bundleIdentifier
        let tab = snap.sourceTab
        let url = snap.sourceURL
        AppleScriptRunLoop.shared.async { [weak self] in
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
                // Only touch the YouTube tab — never media keys (those can
                // wake a different app's session).
                let wasPlaying = self.activeIsPlaying
                var applied = false
                switch self.trySilentYouTubePlayPause() {
                case .ok:
                    applied = true
                case .needsPermission:
                    if self.ensureChromeJavaScriptFromAppleEventsEnabled() {
                        Thread.sleep(forTimeInterval: 0.25)
                        if case .ok = self.trySilentYouTubePlayPause() {
                            applied = true
                        }
                    }
                case .failed:
                    // Pause via MediaRemote is scoped to Now Playing. Play is not —
                    // Chrome often resumes a different tab's session.
                    if wasPlaying {
                        self.runAdapterCommand("pause")
                        applied = true
                    } else {
                        NSLog("[NowPlaying] skip MediaRemote play; no matching YouTube tab")
                    }
                }
                if applied {
                    self.publishOptimisticPlaying(!wasPlaying)
                }

            case .browserMedia:
                if !self.trySilentBrowserPlayPause() {
                    self.runAdapterCommand(self.activeIsPlaying ? "pause" : "play")
                }
                self.publishOptimisticPlaying(!self.activeIsPlaying)

            case .nativeMediaRemote:
                // Explicit play/pause — never media keys, never YouTube JS.
                if self.activeIsPlaying {
                    self.runAdapterCommand("pause")
                } else {
                    self.runAdapterCommand("play")
                }
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
            sendYouTubePlaylistKey(next: true)
        case .browserMedia:
            seekBrowserVideo(by: 10)
        case .nativeMediaRemote:
            runAdapterCommand("next_track")
        }
    }

    private func goPrevious() {
        let target = controlTarget
        NSLog("[NowPlaying] previous target=%@ bundle=%@", target.logName, activeBundleID)

        switch target {
        case .youtubeBrowser:
            sendYouTubePlaylistKey(next: false)
        case .browserMedia:
            seekBrowserVideo(by: -10)
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
            clearNowPlaying()
            return
        }

        do {
            let envelope = try JSONDecoder().decode(AdapterEnvelope.self, from: trimmed)
            guard let payload = envelope.payload, let title = payload.title, !title.isEmpty else {
                clearNowPlaying()
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
        lastMediaSourceURL = ""
        lastMediaSourcePageTitle = ""
        lastMediaSourceTab = nil
        lastListedIdentity = ""
        lastBrowserScanAt = 0
        htmlPlaybackOverride = nil
        lastHTMLPlaybackProbeAt = 0
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
                artwork = nil
                lastArtwork = nil
                lastArtworkKey = ""
            }
        }

        activeBundleID = bundleID
        activeIsPlaying = isPlaying
        activeDuration = max(0, duration)
        activeElapsed = max(0, elapsed)
        activeTitle = title
        activeArtist = artist
        activeAppName = appName
        lastElapsedWallTime = Date().timeIntervalSince1970

        let identity = "\(bundleID)|\(title)|\(artist)"
        let now = Date().timeIntervalSince1970
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
        let shouldScanBrowser = isBrowserBundle(bundleID)
            && (
                identity != lastListedIdentity
                    || (
                        (lastMediaSourceURL.isEmpty || needsOTTContentTitle)
                            && now - lastBrowserScanAt >= 2
                    )
            )
        if identity != lastListedIdentity {
            lastListedIdentity = identity
            lastMediaSourceURL = ""
            lastMediaSourcePageTitle = ""
            lastMediaSourceTab = nil
        }
        if shouldScanBrowser {
            lastBrowserScanAt = now
            let remote = artwork
            let key = artKey
            mediaQueue.async { [weak self] in
                self?.resolveBrowserSourceIfNeeded(
                    title: title,
                    artist: artist,
                    bundleID: bundleID,
                    appName: appName,
                    remoteArtwork: remote,
                    artKey: key
                )
            }
        }

        let prepared = preparedArtwork(
            remote: artwork,
            artKey: artKey,
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title,
            url: lastMediaSourceURL
        )

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
            sourceURL: lastMediaSourceURL.isEmpty ? lastYouTubeControlURL : lastMediaSourceURL,
            sourcePageTitle: lastMediaSourcePageTitle,
            sourceTab: lastMediaSourceTab,
            artworkToken: prepared.token
        )

        DispatchQueue.main.async {
            self.snapshot = next
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
        let useLogo = MediaArtworkPolicy.shouldUsePlatformLogo(
            hasArtwork: remote != nil,
            longestPixelSide: MediaClient.longestPixelSide(of: remote),
            resemblesBrowserIcon: resemblesBrowser,
            isBrowser: isBrowser,
            platform: platform
        )
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

    private func resolveBrowserSourceIfNeeded(
        title: String,
        artist: String,
        bundleID: String,
        appName: String,
        remoteArtwork: NSImage?,
        artKey: String
    ) {
        // Title/artist already captured; listing tabs is AppleScript — keep it off the UI thread.
        let tabs = BrowserMediaNavigator.listTabs(bundleID: bundleID)
        let hinted = StreamingPlatform.resolve(
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title,
            url: lastMediaSourceURL
        )
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

        let sourcePageTitle = BrowserMediaNavigator.playbackTitle(
            on: tab,
            platform: hinted ?? StreamingPlatform.from(url: tab.url),
            bundleID: bundleID
        ) ?? tab.title
        lastMediaSourceURL = tab.url
        lastMediaSourcePageTitle = sourcePageTitle
        lastMediaSourceTab = tab
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
        }
        let prepared = preparedArtwork(
            remote: remoteArtwork,
            artKey: artKey,
            bundleID: bundleID,
            appName: appName,
            artist: artist,
            title: title,
            url: tab.url
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.snapshot
            guard snap.title == title, snap.bundleIdentifier == bundleID else { return }
            snap.sourceURL = tab.url
            snap.sourcePageTitle = sourcePageTitle
            snap.sourceTab = tab
            snap.artwork = prepared.image
            snap.artworkToken = prepared.token
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
        let javascript = """
        (() => {
          const media = Array.from(document.querySelectorAll('video, audio'));
          const player = media.find(m => !m.paused) || media.find(m => m.readyState > 0) || media[0];
          if (!player) return 'no-player';
          if (player.paused) {
            const request = player.play();
            if (request && typeof request.catch === 'function') request.catch(function(){});
            return 'played';
          }
          player.pause();
          return 'paused';
        })()
        """
        return runJavaScriptOnCachedBrowserTab(javascript)
    }

    private func trySilentBrowserSeek(to seconds: TimeInterval) -> Bool {
        let safe = String(format: "%.3f", seconds)
        let javascript = """
        (() => {
          const seconds = \(safe);
          const media = Array.from(document.querySelectorAll('video, audio'));
          const player = media.find(m => !m.paused) || media.find(m => m.readyState > 0) || media[0];
          if (!player) return 'no-player';
          const duration = Number.isFinite(player.duration) ? player.duration : seconds;
          player.currentTime = Math.min(Math.max(0, seconds), Math.max(duration - 0.05, 0));
          return 'seeked';
        })()
        """
        return runJavaScriptOnCachedBrowserTab(javascript)
    }

    private func runJavaScriptOnCachedBrowserTab(_ javascript: String) -> Bool {
        guard let tab = lastMediaSourceTab else { return false }
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
        case .failed:
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
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.snapshot
            snap.isPlaying = playing
            self.snapshot = snap
        }
    }

    /// Chrome often leaves MediaRemote on "playing" after the page pauses.
    /// Sample the matched tab's real video/audio so the waveform can freeze.
    private func probeBrowserPlaybackIfNeeded() {
        guard isBrowserBundle(activeBundleID), let tab = lastMediaSourceTab else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastHTMLPlaybackProbeAt >= Self.htmlPlaybackProbeInterval else { return }
        lastHTMLPlaybackProbeAt = now
        guard let playing = BrowserMediaNavigator.probePlaybackPlaying(
            on: tab,
            bundleID: activeBundleID
        ) else {
            return
        }
        htmlPlaybackOverride = playing
        guard playing != activeIsPlaying else { return }
        NSLog(
            "[NowPlaying] HTML playback %@ (MediaRemote was %@)",
            playing ? "playing" : "paused",
            activeIsPlaying ? "playing" : "paused"
        )
        publishOptimisticPlaying(playing)
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
    private func trySilentYouTubePlayPause() -> YouTubeJSResult {
        if activeIsPlaying {
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
        switch listYouTubeMediaTabs() {
        case .needsPermission:
            return .needsPermission
        case .failed:
            return .failed
        case .ok(let tabs):
            guard let tab = YouTubeTabPicker.pick(
                from: tabs,
                nowPlayingTitle: activeTitle,
                nowPlayingArtist: activeArtist,
                preferredURL: lastYouTubeControlURL,
                bias: bias
            ) else {
                NSLog(
                    "[NowPlaying] no matching YouTube tab title='%@' url='%@' tabs=%d",
                    activeTitle,
                    lastYouTubeControlURL,
                    tabs.count
                )
                return .failed
            }
            let js = tab.url.contains("music.youtube.com") ? musicJS : watchJS
            let result = executeJavaScript(js, onTabURL: tab.url)
            if result == .ok {
                lastYouTubeControlURL = tab.url
                NSLog(
                    "[NowPlaying] YouTube control url=%@ title='%@' paused=%@ bias=%@",
                    tab.url,
                    tab.playerTitle,
                    tab.paused ? "YES" : "NO",
                    String(describing: bias)
                )
            }
            return result
        }
    }

    private enum TabListResult {
        case ok([YouTubeTabPicker.Tab])
        case needsPermission
        case failed
    }

    private func listYouTubeMediaTabs() -> TabListResult {
        let appName = browserAppleScriptName(for: activeBundleID)
        let probeJS = appleScriptEscape("""
        (() => {
          const pick = (s) => (s || '').split('|').join(' ').split(String.fromCharCode(9)).join(' ').trim();
          const music = location.hostname.indexOf('music.youtube') !== -1;
          let title = '';
          let artist = '';
          let paused = true;
          if (music) {
            const tEl = document.querySelector('yt-formatted-string.title.ytmusic-player-bar, .title.ytmusic-player-bar');
            const aEl = document.querySelector('yt-formatted-string.byline.ytmusic-player-bar, .byline.ytmusic-player-bar');
            title = pick(tEl && tEl.textContent);
            artist = pick(aEl && aEl.textContent);
            const v = document.querySelector('#song-video video');
            const btn = document.querySelector('#play-pause-button');
            if (v) paused = v.paused;
            else if (btn) {
              const label = (btn.getAttribute('aria-label') || btn.getAttribute('title') || '').toLowerCase();
              paused = label.indexOf('play') !== -1;
            }
          } else {
            const tEl = document.querySelector('h1.ytd-watch-metadata yt-formatted-string, .ytp-title-link');
            title = pick((tEl && tEl.textContent) || document.title.replace(' - YouTube', ''));
            const p = document.querySelector('#movie_player, .html5-video-player');
            const v = document.querySelector('#movie_player video.html5-main-video, #movie_player video, video.html5-main-video');
            const state = p && typeof p.getPlayerState === 'function' ? p.getPlayerState() : null;
            if (state === 1) paused = false;
            else if (state === 2 || state === 0) paused = true;
            else if (v) paused = v.paused;
          }
          return (paused ? '1' : '0') + '|' + title + '|' + artist;
        })()
        """)

        let script = """
        tell application "\(appName)"
          set out to ""
          repeat with w in windows
            repeat with t in tabs of w
              set u to URL of t
              if u contains "music.youtube.com" or u contains "youtube.com/watch" or u contains "youtu.be/" or u contains "youtube.com/shorts" then
                try
                  set info to execute t javascript "\(probeJS)"
                  set out to out & u & "\t" & info & linefeed
                on error errMsg
                  if errMsg contains "JavaScript" or errMsg contains "javascript" then
                    return "err:" & errMsg
                  end if
                end try
              end if
            end repeat
          end repeat
          if out is "" then return "no-tab"
          return out
        end tell
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return .failed }
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            let message = String(describing: error[NSAppleScript.errorMessage] ?? error)
            NSLog("[NowPlaying] tab list unavailable: %@", message)
            return message.localizedCaseInsensitiveContains("javascript") ? .needsPermission : .failed
        }
        let value = result.stringValue ?? ""
        if value.hasPrefix("err:") {
            return value.localizedCaseInsensitiveContains("javascript") ? .needsPermission : .failed
        }
        if value == "no-tab" || value.isEmpty {
            return .failed
        }

        var tabs: [YouTubeTabPicker.Tab] = []
        for line in value.components(separatedBy: .newlines) where !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let url = String(parts[0])
            let probe = String(parts[1]).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard probe.count >= 1 else { continue }
            let paused = probe[0] == "1"
            let title = probe.count > 1 ? String(probe[1]) : ""
            let artist = probe.count > 2 ? String(probe[2]) : ""
            tabs.append(
                YouTubeTabPicker.Tab(
                    tabID: tabs.count,
                    url: url,
                    playerTitle: title,
                    playerArtist: artist,
                    paused: paused
                )
            )
        }
        return tabs.isEmpty ? .failed : .ok(tabs)
    }

    private func executeJavaScript(_ js: String, onTabURL url: String) -> YouTubeJSResult {
        let appName = browserAppleScriptName(for: activeBundleID)
        let escapedJS = appleScriptEscape(js)
        let escapedURL = appleScriptEscape(url)
        let token = appleScriptEscape(youtubeURLToken(url))
        let script = """
        tell application "\(appName)"
          repeat with w in windows
            repeat with t in tabs of w
              set u to URL of t
              if u is "\(escapedURL)" or ("\(token)" is not "" and u contains "\(token)") then
                try
                  set r to execute t javascript "\(escapedJS)"
                  return r
                on error errMsg
                  return "err:" & errMsg
                end try
              end if
            end repeat
          end repeat
          return "no-tab"
        end tell
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return .failed }
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            let message = String(describing: error[NSAppleScript.errorMessage] ?? error)
            NSLog("[NowPlaying] silent JS unavailable: %@", message)
            return message.localizedCaseInsensitiveContains("javascript") ? .needsPermission : .failed
        }
        let value = result.stringValue ?? ""
        NSLog("[NowPlaying] silent JS result=%@", value)
        if value.hasPrefix("err:") {
            return value.localizedCaseInsensitiveContains("javascript") ? .needsPermission : .failed
        }
        if value == "no-tab" || value == "no-player" || value == "no-video" {
            return .failed
        }
        return .ok
    }

    private func youtubeURLToken(_ url: String) -> String {
        guard let components = URLComponents(string: url) else { return url }
        if let id = components.queryItems?.first(where: { $0.name == "v" })?.value, !id.isEmpty {
            return "v=\(id)"
        }
        return url
    }

    private func appleScriptEscape(_ js: String) -> String {
        js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
