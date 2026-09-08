import AppKit
import ApplicationServices
import Foundation

/// Chrome's `execute javascript` needs a CFRunLoop, but **not** the UI run loop.
/// GCD has no run loop (empty JS results). Main thread hitchs the island.
///
/// Chat-tab polling and Now Playing transport each get their own thread so a
/// 1s Claude/Gemini poll cannot stall play/pause/skip.
final class AppleScriptRunLoop: @unchecked Sendable {
    static let shared = AppleScriptRunLoop(threadName: "island.chrome-applescript")
    static let media = AppleScriptRunLoop(threadName: "island.media-applescript")
    /// HTML playback probes — never share the transport thread or a click waits.
    static let probe = AppleScriptRunLoop(threadName: "island.probe-applescript")
    private let loop: CFRunLoop

    private init(threadName: String) {
        let ready = DispatchSemaphore(value: 0)
        var captured: CFRunLoop!
        let thread = Thread {
            Thread.current.name = threadName
            RunLoop.current.add(NSMachPort(), forMode: .default)
            captured = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
        }
        thread.qualityOfService = threadName.contains("media-applescript")
            ? .userInteractive
            : .userInitiated
        thread.start()
        ready.wait()
        loop = captured
    }

    func async(_ body: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, body)
        CFRunLoopWakeUp(loop)
    }
}

/// Polls Google Chrome for Claude / ChatGPT / Gemini tabs via Apple Events (no extension).
final class ChromeTabMonitor {
    static let shared = ChromeTabMonitor()
    static let chromeBundleID = "com.google.Chrome"

    var onResponseReady: ((ClaudeTabSnapshot) -> Void)?

    private let settings: AppSettings
    private var timer: DispatchSourceTimer?
    private var tracker = ClaudeTabTracker()
    private var macIsAsleep = false
    private var pollInFlight = false
    private var didPromptAutomation = false
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Compiled once on the AppleScript thread.
    private var compiledPollScript: NSAppleScript?
    private var wroteOSAScriptFile = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
        observeWorkspace()
    }

    deinit {
        timer?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
    }

    func start() {
        if timer == nil {
            installTimerIfNeeded()
        }
        pollIfRelevant()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        fastPolling = false
        snapshotCache.removeAll()
        tracker.reset()
    }

    func activate(tab: ClaudeTabInfo) {
        AppleScriptRunLoop.shared.async {
            switch Self.runAppleScript(Self.activateScript(tab: tab)) {
            case .ok("not-found"):
                NSLog(
                    "[ChatTabs] activation tab not found; opening saved URL provider=%@",
                    tab.provider.rawValue
                )
                Self.openSavedChatURL(tab.url)
            case .ok(let route):
                NSLog(
                    "[ChatTabs] activation provider=%@ route=%@ tabID=%d",
                    tab.provider.rawValue,
                    route.isEmpty ? "unknown" : route,
                    tab.tabID
                )
            case .denied:
                NSLog("[ChatTabs] activation denied by Automation permission")
            case .javascriptDisabled:
                NSLog("[ChatTabs] activation unexpectedly reported JavaScript disabled")
            case .failed(let message):
                NSLog("[ChatTabs] activation failed: %@", message)
            }
        }
    }

    private static func openSavedChatURL(_ rawURL: String) {
        guard let url = URL(string: rawURL),
              url.scheme == "https" || url.scheme == "http" else {
            NSLog("[ChatTabs] activation has no valid fallback URL")
            return
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    func acknowledge(
        tab: ClaudeTabInfo,
        preview: String,
        assistantCount: Int,
        replyFingerprint: String = "",
        userFingerprint: String = ""
    ) {
        tracker.acknowledge(
            tabID: tab.tabID,
            preview: preview,
            assistantCount: assistantCount,
            replyFingerprint: replyFingerprint,
            userFingerprint: userFingerprint
        )
    }

    /// Instant reply from the Chrome extension (no poll / no stale candidate text).
    func handlePushReply(_ snapshot: ClaudeTabSnapshot, pageVisible: Bool, tabActive: Bool = false) {
        if let event = tracker.ingestPush(snapshot) {
            let chromeFront = Self.chromeIsFrontmost()
            // Gemini spoofs document.visibility so background tabs keep streaming.
            // Never use that flag as "user is looking." Use Chrome's active tab
            // (helper tabActive / last AppleScript visible tab) plus frontmost.
            let thisTabVisible = event.tab.provider == .gemini
                ? (tabActive || lastVisibleTabID == event.tab.tabID)
                : (pageVisible || event.pageVisible)
            let viewingThisTab = chromeFront && thisTabVisible
            if viewingThisTab {
                tracker.noteUserIsViewing(event)
                NSLog(
                    "[ChatTabs] push skipped; already viewing %@ tab %d",
                    event.tab.provider.rawValue,
                    event.tab.tabID
                )
                settings.updateChromePollStatus("\(event.tab.provider.displayName) reply ready in the front tab")
                return
            }
            NSLog(
                "[ChatTabs] push reply ready provider=%@ len=%d",
                event.tab.provider.rawValue,
                event.textLength
            )
            settings.updateChromePollStatus("\(event.tab.provider.displayName) reply detected — showing island")
            onResponseReady?(event)
        } else {
            NSLog(
                "[ChatTabs] push ignored by tracker provider=%@ len=%d",
                snapshot.tab.provider.rawValue,
                snapshot.textLength
            )
        }
    }

    func recheckPermissionsAndResume() {
        didPromptAutomation = false
        AppleScriptRunLoop.shared.async { [weak self] in
            let probe = Self.chromeAutomationStatus(prompt: true)
            DispatchQueue.main.async {
                self?.applyAutomationProbe(probe)
                self?.installTimerIfNeeded()
                self?.pollIfRelevant()
            }
        }
    }

    // MARK: - Workspace

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepHandler: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.macIsAsleep = true }
        }
        let wakeHandler: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async {
                self?.macIsAsleep = false
                self?.pollIfRelevant()
            }
        }
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil, using: sleepHandler),
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil, using: sleepHandler),
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil, using: wakeHandler),
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil, using: wakeHandler),
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] note in
                guard Self.isChrome(note.userInfo?[NSWorkspace.applicationUserInfoKey]) else { return }
                DispatchQueue.main.async { self?.pollIfRelevant() }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] note in
                guard Self.isChrome(note.userInfo?[NSWorkspace.applicationUserInfoKey]) else { return }
                DispatchQueue.main.async { self?.tracker.reset() }
            }
        ]
    }

    static func chromeIsFrontmost() -> Bool {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return id == chromeBundleID
    }

    private static func isChrome(_ value: Any?) -> Bool {
        (value as? NSRunningApplication)?.bundleIdentifier == chromeBundleID
    }

    /// True when the user is already looking at this chat tab.
    static func shouldSuppressIslandOverlay(
        tabID: Int,
        chromeFrontmost: Bool,
        visibleTabID: Int?,
        pageVisible: Bool = false
    ) -> Bool {
        IslandSurfacePolicy.shouldSuppressChatBanner(
            chromeFrontmost: chromeFrontmost,
            thisTabVisible: pageVisible || visibleTabID == tabID
        )
    }

    static func parseFrontmostActiveTabID(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            let tabParts = raw.components(separatedBy: "<<<ISLAND_TAB>>>")
            let parts = tabParts.count >= 2
                ? tabParts
                : raw.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.first?.trimmingCharacters(in: .whitespaces) == "ACTIVE" else { continue }
            guard parts.count >= 4,
                  let tabID = Int(parts[3].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return tabID
        }
        return nil
    }

    private static func chromeIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == chromeBundleID }
    }

    // MARK: - Timer

    private var snapshotCache: [Int: ClaudeTabSnapshot] = [:]
    private var pollTick = 0
    private var lastVisibleTabID: Int?
    private var lastInFlightTabIDs: Set<Int> = []
    private var fastPolling = false

    private func installTimerIfNeeded() {
        timer?.cancel()
        let repeating: TimeInterval = fastPolling ? 0.45 : 1.0
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.2, repeating: repeating)
        source.setEventHandler { [weak self] in
            self?.pollIfRelevant()
        }
        source.resume()
        timer = source
    }

    private func pollIfRelevant() {
        guard !macIsAsleep else { return }
        guard IslandSurfacePolicy.shouldPollChromeTabs(
            automationDenied: settings.automationDenied,
            helperConnected: settings.chromeHelperConnected
        ) else { return }
        guard Self.chromeIsRunning() else { return }
        guard !pollInFlight else { return }

        pollInFlight = true
        let shouldPrompt = !didPromptAutomation
        didPromptAutomation = true
        let geminiEnabled = settings.geminiMonitoringEnabled
        let inFlight = lastInFlightTabIDs

        AppleScriptRunLoop.shared.async { [weak self] in
            guard let self else { return }
            let result = self.collectSnapshots(
                promptAutomation: shouldPrompt,
                geminiEnabled: geminiEnabled,
                inFlightTabIDs: inFlight
            )
            DispatchQueue.main.async {
                self.pollInFlight = false
                self.handle(result)
            }
        }
    }

    private enum CollectResult {
        case snapshots([ClaudeTabSnapshot], promptEnableJS: Bool, visibleTabID: Int?)
        case automationDenied
        case needsJavaScriptPermission
        case skipped(String)
    }

    private func collectSnapshots(
        promptAutomation: Bool,
        geminiEnabled: Bool,
        inFlightTabIDs: Set<Int>
    ) -> CollectResult {
        if promptAutomation || pollTick % 15 == 0 {
            _ = Self.chromeAutomationStatus(prompt: promptAutomation)
        }
        pollTick += 1

        switch runPollScript() {
        case .denied:
            return .automationDenied
        case .javascriptDisabled:
            return .needsJavaScriptPermission
        case .failed(let message):
            return .skipped(message)
        case .ok(let output):
            let listedTabs = Self.parseListedTabs(output)
            let visibleTabID = Self.parseFrontmostActiveTabID(output)
            let rawByTabID = Self.parseBatchInspectOutput(output)
            let tabs = listedTabs
                .compactMap(\.info)
                .filter { tab in
                    tab.provider != .gemini || geminiEnabled
                }
                .sorted { lhs, rhs in
                Self.inspectPriority(lhs.provider) < Self.inspectPriority(rhs.provider)
            }
            if tabs.isEmpty { return .snapshots([], promptEnableJS: false, visibleTabID: visibleTabID) }

            var snapshots: [ClaudeTabSnapshot] = []
            var sawJSPermissionIssue = false
            for tab in tabs {
                if tab.provider == .claude,
                   tab.tabID != visibleTabID,
                   !inFlightTabIDs.contains(tab.tabID),
                   pollTick % 3 != 0,
                   let cached = snapshotCache[tab.tabID] {
                    snapshots.append(cached)
                    continue
                }
                let raw = rawByTabID[tab.tabID] ?? ""
                if raw.isEmpty {
                    NSLog("[ChatTabs] missing probe JSON for %@ tab %d", tab.provider.rawValue, tab.tabID)
                }
                switch Self.inspectResult(for: tab, raw: raw) {
                case .automationDenied:
                    return .automationDenied
                case .needsJavaScriptPermission:
                    sawJSPermissionIssue = true
                    snapshots.append(Self.unreadSnapshot(tab))
                case .unavailable:
                    if let cached = snapshotCache[tab.tabID] {
                        snapshots.append(cached)
                    } else {
                        snapshots.append(Self.unreadSnapshot(tab))
                    }
                case .inspected(let snapshot):
                    snapshotCache[tab.tabID] = snapshot
                    snapshots.append(snapshot)
                }
            }
            if snapshots.isEmpty {
                if sawJSPermissionIssue {
                    return .needsJavaScriptPermission
                }
                snapshots = tabs.map { Self.unreadSnapshot($0) }
            }
            return .snapshots(
                snapshots,
                promptEnableJS: sawJSPermissionIssue,
                visibleTabID: visibleTabID
            )
        }
    }

    private static func inspectPriority(_ provider: ChatProvider) -> Int {
        switch provider {
        case .chatgpt, .gemini: return 0
        case .claude: return 1
        }
    }

    private func handle(_ result: CollectResult) {
        switch result {
        case .skipped(let message):
            settings.updateChromePollStatus(message)
            NSLog("[ChatTabs] %@", message)
        case .automationDenied:
            settings.markAutomationDenied()
            settings.updateChromePollStatus("Automation permission denied for Google Chrome.")
            NSLog("[ChatTabs] automation denied")
        case .needsJavaScriptPermission:
            settings.needsChromeJavaScriptFromAppleEvents = true
            settings.updateChromePollStatus("Blocked: enable Chrome → View → Developer → Allow JavaScript from Apple Events")
            NSLog("[ChatTabs] JS from Apple Events disabled")
        case .snapshots(let snapshots, let promptEnableJS, let visibleTabID):
            settings.markAutomationGranted()
            let readable = snapshots.filter(\.foundDOM)
            if !readable.isEmpty {
                if settings.needsChromeJavaScriptFromAppleEvents {
                    settings.needsChromeJavaScriptFromAppleEvents = false
                }
                settings.updateChromePollStatus(Self.statusSummary(watching: readable))
            } else if promptEnableJS {
                if !settings.needsChromeJavaScriptFromAppleEvents {
                    settings.needsChromeJavaScriptFromAppleEvents = true
                }
                settings.updateChromePollStatus("Found \(snapshots.count) tab(s), but JS from Apple Events is off")
            } else {
                if settings.needsChromeJavaScriptFromAppleEvents {
                    settings.needsChromeJavaScriptFromAppleEvents = false
                }
                settings.updateChromePollStatus(
                    snapshots.isEmpty
                        ? "No Claude, ChatGPT, or Gemini tabs open"
                        : "Found \(snapshots.count) AI chat tab(s), waiting for chat UI"
                )
            }
            let chromeFront = Self.chromeIsFrontmost()
            lastVisibleTabID = visibleTabID
            // document.visibility stays true for the selected Chrome tab even
            // when Cursor / another app is frontmost. Only treat as "viewing"
            // when Chrome actually has focus. Gemini spoofs visibility — skip
            // that flag and match the AppleScript active tab only.
            for snap in snapshots where chromeFront && (snap.pageVisible || snap.tab.tabID == visibleTabID) {
                if snap.tab.provider == .gemini { continue }
                tracker.noteUserIsViewing(snap)
            }
            let event = tracker.ingest(snapshots)
            lastInFlightTabIDs = tracker.inFlightTabIDs
            let shouldFastPoll = tracker.hasInFlightGeneration
                || snapshots.contains(where: { $0.isGenerating && ($0.tab.provider == .chatgpt || $0.tab.provider == .gemini) })
            if shouldFastPoll != fastPolling {
                fastPolling = shouldFastPoll
                installTimerIfNeeded()
            }
            if let event {
                let suppress = Self.shouldSuppressIslandOverlay(
                    tabID: event.tab.tabID,
                    chromeFrontmost: chromeFront,
                    visibleTabID: visibleTabID,
                    pageVisible: event.tab.provider == .gemini ? false : event.pageVisible
                )
                if suppress {
                    NSLog(
                        "[ChatTabs] skipped overlay; already viewing %@ tab %d",
                        event.tab.provider.rawValue,
                        event.tab.tabID
                    )
                    settings.updateChromePollStatus("\(event.tab.provider.displayName) reply ready in the front tab")
                    return
                }
                NSLog("[ChatTabs] response ready event fired provider=%@ len=%d count=%d", event.tab.provider.rawValue, event.textLength, event.assistantCount)
                settings.updateChromePollStatus("\(event.tab.provider.displayName) reply detected — showing island")
                onResponseReady?(event)
            }
        }
    }

    private func applyAutomationProbe(_ probe: AutomationProbe) {
        switch probe {
        case .granted:
            settings.markAutomationGranted()
        case .denied:
            settings.markAutomationDenied()
        case .unknown:
            break
        }
    }

    // MARK: - Automation permission

    enum AutomationProbe {
        case granted, denied, unknown
    }

    static func chromeAutomationStatus(prompt: Bool) -> AutomationProbe {
        var target = AEAddressDesc()
        let bundle = chromeBundleID as NSString
        let bytes = bundle.utf8String
        let length = bundle.lengthOfBytes(using: String.Encoding.utf8.rawValue)
        guard let bytes else { return .unknown }
        let created = AECreateDesc(typeApplicationBundleID, bytes, length, &target)
        defer { AEDisposeDesc(&target) }
        guard created == noErr else { return .unknown }

        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, prompt)
        switch status {
        case noErr:
            return .granted
        case -1743:
            return .denied
        case -600:
            return .unknown
        default:
            return .unknown
        }
    }

    // MARK: - AppleScript

    private enum InspectResult {
        case inspected(ClaudeTabSnapshot)
        case unavailable(String)
        case needsJavaScriptPermission
        case automationDenied
    }

    private struct ListedChromeTab {
        var windowIndex: Int
        var tabIndex: Int
        var tabID: Int
        var provider: ChatProvider?
        var url: String

        var info: ClaudeTabInfo? {
            guard let provider else { return nil }
            return ClaudeTabInfo(
                tabID: tabID,
                windowIndex: windowIndex,
                tabIndex: tabIndex,
                provider: provider,
                url: url
            )
        }
    }

    private static func statusSummary(watching snapshots: [ClaudeTabSnapshot]) -> String {
        let counts = Dictionary(grouping: snapshots, by: \.tab.provider).mapValues(\.count)
        let parts = ChatProvider.allCases.compactMap { provider -> String? in
            guard let count = counts[provider], count > 0 else { return nil }
            return "\(count) \(provider.displayName)"
        }
        if parts.isEmpty {
            return "Watching \(snapshots.count) AI chat tab(s)"
        }
        return "Watching " + parts.joined(separator: ", ")
    }

    static func activateScript(tab: ClaudeTabInfo) -> String {
        let targetURL = appleScriptEscape(tab.url)
        let allowURLFallback = chatActivationURLIsSpecific(tab.url)
        let urlClause = allowURLFallback
            ? #"if (URL of candidate) is targetURL then"#
            : "if false then"
        return """
        tell application "Google Chrome"
          set targetID to "\(tab.tabID)"
          set targetURL to "\(targetURL)"
          set winID to 0
          set tabIdx to 0
          set matched to "none"
          repeat with w from 1 to count of windows
            repeat with t from 1 to count of tabs of window w
              try
                set candidate to tab t of window w
                if ((id of candidate) as text) is targetID then
                  set winID to id of window w
                  set tabIdx to t
                  set matched to "id"
                  exit repeat
                end if
              end try
            end repeat
            if winID is not 0 then exit repeat
          end repeat
          if winID is 0 and targetURL is not "" then
            repeat with w from 1 to count of windows
              repeat with t from 1 to count of tabs of window w
                try
                  set candidate to tab t of window w
                  \(urlClause)
                    set winID to id of window w
                    set tabIdx to t
                    set matched to "url"
                    exit repeat
                  end if
                end try
              end repeat
              if winID is not 0 then exit repeat
            end repeat
          end if
          if winID is 0 then return "not-found"
          set active tab index of window id winID to tabIdx
          set index of window id winID to 1
          activate
          set index of window id winID to 1
          return matched
        end tell
        """
    }

    /// Home/new-chat URLs exist in every Chrome profile. Matching them after
    /// a Space swipe activates whichever profile happens to be window 1.
    static func chatActivationURLIsSpecific(_ rawURL: String) -> Bool {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
            return false
        }
        let path = url.path.lowercased()
        let parts = path.split(separator: "/").filter { !$0.isEmpty }
        if host.contains("claude.") {
            return parts.count >= 2 && parts[0] == "chat" && parts[1].count >= 8
        }
        if host.contains("chatgpt.com") || host.contains("openai.com") {
            return parts.count >= 2 && parts[0] == "c" && parts[1].count >= 8
        }
        if host.contains("gemini.google.com") {
            return parts.count >= 2 && parts[0] == "app" && parts[1].count >= 6
        }
        return false
    }

    private static func parseListedTabs(_ output: String) -> [ListedChromeTab] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> ListedChromeTab? in
                let raw = String(line)
                let tabParts = raw.components(separatedBy: "<<<ISLAND_TAB>>>")
                let parts: [String]
                if tabParts.count >= 4 {
                    parts = tabParts
                } else {
                    parts = raw.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
                }
                guard parts.count >= 4,
                      let windowIndex = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                      let tabIndex = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                      let tabID = Int(parts[2].trimmingCharacters(in: .whitespaces)) else {
                    return nil
                }
                let provider = ChatProvider(rawValue: parts[3].trimmingCharacters(in: .whitespaces))
                let url = parts.count >= 5 ? parts[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                return ListedChromeTab(
                    windowIndex: windowIndex,
                    tabIndex: tabIndex,
                    tabID: tabID,
                    provider: provider,
                    url: url
                )
            }
    }

    static func parseTabList(_ output: String) -> [ClaudeTabInfo] {
        parseListedTabs(output).compactMap(\.info)
    }

    private static func logGeminiProbeFailure(_ prefix: String, details: String) {
        NSLog("[GeminiDiag] %@ %@", prefix, details)
    }

    private static func unreadSnapshot(_ tab: ClaudeTabInfo) -> ClaudeTabSnapshot {
        ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "",
            foundDOM: false,
            textLength: 0
        )
    }

    private static let inspectRecordSeparator = "<<<ISLAND_PROBE>>>"

    /// Lists AI tabs and probes each one. Compiled once; same JS/JSON as before.
    private static var combinedPollScriptSource: String {
        let claudeJS = appleScriptEscape(claudeProbeJavaScript)
        let chatgptJS = appleScriptEscape(chatgptProbeJavaScript)
        let geminiJS = appleScriptEscape(geminiProbeJavaScript)
        return """
        tell application "Google Chrome"
          if (count of windows) is 0 then return ""
          set sep to "<<<ISLAND_TAB>>>"
          set recSep to "\(inspectRecordSeparator)"
          set claudeJS to "\(claudeJS)"
          set chatgptJS to "\(chatgptJS)"
          set geminiJS to "\(geminiJS)"
          set frontTid to 0
          set frontW to 1
          set frontT to 1
          set bestIdx to 999999
          repeat with w from 1 to count of windows
            try
              set widx to index of window w
              if widx < bestIdx then
                set bestIdx to widx
                set frontW to w
                set frontT to active tab index of window w
                set frontTid to id of active tab of window w
              end if
            end try
          end repeat
          set out to "ACTIVE" & sep & frontW & sep & frontT & sep & frontTid & linefeed
          repeat with w from 1 to count of windows
            repeat with t from 1 to count of tabs of window w
              set tabURL to URL of tab t of window w
              set tid to id of tab t of window w
              set providerName to "none"
              set js to ""
              if tabURL contains "claude.ai" or tabURL contains "claude.com" then
                set providerName to "claude"
                set js to claudeJS
              else if tabURL contains "chatgpt.com" or tabURL contains "chat.openai.com" then
                set providerName to "chatgpt"
                set js to chatgptJS
              else if tabURL contains "gemini.google.com" then
                set providerName to "gemini"
                set js to geminiJS
              end if
              set out to out & w & sep & t & sep & tid & sep & providerName & sep & tabURL & linefeed
              if js is not "" then
                try
                  set r to execute tab t of window w javascript (js as text)
                  set out to out & recSep & (tid as text) & recSep & (r as text) & linefeed
                on error errMsg number errNum
                  set out to out & recSep & (tid as text) & recSep & "err:" & errNum & ":" & errMsg & linefeed
                end try
              end if
            end repeat
          end repeat
          return out
        end tell
        """
    }

    private func runPollScript() -> ScriptResult {
        if compiledPollScript == nil {
            guard let script = NSAppleScript(source: Self.combinedPollScriptSource) else {
                NSLog("[ChatTabs] could not create poll AppleScript (source length=%d)", Self.combinedPollScriptSource.count)
                return runPollViaOSAScript()
            }
            var compileError: NSDictionary?
            if !script.compileAndReturnError(&compileError) {
                let message = String(describing: compileError?[NSAppleScript.errorMessage] ?? "compile failed")
                NSLog("[ChatTabs] poll AppleScript compile failed: %@", message)
                return runPollViaOSAScript()
            }
            compiledPollScript = script
        }
        guard let script = compiledPollScript else {
            return runPollViaOSAScript()
        }
        let result = Self.execute(script)
        if case .ok(let output) = result, output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSLog("[ChatTabs] in-process AppleScript empty; falling back to osascript")
            return runPollViaOSAScript()
        }
        return result
    }

    /// Child `osascript` has its own run loop, so Chrome JS runs without blocking the island.
    private func runPollViaOSAScript() -> ScriptResult {
        let url = Self.pollScriptFileURL
        if !wroteOSAScriptFile {
            do {
                try Self.combinedPollScriptSource.write(to: url, atomically: true, encoding: .utf8)
                wroteOSAScriptFile = true
            } catch {
                return .failed("Could not write poll script: \(error.localizedDescription)")
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [url.path]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failed(error.localizedDescription)
        }
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            if message.localizedCaseInsensitiveContains("not authorized") {
                return .denied
            }
            if message.localizedCaseInsensitiveContains("javascript") {
                return .javascriptDisabled
            }
            return .failed(message.isEmpty ? "osascript exit \(process.terminationStatus)" : message)
        }
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return .ok(output)
    }

    private static var pollScriptFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("island-chrome-poll.applescript")
    }

    static func parseBatchInspectOutput(_ output: String) -> [Int: String] {
        let sep = inspectRecordSeparator
        var map: [Int: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let record = String(line)
            guard record.hasPrefix(sep) else { continue }
            let fields = record.components(separatedBy: sep)
            guard fields.count >= 3,
                  let tabID = Int(fields[1].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            // JSON.stringify escapes embedded newlines, so every probe is one
            // physical line. Reading through to the next record separator used
            // to append all intervening Chrome tab-list rows to this payload,
            // making every poll result invalid JSON unless another AI tab
            // happened to follow immediately.
            map[tabID] = fields.dropFirst(2)
                .joined(separator: sep)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return map
    }

    private static func inspectResult(for tab: ClaudeTabInfo, raw: String) -> InspectResult {
        if raw.hasPrefix("err:") {
            if tab.provider == .gemini {
                logGeminiProbeFailure("execute javascript returned error:", details: raw)
            }
            if raw.localizedCaseInsensitiveContains("javascript") {
                return .needsJavaScriptPermission
            }
            return .unavailable(raw)
        }
        guard let parsed = parseProbeJSON(raw) else {
            if tab.provider == .gemini {
                logGeminiProbeFailure("parseProbeJSON failed for raw:", details: raw)
            }
            return .unavailable(raw.isEmpty ? "Missing inspect result." : "Could not parse chat tab JSON.")
        }
        let preview = (tab.provider == .gemini || parsed.foundDOM) ? parsed.preview : ""
        let foundDOM = parsed.foundDOM
            || (tab.provider == .gemini && (!parsed.preview.isEmpty || !parsed.networkCompletionToken.isEmpty))
        return .inspected(
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: parsed.isGenerating,
                preview: preview,
                foundDOM: foundDOM,
                textLength: parsed.textLength,
                assistantCount: parsed.assistantCount,
                latestUserPrompt: parsed.latestUserPrompt,
                latestUserFingerprint: parsed.latestUserFingerprint,
                replyFingerprint: parsed.replyFingerprint,
                replyAnchoredToLatestUser: parsed.replyAnchoredToLatestUser,
                networkCompletionToken: parsed.networkCompletionToken,
                pageVisible: tab.provider == .gemini ? false : parsed.pageVisible
            )
        )
    }

    private enum ScriptResult {
        case ok(String)
        case denied
        case javascriptDisabled
        case failed(String)
    }

    private static func runAppleScript(_ source: String, context: String? = nil) -> ScriptResult {
        guard let script = NSAppleScript(source: source) else {
            if let context {
                NSLog("[GeminiDiag] %@ could not create NSAppleScript", context)
            }
            return .failed("Could not create AppleScript.")
        }
        return execute(script, context: context)
    }

    private static func execute(_ script: NSAppleScript, context: String? = nil) -> ScriptResult {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = String(describing: error[NSAppleScript.errorMessage] ?? "")
            NSLog("[ChatTabs] AppleScript error number=%d message=%@", number, message)
            if number == -1743 || message.localizedCaseInsensitiveContains("not authorized") {
                return .denied
            }
            if message.localizedCaseInsensitiveContains("javascript") {
                return .javascriptDisabled
            }
            return .failed(message)
        }
        return .ok(result.stringValue ?? "")
    }

    private static func appleScriptEscape(_ js: String) -> String {
        js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Shared Stop-button / streaming detection. ChatGPT's composer often uses
    /// aria-label "Stop" (not "Stop generating"). Gemini may hide it in shadow DOM.
    private static let generatingHelperJavaScript = "function isStopLabel(s){s=(s||'').toLowerCase();if(!s)return false;if(s.indexOf('dictation')!==-1||s.indexOf('recording')!==-1||s.indexOf('listening')!==-1||s.indexOf('playback')!==-1)return false;return /(^|[^a-z])stop([^a-z]|$)/.test(s);}function scanGenerating(root,depth){if(!root||depth>5)return false;try{if(root.querySelector){if(root.querySelector('[data-testid=\"stop-button\"],[data-testid=\"composer-stop-button\"],.result-streaming,[data-is-streaming=\"true\"],button[aria-label=\"Stop\"],button[aria-label=\"Stop response\"]'))return true;var list=root.querySelectorAll('button,[role=\"button\"]');for(var i=0;i<list.length;i++){var label=((list[i].getAttribute('aria-label')||'')+' '+(list[i].getAttribute('data-testid')||'')+' '+(list[i].innerText||''));if(isStopLabel(label))return true;}var hosts=root.querySelectorAll('rich-textarea,gem-icon-button,mat-icon-button,speech-dictation-mic-button');for(var j=0;j<hosts.length;j++){if(hosts[j].shadowRoot&&scanGenerating(hosts[j].shadowRoot,depth+1))return true;}}}catch(e){}return false;}"

    private static var claudeProbeJavaScript: String {
        "(function(){"
        + generatingHelperJavaScript
        + "function isProcessOnly(t){var s=(t||'').toLowerCase().replace(/\\s+/g,' ').trim();if(!s)return true;var stages=['crystallizing','reckoning','thinking','researching','searching','analyzing','writing','crafting','planning','working','generating','reasoning','reading','browsing','synthesizing','reflecting','compiling','drafting'];var tokens=s.split(/[^a-z]+/).filter(Boolean);if(!tokens.length)return true;if(tokens.every(function(w){return stages.indexOf(w)!==-1;}))return true;if(tokens.length<=4&&stages.indexOf(tokens[0])!==-1)return true;return false;}"
        + "function cleanText(t){var s=(t||'').replace(/Show message actions for /ig,'').replace(/Claude responded:\\s*/ig,'').replace(/\\bjust now\\b/ig,' ').replace(/\\b\\d+\\s*(second|minute|hour|day|week|month|year)s?\\s+ago\\b/ig,' ').replace(/\\byesterday\\b/ig,' ').replace(/[\\uE000-\\uF8FF]/g,' ').replace(/\\s+/g,' ').trim();return s;}"
        + "function collectAssistants(){var texts=[];function push(t){t=cleanText(t||'');if(t&&!isProcessOnly(t)&&texts[texts.length-1]!==t)texts.push(t);}var rows=document.querySelectorAll('[data-testid=\"transcript-row\"]');rows.forEach(function(row){if(row.querySelector('[data-testid=\"user-message\"],[data-testid=\"human-message\"]'))return;push(row.innerText||'');});if(texts.length)return texts;var sels=['.font-claude-response','.font-claude-message','[data-testid=\"ai-message\"]','[data-testid=\"message-assistant\"]','[data-testid=\"assistant-message\"]','[data-testid=\"assistant-turn\"]','.assistant-message'];for(var s=0;s<sels.length;s++){var nodes=document.querySelectorAll(sels[s]);for(var i=0;i<nodes.length;i++){if(nodes[i].querySelector&&nodes[i].querySelector('[data-testid=\"user-message\"],[data-testid=\"human-message\"]'))continue;push(nodes[i].innerText||nodes[i].textContent||'');}if(texts.length)return texts;}var bars=document.querySelectorAll('[data-testid=\"action-bar-copy\"]');bars.forEach(function(bar){var el=bar.parentElement;var lastGood=el;for(var i=0;i<20&&el&&el!==document.body;i++){if(el.querySelector('[data-testid=\"user-message\"],[data-testid=\"human-message\"]'))break;lastGood=el;el=el.parentElement;}push(lastGood&&lastGood.innerText?lastGood.innerText:'');});return texts;}"
        + "var foundDOM=!!(document.querySelector('[data-testid=\"user-message\"]')||document.querySelector('[data-testid=\"human-message\"]')||document.querySelector('.font-claude-response')||document.querySelector('[data-testid=\"chat-input\"]')||document.querySelector('[data-testid=\"action-bar-copy\"]'));"
        + "var texts=collectAssistants();var text=texts.length?texts[texts.length-1]:'';var words=text?text.split(/\\s+/).filter(Boolean).slice(0,40).join(' '):'';"
        + "var generating=scanGenerating(document,0)||!!document.querySelector('[data-is-streaming=\"true\"]')||(words.length>0&&isProcessOnly(words));"
        + "return JSON.stringify({isGenerating:!!generating,preview:words,foundDOM:foundDOM,textLength:text.length,assistantCount:texts.length,pageVisible:(document.visibilityState==='visible'&&document.hidden===false)});})()"
    }

    private static var chatgptProbeJavaScript: String {
        "(function(){"
        + generatingHelperJavaScript
        + "function isProcessOnly(t){var s=(t||'').toLowerCase().replace(/\\s+/g,' ').trim();if(!s)return true;var stages=['thinking','researching','searching','analyzing','writing','crafting','planning','working','generating','reasoning','reading','browsing','synthesizing','reflecting','compiling','drafting','connecting','considering'];var tokens=s.split(/[^a-z]+/).filter(Boolean);if(!tokens.length)return true;if(tokens.every(function(w){return stages.indexOf(w)!==-1;}))return true;if(tokens.length<=4&&stages.indexOf(tokens[0])!==-1)return true;return false;}function cleanText(t){var s=(t||'').replace(/Show message actions for /ig,'').replace(/ChatGPT said:\\s*/ig,'').replace(/ChatGPT responded:\\s*/ig,'').replace(/You said:\\s*/ig,'').replace(/\\bjust now\\b/ig,' ').replace(/\\b\\d+\\s*(second|minute|hour|day|week|month|year)s?\\s+ago\\b/ig,' ').replace(/\\byesterday\\b/ig,' ').replace(/[\\uE000-\\uF8FF]/g,' ').replace(/\\s+/g,' ').trim();return s;}function collectAssistants(){var texts=[];var sels=['[data-message-author-role=\"assistant\"]','[data-turn=\"assistant\"]','[data-role=\"assistant\"]','[data-message-author=\"assistant\"]','.agent-turn'];for(var s=0;s<sels.length;s++){var nodes=document.querySelectorAll(sels[s]);for(var i=0;i<nodes.length;i++){var t=cleanText(nodes[i].innerText||'');if(t&&!isProcessOnly(t))texts.push(t);}if(texts.length)return texts;}return texts;}var foundDOM=!!(document.querySelector('[data-message-author-role=\"user\"]')||document.querySelector('#prompt-textarea')||document.querySelector('[data-testid=\"composer-text-input\"]')||document.querySelector('#composer')||document.querySelector('[data-message-author-role=\"assistant\"]'));var texts=collectAssistants();var text=texts.length?texts[texts.length-1]:'';var words=text?text.split(/\\s+/).filter(Boolean).slice(0,40).join(' '):'';var generating=scanGenerating(document,0)||(words.length>0&&isProcessOnly(words));return JSON.stringify({isGenerating:generating,preview:words,foundDOM:foundDOM,textLength:text.length,assistantCount:texts.length,pageVisible:(document.visibilityState==='visible'&&document.hidden===false)});})()"
    }

    /// Gemini freezes DOM painting in background tabs, but XHR still finishes.
    /// Capture StreamGenerate bodies and parse wrb.fr frames for real reply text.
    private static var geminiProbeJavaScript: String {
        "(function(){try{"
        + generatingHelperJavaScript
        + GeminiProbeScript.body
        + "}catch(e){return JSON.stringify({isGenerating:false,preview:'',foundDOM:false,textLength:0,assistantCount:0,probeError:String(e&&e.message||e)});}})()"
    }

    private struct ProbePayload: Decodable {
        var isGenerating: Bool?
        var preview: String?
        var foundDOM: Bool?
        var textLength: Int?
        var assistantCount: Int?
        var latestUserPrompt: String?
        var latestUserFingerprint: String?
        var replyFingerprint: String?
        var replyAnchoredToLatestUser: Bool?
        var networkCompletionToken: String?
        var pageVisible: Bool?
    }

    static func parseProbeJSON(_ raw: String) -> (isGenerating: Bool, preview: String, foundDOM: Bool, textLength: Int, assistantCount: Int, latestUserPrompt: String, latestUserFingerprint: String, replyFingerprint: String, replyAnchoredToLatestUser: Bool, networkCompletionToken: String, pageVisible: Bool)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        guard let data = text.data(using: .utf8) else { return nil }
        guard let payload = try? JSONDecoder().decode(ProbePayload.self, from: data) else { return nil }
        let preview = (payload.preview ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let latestUserPrompt = (payload.latestUserPrompt ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            payload.isGenerating ?? false,
            preview,
            payload.foundDOM ?? false,
            payload.textLength ?? 0,
            payload.assistantCount ?? 0,
            latestUserPrompt,
            payload.latestUserFingerprint ?? "",
            payload.replyFingerprint ?? "",
            payload.replyAnchoredToLatestUser ?? false,
            payload.networkCompletionToken ?? "",
            payload.pageVisible ?? false
        )
    }
}
