import AppKit
import Foundation

/// Lists browser tabs (title + URL only — no page JS) and brings the Now Playing
/// tab to the front. Separate from Chrome chat polling.
enum BrowserMediaNavigator {
    struct Tab: Equatable {
        var windowIndex: Int
        var tabIndex: Int
        var tabID: Int
        var title: String
        var url: String
    }

    static func appleScriptName(for bundleID: String) -> String {
        let id = bundleID.lowercased()
        if id.contains("safari") { return "Safari" }
        if id.contains("brave") { return "Brave Browser" }
        if id.contains("edgemac") { return "Microsoft Edge" }
        if id.contains("thebrowser") { return "Arc" }
        if id.contains("firefox") { return "Firefox" }
        return "Google Chrome"
    }

    static func pick(
        from tabs: [Tab],
        nowPlayingTitle: String,
        nowPlayingArtist: String,
        preferredURL: String,
        platform: StreamingPlatform?
    ) -> Tab? {
        guard !tabs.isEmpty else { return nil }
        let ranked = tabs.map { tab in
            (
                tab: tab,
                score: score(
                    tab,
                    nowPlayingTitle: nowPlayingTitle,
                    nowPlayingArtist: nowPlayingArtist,
                    preferredURL: preferredURL,
                    platform: platform
                )
            )
        }
        .sorted { $0.score > $1.score }

        guard ranked.contains(where: { $0.score >= 20 }) else { return nil }
        if let titled = ranked.first(where: {
            $0.score >= 20
                && YouTubeTabPicker.titlesMatchSameTrack($0.tab.title, nowPlayingTitle)
                && StreamingPlatform.from(url: $0.tab.url) != nil
                && StreamingPlatform.sourceURLCompatible($0.tab.url, withTitleHint: platform)
        }) {
            return titled.tab
        }
        let watchPlayback = ranked.first {
            $0.score >= 20
                && StreamingPlatform.from(url: $0.tab.url) == .youtube
                && YouTubeTabPicker.chromeTabCanBindToNowPlaying(
                    tabTitle: $0.tab.title,
                    tabURL: $0.tab.url,
                    nowPlayingTitle: nowPlayingTitle
                )
        }?.tab
        // Stale named youtube.com/watch must not beat Music. A generic watch
        // tab *can* bind (new video); prefer it over paused Music home.
        if let music = ranked.first(where: {
            $0.score >= 20
                && StreamingPlatform.from(url: $0.tab.url) == .youtubeMusic
                && StreamingPlatform.sourceURLCompatible($0.tab.url, withTitleHint: platform)
        }) {
            if let watchPlayback {
                return watchPlayback
            }
            return music.tab
        }
        if let watchPlayback {
            return watchPlayback
        }
        return ranked.first { $0.score >= 20 }?.tab
    }

    static func score(
        _ tab: Tab,
        nowPlayingTitle: String,
        nowPlayingArtist: String,
        preferredURL: String,
        platform: StreamingPlatform?
    ) -> Int {
        var value = 0
        let tabPlatform = StreamingPlatform.from(url: tab.url)
        if let platform, let tabPlatform, !StreamingPlatform.isSameFamily(platform, tabPlatform) {
            return 0
        }
        if YouTubeTabPicker.titlesMatch(tab.title, nowPlayingTitle) {
            value += 100
        } else if tabPlatform != nil,
                  YouTubeTabPicker.titlesMatch(tab.url, nowPlayingTitle) {
            value += 100
        }
        if YouTubeTabPicker.titlesMatch(tab.title, nowPlayingArtist) {
            value += 15
        }
        if !preferredURL.isEmpty,
           YouTubeTabPicker.urlsMatch(tab.url, preferredURL),
           YouTubeTabPicker.tabMatchesNowPlaying(
            tabTitle: tab.title,
            nowPlayingTitle: nowPlayingTitle,
            nowPlayingArtist: nowPlayingArtist
           ) {
            value += 80
        }
        if let platform, tabPlatform == platform {
            value += 40
        } else if tabPlatform != nil {
            value += 10
        }
        if isLikelyPlaybackURL(tab.url, platform: tabPlatform) {
            value += 30
        }
        return value
    }

    /// Streaming tabs frequently keep a generic page title while playing.
    /// A watch/detail URL is stronger evidence than a provider home page.
    static func isLikelyPlaybackURL(_ rawURL: String, platform: StreamingPlatform?) -> Bool {
        guard platform != nil, let components = URLComponents(string: rawURL) else {
            return false
        }
        let path = components.path.lowercased()
        let query = components.query?.lowercased() ?? ""
        switch platform {
        case .primeVideo:
            return path.contains("/detail/") || path.contains("/gp/video/")
                || path.contains("/video/detail/")
        case .netflix:
            return path.contains("/watch/")
        case .jioHotstar, .disneyPlus, .hulu, .max, .crunchyroll, .sonyliv, .zee5:
            return path.contains("/watch") || path.contains("/play")
                || path.contains("/movies/") || path.contains("/shows/")
        case .youtube, .youtubeMusic:
            // YouTube Music keeps `https://music.youtube.com/` while a track
            // plays in the SPA player; that is still the playback surface.
            if platform == .youtubeMusic {
                return true
            }
            return path.contains("/watch") || path.contains("/shorts/")
                || query.contains("v=")
        case .spotify, .appleMusic, .appleTV, .twitch, .jioSaavn, .soundcloud, .vimeo, .plex:
            return path.split(separator: "/").count >= 2
        case .none:
            return false
        }
    }

    static func listTabs(bundleID: String) -> [Tab] {
        listTabs(bundleID: bundleID, urlContainsAny: nil)
    }

    /// Same as `listTabs`, but only returns tabs whose URL contains one of the
    /// needles. Cuts AppleScript payload size when hunting dual secondaries.
    static func listTabs(
        bundleID: String,
        urlContainsAny needles: [String]?
    ) -> [Tab] {
        let appName = appleScriptName(for: bundleID)
        if appName == "Firefox" { return [] }
        let script: String
        if appName == "Safari" {
            if let needles, !needles.isEmpty {
                let checks = needles.map { needle in
                    let escaped = appleScriptEscape(needle)
                    return "(u contains \"\(escaped)\")"
                }.joined(separator: " or ")
                script = """
                tell application "Safari"
                  set out to ""
                  repeat with wi from 1 to count of windows
                    repeat with ti from 1 to count of tabs of window wi
                      try
                        set currentTab to tab ti of window wi
                        set u to (URL of currentTab) as text
                        if \(checks) then
                          set out to out & wi & "\t" & ti & "\t" & "0" & "\t" & (name of currentTab) & "\t" & u & linefeed
                        end if
                      end try
                    end repeat
                  end repeat
                  return out
                end tell
                """
            } else {
                script = """
                tell application "Safari"
                  set out to ""
                  repeat with wi from 1 to count of windows
                    repeat with ti from 1 to count of tabs of window wi
                      try
                        set currentTab to tab ti of window wi
                        set out to out & wi & "\t" & ti & "\t" & "0" & "\t" & (name of currentTab) & "\t" & (URL of currentTab) & linefeed
                      end try
                    end repeat
                  end repeat
                  return out
                end tell
                """
            }
        } else if let needles, !needles.isEmpty {
            let checks = needles.map { needle in
                let escaped = appleScriptEscape(needle)
                return "(u contains \"\(escaped)\")"
            }.joined(separator: " or ")
            script = """
            tell application "\(appName)"
              set out to ""
              repeat with wi from 1 to count of windows
                repeat with ti from 1 to count of tabs of window wi
                  try
                    set currentTab to tab ti of window wi
                    set u to (URL of currentTab) as text
                    if \(checks) then
                      set out to out & wi & "\t" & ti & "\t" & ((id of currentTab) as text) & "\t" & (title of currentTab) & "\t" & u & linefeed
                    end if
                  end try
                end repeat
              end repeat
              return out
            end tell
            """
        } else {
            script = """
            tell application "\(appName)"
              set out to ""
              repeat with wi from 1 to count of windows
                repeat with ti from 1 to count of tabs of window wi
                  try
                    set currentTab to tab ti of window wi
                    set out to out & wi & "\t" & ti & "\t" & ((id of currentTab) as text) & "\t" & (title of currentTab) & "\t" & (URL of currentTab) & linefeed
                  end try
                end repeat
              end repeat
              return out
            end tell
            """
        }
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return [] }
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            NSLog("[BrowserMedia] tab scan failed app=%@ error=%@", appName, String(describing: error))
            return []
        }
        let tabs = parseTabList(result.stringValue ?? "")
        NSLog("[BrowserMedia] scanned app=%@ tabs=%d filtered=%@", appName, tabs.count, needles == nil ? "no" : "yes")
        return tabs
    }

    /// Hosts we care about for dual Now Playing secondary discovery.
    static var streamingURLNeedles: [String] {
        [
            "youtube.com", "youtu.be", "music.youtube.com",
            "netflix.com", "spotify.com", "primevideo.com", "amazon.com",
            "disneyplus.com", "hotstar.com", "hulu.com", "max.com",
            "twitch.tv", "soundcloud.com", "jiosaavn.com", "music.apple.com",
            "tv.apple.com", "crunchyroll.com", "sonyliv.com", "zee5.com",
            "vimeo.com", "plex.tv"
        ]
    }

    /// Front window's selected tab only — used to load a YouTube poster without
    /// waiting for a full tab listing.
    static func activeTab(bundleID: String) -> Tab? {
        let appName = appleScriptName(for: bundleID)
        if appName == "Firefox" { return nil }
        let script: String
        if appName == "Safari" {
            script = """
            tell application "Safari"
              if (count of windows) is 0 then return ""
              set w to window 1
              set currentTab to current tab of w
              return "1" & "\t" & (index of currentTab as text) & "\t" & "0" & "\t" & (name of currentTab) & "\t" & (URL of currentTab)
            end tell
            """
        } else {
            script = """
            tell application "\(appName)"
              if (count of windows) is 0 then return ""
              set bestIdx to 999999
              set frontW to 1
              set frontT to 1
              repeat with w from 1 to count of windows
                try
                  set widx to index of window w
                  if widx < bestIdx then
                    set bestIdx to widx
                    set frontW to w
                    set frontT to active tab index of window w
                  end if
                end try
              end repeat
              set currentTab to tab frontT of window frontW
              return (frontW as text) & "\t" & (frontT as text) & "\t" & ((id of currentTab) as text) & "\t" & (title of currentTab) & "\t" & (URL of currentTab)
            end tell
            """
        }
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        let result = appleScript.executeAndReturnError(&error)
        if error != nil { return nil }
        return parseTabList(result.stringValue ?? "").first
    }

    static func tab(bundleID: String, windowIndex: Int, tabIndex: Int) -> Tab? {
        let appName = appleScriptName(for: bundleID)
        if appName == "Firefox" { return nil }
        let script: String
        if appName == "Safari" {
            script = """
            tell application "Safari"
              if (count of windows) < \(windowIndex) then return ""
              set currentTab to tab \(tabIndex) of window \(windowIndex)
              return "\(windowIndex)" & "\t" & "\(tabIndex)" & "\t" & "0" & "\t" & (name of currentTab) & "\t" & (URL of currentTab)
            end tell
            """
        } else {
            script = """
            tell application "\(appName)"
              if (count of windows) < \(windowIndex) then return ""
              set currentTab to tab \(tabIndex) of window \(windowIndex)
              return "\(windowIndex)" & "\t" & "\(tabIndex)" & "\t" & ((id of currentTab) as text) & "\t" & (title of currentTab) & "\t" & (URL of currentTab)
            end tell
            """
        }
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        let result = appleScript.executeAndReturnError(&error)
        if error != nil { return nil }
        return parseTabList(result.stringValue ?? "").first
    }

    static func parseTabList(_ output: String) -> [Tab] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Tab? in
                let parts = String(line).split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
                guard parts.count >= 5,
                      let windowIndex = Int(parts[0]),
                      let tabIndex = Int(parts[1]) else { return nil }
                return Tab(
                    windowIndex: windowIndex,
                    tabIndex: tabIndex,
                    tabID: Int(parts[2]) ?? 0,
                    title: String(parts[3]),
                    url: String(parts[4])
                )
            }
    }

    enum JavaScriptResult: Equatable {
        case success(String)
        case needsPermission
        case failed
        case missingTab
    }

    static func classifyJavaScriptReturn(_ value: String) -> JavaScriptResult {
        if value.hasPrefix("err:") {
            return value.localizedCaseInsensitiveContains("javascript")
                ? .needsPermission
                : .failed
        }
        if value == "no-tab" {
            return .missingTab
        }
        if value == "no-player" || value == "no-video" {
            return .failed
        }
        return .success(value)
    }

    enum PlaybackProbe: Equatable {
        case playing(Bool)
        case unknown
        case missingTab
    }

    /// True / false when the tab can see a media element or mediaSession.
    /// Nil means unknown — keep the MediaRemote snapshot.
    static func parsePlaybackProbe(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing", "1":
            return true
        case "paused", "0":
            return false
        default:
            return nil
        }
    }

    /// Reads pause from the actual `<video>` / `<audio>` (and same-origin
    /// iframes). MediaRemote for Chrome often stays "playing" after the page
    /// pauses, which is what kept the island waveform animating.
    static func probePlayback(on tab: Tab, bundleID: String) -> PlaybackProbe {
        switch executeJavaScript(playbackProbeJavaScript, on: tab, bundleID: bundleID) {
        case .success(let value):
            if let playing = parsePlaybackProbe(value) { return .playing(playing) }
            return .unknown
        case .needsPermission, .failed:
            return .unknown
        case .missingTab:
            return .missingTab
        }
    }

    static func probePlaybackPlaying(on tab: Tab, bundleID: String) -> Bool? {
        switch probePlayback(on: tab, bundleID: bundleID) {
        case .playing(let playing):
            return playing
        case .unknown, .missingTab:
            return nil
        }
    }

    /// Elapsed / duration from the in-tab player when MediaRemote has none.
    static func probePlaybackTiming(on tab: Tab, bundleID: String) -> (elapsed: TimeInterval, duration: TimeInterval)? {
        switch executeJavaScript(playbackTimingJavaScript, on: tab, bundleID: bundleID) {
        case .success(let value):
            let parts = value.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2,
                  let elapsed = Double(parts[0]),
                  let duration = Double(parts[1]) else { return nil }
            return (max(0, elapsed), max(0, duration))
        case .needsPermission, .failed, .missingTab:
            return nil
        }
    }

    /// Per-tab frequency bands (7 values, `0...1`) from the playing media element.
    /// Nil when the tab has no analyser (paused, missing media, or JS denied).
    /// Independent of system mix — dual Watch + Music each get their own feed.
    static func probeWaveformBands(on tab: Tab, bundleID: String) -> [CGFloat]? {
        switch executeJavaScript(waveformBandsJavaScript, on: tab, bundleID: bundleID) {
        case .success(let value):
            return parseWaveformBands(value)
        case .needsPermission, .failed, .missingTab:
            return nil
        }
    }

    /// `0.12,0.40,...` (7 commas) → normalized bands. Sentinels → nil.
    static func parseWaveformBands(_ raw: String) -> [CGFloat]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty
            || trimmed == "no-wave"
            || trimmed == "idle"
            || trimmed.hasPrefix("err") {
            return nil
        }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == SimulatedWaveformEngine.barCount else { return nil }
        var bands: [CGFloat] = []
        bands.reserveCapacity(parts.count)
        for part in parts {
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            bands.append(CGFloat(min(1, max(0, value))))
        }
        return bands
    }

    private static let playbackTimingJavaScript = """
    (() => {
      const v = document.querySelector('#movie_player video.html5-main-video, #movie_player video, #song-video video, video.html5-main-video, video');
      if (!v) return '0\\t0';
      const elapsed = Number.isFinite(v.currentTime) ? v.currentTime : 0;
      const duration = Number.isFinite(v.duration) ? v.duration : 0;
      return elapsed + '\\t' + duration;
    })()
    """

    /// Installs a per-tab AnalyserNode via `captureStream` (does not steal
    /// `createMediaElementSource`). Returns 7 log-spaced band energies.
    private static let waveformBandsJavaScript = """
    (() => {
      const N = 7;
      const pick = () => {
        const sels = [
          '#movie_player video.html5-main-video',
          '#movie_player video',
          '#song-video video',
          'video.html5-main-video',
          'video',
          'audio'
        ];
        for (let i = 0; i < sels.length; i++) {
          const el = document.querySelector(sels[i]);
          if (el && !el.paused && !el.ended) return el;
        }
        const all = document.querySelectorAll('video, audio');
        for (let i = 0; i < all.length; i++) {
          const m = all[i];
          if (m && !m.paused && !m.ended) return m;
        }
        return null;
      };
      const media = pick();
      if (!media) return 'no-wave';
      try {
        let state = window.__diIslandWave;
        if (!state || state.media !== media) {
          const AC = window.AudioContext || window.webkitAudioContext;
          if (!AC || typeof media.captureStream !== 'function') return 'no-wave';
          const ctx = new AC();
          const stream = media.captureStream();
          if (!stream || !stream.getAudioTracks || stream.getAudioTracks().length === 0) {
            return 'no-wave';
          }
          const src = ctx.createMediaStreamSource(stream);
          const analyser = ctx.createAnalyser();
          analyser.fftSize = 256;
          analyser.smoothingTimeConstant = 0.5;
          src.connect(analyser);
          state = {
            media: media,
            ctx: ctx,
            analyser: analyser,
            data: new Uint8Array(analyser.frequencyBinCount)
          };
          window.__diIslandWave = state;
        }
        if (state.ctx.state === 'suspended') state.ctx.resume();
        state.analyser.getByteFrequencyData(state.data);
        const data = state.data;
        const len = data.length;
        const bands = [];
        for (let i = 0; i < N; i++) {
          const start = Math.floor(Math.pow(i / N, 1.55) * len);
          const end = Math.max(start + 1, Math.floor(Math.pow((i + 1) / N, 1.55) * len));
          let sum = 0;
          let count = 0;
          for (let j = start; j < end && j < len; j++) {
            sum += data[j];
            count++;
          }
          const avg = count > 0 ? sum / count : 0;
          bands.push((avg / 255).toFixed(3));
        }
        return bands.join(',');
      } catch (e) {
        return 'no-wave';
      }
    })()
    """

    private static let playbackProbeJavaScript = """
    (() => {
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
      if (seen.length) {
        for (let i = 0; i < seen.length; i++) {
          const m = seen[i];
          if (m && !m.paused && !m.ended) return 'playing';
        }
        return 'paused';
      }
      const state = (navigator.mediaSession && navigator.mediaSession.playbackState) || '';
      if (state === 'playing') return 'playing';
      if (state === 'paused') return 'paused';
      return 'unknown';
    })()
    """

    /// Next item on YouTube Music — one click, no playlist key simulation.
    static let youtubeMusicNextJavaScript = """
    (() => {
      const b = document.querySelector('#next-button, .next-button, ytmusic-player-bar .next-button, [aria-label="Next"], [title="Next"]');
      if (b) { b.click(); return 'ytm-next'; }
      return 'no-player';
    })()
    """

    /// Previous *item* on YouTube Music. Mid-track, YouTube restarts on the
    /// first click — send a second click in the same turn so one island click
    /// goes to the previous song.
    static let youtubeMusicPreviousJavaScript = """
    (() => {
      const b = document.querySelector('#previous-button, .previous-button, ytmusic-player-bar .previous-button, [aria-label="Previous"], [title="Previous"]');
      const v = document.querySelector('#song-video video, video');
      const nearStart = !v || v.currentTime <= 1.25;
      if (!b) return 'no-player';
      b.click();
      if (!nearStart) b.click();
      return 'ytm-prev';
    })()
    """

    /// Next video on youtube.com. Click the control first — `nextVideo()` is a
    /// no-op on many watch pages that are not an explicit playlist.
    static let youtubeWatchNextJavaScript = """
    (() => {
      const p = document.querySelector('#movie_player, .html5-video-player');
      const b = document.querySelector('a.ytp-next-button, .ytp-next-button');
      const href = (b && (b.href || b.getAttribute('href'))) || '';
      if (href.indexOf('/watch') !== -1) {
        window.location.href = href;
        return 'nav';
      }
      if (p && typeof p.nextVideo === 'function') { p.nextVideo(); return 'api'; }
      if (b) { b.click(); return 'click'; }
      return 'no-player';
    })()
    """

    /// When the watch player has finished and Autoplay is on, start the next video.
    static let youtubeWatchEndedAutoplayJavaScript = """
    (() => {
      const v = document.querySelector('#movie_player video.html5-main-video, #movie_player video, video.html5-main-video, video');
      if (!v) return 'no-video';
      const ended = v.ended || (Number.isFinite(v.duration) && v.duration > 1 && v.currentTime >= v.duration - 0.45);
      if (!ended) return 'not-ended';
      const btn = document.querySelector('.ytp-autonav-toggle-button');
      const checked = btn ? String(btn.getAttribute('aria-checked') || '') : 'true';
      if (btn && checked !== 'true') return 'autoplay-off';
      const next = document.querySelector('.ytp-next-button');
      if (next && next.getAttribute('aria-disabled') !== 'true') { next.click(); return 'click-next'; }
      const p = document.querySelector('#movie_player, .html5-video-player');
      if (p && typeof p.nextVideo === 'function') { p.nextVideo(); return 'api-next'; }
      return 'ended-no-next';
    })()
    """

    static let youtubeMusicEndedAutoplayJavaScript = """
    (() => {
      const v = document.querySelector('#song-video video, video');
      if (!v) return 'no-video';
      const ended = v.ended || (Number.isFinite(v.duration) && v.duration > 1 && v.currentTime >= v.duration - 0.45);
      if (!ended) return 'not-ended';
      const b = document.querySelector('#next-button, .next-button, ytmusic-player-bar .next-button, [aria-label="Next"], [title="Next"]');
      if (b) { b.click(); return 'ytm-next'; }
      return 'ended-no-next';
    })()
    """

    /// Previous video on youtube.com in one click (not restart-then-skip).
    static let youtubeWatchPreviousJavaScript = """
    (() => {
      const p = document.querySelector('#movie_player, .html5-video-player');
      const b = document.querySelector('a.ytp-prev-button, .ytp-prev-button');
      const v = document.querySelector('#movie_player video.html5-main-video, video.html5-main-video, video');
      const nearStart = !v || v.currentTime <= 1.25;
      const href = (b && (b.href || b.getAttribute('href'))) || '';
      if (!nearStart && v) {
        if (p && typeof p.seekTo === 'function') { p.seekTo(0, true); }
        v.currentTime = 0;
        return 'restart';
      }
      if (href.indexOf('/watch') !== -1) {
        window.location.href = href;
        return 'nav';
      }
      if (p && typeof p.previousVideo === 'function') { p.previousVideo(); return 'api'; }
      if (b) {
        b.click();
        return 'click';
      }
      if (history.length > 1) { history.back(); return 'history-back'; }
      return 'no-player';
    })()
    """

    /// Pause/play any in-tab player (Netflix, Prime, Spotify Web, etc.)
    /// without activating the browser. Walks same-origin iframes like the probe.
    static let playPauseJavaScript = """
    (() => {
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
      const player = seen.find(m => m && !m.paused && !m.ended)
        || seen.find(m => m && m.readyState > 0)
        || seen[0];
      if (player) {
        if (player.paused) {
          const request = player.play();
          if (request && typeof request.catch === 'function') request.catch(function(){});
          return 'played';
        }
        player.pause();
        return 'paused';
      }
      const selectors = [
        '[data-uia="control-play-pause-pause"]',
        '[data-uia="control-play-pause-play"]',
        '[data-testid="control-button-playpause"]',
        'button[aria-label*="Pause" i]',
        'button[aria-label*="Play" i]'
      ];
      for (let i = 0; i < selectors.length; i++) {
        const el = document.querySelector(selectors[i]);
        if (el) { el.click(); return 'clicked'; }
      }
      return 'no-player';
    })()
    """

    static func seekJavaScript(to seconds: TimeInterval) -> String {
        let safe = String(format: "%.3f", seconds)
        return """
        (() => {
          const seconds = \(safe);
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
          const player = seen.find(m => m && !m.paused && !m.ended)
            || seen.find(m => m && m.readyState > 0)
            || seen[0];
          if (!player) return 'no-player';
          const duration = Number.isFinite(player.duration) ? player.duration : seconds;
          player.currentTime = Math.min(Math.max(0, seconds), Math.max(duration - 0.05, 0));
          return 'seeked';
        })()
        """
    }

    /// Netflix and some other OTT players publish only the provider name to
    /// MediaRemote. Read the actual programme title from the already-matched
    /// playback tab without activating it.
    static func playbackTitle(
        on tab: Tab,
        platform: StreamingPlatform?,
        bundleID: String
    ) -> String? {
        guard let platform, platform.prefersPageContentTitle else { return nil }
        let aliases = StreamingPlatform.playbackTitleSkipNames(platform)
        let skipJSON = (try? JSONSerialization.data(withJSONObject: aliases)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "[]"
        let javascript = """
        (() => {
          const skip = \(skipJSON).map((name) => String(name).toLowerCase());
          const isGeneric = (value) => {
            const lower = String(value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
            if (!lower) return true;
            if (skip.includes(lower)) return true;
            if (lower.includes('watch movies') || lower.includes('watch tv shows')) return true;
            return false;
          };
          const text = (element) => {
            if (!element) return '';
            const raw = element.content || element.getAttribute?.('content')
              || element.getAttribute?.('aria-label')
              || element.innerText || element.textContent || '';
            return String(raw).split('\\n')[0].replace(/\\s+/g, ' ').trim();
          };
          const selectors = [
            '[data-uia="video-title"] h4',
            'h4[data-uia="video-title"]',
            '[data-uia="video-title"]',
            '.watch-video--bottom-controls-container h4',
            '.video-title h4',
            '.video-title',
            '[class*="video-title"] h4',
            '[data-testid="title"]',
            '[class*="Title"] h1',
            'video[aria-label]',
            'meta[property="og:title"]',
            'meta[name="twitter:title"]',
            'h1'
          ];
          const collect = (root, depth, into) => {
            if (!root || depth > 5) return;
            try {
              const md = (root.defaultView || window).navigator
                && (root.defaultView || window).navigator.mediaSession
                && (root.defaultView || window).navigator.mediaSession.metadata;
              if (md) {
                into.push(md.title);
                into.push(md.album);
                into.push(md.artist);
              }
            } catch (e) {}
            for (let i = 0; i < selectors.length; i++) {
              try {
                const node = root.querySelector(selectors[i]);
                if (node) into.push(text(node));
              } catch (e) {}
            }
            let nodes;
            try { nodes = root.querySelectorAll('*'); } catch (e) { nodes = []; }
            for (let i = 0; i < nodes.length && i < 400; i++) {
              try {
                if (nodes[i].shadowRoot) collect(nodes[i].shadowRoot, depth + 1, into);
              } catch (e) {}
            }
            let frames;
            try { frames = root.querySelectorAll('iframe'); } catch (e) { return; }
            for (let i = 0; i < frames.length; i++) {
              try {
                const doc = frames[i].contentDocument;
                if (doc) collect(doc, depth + 1, into);
              } catch (e) {}
            }
          };
          const candidates = [];
          collect(document, 0, candidates);
          try {
            const html = document.documentElement && document.documentElement.innerHTML || '';
            const dumped = html.match(/"videoTitle"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"/);
            if (dumped) candidates.push(JSON.parse('"' + dumped[1] + '"'));
          } catch (e) {}
          candidates.push(document.title);
          for (let i = 0; i < candidates.length; i++) {
            const value = String(candidates[i] || '').replace(/\\s+/g, ' ').trim();
            if (!isGeneric(value)) return value;
          }
          return 'no-title';
        })()
        """
        let jsResult = executeJavaScript(
            javascript,
            on: tab,
            bundleID: bundleID
        )
        guard case .success(let value) = jsResult else {
            return nil
        }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let scraped = title == "no-title" || title.isEmpty ? nil : title
        return scraped
    }

    struct YouTubeMusicPlayback {
        var videoID: String?
        var artworkURL: String?
    }

    /// YouTube Music often leaves the tab URL at `/` while the player-bar
    /// already has a video id and album image.
    static func probeYouTubeMusicPlayback(on tab: Tab, bundleID: String) -> YouTubeMusicPlayback? {
        guard tab.url.contains("music.youtube.com") else { return nil }
        let javascript = """
        (() => {
          const pick = (value) => String(value || '').trim();
          const isAvatar = (src) => /yt3\\.(ggpht|googleusercontent)\\./i.test(src);
          const idFrom = (raw) => {
            const text = pick(raw);
            if (!text) return '';
            try {
              const url = new URL(text, location.href);
              const queryId = url.searchParams.get('v');
              if (queryId) return queryId;
              const vi = url.pathname.match(/\\/vi\\/([a-zA-Z0-9_-]{8,20})/);
              if (vi) return vi[1];
            } catch (e) {}
            const m = text.match(/[?&]v=([a-zA-Z0-9_-]{8,20})/)
              || text.match(/\\/vi\\/([a-zA-Z0-9_-]{8,20})\\//);
            return m ? m[1] : '';
          };
          const imgs = Array.from(document.querySelectorAll(
            'ytmusic-player-bar img, #song-image img, .thumbnail-image-wrapper img, ytmusic-player img'
          ));
          let art = '';
          let avatarArt = '';
          for (const img of imgs) {
            const src = pick(img && (img.currentSrc || img.src));
            if (!src || src.toLowerCase().startsWith('data:')) continue;
            if (isAvatar(src)) {
              if (!avatarArt) avatarArt = src;
              continue;
            }
            art = src;
            break;
          }
          const md = navigator.mediaSession && navigator.mediaSession.metadata;
          let sessionArt = '';
          let sessionArea = 0;
          if (md && md.artwork) {
            for (const item of md.artwork) {
              const src = pick(item && item.src);
              if (!src) continue;
              const dim = String(item.sizes || '').match(/(\\d+)\\s*x\\s*(\\d+)/i);
              const area = dim ? (Number(dim[1]) * Number(dim[2])) : 0;
              if (area >= sessionArea) {
                sessionArt = src;
                sessionArea = area;
              }
            }
          }
          const player = document.querySelector('ytmusic-player, ytmusic-player-bar, ytmusic-app');
          const attrId = pick(
            player && (
              player.getAttribute('video-id')
              || player.getAttribute('videoId')
            )
          );
          const videoId = idFrom(location.href)
            || attrId
            || idFrom(art)
            || idFrom(sessionArt)
            || idFrom(avatarArt)
            || idFrom(document.querySelector('link[rel="canonical"]') && document.querySelector('link[rel="canonical"]').href);
          const chosen = (art && !isAvatar(art) ? art : '')
            || (sessionArt && !isAvatar(sessionArt) ? sessionArt : '')
            || sessionArt
            || art
            || avatarArt;
          return videoId + '\\t' + chosen;
        })()
        """
        guard case .success(let value) = executeJavaScript(
            javascript,
            on: tab,
            bundleID: bundleID
        ) else {
            return nil
        }
        let parts = value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        let rawID = parts.first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artworkURL = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let id = rawID.isEmpty
            ? nil
            : YouTubeTabPicker.youtubeVideoID(from: "https://music.youtube.com/watch?v=\(rawID)")
        let art = artworkURL.isEmpty || artworkURL.lowercased().hasPrefix("data:")
            ? nil
            : MediaArtworkPolicy.preferredYouTubeMusicArtworkURL(playerBarURL: artworkURL)
        if id == nil, art == nil { return nil }
        return YouTubeMusicPlayback(videoID: id, artworkURL: art)
    }

    /// Executes against the cached playback tab first, avoiding a full tab scan
    /// on every transport-control click.
    static func executeJavaScript(
        _ javascript: String,
        on tab: Tab,
        bundleID: String
    ) -> JavaScriptResult {
        let appName = appleScriptName(for: bundleID)
        guard appName != "Firefox" else { return .failed }
        let escapedJS = appleScriptEscape(javascript)
        let windowIndex = max(tab.windowIndex, 1)
        let tabIndex = max(tab.tabIndex, 1)
        let script: String

        if appName == "Safari" {
            script = """
            tell application "Safari"
              if \(windowIndex) is less than or equal to count of windows then
                if \(tabIndex) is less than or equal to count of tabs of window \(windowIndex) then
                  try
                    return do JavaScript "\(escapedJS)" in tab \(tabIndex) of window \(windowIndex)
                  on error errMsg
                    return "err:" & errMsg
                  end try
                end if
              end if
              return "no-tab"
            end tell
            """
        } else {
            let tabID = tab.tabID
            let liveURLGuard = activationURLAppleScriptGuard(
                expectedURL: tab.url,
                variable: "liveURL"
            )
            script = """
            tell application "\(appName)"
              if \(windowIndex) is less than or equal to count of windows then
                if \(tabIndex) is less than or equal to count of tabs of window \(windowIndex) then
                  set directTab to tab \(tabIndex) of window \(windowIndex)
                  set directID to (id of directTab) as text
                  set liveURL to URL of directTab
                  if ("\(tabID)" is "0" or directID is "\(tabID)") and (\(liveURLGuard)) then
                    try
                      return execute directTab javascript "\(escapedJS)"
                    on error errMsg
                      return "err:" & errMsg
                    end try
                  end if
                end if
              end if
              if "\(tabID)" is not "0" then
                repeat with w from 1 to count of windows
                  try
                    set idTab to (first tab of window w whose id is \(tabID))
                    set liveURL to URL of idTab
                    if \(liveURLGuard) then
                      return execute idTab javascript "\(escapedJS)"
                    end if
                  end try
                end repeat
              end if
              return "no-tab"
            end tell
            """
        }

        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            let message = String(describing: error[NSAppleScript.errorMessage] ?? error)
            return message.localizedCaseInsensitiveContains("javascript")
                ? .needsPermission
                : .failed
        }
        let value = result?.stringValue ?? ""
        return classifyJavaScriptReturn(value)
    }

    private static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Prefer a live tab ID so Shorts can keep playing after the URL changes.
    static func resolveLiveTab(_ tab: Tab, from tabs: [Tab]) -> Tab? {
        if tab.tabID != 0,
           let match = tabs.first(where: {
               $0.tabID == tab.tabID
                   && activationURLIsCompatible(expectedURL: tab.url, liveURL: $0.url)
           }) {
            return match
        }
        if !tab.url.isEmpty, let match = tabs.first(where: { YouTubeTabPicker.urlsMatch($0.url, tab.url) }) {
            return match
        }
        return nil
    }

    /// A stable Chrome tab ID is useful only while that tab remains on the
    /// exact expected YouTube video (or the expected non-YouTube service).
    /// Chrome keeps the ID when a tab navigates, so a host-only check can still
    /// open another YouTube video in the wrong window.
    static func activationURLIsCompatible(expectedURL: String, liveURL: String) -> Bool {
        if StreamingPlatform.from(url: expectedURL) == .youtube,
           YouTubeTabPicker.youtubeVideoID(from: expectedURL) != nil {
            return YouTubeTabPicker.videoIDsMatch(expectedURL, liveURL)
        }
        guard let liveHost = normalizedHost(from: liveURL) else { return false }
        return activationAllowedHosts(for: expectedURL).contains(liveHost)
    }

    /// The front-tab shortcut is only safe for a recognized playback service.
    /// Unknown pages still participate in the full ranked scan, but can never
    /// preempt a background YouTube tab merely because their titles overlap.
    static func canFastBindActiveTab(_ tab: Tab, titleHint: StreamingPlatform?) -> Bool {
        guard StreamingPlatform.from(url: tab.url) != nil else { return false }
        return StreamingPlatform.sourceURLCompatible(tab.url, withTitleHint: titleHint)
    }

    @discardableResult
    static func activateTab(_ tab: Tab, bundleID: String) -> Bool {
        let appName = appleScriptName(for: bundleID)
        let script = activationAppleScript(tab: tab, bundleID: bundleID)
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            NSLog(
                "[BrowserMedia] activation failed app=%@ url=%@ error=%@",
                appName,
                tab.url,
                String(describing: error)
            )
            return false
        } else {
            let value = result?.stringValue ?? ""
            let ok = value == "true"
                || value.hasPrefix("ok")
                || (result?.booleanValue ?? false)
            NSLog("[BrowserMedia] activated app=%@ url=%@ result=%@", appName, tab.url, value)
            return ok
        }
    }

    /// Locate the tab with a read-only scan, then retarget by stable window id.
    /// Integer `window w` is z-order and goes stale. Chrome becoming frontmost
    /// can also restore its last-used window, so reassert the resolved stable
    /// window ID and tab index after making the process frontmost.
    ///
    /// Match **tab ID first**. OR-ing URL / video-id in the same scan picks the
    /// first window that happens to have that watch URL — often a duplicate
    /// tab — and never reaches the Now Playing tab.
    static func activationAppleScript(tab: Tab, bundleID: String) -> String {
        let appName = appleScriptName(for: bundleID)
        let escapedURL = appleScriptEscape(tab.url)
        let escapedVideoID = appleScriptEscape(YouTubeTabPicker.youtubeVideoID(from: tab.url) ?? "")
        let liveURLGuard = activationURLAppleScriptGuard(
            expectedURL: tab.url,
            variable: "liveURL"
        )
        if appName == "Safari" {
            return """
            set winID to 0
            set tabIdx to 0
            tell application "Safari"
              set targetURL to "\(escapedURL)"
              set targetVideo to "\(escapedVideoID)"
              if targetURL is not "" then
                repeat with w from 1 to count of windows
                  repeat with t from 1 to count of tabs of window w
                    try
                      set u to URL of tab t of window w
                      if u is targetURL then
                        set winID to (id of window w) as integer
                        set tabIdx to t
                        exit repeat
                      end if
                    end try
                  end repeat
                  if winID is not 0 then exit repeat
                end repeat
              end if
              if winID is 0 and targetVideo is not "" then
                repeat with w from 1 to count of windows
                  repeat with t from 1 to count of tabs of window w
                    try
                      set u to URL of tab t of window w
                      if u contains ("/shorts/" & targetVideo) or u contains ("v=" & targetVideo) or u contains ("youtu.be/" & targetVideo) then
                        set winID to (id of window w) as integer
                        set tabIdx to t
                        exit repeat
                      end if
                    end try
                  end repeat
                  if winID is not 0 then exit repeat
                end repeat
              end if
            end tell
            if winID is 0 then return false
            tell application "Safari"
              tell window id winID to set current tab to tab tabIdx
              set index of window id winID to 1
            end tell
            \(makeApplicationFrontmostAppleScript(appName: "Safari"))
            tell application "Safari"
              set index of window id winID to 1
              tell window id winID to set current tab to tab tabIdx
              set index of window id winID to 1
              return "ok:" & ((index of window id winID) as text)
            end tell
            """
        }
        if appName == "Firefox" {
            return """
            tell application "Firefox" to activate
            return true
            """
        }
        return """
        set winID to 0
        set tabIdx to 0
        tell application "\(appName)"
          set targetURL to "\(escapedURL)"
          set targetID to "\(tab.tabID)"
          set targetVideo to "\(escapedVideoID)"
          if targetID is not "0" then
            repeat with w from 1 to count of windows
              repeat with t from 1 to count of tabs of window w
                try
                  if ((id of tab t of window w) as text) is targetID then
                    set liveURL to URL of tab t of window w
                    if \(liveURLGuard) then
                      set winID to (id of window w) as integer
                      set tabIdx to t
                      exit repeat
                    end if
                  end if
                end try
              end repeat
              if winID is not 0 then exit repeat
            end repeat
          end if
          if winID is 0 and targetURL is not "" then
            repeat with w from 1 to count of windows
              repeat with t from 1 to count of tabs of window w
                try
                  if (URL of tab t of window w) is targetURL then
                    set winID to (id of window w) as integer
                    set tabIdx to t
                    exit repeat
                  end if
                end try
              end repeat
              if winID is not 0 then exit repeat
            end repeat
          end if
          if winID is 0 and targetVideo is not "" then
            repeat with w from 1 to count of windows
              repeat with t from 1 to count of tabs of window w
                try
                  set u to URL of tab t of window w
                  if u contains ("/shorts/" & targetVideo) or u contains ("v=" & targetVideo) or u contains ("youtu.be/" & targetVideo) then
                    set winID to (id of window w) as integer
                    set tabIdx to t
                    exit repeat
                  end if
                end try
              end repeat
              if winID is not 0 then exit repeat
            end repeat
          end if
        end tell
        if winID is 0 then return false
        tell application "\(appName)"
          set active tab index of window id winID to tabIdx
          try
            set minimized of window id winID to false
          end try
          set index of window id winID to 1
        end tell
        \(makeApplicationFrontmostAppleScript(appName: appName))
        tell application "\(appName)"
          set index of window id winID to 1
          set active tab index of window id winID to tabIdx
          set index of window id winID to 1
          return "ok:" & ((index of window id winID) as text)
        end tell
        """
    }

    private static func normalizedHost(from rawURL: String) -> String? {
        guard let host = URLComponents(string: rawURL)?.host?
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty else {
            return nil
        }
        return host
    }

    private static func activationAllowedHosts(for rawURL: String) -> Set<String> {
        guard let host = normalizedHost(from: rawURL) else { return [] }
        if let platform = StreamingPlatform.from(url: rawURL),
           platform == .youtube || platform == .youtubeMusic {
            return [
                "youtube.com",
                "www.youtube.com",
                "m.youtube.com",
                "music.youtube.com",
                "youtu.be",
                "www.youtu.be"
            ]
        }
        if host.hasPrefix("www.") {
            return [host, String(host.dropFirst(4))]
        }
        return [host, "www.\(host)"]
    }

    private static func activationURLAppleScriptGuard(
        expectedURL: String,
        variable: String
    ) -> String {
        if StreamingPlatform.from(url: expectedURL) == .youtube,
           let videoID = YouTubeTabPicker.youtubeVideoID(from: expectedURL) {
            let escapedID = appleScriptEscape(videoID)
            return [
                "\(variable) contains \"/shorts/\(escapedID)\"",
                "\(variable) contains \"v=\(escapedID)\"",
                "\(variable) contains \"youtu.be/\(escapedID)\""
            ]
            .joined(separator: " or ")
        }
        let clauses = activationAllowedHosts(for: expectedURL)
            .sorted()
            .flatMap { host in
                let escapedHost = appleScriptEscape(host)
                return [
                    "\(variable) is \"https://\(escapedHost)\"",
                    "\(variable) starts with \"https://\(escapedHost)/\"",
                    "\(variable) is \"http://\(escapedHost)\"",
                    "\(variable) starts with \"http://\(escapedHost)/\""
                ]
            }
        return clauses.isEmpty ? "false" : clauses.joined(separator: " or ")
    }

    /// Letter-heavy prefix so Accessibility window names still match after
    /// YouTube emoji / badge text is stripped.
    static func accessibilityWindowNeedle(from title: String) -> String {
        let kept = title.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "'"
                || scalar == " "
        }
        let compact = String(String.UnicodeScalarView(kept))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count >= 4 {
            return String(compact.prefix(32))
        }
        return String(title.prefix(24))
    }

    private static func makeApplicationFrontmostAppleScript(appName: String) -> String {
        return """
        try
          tell application "System Events"
            tell process "\(appName)"
              set frontmost to true
            end tell
          end tell
        end try
        """
    }

    static func activateApplication(bundleID: String) {
        let running = NSWorkspace.shared.runningApplications.first {
            ($0.bundleIdentifier ?? "").lowercased() == bundleID.lowercased()
        }
        if let running {
            running.activate(options: [.activateIgnoringOtherApps])
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
