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

        guard let best = ranked.first, best.score >= 20 else { return nil }
        return best.tab
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
        if YouTubeTabPicker.titlesMatch(tab.title, nowPlayingTitle)
            || YouTubeTabPicker.titlesMatch(tab.url, nowPlayingTitle) {
            value += 100
        }
        if YouTubeTabPicker.titlesMatch(tab.title, nowPlayingArtist) {
            value += 15
        }
        if !preferredURL.isEmpty, YouTubeTabPicker.urlsMatch(tab.url, preferredURL) {
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
            return path.contains("/watch") || path.contains("/shorts/")
                || query.contains("v=")
        case .spotify, .appleMusic, .appleTV, .twitch, .jioSaavn, .soundcloud, .vimeo, .plex:
            return path.split(separator: "/").count >= 2
        case .none:
            return false
        }
    }

    static func listTabs(bundleID: String) -> [Tab] {
        let appName = appleScriptName(for: bundleID)
        if appName == "Firefox" { return [] }
        let script: String
        if appName == "Safari" {
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
        NSLog("[BrowserMedia] scanned app=%@ tabs=%d", appName, tabs.count)
        return tabs
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
    static func probePlaybackPlaying(on tab: Tab, bundleID: String) -> Bool? {
        switch executeJavaScript(playbackProbeJavaScript, on: tab, bundleID: bundleID) {
        case .success(let value):
            return parsePlaybackProbe(value)
        case .needsPermission, .failed:
            return nil
        }
    }

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

    /// Netflix and some other OTT players publish only the provider name to
    /// MediaRemote. Read the actual programme title from the already-matched
    /// playback tab without activating it.
    static func playbackTitle(
        on tab: Tab,
        platform: StreamingPlatform?,
        bundleID: String
    ) -> String? {
        guard platform == .netflix || platform == .primeVideo else { return nil }
        let provider = platform == .netflix ? "netflix" : "prime video"
        let javascript = """
        (() => {
          const provider = "\(provider)";
          const text = (element) => {
            if (!element) return '';
            const raw = element.content || element.getAttribute?.('aria-label')
              || element.innerText || element.textContent || '';
            return String(raw).split('\\n')[0].replace(/\\s+/g, ' ').trim();
          };
          const selectors = [
            '[data-uia="video-title"] h4',
            '[data-uia="video-title"]',
            '.video-title h4',
            '.video-title',
            '[class*="video-title"] h4',
            '[data-testid="title"]',
            '[class*="Title"] h1',
            'meta[property="og:title"]',
            'h1'
          ];
          const mediaSessionTitle = navigator.mediaSession
            && navigator.mediaSession.metadata
            && navigator.mediaSession.metadata.title;
          const candidates = [mediaSessionTitle]
            .concat(selectors.map(selector => text(document.querySelector(selector))))
            .concat([document.title]);
          for (const raw of candidates) {
            const value = String(raw || '').replace(/\\s+/g, ' ').trim();
            const lower = value.toLowerCase();
            if (!value || lower === provider || lower === 'amazon prime video') continue;
            if (lower.includes('watch movies') || lower.includes('watch tv shows')) continue;
            return value;
          }
          return 'no-title';
        })()
        """
        guard case .success(let value) = executeJavaScript(
            javascript,
            on: tab,
            bundleID: bundleID
        ) else {
            return nil
        }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return title == "no-title" || title.isEmpty ? nil : title
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
        let escapedURL = appleScriptEscape(tab.url)
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
              repeat with w from 1 to count of windows
                repeat with t from 1 to count of tabs of window w
                  if (URL of tab t of window w) is "\(escapedURL)" then
                    try
                      return do JavaScript "\(escapedJS)" in tab t of window w
                    on error errMsg
                      return "err:" & errMsg
                    end try
                  end if
                end repeat
              end repeat
              return "no-tab"
            end tell
            """
        } else {
            script = """
            tell application "\(appName)"
              if \(windowIndex) is less than or equal to count of windows then
                if \(tabIndex) is less than or equal to count of tabs of window \(windowIndex) then
                  set directTab to tab \(tabIndex) of window \(windowIndex)
                  set directID to (id of directTab) as text
                  if "\(tab.tabID)" is "0" or directID is "\(tab.tabID)" or (URL of directTab) is "\(escapedURL)" then
                    try
                      return execute directTab javascript "\(escapedJS)"
                    on error errMsg
                      return "err:" & errMsg
                    end try
                  end if
                end if
              end if
              repeat with w from 1 to count of windows
                repeat with t from 1 to count of tabs of window w
                  if (URL of tab t of window w) is "\(escapedURL)" then
                    try
                      return execute tab t of window w javascript "\(escapedJS)"
                    on error errMsg
                      return "err:" & errMsg
                    end try
                  end if
                end repeat
              end repeat
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
        if value.hasPrefix("err:") {
            return value.localizedCaseInsensitiveContains("javascript")
                ? .needsPermission
                : .failed
        }
        if value == "no-tab" || value == "no-player" || value == "no-video" {
            return .failed
        }
        return .success(value)
    }

    private static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Prefer a live tab ID so Shorts can keep playing after the URL changes.
    static func resolveLiveTab(_ tab: Tab, from tabs: [Tab]) -> Tab? {
        if tab.tabID != 0, let match = tabs.first(where: { $0.tabID == tab.tabID }) {
            return match
        }
        if !tab.url.isEmpty, let match = tabs.first(where: { YouTubeTabPicker.urlsMatch($0.url, tab.url) }) {
            return match
        }
        return nil
    }

    @discardableResult
    static func activateTab(_ tab: Tab, bundleID: String) -> Bool {
        let appName = appleScriptName(for: bundleID)
        let escapedURL = appleScriptEscape(tab.url)
        let escapedVideoID = appleScriptEscape(YouTubeTabPicker.youtubeVideoID(from: tab.url) ?? "")
        let script: String
        if appName == "Safari" {
            script = """
            tell application "Safari"
              activate
              set targetURL to "\(escapedURL)"
              set targetVideo to "\(escapedVideoID)"
              set found to false
              repeat with w from 1 to count of windows
                repeat with t from 1 to count of tabs of window w
                  try
                    set u to URL of tab t of window w
                    if u is targetURL or (targetVideo is not "" and (u contains ("/shorts/" & targetVideo) or u contains ("v=" & targetVideo) or u contains ("youtu.be/" & targetVideo))) then
                      set index of window w to 1
                      tell window 1 to set current tab to tab t of window 1
                      set found to true
                      exit repeat
                    end if
                  end try
                end repeat
                if found then exit repeat
              end repeat
              return found
            end tell
            """
        } else if appName == "Firefox" {
            script = """
            tell application "Firefox" to activate
            return true
            """
        } else {
            script = """
            tell application "\(appName)"
              activate
              set targetURL to "\(escapedURL)"
              set targetID to "\(tab.tabID)"
              set targetVideo to "\(escapedVideoID)"
              set found to false
              repeat with w from 1 to count of windows
                repeat with t from 1 to count of tabs of window w
                  try
                    set candidate to tab t of window w
                    set candidateID to (id of candidate) as text
                    set u to URL of candidate
                    if (targetID is not "0" and candidateID is targetID) or u is targetURL or (targetVideo is not "" and (u contains ("/shorts/" & targetVideo) or u contains ("v=" & targetVideo) or u contains ("youtu.be/" & targetVideo))) then
                      set index of window w to 1
                      set active tab index of window 1 to t
                      set found to true
                      exit repeat
                    end if
                  end try
                end repeat
                if found then exit repeat
              end repeat
              return found
            end tell
            """
        }
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
            NSLog("[BrowserMedia] activated app=%@ url=%@", appName, tab.url)
            return result?.booleanValue ?? true
        }
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
