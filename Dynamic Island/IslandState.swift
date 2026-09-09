import Foundation

/// Long-lived island content. Survives transient notifications.
enum PersistentState: Equatable {
    case idle
    case musicPlaying
}

enum ChatProvider: String, Equatable, CaseIterable {
    case claude
    case chatgpt
    case gemini

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .gemini: return "Gemini"
        }
    }

    var logoAssetName: String {
        switch self {
        case .claude: return "ClaudeLogo"
        case .chatgpt: return "ChatGPTLogo"
        case .gemini: return "GeminiLogo"
        }
    }

    static func from(url: String) -> ChatProvider? {
        let lowered = url.lowercased()
        if lowered.contains("claude.ai") || lowered.contains("claude.com") {
            return .claude
        }
        if lowered.contains("chatgpt.com") || lowered.contains("chat.openai.com") {
            return .chatgpt
        }
        if lowered.contains("gemini.google.com") {
            return .gemini
        }
        return nil
    }
}

struct ClaudeTabInfo: Equatable, Hashable {
    /// Stable Chrome tab id — survives window reorder.
    var tabID: Int
    /// Latest window/tab indices for activation (may change).
    var windowIndex: Int
    var tabIndex: Int
    var provider: ChatProvider = .claude
    /// Exact page URL, used when Chrome extension and AppleScript tab IDs differ.
    var url: String = ""

    func hash(into hasher: inout Hasher) {
        hasher.combine(tabID)
    }

    static func == (lhs: ClaudeTabInfo, rhs: ClaudeTabInfo) -> Bool {
        lhs.tabID == rhs.tabID
    }
}

/// Short-lived layer drawn on top of `PersistentState`. Clearing it must not
/// mutate music playback or other persistent fields.
enum TransientOverlay: Equatable {
    case chatReady(preview: String, tab: ClaudeTabInfo)
    case charging(percent: Int)
    case lowBattery(percent: Int)
    case volume(percent: Int, muted: Bool)
    case brightness(percent: Int)
    case focusMode(isOn: Bool)

    var preview: String {
        switch self {
        case .chatReady(let preview, _):
            return preview
        case .charging, .lowBattery, .volume, .brightness, .focusMode:
            return ""
        }
    }

    var tab: ClaudeTabInfo {
        switch self {
        case .chatReady(_, let tab):
            return tab
        case .charging, .lowBattery, .volume, .brightness, .focusMode:
            return ClaudeTabInfo(tabID: -1, windowIndex: 0, tabIndex: 0)
        }
    }

    var provider: ChatProvider {
        tab.provider
    }

    var isChat: Bool {
        if case .chatReady = self { return true }
        return false
    }

    /// Charging, Focus, volume, and brightness already have island banners.
    /// Hide the matching macOS HUD / Control Center bezel for those only.
    var replacesSystemHUD: Bool {
        switch self {
        case .charging, .lowBattery, .volume, .brightness, .focusMode:
            return true
        case .chatReady:
            return false
        }
    }
}

extension Notification.Name {
    static let previewClaudeReady = Notification.Name("island.previewClaudeReady")
    static let previewChatReady = Notification.Name("island.previewChatReady")
    static let previewCharging = Notification.Name("island.previewCharging")
    static let previewLowBattery = Notification.Name("island.previewLowBattery")
    static let previewSound = Notification.Name("island.previewSound")
    static let previewBrightness = Notification.Name("island.previewBrightness")
    static let previewFocusMode = Notification.Name("island.previewFocusMode")
    static let previewScreenRecording = Notification.Name("island.previewScreenRecording")
    static let previewRecordingChat = Notification.Name("island.previewRecordingChat")
    static let previewShelfHold = Notification.Name("island.previewShelfHold")
    static let previewShelfDrop = Notification.Name("island.previewShelfDrop")
    static let previewShelfClear = Notification.Name("island.previewShelfClear")
    static let overlayActivated = Notification.Name("island.overlayActivated")
    static let overlayCleared = Notification.Name("island.overlayCleared")
    static let islandIdleGlanceExpanded = Notification.Name("island.idleGlanceExpanded")
}

struct ClaudeTabSnapshot: Equatable {
    var tab: ClaudeTabInfo
    var isGenerating: Bool
    var preview: String
    var foundDOM: Bool
    var textLength: Int = 0
    var assistantCount: Int = 0
    var latestUserPrompt: String = ""
    var latestUserFingerprint: String = ""
    var replyFingerprint: String = ""
    var replyAnchoredToLatestUser: Bool = false
    /// Browser-recorded completion marker for providers whose rendered DOM can
    /// freeze in a background tab (currently Gemini).
    var networkCompletionToken: String = ""
    /// True when this tab's document is visible (user is looking at it).
    var pageVisible: Bool = false
}

/// Emits only after a live generation finishes with a *new* final reply.
/// Never notifies for:
/// - process stages (crystallizing / reckoning / …)
/// - already-visible older replies (including timestamp-only DOM churn)
struct ClaudeTabTracker {
    private var shownFingerprint: [Int: String] = [:]
    private var fingerprintWhenGeneratingStarted: [Int: String] = [:]
    private var generationStartedFromEmpty: Set<Int> = []
    private var wasGenerating: [Int: Bool] = [:]
    /// Last *observed* fingerprint/length, updated every poll. Used to detect
    /// streaming when the site's Stop button isn't visible to AppleScript JS.
    private var lastObservedFingerprint: [Int: String] = [:]
    private var lastObservedTextLength: [Int: Int] = [:]
    private var lastObservedAssistantCount: [Int: Int] = [:]
    private var lastObservedNetworkCompletion: [Int: String] = [:]
    private var lastObservedGeminiPromptFingerprint: [Int: String] = [:]
    private var lastObservedGeminiReplyFingerprint: [Int: String] = [:]
    private var notifiedNetworkToken: [Int: String] = [:]
    private var lastNotifiedGeminiPromptFingerprint: [Int: String] = [:]
    private var lastNotifiedAssistantCount: [Int: Int] = [:]
    private var lastNotifiedPreview: [Int: String] = [:]
    private var candidateSnapshotDuringGeneration: [Int: ClaudeTabSnapshot] = [:]
    private var snoozeUntil: [Int: Date] = [:]
    private var hasBaselined = false

    var hasInFlightGeneration: Bool {
        wasGenerating.values.contains(true)
    }

    var inFlightTabIDs: Set<Int> {
        Set(wasGenerating.compactMap { $0.value ? $0.key : nil })
    }

    mutating func reset() {
        shownFingerprint.removeAll()
        fingerprintWhenGeneratingStarted.removeAll()
        generationStartedFromEmpty.removeAll()
        wasGenerating.removeAll()
        lastObservedFingerprint.removeAll()
        lastObservedTextLength.removeAll()
        lastObservedAssistantCount.removeAll()
        lastObservedNetworkCompletion.removeAll()
        lastObservedGeminiPromptFingerprint.removeAll()
        lastObservedGeminiReplyFingerprint.removeAll()
        notifiedNetworkToken.removeAll()
        lastNotifiedGeminiPromptFingerprint.removeAll()
        lastNotifiedAssistantCount.removeAll()
        lastNotifiedPreview.removeAll()
        candidateSnapshotDuringGeneration.removeAll()
        snoozeUntil.removeAll()
        hasBaselined = false
    }

    /// User is looking at this tab. Treat the on-screen reply as already seen so
    /// switching away later does not pop the island for the same answer.
    /// Thinking chips are ignored so leaving mid-generation can still notify.
    mutating func noteUserIsViewing(_ snap: ClaudeTabSnapshot) {
        guard snap.foundDOM else { return }
        let cleaned = Self.cleanedPreview(snap.preview)
        guard cleaned.count >= 8, !Self.isProcessStage(cleaned) else { return }

        let id = snap.tab.tabID
        let fp = Self.fingerprint(snap)
        shownFingerprint[id] = fp
        lastNotifiedPreview[id] = cleaned
        lastNotifiedAssistantCount[id] = snap.assistantCount
        if !snap.latestUserFingerprint.isEmpty {
            lastNotifiedGeminiPromptFingerprint[id] = snap.latestUserFingerprint
        }
        if !snap.networkCompletionToken.isEmpty {
            notifiedNetworkToken[id] = snap.networkCompletionToken
        }
        if !Self.isLiveGenerating(snap) {
            wasGenerating[id] = false
            fingerprintWhenGeneratingStarted[id] = nil
            candidateSnapshotDuringGeneration.removeValue(forKey: id)
            generationStartedFromEmpty.remove(id)
        }
    }

    /// User already opened this reply. Ignore further banners for the tab until
    /// a *new* generation starts (Stop / thinking), or the snooze elapses.
    mutating func acknowledge(
        tabID: Int,
        preview: String,
        assistantCount: Int,
        replyFingerprint: String = "",
        userFingerprint: String = ""
    ) {
        let cleaned = Self.cleanedPreview(preview)
        lastNotifiedPreview[tabID] = cleaned
        lastNotifiedAssistantCount[tabID] = assistantCount
        shownFingerprint[tabID] = "\(assistantCount)#\(cleaned.prefix(160))"
        wasGenerating[tabID] = false
        fingerprintWhenGeneratingStarted[tabID] = nil
        generationStartedFromEmpty.remove(tabID)
        candidateSnapshotDuringGeneration.removeValue(forKey: tabID)
        snoozeUntil[tabID] = Date().addingTimeInterval(45)
        if let token = lastObservedNetworkCompletion[tabID], !token.isEmpty {
            notifiedNetworkToken[tabID] = token
        }
        if !cleaned.isEmpty {
            // Push path: also lock the reply fingerprint so a late poll cannot re-fire.
            lastObservedFingerprint[tabID] = shownFingerprint[tabID]
        }
        let replyFP = replyFingerprint.isEmpty ? Self.makeContentFingerprint(cleaned) : replyFingerprint
        if !replyFP.isEmpty {
            lastObservedGeminiReplyFingerprint[tabID] = replyFP
        }
        if !userFingerprint.isEmpty {
            lastNotifiedGeminiPromptFingerprint[tabID] = userFingerprint
            lastObservedGeminiPromptFingerprint[tabID] = userFingerprint
        }
    }

    /// Instant path from the Chrome extension. No poll-wait, no stale Gemini candidate text.
    mutating func ingestPush(_ snap: ClaudeTabSnapshot) -> ClaudeTabSnapshot? {
        let cleaned = Self.cleanedPreview(snap.preview)
        guard cleaned.count >= 8, !Self.isProcessStage(cleaned) else { return nil }
        guard !Self.looksLikeGeminiWireNoise(cleaned) else { return nil }

        let id = snap.tab.tabID
        let replyFP = snap.replyFingerprint.isEmpty
            ? Self.makeContentFingerprint(cleaned)
            : snap.replyFingerprint
        let userFP = snap.latestUserFingerprint

        if snap.tab.provider == .gemini, userFP.isEmpty {
            return nil
        }

        let isPlaceholderReply = cleaned.caseInsensitiveCompare("Gemini response ready") == .orderedSame
            || replyFP.hasPrefix("gemini-request#")

        if let until = snoozeUntil[id], until > Date() {
            // User already opened / we already announced this tab's reply.
            // Only a brand-new user prompt should reopen the island during snooze.
            // A later webRequest token must not bypass this — it was double-bannering
            // the same Gemini turn (DOM push, then "Gemini response ready").
            let lastPrompt = lastNotifiedGeminiPromptFingerprint[id] ?? ""
            let isNewUserTurn = !userFP.isEmpty && userFP != lastPrompt
            if !isNewUserTurn {
                if !replyFP.isEmpty && !replyFP.hasPrefix("gemini-request#") {
                    lastObservedGeminiReplyFingerprint[id] = replyFP
                }
                return nil
            }
        }

        if isPlaceholderReply, lastNotifiedPreview[id] != nil {
            return nil
        }

        if let lastReply = lastObservedGeminiReplyFingerprint[id], !lastReply.isEmpty, lastReply == replyFP {
            return nil
        }
        if let lastPreview = lastNotifiedPreview[id], lastPreview == cleaned {
            return nil
        }

        // Gemini helper can emit the already-open thread after a reload or
        // reconnect. Seed it; only a later new prompt/reply should banner.
        if snap.tab.provider == .gemini,
           wasGenerating[id] != true,
           !generationStartedFromEmpty.contains(id),
           snap.networkCompletionToken.isEmpty,
           lastNotifiedPreview[id] == nil,
           (lastObservedGeminiReplyFingerprint[id] ?? "").isEmpty {
            shownFingerprint[id] = Self.fingerprint(snap)
            lastObservedFingerprint[id] = shownFingerprint[id]
            lastObservedTextLength[id] = snap.textLength
            lastObservedAssistantCount[id] = snap.assistantCount
            lastNotifiedPreview[id] = cleaned
            lastNotifiedAssistantCount[id] = snap.assistantCount
            if !userFP.isEmpty {
                lastNotifiedGeminiPromptFingerprint[id] = userFP
                lastObservedGeminiPromptFingerprint[id] = userFP
            }
            if !replyFP.isEmpty {
                lastObservedGeminiReplyFingerprint[id] = replyFP
            }
            hasBaselined = true
            return nil
        }

        var finished = snap
        finished.isGenerating = false
        finished.preview = cleaned
        finished.replyFingerprint = replyFP
        finished.replyAnchoredToLatestUser = snap.replyAnchoredToLatestUser || !userFP.isEmpty

        shownFingerprint[id] = Self.fingerprint(finished)
        lastObservedFingerprint[id] = shownFingerprint[id]
        lastObservedTextLength[id] = finished.textLength
        lastObservedAssistantCount[id] = finished.assistantCount
        lastNotifiedPreview[id] = cleaned
        lastNotifiedAssistantCount[id] = finished.assistantCount
        if !userFP.isEmpty {
            lastNotifiedGeminiPromptFingerprint[id] = userFP
            lastObservedGeminiPromptFingerprint[id] = userFP
        }
        if !replyFP.isEmpty {
            lastObservedGeminiReplyFingerprint[id] = replyFP
        }
        if !finished.networkCompletionToken.isEmpty {
            lastObservedNetworkCompletion[id] = finished.networkCompletionToken
            notifiedNetworkToken[id] = finished.networkCompletionToken
        }
        fingerprintWhenGeneratingStarted[id] = nil
        wasGenerating[id] = false
        generationStartedFromEmpty.remove(id)
        candidateSnapshotDuringGeneration.removeValue(forKey: id)
        snoozeUntil[id] = Date().addingTimeInterval(45)
        hasBaselined = true
        return finished
    }

    static func makeContentFingerprint(_ text: String) -> String {
        let cleaned = cleanedPreview(text)
        guard !cleaned.isEmpty else { return "" }
        return "\(cleaned.count)#\(cleaned.prefix(200))"
    }

    mutating func ingest(_ snapshots: [ClaudeTabSnapshot]) -> ClaudeTabSnapshot? {
        let live = Set(snapshots.map(\.tab.tabID))
        shownFingerprint = shownFingerprint.filter { live.contains($0.key) }
        fingerprintWhenGeneratingStarted = fingerprintWhenGeneratingStarted.filter { live.contains($0.key) }
        generationStartedFromEmpty = Set(generationStartedFromEmpty.filter { live.contains($0) })
        wasGenerating = wasGenerating.filter { live.contains($0.key) }
        lastObservedFingerprint = lastObservedFingerprint.filter { live.contains($0.key) }
        lastObservedTextLength = lastObservedTextLength.filter { live.contains($0.key) }
        lastObservedAssistantCount = lastObservedAssistantCount.filter { live.contains($0.key) }
        lastObservedNetworkCompletion = lastObservedNetworkCompletion.filter { live.contains($0.key) }
        lastObservedGeminiPromptFingerprint = lastObservedGeminiPromptFingerprint.filter { live.contains($0.key) }
        lastObservedGeminiReplyFingerprint = lastObservedGeminiReplyFingerprint.filter { live.contains($0.key) }
        notifiedNetworkToken = notifiedNetworkToken.filter { live.contains($0.key) }
        lastNotifiedGeminiPromptFingerprint = lastNotifiedGeminiPromptFingerprint.filter { live.contains($0.key) }
        lastNotifiedAssistantCount = lastNotifiedAssistantCount.filter { live.contains($0.key) }
        lastNotifiedPreview = lastNotifiedPreview.filter { live.contains($0.key) }
        candidateSnapshotDuringGeneration = candidateSnapshotDuringGeneration.filter { live.contains($0.key) }
        snoozeUntil = snoozeUntil.filter { live.contains($0.key) }

        if !hasBaselined {
            for snap in snapshots {
                let id = snap.tab.tabID
                let fp = Self.fingerprint(snap)
                shownFingerprint[id] = fp
                lastObservedFingerprint[id] = fp
                lastObservedTextLength[id] = snap.textLength
                lastObservedAssistantCount[id] = snap.assistantCount
                if !snap.networkCompletionToken.isEmpty {
                    lastObservedNetworkCompletion[id] = snap.networkCompletionToken
                }
                if snap.tab.provider == .gemini {
                    if !snap.latestUserFingerprint.isEmpty {
                        lastObservedGeminiPromptFingerprint[id] = snap.latestUserFingerprint
                    }
                    if !snap.replyFingerprint.isEmpty {
                        lastObservedGeminiReplyFingerprint[id] = snap.replyFingerprint
                    }
                }
                // Empty / unread tabs are not "generating". Treating "" as a
                // process stage used to mark every new Claude tab in-flight, then
                // fire when the old transcript finally painted.
                wasGenerating[id] = Self.isLiveGenerating(snap)
                if snap.tab.provider == .gemini, wasGenerating[id] == true, Self.isEmptyFingerprint(fp) {
                    generationStartedFromEmpty.insert(id)
                }
            }
            hasBaselined = true
            return nil
        }

        var best: ClaudeTabSnapshot?
        for snap in snapshots where snap.foundDOM {
            let id = snap.tab.tabID
            let processStage = Self.isProcessStage(snap.preview)
            let fp = Self.fingerprint(snap)
            let lastFp = lastObservedFingerprint[id]
            let lastLen = lastObservedTextLength[id] ?? 0
            let lastCount = lastObservedAssistantCount[id] ?? 0
            let priorNetworkCompletion = lastObservedNetworkCompletion[id]
            let priorGeminiPromptFingerprint = lastObservedGeminiPromptFingerprint[id] ?? ""
            let priorGeminiReplyFingerprint = lastObservedGeminiReplyFingerprint[id] ?? ""
            let networkCompleted = snap.tab.provider == .gemini
                && !snap.networkCompletionToken.isEmpty
                && snap.networkCompletionToken != priorNetworkCompletion
            let contentMoving = snap.assistantCount > lastCount
                || snap.textLength > lastLen + 32
                || (lastFp != nil && lastFp != fp && snap.textLength > lastLen + 24)
            lastObservedFingerprint[id] = fp
            lastObservedTextLength[id] = snap.textLength
            lastObservedAssistantCount[id] = snap.assistantCount
            if !snap.networkCompletionToken.isEmpty {
                lastObservedNetworkCompletion[id] = snap.networkCompletionToken
            }
            if snap.tab.provider == .gemini {
                if !snap.latestUserFingerprint.isEmpty {
                    lastObservedGeminiPromptFingerprint[id] = snap.latestUserFingerprint
                }
                if !snap.replyFingerprint.isEmpty {
                    lastObservedGeminiReplyFingerprint[id] = snap.replyFingerprint
                }
            }

            let liveGenerating = Self.isLiveGenerating(snap)

            guard let previous = shownFingerprint[id] else {
                shownFingerprint[id] = fp
                wasGenerating[id] = liveGenerating
                candidateSnapshotDuringGeneration[id] = nil
                if snap.tab.provider == .gemini, liveGenerating, Self.isEmptyFingerprint(fp) {
                    generationStartedFromEmpty.insert(id)
                }
                continue
            }

            if snap.tab.provider == .gemini {
                let cleaned = Self.cleanedPreview(snap.preview)
                let lastNotifiedPrompt = lastNotifiedGeminiPromptFingerprint[id] ?? ""
                let alreadyNotifiedPrompt = !snap.latestUserFingerprint.isEmpty
                    && snap.latestUserFingerprint == lastNotifiedPrompt
                // Compare against the prompt we last announced, not the last poll.
                // Otherwise a new prompt seen while generating consumes promptChanged
                // and the 45s snooze from the previous island swallows the reply.
                let promptChanged = !snap.latestUserFingerprint.isEmpty
                    && snap.latestUserFingerprint != (lastNotifiedPrompt.isEmpty
                        ? priorGeminiPromptFingerprint
                        : lastNotifiedPrompt)
                let replyChanged = !snap.replyFingerprint.isEmpty
                    && snap.replyFingerprint != priorGeminiReplyFingerprint
                let staleReplyOnNewPrompt = promptChanged
                    && !snap.replyFingerprint.isEmpty
                    && snap.replyFingerprint == priorGeminiReplyFingerprint
                    && !priorGeminiReplyFingerprint.isEmpty
                let hasReliablePair = snap.replyAnchoredToLatestUser
                    && !snap.latestUserFingerprint.isEmpty
                    && !snap.replyFingerprint.isEmpty
                    && cleaned.count >= 8
                    && !Self.isProcessStage(cleaned)
                    && !Self.looksLikeGeminiWireNoise(cleaned)
                    && !staleReplyOnNewPrompt
                let sameTurnAsLastObserved = !snap.latestUserFingerprint.isEmpty
                    && snap.latestUserFingerprint == priorGeminiPromptFingerprint
                    && !snap.replyFingerprint.isEmpty
                    && snap.replyFingerprint == priorGeminiReplyFingerprint
                    && !priorGeminiReplyFingerprint.isEmpty

                // Stream finished in the network even if Stop/pending still
                // looks generating — fall through and announce the pair.
                let streamFinishedWhileFlagged = networkCompleted && hasReliablePair
                if liveGenerating, !streamFinishedWhileFlagged {
                    if hasReliablePair {
                        let candidate = ClaudeTabSnapshot(
                            tab: snap.tab,
                            isGenerating: true,
                            preview: cleaned,
                            foundDOM: snap.foundDOM,
                            textLength: snap.textLength,
                            assistantCount: snap.assistantCount,
                            latestUserPrompt: snap.latestUserPrompt,
                            latestUserFingerprint: snap.latestUserFingerprint,
                            replyFingerprint: snap.replyFingerprint,
                            replyAnchoredToLatestUser: true,
                            networkCompletionToken: snap.networkCompletionToken
                        )
                        let existingCandidate = candidateSnapshotDuringGeneration[id]
                        let existingIsSamePrompt = existingCandidate?.latestUserFingerprint == snap.latestUserFingerprint
                        if !(existingIsSamePrompt && (existingCandidate?.textLength ?? 0) > snap.textLength) {
                            candidateSnapshotDuringGeneration[id] = candidate
                        }
                    }
                    wasGenerating[id] = true
                    shownFingerprint[id] = fp.isEmpty ? previous : fp
                    continue
                }

                if alreadyNotifiedPrompt {
                    shownFingerprint[id] = fp.isEmpty ? previous : fp
                    wasGenerating[id] = false
                    candidateSnapshotDuringGeneration[id] = nil
                    if !snap.networkCompletionToken.isEmpty {
                        notifiedNetworkToken[id] = snap.networkCompletionToken
                    }
                    continue
                }
                if sameTurnAsLastObserved && !promptChanged && !networkCompleted {
                    shownFingerprint[id] = fp.isEmpty ? previous : fp
                    wasGenerating[id] = false
                    candidateSnapshotDuringGeneration[id] = nil
                    continue
                }

                var finished: ClaudeTabSnapshot?
                if hasReliablePair {
                    finished = snap
                    finished?.preview = cleaned
                }
                if let candidate = candidateSnapshotDuringGeneration[id],
                   candidate.replyAnchoredToLatestUser,
                   !candidate.latestUserFingerprint.isEmpty,
                   candidate.latestUserFingerprint == snap.latestUserFingerprint || snap.latestUserFingerprint.isEmpty {
                    let candidateCleaned = Self.cleanedPreview(candidate.preview)
                    if candidateCleaned.count >= 8, !Self.isProcessStage(candidateCleaned) {
                        if finished == nil || snap.textLength + 48 < candidate.textLength {
                            finished = candidate
                            finished?.preview = candidateCleaned
                        }
                    }
                }

                let networkFinishedWatchedTurn = networkCompleted
                    && (wasGenerating[id] == true
                        || generationStartedFromEmpty.contains(id)
                        || priorGeminiReplyFingerprint.isEmpty
                        || promptChanged
                        || replyChanged)

                if let finishedReply = finished,
                   (promptChanged || replyChanged || wasGenerating[id] == true || networkFinishedWatchedTurn) {
                    let finishedPreview = Self.cleanedPreview(finishedReply.preview)
                    guard finishedPreview.count >= 8, !Self.isProcessStage(finishedPreview) else {
                        shownFingerprint[id] = fp.isEmpty ? previous : fp
                        wasGenerating[id] = !hasReliablePair
                        if hasReliablePair {
                            candidateSnapshotDuringGeneration[id] = nil
                        }
                        continue
                    }
                    var notifySnap = finishedReply
                    notifySnap.isGenerating = false
                    notifySnap.preview = finishedPreview
                    shownFingerprint[id] = Self.fingerprint(notifySnap)
                    lastNotifiedPreview[id] = finishedPreview
                    lastNotifiedAssistantCount[id] = notifySnap.assistantCount
                    lastNotifiedGeminiPromptFingerprint[id] = notifySnap.latestUserFingerprint.isEmpty
                        ? snap.latestUserFingerprint
                        : notifySnap.latestUserFingerprint
                    if !notifySnap.networkCompletionToken.isEmpty {
                        notifiedNetworkToken[id] = notifySnap.networkCompletionToken
                    }
                    fingerprintWhenGeneratingStarted[id] = nil
                    wasGenerating[id] = false
                    generationStartedFromEmpty.remove(id)
                    candidateSnapshotDuringGeneration[id] = nil
                    snoozeUntil[id] = Date().addingTimeInterval(45)
                    if best == nil || notifySnap.assistantCount >= (best?.assistantCount ?? 0) {
                        best = notifySnap
                    }
                    continue
                }

                shownFingerprint[id] = fp.isEmpty ? previous : fp
                // A prompt with no matched reply is in-flight only when it is a
                // *new* turn (or Stop is showing). Idle tabs whose DOM has not
                // finished hydrating must not be marked generating — that was
                // re-bannered old Gemini answers later.
                if !hasReliablePair,
                   !snap.latestUserFingerprint.isEmpty,
                   !alreadyNotifiedPrompt,
                   (liveGenerating
                    || promptChanged
                    || generationStartedFromEmpty.contains(id)
                    || (wasGenerating[id] == true
                        && (cleaned.isEmpty || Self.isProcessStage(cleaned)))) {
                    wasGenerating[id] = true
                } else {
                    wasGenerating[id] = false
                    candidateSnapshotDuringGeneration[id] = nil
                }
                continue
            }

            // Already announced this Gemini stream — absorb delayed DOM paint.
            if let notified = notifiedNetworkToken[id],
               !notified.isEmpty,
               notified == snap.networkCompletionToken || notified == lastObservedNetworkCompletion[id],
               !networkCompleted {
                shownFingerprint[id] = fp.isEmpty ? previous : fp
                wasGenerating[id] = false
                fingerprintWhenGeneratingStarted[id] = nil
                candidateSnapshotDuringGeneration[id] = nil
                continue
            }

            // Gemini's network stream completes in a background tab even when
            // Chrome postpones painting the final response into the DOM.
            if networkCompleted {
                if notifiedNetworkToken[id] == snap.networkCompletionToken {
                    continue
                }
                let cleaned = Self.cleanedPreview(snap.preview)
                // Wait for wrb.fr / DOM preview — never banner the placeholder.
                if cleaned.count < 8 || Self.isProcessStage(cleaned) {
                    lastObservedNetworkCompletion[id] = priorNetworkCompletion
                    wasGenerating[id] = true
                    continue
                }
                var finished = snap
                finished.isGenerating = false
                finished.preview = cleaned
                let notifyFP = Self.fingerprint(finished)
                // Historical StreamGenerate (or a late performance entry) must
                // not re-announce the reply we already baselined — including
                // when an unread tab later paints an old transcript.
                let watchedThisStream = wasGenerating[id] == true
                if !watchedThisStream,
                   (Self.isEmptyFingerprint(previous)
                    || notifyFP == previous
                    || Self.preview(fromFingerprint: previous) == String(cleaned.prefix(160))) {
                    notifiedNetworkToken[id] = snap.networkCompletionToken
                    shownFingerprint[id] = notifyFP
                    wasGenerating[id] = false
                    fingerprintWhenGeneratingStarted[id] = nil
                    candidateSnapshotDuringGeneration[id] = nil
                    continue
                }
                shownFingerprint[id] = notifyFP
                lastNotifiedPreview[id] = cleaned
                lastNotifiedAssistantCount[id] = snap.assistantCount
                notifiedNetworkToken[id] = snap.networkCompletionToken
                lastObservedNetworkCompletion[id] = snap.networkCompletionToken
                wasGenerating[id] = false
                fingerprintWhenGeneratingStarted[id] = nil
                candidateSnapshotDuringGeneration[id] = nil
                snoozeUntil[id] = Date().addingTimeInterval(45)
                if best == nil || finished.assistantCount >= (best?.assistantCount ?? 0) {
                    best = finished
                }
                continue
            }

            // First time this tab became readable — seed, don't treat as a new reply.
            if Self.isEmptyFingerprint(previous), wasGenerating[id] != true {
                let cleaned = Self.cleanedPreview(snap.preview)
                if snap.tab.provider == .gemini,
                   !Self.isEmptyFingerprint(fp),
                   cleaned.count >= 8,
                   lastFp == previous {
                    if let until = snoozeUntil[id], until > Date() {
                        shownFingerprint[id] = fp
                        wasGenerating[id] = false
                        candidateSnapshotDuringGeneration[id] = nil
                        continue
                    }
                    snoozeUntil[id] = nil
                    shownFingerprint[id] = fp
                    wasGenerating[id] = false
                    generationStartedFromEmpty.remove(id)
                    candidateSnapshotDuringGeneration[id] = nil
                    lastNotifiedAssistantCount[id] = snap.assistantCount
                    lastNotifiedPreview[id] = cleaned
                    var finished = snap
                    finished.preview = cleaned
                    if best == nil || finished.assistantCount >= (best?.assistantCount ?? 0) {
                        best = finished
                    }
                    continue
                }
                shownFingerprint[id] = fp
                wasGenerating[id] = liveGenerating
                candidateSnapshotDuringGeneration[id] = nil
                if snap.tab.provider == .gemini, liveGenerating {
                    generationStartedFromEmpty.insert(id)
                } else {
                    generationStartedFromEmpty.remove(id)
                }
                continue
            }

            if liveGenerating {
                // Do not clear snooze for a stream we already announced; the
                // delayed Gemini paint can briefly look like a new generation.
                let alreadyNotifiedThisStream = notifiedNetworkToken[id] != nil
                    && notifiedNetworkToken[id] == lastObservedNetworkCompletion[id]
                if snoozeUntil[id] != nil, !alreadyNotifiedThisStream {
                    snoozeUntil[id] = nil
                    notifiedNetworkToken[id] = nil
                }
                if alreadyNotifiedThisStream {
                    wasGenerating[id] = false
                    generationStartedFromEmpty.remove(id)
                    candidateSnapshotDuringGeneration[id] = nil
                    continue
                }
                if wasGenerating[id] != true {
                    fingerprintWhenGeneratingStarted[id] = processStage ? fp : previous
                    candidateSnapshotDuringGeneration[id] = nil
                    if snap.tab.provider == .gemini, Self.isEmptyFingerprint(previous) {
                        generationStartedFromEmpty.insert(id)
                    }
                }
                if snap.tab.provider == .gemini {
                    let cleaned = Self.cleanedPreview(snap.preview)
                    let before = fingerprintWhenGeneratingStarted[id] ?? previous
                    if cleaned.count >= 8, !Self.isProcessStage(cleaned), fp != before {
                        let candidate = ClaudeTabSnapshot(
                            tab: snap.tab,
                            isGenerating: true,
                            preview: cleaned,
                            foundDOM: snap.foundDOM,
                            textLength: snap.textLength,
                            assistantCount: snap.assistantCount,
                            networkCompletionToken: snap.networkCompletionToken
                        )
                        if let existing = candidateSnapshotDuringGeneration[id] {
                            if candidate.textLength >= existing.textLength || candidate.assistantCount >= existing.assistantCount {
                                candidateSnapshotDuringGeneration[id] = candidate
                            }
                        } else {
                            candidateSnapshotDuringGeneration[id] = candidate
                        }
                    }
                }
                wasGenerating[id] = true
                continue
            }

            // First jump of a reply with no Stop button — wait until the next
            // poll so we don't banner an old conversation that just became readable.
            if contentMoving, wasGenerating[id] != true {
                if Self.isEmptyFingerprint(previous) {
                    shownFingerprint[id] = fp
                    wasGenerating[id] = false
                    fingerprintWhenGeneratingStarted[id] = nil
                    candidateSnapshotDuringGeneration[id] = nil
                    continue
                }
                fingerprintWhenGeneratingStarted[id] = previous
                candidateSnapshotDuringGeneration[id] = nil
                wasGenerating[id] = true
                continue
            }

            let previouslyGenerating = wasGenerating[id] ?? false

            guard previouslyGenerating else {
                if !fp.isEmpty {
                    shownFingerprint[id] = previous
                }
                fingerprintWhenGeneratingStarted[id] = nil
                candidateSnapshotDuringGeneration[id] = nil
                continue
            }

            // Notify as soon as generation has been observed and Stop/thinking is gone.
            let before = fingerprintWhenGeneratingStarted[id] ?? previous

            guard !processStage, fp != before, fp != previous, !Self.isProcessStage(snap.preview) else {
                if !contentMoving {
                    if Self.isEmptyFingerprint(fp), generationStartedFromEmpty.contains(id) {
                        shownFingerprint[id] = previous
                        continue
                    }
                    wasGenerating[id] = false
                    fingerprintWhenGeneratingStarted[id] = nil
                    generationStartedFromEmpty.remove(id)
                    candidateSnapshotDuringGeneration[id] = nil
                }
                shownFingerprint[id] = previous
                continue
            }

            let cleaned = Self.cleanedPreview(snap.preview)
            guard cleaned.count >= 2 else {
                shownFingerprint[id] = previous
                continue
            }

            // Empty → full transcript is hydration of an old thread, not a reply
            // that started while we were watching.
            if Self.isEmptyFingerprint(before), !generationStartedFromEmpty.contains(id) {
                shownFingerprint[id] = fp
                lastObservedFingerprint[id] = fp
                wasGenerating[id] = false
                fingerprintWhenGeneratingStarted[id] = nil
                continue
            }
            generationStartedFromEmpty.remove(id)

            if let until = snoozeUntil[id], until > Date() {
                shownFingerprint[id] = fp
                wasGenerating[id] = false
                candidateSnapshotDuringGeneration[id] = nil
                continue
            }
            snoozeUntil[id] = nil

            var finished = snap
            finished.preview = cleaned
            if snap.tab.provider == .gemini,
               let candidate = candidateSnapshotDuringGeneration[id] {
                let candidateCleaned = Self.cleanedPreview(candidate.preview)
                let currentLooksStale = fp == before
                    || snap.textLength + 48 < candidate.textLength
                    || snap.assistantCount < candidate.assistantCount
                if candidateCleaned.count >= 8, currentLooksStale {
                    finished.preview = candidateCleaned
                    finished.textLength = max(snap.textLength, candidate.textLength)
                    finished.assistantCount = max(snap.assistantCount, candidate.assistantCount)
                }
            }

            if let lastPreview = lastNotifiedPreview[id] {
                let oldHead = String(lastPreview.prefix(48))
                if !oldHead.isEmpty, finished.preview.hasPrefix(oldHead) {
                    shownFingerprint[id] = fp
                    lastNotifiedPreview[id] = finished.preview
                    lastNotifiedAssistantCount[id] = max(finished.assistantCount, lastNotifiedAssistantCount[id] ?? 0)
                    wasGenerating[id] = false
                    generationStartedFromEmpty.remove(id)
                    candidateSnapshotDuringGeneration[id] = nil
                    continue
                }
            }

            shownFingerprint[id] = fp
            lastNotifiedAssistantCount[id] = finished.assistantCount
            lastNotifiedPreview[id] = finished.preview
            fingerprintWhenGeneratingStarted[id] = nil
            wasGenerating[id] = false
            generationStartedFromEmpty.remove(id)
            candidateSnapshotDuringGeneration[id] = nil
            if best == nil || finished.assistantCount >= (best?.assistantCount ?? 0) {
                best = finished
            }
        }
        return best
    }

    static func isLiveGenerating(_ snap: ClaudeTabSnapshot) -> Bool {
        if snap.isGenerating { return true }
        let cleaned = cleanedPreview(snap.preview)
        guard !cleaned.isEmpty else { return false }
        return isProcessStage(cleaned)
    }

    static func isEmptyFingerprint(_ fp: String) -> Bool {
        preview(fromFingerprint: fp).isEmpty
    }

    static func preview(fromFingerprint fp: String) -> String {
        let parts = fp.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return "" }
        return String(parts[1])
    }

    static func fingerprint(_ snap: ClaudeTabSnapshot) -> String {
        let preview = cleanedPreview(snap.preview)
        return "\(snap.assistantCount)#\(preview.prefix(160))"
    }

    /// Strip UI chrome / relative timestamps so old messages don't look "new".
    static func cleanedPreview(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "Show message actions for ",
            "Claude responded: ",
            "Claude responded:",
            "ChatGPT said: ",
            "ChatGPT said:",
            "ChatGPT responded: ",
            "Gemini said: ",
            "Gemini said:",
            "You said: "
        ]
        var keepGoing = true
        while keepGoing {
            keepGoing = false
            for prefix in prefixes where text.lowercased().hasPrefix(prefix.lowercased()) {
                text = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                keepGoing = true
            }
        }

        // "just now", "10 minutes ago", "2 hours ago", "Yesterday", etc.
        let patterns = [
            #"(?i)\bjust now\b"#,
            #"(?i)\b\d+\s*(second|minute|hour|day|week|month|year)s?\s+ago\b"#,
            #"(?i)\byesterday\b"#,
            #"(?i)\btoday\b"#,
            #"[\u{E000}-\u{F8FF}]"# // private-use glyph junk from a11y trees
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
        text = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    /// RPC / batchexecute fragments scraped from Gemini's homepage widgets.
    static func looksLikeGeminiWireNoise(_ preview: String) -> Bool {
        let text = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("]") || text.hasPrefix("[[") || text.hasPrefix(",\"") {
            return true
        }
        let lowered = text.lowercased()
        return lowered.contains("af.httprm") || lowered.contains("batchexecute")
    }

    /// Claude status chips / thinking labels — not the final answer.
    static func isProcessStage(_ preview: String) -> Bool {
        let cleaned = cleanedPreview(preview)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Blank text is unread/hydration, not a thinking chip. Treating it as a
        // process stage made idle Claude tabs look like live generations.
        guard !cleaned.isEmpty else { return false }

        let stages: Set<String> = [
            "crystallizing", "reckoning", "thinking", "thoughts", "researching", "searching",
            "analyzing", "writing", "crafting", "planning", "working",
            "generating", "reasoning", "reading", "browsing", "synthesizing",
            "reflecting", "compiling", "drafting", "connecting", "considering"
        ]
        let tokens = cleaned
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return true }
        if tokens.allSatisfy({ stages.contains($0) }) { return true }
        if tokens.count <= 4, let first = tokens.first, stages.contains(first) {
            return true
        }
        return false
    }
}
