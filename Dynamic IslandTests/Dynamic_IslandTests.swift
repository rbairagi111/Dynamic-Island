import Testing
import CoreGraphics
import AppKit
@testable import Dynamic_Island

struct Dynamic_IslandTests {

    @Test func newClaudeChatStillNotifiesFirstRealReply() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 8, windowIndex: 1, tabIndex: 1, provider: .claude)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "Thinking",
                    foundDOM: true,
                    textLength: 8,
                    assistantCount: 0
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Fresh first answer in a new chat",
                foundDOM: true,
                textLength: 40,
                assistantCount: 1
            )
        ])
        #expect(done?.preview == "Fresh first answer in a new chat")
    }

    @Test func geminiBackgroundReplyFromEmptyGeneratingStateStillNotifies() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 15, windowIndex: 1, tabIndex: 5, provider: .gemini)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0,
                    latestUserPrompt: "When is Diwali in 2026",
                    latestUserFingerprint: "22#When is Diwali in 2026",
                    replyFingerprint: "",
                    replyAnchoredToLatestUser: false
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0,
                    latestUserPrompt: "When is Diwali in 2026",
                    latestUserFingerprint: "22#When is Diwali in 2026",
                    replyFingerprint: "",
                    replyAnchoredToLatestUser: false
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Diwali in 2026 falls on November 8 and here are the flight details",
                foundDOM: true,
                textLength: 120,
                assistantCount: 1,
                latestUserPrompt: "When is Diwali in 2026",
                latestUserFingerprint: "22#When is Diwali in 2026",
                replyFingerprint: "66#Diwali in 2026 falls on November 8 and here are the flight details",
                replyAnchoredToLatestUser: true
            )
        ])
        #expect(done?.tab.provider == .gemini)
        #expect(done?.preview == "Diwali in 2026 falls on November 8 and here are the flight details")
    }

    @Test func geminiWaitsThroughEmptyPostGenerationBeforeFinalPreview() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 16, windowIndex: 1, tabIndex: 6, provider: .gemini)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0,
                    latestUserPrompt: "Give me a fresh Gemini reply",
                    latestUserFingerprint: "28#Give me a fresh Gemini reply",
                    replyFingerprint: "",
                    replyAnchoredToLatestUser: false
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0,
                    latestUserPrompt: "Give me a fresh Gemini reply",
                    latestUserFingerprint: "28#Give me a fresh Gemini reply",
                    replyFingerprint: "",
                    replyAnchoredToLatestUser: false
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Fresh Gemini reply that appeared after the empty hidden phase",
                foundDOM: true,
                textLength: 90,
                assistantCount: 1,
                latestUserPrompt: "Give me a fresh Gemini reply",
                latestUserFingerprint: "28#Give me a fresh Gemini reply",
                replyFingerprint: "60#Fresh Gemini reply that appeared after the empty hidden phase",
                replyAnchoredToLatestUser: true
            )
        ])
        #expect(done?.tab.provider == .gemini)
        #expect(done?.preview == "Fresh Gemini reply that appeared after the empty hidden phase")
    }

    @Test func geminiPrefersFreshCandidateOverStaleRegressionAtCompletion() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 17, windowIndex: 1, tabIndex: 7, provider: .gemini)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Older Gemini answer that was already on screen",
                    foundDOM: true,
                    textLength: 180,
                    assistantCount: 1,
                    latestUserPrompt: "Older prompt",
                    latestUserFingerprint: "12#Older prompt",
                    replyFingerprint: "46#Older Gemini answer that was already on screen",
                    replyAnchoredToLatestUser: true
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0,
                    latestUserPrompt: "Ask a new Gemini question",
                    latestUserFingerprint: "25#Ask a new Gemini question",
                    replyFingerprint: "",
                    replyAnchoredToLatestUser: false
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "Fresh Gemini answer that briefly appeared before the DOM regressed",
                    foundDOM: true,
                    textLength: 260,
                    assistantCount: 1,
                    latestUserPrompt: "Ask a new Gemini question",
                    latestUserFingerprint: "25#Ask a new Gemini question",
                    replyFingerprint: "66#Fresh Gemini answer that briefly appeared before the DOM regressed",
                    replyAnchoredToLatestUser: true
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Older Gemini answer that was already on screen",
                foundDOM: true,
                textLength: 180,
                assistantCount: 1,
                latestUserPrompt: "Ask a new Gemini question",
                latestUserFingerprint: "25#Ask a new Gemini question",
                replyFingerprint: "",
                replyAnchoredToLatestUser: false
            )
        ])
        #expect(done?.tab.provider == .gemini)
        #expect(done?.preview == "Fresh Gemini answer that briefly appeared before the DOM regressed")
    }

    @Test func geminiNotifiesWhenEmptyTabFillsWithoutGeneratingSignal() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 18, windowIndex: 1, tabIndex: 8, provider: .gemini)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0,
                    latestUserPrompt: "Which iPhone is better, 17 or 18?",
                    latestUserFingerprint: "34#Which iPhone is better, 17 or 18?",
                    replyFingerprint: "",
                    replyAnchoredToLatestUser: false
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Determining whether the Apple iPhone 17 or iPhone 18 is better depends on your budget and timeline",
                foundDOM: true,
                textLength: 160,
                assistantCount: 1,
                latestUserPrompt: "Which iPhone is better, 17 or 18?",
                latestUserFingerprint: "34#Which iPhone is better, 17 or 18?",
                replyFingerprint: "97#Determining whether the Apple iPhone 17 or iPhone 18 is better depends on your budget and timeline",
                replyAnchoredToLatestUser: true
            )
        ])
        #expect(done?.tab.provider == .gemini)
        #expect(done?.preview == "Determining whether the Apple iPhone 17 or iPhone 18 is better depends on your budget and timeline")
    }

    @Test func geminiUsesLatestUserTurnFingerprintToNotifyMatchedReply() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 19, windowIndex: 1, tabIndex: 9, provider: .gemini)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Older bike answer",
                    foundDOM: true,
                    textLength: 40,
                    assistantCount: 1,
                    latestUserPrompt: "Which bikes are under 5 lakhs?",
                    latestUserFingerprint: "29#Which bikes are under 5 lakhs?",
                    replyFingerprint: "18#Older bike answer",
                    replyAnchoredToLatestUser: true
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0,
                    latestUserPrompt: "What about second-hand Benelli 600i",
                    latestUserFingerprint: "35#What about second-hand Benelli 600i",
                    replyFingerprint: "",
                    replyAnchoredToLatestUser: false
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "A used Benelli 600i can fit, but condition and maintenance history matter more than model year.",
                foundDOM: true,
                textLength: 120,
                assistantCount: 1,
                latestUserPrompt: "What about second-hand Benelli 600i",
                latestUserFingerprint: "35#What about second-hand Benelli 600i",
                replyFingerprint: "96#A used Benelli 600i can fit, but condition and maintenance history matter more than model year.",
                replyAnchoredToLatestUser: true
            )
        ])
        #expect(done?.tab.provider == .gemini)
        #expect(done?.preview == "A used Benelli 600i can fit, but condition and maintenance history matter more than model year.")
    }

    @Test func geminiNotifiesAfterBackgroundPromptWithNoGeneratingFlag() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 21, windowIndex: 1, tabIndex: 11, provider: .gemini)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Older superbike answer already on the page",
                    foundDOM: true,
                    textLength: 80,
                    assistantCount: 1,
                    latestUserPrompt: "Which superbikes are under 5 lakhs?",
                    latestUserFingerprint: "35#Which superbikes are under 5 lakhs?",
                    replyFingerprint: "42#Older superbike answer already on the page",
                    replyAnchoredToLatestUser: true
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0,
                    latestUserPrompt: "Tell me about the Kawasaki ZX-4R",
                    latestUserFingerprint: "32#Tell me about the Kawasaki ZX-4R",
                    replyFingerprint: "",
                    replyAnchoredToLatestUser: false
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "The Kawasaki ZX-4R is a 399cc supersport with strong high-rpm power.",
                foundDOM: true,
                textLength: 140,
                assistantCount: 1,
                latestUserPrompt: "Tell me about the Kawasaki ZX-4R",
                latestUserFingerprint: "32#Tell me about the Kawasaki ZX-4R",
                replyFingerprint: "68#The Kawasaki ZX-4R is a 399cc supersport with strong high-rpm power.",
                replyAnchoredToLatestUser: true
            )
        ])
        #expect(done?.tab.provider == .gemini)
        #expect(done?.preview == "The Kawasaki ZX-4R is a 399cc supersport with strong high-rpm power.")
    }

    @Test func geminiSecondPromptNotifiesEvenDuringSnoozeFromFirst() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 22, windowIndex: 1, tabIndex: 12, provider: .gemini)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0,
                    latestUserPrompt: "Okay, how can I improve my communication skills?",
                    latestUserFingerprint: "48#Okay, how can I improve my communication skills?",
                    replyFingerprint: "",
                    replyAnchoredToLatestUser: false
                )
            ]) == nil
        )
        let first = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Developing strong communication skills relies on three main areas: active listening, clear delivery, and confident non-verbal cues.",
                foundDOM: true,
                textLength: 1450,
                assistantCount: 1,
                latestUserPrompt: "Okay, how can I improve my communication skills?",
                latestUserFingerprint: "48#Okay, how can I improve my communication skills?",
                replyFingerprint: "132#Developing strong communication skills relies on three main areas: active listening, clear delivery, and confident non-verbal cues.",
                replyAnchoredToLatestUser: true
            )
        ])
        #expect(first?.preview.contains("active listening") == true)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0,
                    latestUserPrompt: "Someone was telling me that if you want to improve your communication skills, you just need to speak English daily.",
                    latestUserFingerprint: "116#Someone was telling me that if you want to improve your communication skills, you just need to speak English daily.",
                    replyFingerprint: "",
                    replyAnchoredToLatestUser: false
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "Simply speaking English daily will make you fluent in English",
                    foundDOM: true,
                    textLength: 61,
                    assistantCount: 1,
                    latestUserPrompt: "Someone was telling me that if you want to improve your communication skills, you just need to speak English daily.",
                    latestUserFingerprint: "116#Someone was telling me that if you want to improve your communication skills, you just need to speak English daily.",
                    replyFingerprint: "61#Simply speaking English daily will make you fluent in English",
                    replyAnchoredToLatestUser: true
                )
            ]) == nil
        )
        let second = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Daily English practice helps, but it is not the ultimate mantra. You also need listening, feedback, and real conversations.",
                foundDOM: true,
                textLength: 420,
                assistantCount: 1,
                latestUserPrompt: "Someone was telling me that if you want to improve your communication skills, you just need to speak English daily.",
                latestUserFingerprint: "116#Someone was telling me that if you want to improve your communication skills, you just need to speak English daily.",
                replyFingerprint: "124#Daily English practice helps, but it is not the ultimate mantra. You also need listening, feedback, and real conversations.",
                replyAnchoredToLatestUser: true
            )
        ])
        #expect(second?.tab.provider == .gemini)
        #expect(second?.preview.contains("not the ultimate mantra") == true)
    }

    @Test func geminiDoesNotNotifyWithoutAnchoredLatestTurnReply() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 20, windowIndex: 1, tabIndex: 10, provider: .gemini)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Older iPhone answer",
                    foundDOM: true,
                    textLength: 40,
                    assistantCount: 1,
                    latestUserPrompt: "Which iPhone is better?",
                    latestUserFingerprint: "24#Which iPhone is better?",
                    replyFingerprint: "20#Older iPhone answer",
                    replyAnchoredToLatestUser: true
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Older iPhone answer",
                foundDOM: true,
                textLength: 40,
                assistantCount: 1,
                latestUserPrompt: "What about second-hand Benelli 600i",
                latestUserFingerprint: "35#What about second-hand Benelli 600i",
                replyFingerprint: "",
                replyAnchoredToLatestUser: false
            )
        ])
        #expect(done == nil)
    }

    @Test func claudeTrackerBaselinesExistingRepliesWithoutFiring() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 101, windowIndex: 1, tabIndex: 4)
        let old = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "hi hi 10 minutes ago",
            foundDOM: true,
            textLength: 40,
            assistantCount: 1
        )
        #expect(tracker.ingest([old]) == nil)
        // Timestamp-only churn must not notify.
        let later = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "hi hi 11 minutes ago",
            foundDOM: true,
            textLength: 40,
            assistantCount: 1
        )
        #expect(tracker.ingest([later]) == nil)
        #expect(tracker.ingest([later]) == nil)
    }

    @Test func cleanedPreviewStripsRelativeTimestamps() {
        let cleaned = ClaudeTabTracker.cleanedPreview("hi hi just now")
        #expect(cleaned == "hi hi")
        #expect(ClaudeTabTracker.cleanedPreview("hello 10 minutes ago") == "hello")
    }

    @Test func processStagesIncludeReckoning() {
        #expect(ClaudeTabTracker.isProcessStage("Reckoning Reckoning"))
        #expect(ClaudeTabTracker.isProcessStage("Crystallizing"))
        #expect(!ClaudeTabTracker.isProcessStage("7/10. Here's the rough math"))
    }

    @Test func claudeTrackerFiresOnlyAfterGeneratingFinishesWithNewReply() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 9, windowIndex: 1, tabIndex: 1)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Old long answer",
                    foundDOM: true,
                    textLength: 400,
                    assistantCount: 1
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "Reckoning",
                    foundDOM: true,
                    textLength: 9,
                    assistantCount: 1
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Yep fresh answer",
                foundDOM: true,
                textLength: 16,
                assistantCount: 2
            )
        ])
        #expect(done?.preview == "Yep fresh answer")
    }

    @Test func claudeTrackerDoesNotNotifyOldReplyAfterSpuriousGenerationFlag() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 202, windowIndex: 1, tabIndex: 4)
        let old = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "First long reply about architecture",
            foundDOM: true,
            textLength: 800,
            assistantCount: 1
        )
        #expect(tracker.ingest([old]) == nil)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "First long reply about architecture",
                    foundDOM: true,
                    textLength: 800,
                    assistantCount: 1
                )
            ]) == nil
        )
        // Generation "ends" but content is still the old reply.
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "First long reply about architecture",
                    foundDOM: true,
                    textLength: 800,
                    assistantCount: 1
                )
            ]) == nil
        )
    }

    @Test func claudeTrackerIgnoresIdlePreviewChurnWithoutGenerating() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 555, windowIndex: 1, tabIndex: 8)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "One",
                    foundDOM: true,
                    textLength: 40,
                    assistantCount: 1
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "One two",
                    foundDOM: true,
                    textLength: 60,
                    assistantCount: 1
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "One two",
                    foundDOM: true,
                    textLength: 60,
                    assistantCount: 1
                )
            ]) == nil
        )
    }

    @Test func probeJSONParsesTextLengthAndAssistantCount() throws {
        let raw = #"{"isGenerating":false,"preview":"one two","foundDOM":true,"textLength":42,"assistantCount":3}"#
        let parsed = try #require(ChromeTabMonitor.parseProbeJSON(raw))
        #expect(parsed.textLength == 42)
        #expect(parsed.assistantCount == 3)
        #expect(!parsed.isGenerating)
        #expect(!parsed.pageVisible)
    }

    @Test func probeJSONParsesPageVisible() throws {
        let raw = #"{"isGenerating":false,"preview":"done","foundDOM":true,"textLength":10,"assistantCount":1,"pageVisible":true}"#
        let parsed = try #require(ChromeTabMonitor.parseProbeJSON(raw))
        #expect(parsed.pageVisible)
    }

    @Test func batchInspectOutputPreservesEveryProbeFieldPerTab() throws {
        let claudeJSON = #"{"isGenerating":true,"preview":"Hello from Claude","foundDOM":true,"textLength":18,"assistantCount":1,"pageVisible":false}"#
        let chatJSON = #"{"isGenerating":false,"preview":"Done reply","foundDOM":true,"textLength":10,"assistantCount":2,"pageVisible":true}"#
        let geminiJSON = #"{"isGenerating":false,"preview":"Gemini answer","foundDOM":true,"textLength":13,"assistantCount":1,"latestUserPrompt":"When is Diwali","latestUserFingerprint":"15#When is Diwali","replyFingerprint":"13#Gemini answer","replyAnchoredToLatestUser":true,"networkCompletionToken":"80:4200"}"#
        let output = """
        <<<ISLAND_PROBE>>>101<<<ISLAND_PROBE>>>\(claudeJSON)
        <<<ISLAND_PROBE>>>202<<<ISLAND_PROBE>>>\(chatJSON)
        <<<ISLAND_PROBE>>>303<<<ISLAND_PROBE>>>\(geminiJSON)
        """
        let rawByTab = ChromeTabMonitor.parseBatchInspectOutput(output)
        #expect(Set(rawByTab.keys) == [101, 202, 303])

        let claude = try #require(ChromeTabMonitor.parseProbeJSON(rawByTab[101] ?? ""))
        #expect(claude.isGenerating)
        #expect(claude.preview == "Hello from Claude")
        #expect(claude.foundDOM)
        #expect(claude.textLength == 18)
        #expect(claude.assistantCount == 1)
        #expect(!claude.pageVisible)

        let chatgpt = try #require(ChromeTabMonitor.parseProbeJSON(rawByTab[202] ?? ""))
        #expect(!chatgpt.isGenerating)
        #expect(chatgpt.preview == "Done reply")
        #expect(chatgpt.foundDOM)
        #expect(chatgpt.textLength == 10)
        #expect(chatgpt.assistantCount == 2)
        #expect(chatgpt.pageVisible)

        let gemini = try #require(ChromeTabMonitor.parseProbeJSON(rawByTab[303] ?? ""))
        #expect(gemini.preview == "Gemini answer")
        #expect(gemini.foundDOM)
        #expect(gemini.textLength == 13)
        #expect(gemini.assistantCount == 1)
        #expect(gemini.latestUserPrompt == "When is Diwali")
        #expect(gemini.latestUserFingerprint == "15#When is Diwali")
        #expect(gemini.replyFingerprint == "13#Gemini answer")
        #expect(gemini.replyAnchoredToLatestUser)
        #expect(gemini.networkCompletionToken == "80:4200")
    }

    @Test func batchInspectOutputDoesNotAppendFollowingTabRowsToProbeJSON() throws {
        let geminiJSON = #"{"isGenerating":false,"preview":"Background reply","foundDOM":true,"textLength":16,"assistantCount":1}"#
        let output = """
        ACTIVE<<<ISLAND_TAB>>>1<<<ISLAND_TAB>>>2<<<ISLAND_TAB>>>303
        1<<<ISLAND_TAB>>>2<<<ISLAND_TAB>>>303<<<ISLAND_TAB>>>gemini<<<ISLAND_TAB>>>https://gemini.google.com/app/test
        <<<ISLAND_PROBE>>>303<<<ISLAND_PROBE>>>\(geminiJSON)
        1<<<ISLAND_TAB>>>3<<<ISLAND_TAB>>>404<<<ISLAND_TAB>>>none<<<ISLAND_TAB>>>https://example.com
        """

        let rawByTab = ChromeTabMonitor.parseBatchInspectOutput(output)
        #expect(rawByTab[303] == geminiJSON)
        let parsed = try #require(ChromeTabMonitor.parseProbeJSON(rawByTab[303] ?? ""))
        #expect(parsed.preview == "Background reply")
    }

    @Test func geminiProbeTracksCurrentFrontendRpcAndCustomElements() {
        let body = GeminiProbeScript.body
        #expect(body.contains("batchexecute"))
        #expect(body.contains("bardchatui"))
        #expect(body.contains("/_/bard"))
        #expect(body.contains("user-query"))
        #expect(body.contains("model-response"))
        #expect(body.contains("net.token||net.pending"))
        #expect(body.contains("domHasNet"))
        #expect(body.contains("performance.getEntriesByType('resource')"))
        #expect(body.contains("isCompletionStreamURL"))
        #expect(body.contains("Gemini response ready"))
        #expect(body.contains("walk(JSON.parse(v),depth+1);return"))
        #expect(body.contains("!assistantEntries.length&&net.preview"))
        #expect(body.contains("var re=/\"text\""))
        #expect(!body.contains("data-is-streaming"))
    }

    @Test func chatProviderDetectsKnownHosts() {
        #expect(ChatProvider.from(url: "https://claude.ai/chat/abc") == .claude)
        #expect(ChatProvider.from(url: "https://chatgpt.com/c/xyz") == .chatgpt)
        #expect(ChatProvider.from(url: "https://chat.openai.com/") == .chatgpt)
        #expect(ChatProvider.from(url: "https://gemini.google.com/app") == .gemini)
        #expect(ChatProvider.from(url: "https://example.com") == nil)
    }

    @Test func parseTabListReadsProvider() {
        let tabs = ChromeTabMonitor.parseTabList("""
        1,2,101,claude
        1,3,202,chatgpt
        2,1,303,gemini
        """)
        #expect(tabs.map(\.provider) == [.claude, .chatgpt, .gemini])
        #expect(tabs.map(\.tabID) == [101, 202, 303])
        #expect(ChromeTabMonitor.parseTabList("1,2,101").isEmpty)
    }

    @Test func parseFrontmostActiveTabIDFromListOutput() {
        let output = """
        ACTIVE<<<ISLAND_TAB>>>1<<<ISLAND_TAB>>>3<<<ISLAND_TAB>>>202
        1<<<ISLAND_TAB>>>2<<<ISLAND_TAB>>>101<<<ISLAND_TAB>>>claude<<<ISLAND_TAB>>>https://claude.ai/new
        1<<<ISLAND_TAB>>>3<<<ISLAND_TAB>>>202<<<ISLAND_TAB>>>chatgpt<<<ISLAND_TAB>>>https://chatgpt.com/
        """
        #expect(ChromeTabMonitor.parseFrontmostActiveTabID(output) == 202)
        #expect(ChromeTabMonitor.parseTabList(output).map(\.tabID) == [101, 202])
        #expect(ChromeTabMonitor.parseFrontmostActiveTabID("1,2,101,claude") == nil)
    }

    @Test func chatActivationSelectsMatchedWindowNotWindowListPositionOne() {
        let conversation = ClaudeTabInfo(
            tabID: 1530773650,
            windowIndex: 2,
            tabIndex: 4,
            provider: .claude,
            url: "https://claude.ai/chat/abc12345-def6-7890"
        )
        let script = ChromeTabMonitor.activateScript(tab: conversation)
        #expect(script.contains("set active tab index of window id winID to tabIdx"))
        #expect(script.contains("set index of window id winID to 1"))
        #expect(!script.contains("set active tab index of window 1 to"))
        #expect(script.contains("if (URL of candidate) is targetURL then"))
        let home = ClaudeTabInfo(
            tabID: 99,
            windowIndex: 1,
            tabIndex: 1,
            provider: .claude,
            url: "https://claude.ai/new"
        )
        let homeScript = ChromeTabMonitor.activateScript(tab: home)
        #expect(homeScript.contains("if false then"))
        #expect(!homeScript.contains("if (URL of candidate) is targetURL then"))
        #expect(ChromeTabMonitor.chatActivationURLIsSpecific("https://claude.ai/chat/abc12345-def6-7890"))
        #expect(!ChromeTabMonitor.chatActivationURLIsSpecific("https://claude.ai/new"))
        #expect(!ChromeTabMonitor.chatActivationURLIsSpecific("https://claude.ai/"))
        #expect(ChromeTabMonitor.chatActivationURLIsSpecific("https://chatgpt.com/c/xyz98765-aaaa"))
        #expect(!ChromeTabMonitor.chatActivationURLIsSpecific("https://chatgpt.com/"))
    }

    @Test func suppressOverlayWhenFrontChatTabIsAlreadyVisible() {
        #expect(
            ChromeTabMonitor.shouldSuppressIslandOverlay(
                tabID: 202,
                chromeFrontmost: true,
                visibleTabID: 202
            )
        )
        #expect(
            !ChromeTabMonitor.shouldSuppressIslandOverlay(
                tabID: 202,
                chromeFrontmost: true,
                visibleTabID: 101
            )
        )
        #expect(
            !ChromeTabMonitor.shouldSuppressIslandOverlay(
                tabID: 202,
                chromeFrontmost: false,
                visibleTabID: 202
            )
        )
        #expect(
            !ChromeTabMonitor.shouldSuppressIslandOverlay(
                tabID: 202,
                chromeFrontmost: false,
                visibleTabID: 101,
                pageVisible: true
            )
        )
        #expect(
            ChromeTabMonitor.shouldSuppressIslandOverlay(
                tabID: 202,
                chromeFrontmost: true,
                visibleTabID: 202,
                pageVisible: false
            )
        )
        #expect(
            !ChromeTabMonitor.shouldSuppressIslandOverlay(
                tabID: 202,
                chromeFrontmost: true,
                visibleTabID: 101,
                pageVisible: false
            )
        )
        #expect(ClaudeTabTracker.looksLikeGeminiWireNoise(#"],"af.httprm",181,"-3040"#))
        #expect(!ClaudeTabTracker.looksLikeGeminiWireNoise("Friday weather in Delhi is 31 C."))
    }

    @Test func viewingAFinishedReplyDoesNotNotifyAfterSwitchingAway() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 41, windowIndex: 1, tabIndex: 1, provider: .claude)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "Thinking",
                    foundDOM: true,
                    textLength: 8,
                    assistantCount: 0
                )
            ]) == nil
        )
        let visibleReply = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: true,
            preview: "Here is the finished answer the user already read",
            foundDOM: true,
            textLength: 48,
            assistantCount: 1
        )
        tracker.noteUserIsViewing(visibleReply)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Here is the finished answer the user already read",
                    foundDOM: true,
                    textLength: 48,
                    assistantCount: 1
                )
            ]) == nil
        )
    }

    @Test func leavingDuringThinkingStillNotifiesWhenReplyFinishes() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 42, windowIndex: 1, tabIndex: 1, provider: .claude)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0
                )
            ]) == nil
        )
        let thinking = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: true,
            preview: "Thinking",
            foundDOM: true,
            textLength: 8,
            assistantCount: 0
        )
        #expect(tracker.ingest([thinking]) == nil)
        tracker.noteUserIsViewing(thinking)
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                    isGenerating: false,
                    preview: "New answer after the user left the tab",
                    foundDOM: true,
                    textLength: 40,
                    assistantCount: 1
            )
        ])
        #expect(done?.preview == "New answer after the user left the tab")
    }

    @Test func cleanedPreviewStripsChatGPTAndGeminiPrefixes() {
        #expect(ClaudeTabTracker.cleanedPreview("ChatGPT said: Hello there") == "Hello there")
        #expect(ClaudeTabTracker.cleanedPreview("Gemini said: Here's the plan") == "Here's the plan")
    }

    @Test func chatgptTrackerFiresOnlyAfterGeneratingFinishesWithNewReply() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 88, windowIndex: 1, tabIndex: 2, provider: .chatgpt)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Old ChatGPT answer",
                    foundDOM: true,
                    textLength: 400,
                    assistantCount: 1
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "Thinking",
                    foundDOM: true,
                    textLength: 8,
                    assistantCount: 1
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Fresh ChatGPT answer",
                foundDOM: true,
                textLength: 20,
                assistantCount: 2
            )
        ])
        #expect(done?.preview == "Fresh ChatGPT answer")
        #expect(done?.tab.provider == .chatgpt)
    }

    @Test func chatgptTrackerFiresWhenStopButtonNeverAppears() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 77, windowIndex: 1, tabIndex: 3, provider: .chatgpt)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Old ChatGPT answer",
                    foundDOM: true,
                    textLength: 400,
                    assistantCount: 1
                )
            ]) == nil
        )
        // Streamed in without any Stop-button flag.
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Fresh ChatGPT answer starts here",
                    foundDOM: true,
                    textLength: 80,
                    assistantCount: 2
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Fresh ChatGPT answer starts here",
                foundDOM: true,
                textLength: 80,
                assistantCount: 2
            )
        ])
        #expect(done?.preview == "Fresh ChatGPT answer starts here")
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Fresh ChatGPT answer starts here plus sources",
                    foundDOM: true,
                    textLength: 140,
                    assistantCount: 2
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Fresh ChatGPT answer starts here plus sources",
                    foundDOM: true,
                    textLength: 140,
                    assistantCount: 2
                )
            ]) == nil
        )
    }

    @Test func geminiTrackerFiresWhenStopButtonNeverAppears() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 12, windowIndex: 1, tabIndex: 5, provider: .gemini)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Old Gemini reply",
                    foundDOM: true,
                    textLength: 120,
                    assistantCount: 1,
                    latestUserPrompt: "Old Gemini question",
                    latestUserFingerprint: "19#Old Gemini question",
                    replyFingerprint: "16#Old Gemini reply",
                    replyAnchoredToLatestUser: true
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 1,
                    latestUserPrompt: "Ask Gemini something new",
                    latestUserFingerprint: "24#Ask Gemini something new",
                    replyFingerprint: "",
                    replyAnchoredToLatestUser: false
                )
            ]) == nil
        )
        let done = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Brand new Gemini reply about the site",
                foundDOM: true,
                textLength: 210,
                assistantCount: 2,
                latestUserPrompt: "Ask Gemini something new",
                latestUserFingerprint: "24#Ask Gemini something new",
                replyFingerprint: "37#Brand new Gemini reply about the site",
                replyAnchoredToLatestUser: true
            )
        ])
        #expect(done?.preview == "Brand new Gemini reply about the site")
        #expect(done?.tab.provider == .gemini)
    }

    @Test func acknowledgingAReplySuppressesTheSameTabUntilSnoozeEnds() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 3, windowIndex: 1, tabIndex: 1, provider: .chatgpt)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Old ChatGPT answer",
                    foundDOM: true,
                    textLength: 40,
                    assistantCount: 1
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "Thinking",
                    foundDOM: true,
                    textLength: 8,
                    assistantCount: 1
                )
            ]) == nil
        )
        let first = tracker.ingest([
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Brand new ChatGPT reply for the user",
                foundDOM: true,
                textLength: 80,
                assistantCount: 2
            )
        ])
        #expect(first?.preview == "Brand new ChatGPT reply for the user")
        tracker.acknowledge(
            tabID: tab.tabID,
            preview: "Brand new ChatGPT reply for the user",
            assistantCount: 2
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Brand new ChatGPT reply for the user with extra citations",
                    foundDOM: true,
                    textLength: 160,
                    assistantCount: 2
                )
            ]) == nil
        )
    }

    @Test func geminiNetworkCompletionFiresWhileDOMIsFrozen() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 9, windowIndex: 1, tabIndex: 2, provider: .gemini)
        let frozen = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: true,
            preview: "Thinking",
            foundDOM: true,
            textLength: 8,
            assistantCount: 1,
            latestUserPrompt: "What is the capital of France?",
            latestUserFingerprint: "30#What is the capital of France?",
            replyFingerprint: "",
            replyAnchoredToLatestUser: false
        )
        #expect(tracker.ingest([frozen]) == nil)

        var pending = frozen
        pending.isGenerating = false
        pending.preview = ""
        pending.textLength = 0
        #expect(tracker.ingest([pending]) == nil)

        var completed = pending
        completed.preview = "The capital of France is Paris and it has many famous landmarks"
        completed.textLength = 120
        completed.replyFingerprint = "63#The capital of France is Paris and it has many famous landmarks"
        completed.replyAnchoredToLatestUser = true
        let event = tracker.ingest([completed])

        #expect(event?.preview == "The capital of France is Paris and it has many famous landmarks")
        #expect(event?.isGenerating == false)
        #expect(tracker.ingest([completed]) == nil)

        var painted = completed
        painted.preview = "The capital of France is Paris and it has many famous landmarks including the Eiffel Tower"
        painted.textLength = 200
        painted.assistantCount = 2
        painted.replyFingerprint = "90#The capital of France is Paris and it has many famous landmarks including the Eiffel Tower"
        #expect(tracker.ingest([painted]) == nil)
    }

    @Test func geminiNotifiesWhenNetworkFinishesWhileGeneratingFlagStaysTrue() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 23, windowIndex: 1, tabIndex: 4, provider: .gemini)
        let waiting = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: true,
            preview: "",
            foundDOM: true,
            textLength: 0,
            assistantCount: 0,
            latestUserPrompt: "When is Diwali",
            latestUserFingerprint: "15#When is Diwali",
            replyFingerprint: "",
            replyAnchoredToLatestUser: false
        )
        #expect(tracker.ingest([waiting]) == nil)

        var streamed = waiting
        streamed.preview = "Diwali is typically in October or November depending on the lunar calendar"
        streamed.textLength = 80
        streamed.replyFingerprint = "74#Diwali is typically in October or November depending on the lunar calendar"
        streamed.replyAnchoredToLatestUser = true
        streamed.networkCompletionToken = "21:80"
        let event = tracker.ingest([streamed])
        #expect(event?.preview.contains("Diwali") == true)
        #expect(event?.isGenerating == false)
    }

    @Test func geminiBackgroundNetworkReplyNotifiesWhileDOMStillShowsOldAnswer() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 41, windowIndex: 1, tabIndex: 2, provider: .gemini)
        let old = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "Old Gemini reply sitting in the background tab",
            foundDOM: true,
            textLength: 48,
            assistantCount: 1,
            latestUserPrompt: "First question",
            latestUserFingerprint: "14#First question",
            replyFingerprint: "48#Old Gemini reply sitting in the background tab",
            replyAnchoredToLatestUser: true
        )
        #expect(tracker.ingest([old]) == nil)

        var generating = old
        generating.isGenerating = true
        generating.latestUserPrompt = "Second question about flights"
        generating.latestUserFingerprint = "29#Second question about flights"
        generating.replyAnchoredToLatestUser = false
        #expect(tracker.ingest([generating]) == nil)

        var completed = generating
        completed.isGenerating = true
        completed.preview = "Here are the flight options for tomorrow morning"
        completed.textLength = 50
        completed.replyFingerprint = "50#Here are the flight options for tomorrow morning"
        completed.replyAnchoredToLatestUser = true
        completed.networkCompletionToken = "99:50"
        let event = tracker.ingest([completed])
        #expect(event?.preview == "Here are the flight options for tomorrow morning")
        #expect(event?.isGenerating == false)
    }

    @Test func geminiDoesNotAnnouncePreviousAnswerAsTheNewTurn() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 42, windowIndex: 1, tabIndex: 2, provider: .gemini)
        let old = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "Old Gemini reply sitting in the background tab",
            foundDOM: true,
            textLength: 48,
            assistantCount: 1,
            latestUserPrompt: "First question",
            latestUserFingerprint: "14#First question",
            replyFingerprint: "48#Old Gemini reply sitting in the background tab",
            replyAnchoredToLatestUser: true
        )
        #expect(tracker.ingest([old]) == nil)

        var generating = old
        generating.isGenerating = true
        generating.latestUserPrompt = "Second question about flights"
        generating.latestUserFingerprint = "29#Second question about flights"
        generating.replyAnchoredToLatestUser = true
        generating.networkCompletionToken = "99:50"
        #expect(tracker.ingest([generating]) == nil)
        #expect(tracker.ingest([generating]) == nil)
    }

    @Test func unreadClaudeTabPaintingOldTranscriptDoesNotNotify() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 44, windowIndex: 1, tabIndex: 2, provider: .claude)
        let unread = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "",
            foundDOM: false,
            textLength: 0,
            assistantCount: 0
        )
        #expect(tracker.ingest([unread]) == nil)

        let painted = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "Old architecture answer from last week",
            foundDOM: true,
            textLength: 420,
            assistantCount: 3
        )
        #expect(tracker.ingest([painted]) == nil)
        #expect(tracker.ingest([painted]) == nil)
    }

    @Test func emptyClaudeUIThenOldMessagesDoNotNotify() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 45, windowIndex: 1, tabIndex: 1, provider: .claude)
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: true,
                    preview: "",
                    foundDOM: true,
                    textLength: 0,
                    assistantCount: 0
                )
            ]) == nil
        )
        #expect(
            tracker.ingest([
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Cached Claude reply the user never just asked",
                    foundDOM: true,
                    textLength: 380,
                    assistantCount: 2
                )
            ]) == nil
        )
    }

    @Test func geminiHistoricalStreamTokenDoesNotNotifyOldReply() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 19, windowIndex: 1, tabIndex: 3, provider: .gemini)
        let old = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "Old Gemini reply sitting in the tab",
            foundDOM: true,
            textLength: 200,
            assistantCount: 1,
            networkCompletionToken: ""
        )
        #expect(tracker.ingest([old]) == nil)

        var historical = old
        historical.networkCompletionToken = "80:4200"
        #expect(tracker.ingest([historical]) == nil)
        #expect(tracker.ingest([historical]) == nil)
    }

    @Test func geminiDoesNotRelaunchAnOldHydratedThread() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 31, windowIndex: 1, tabIndex: 2, provider: .gemini)
        let old = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "Here are flight options from Hyderabad (HYD) to Nagpur (NAG)",
            foundDOM: true,
            textLength: 220,
            assistantCount: 3,
            latestUserPrompt: "Flights from Hyderabad to Nagpur",
            latestUserFingerprint: "33#Flights from Hyderabad to Nagpur",
            replyFingerprint: "62#Here are flight options from Hyderabad (HYD) to Nagpur (NAG)",
            replyAnchoredToLatestUser: true
        )
        #expect(tracker.ingest([old]) == nil)

        var replayed = old
        replayed.networkCompletionToken = "\(Int(Date().timeIntervalSince1970 * 1000)):220"
        #expect(tracker.ingest([replayed]) == nil)

        var incomplete = old
        incomplete.replyFingerprint = ""
        incomplete.replyAnchoredToLatestUser = false
        incomplete.preview = ""
        incomplete.textLength = 0
        #expect(tracker.ingest([incomplete]) == nil)
        #expect(tracker.ingest([old]) == nil)
    }

    @Test func geminiPushOfAlreadyLoadedThreadDoesNotNotify() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 32, windowIndex: 1, tabIndex: 3, provider: .gemini)
        let event = tracker.ingestPush(
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Here are flight options from Hyderabad (HYD) to Nagpur (NAG)",
                foundDOM: true,
                textLength: 220,
                assistantCount: 3,
                latestUserPrompt: "Flights from Hyderabad to Nagpur",
                latestUserFingerprint: "33#Flights from Hyderabad to Nagpur",
                replyFingerprint: "62#Here are flight options from Hyderabad (HYD) to Nagpur (NAG)",
                replyAnchoredToLatestUser: true
            )
        )
        #expect(event == nil)
        #expect(
            tracker.ingestPush(
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Here are flight options from Hyderabad (HYD) to Nagpur (NAG)",
                    foundDOM: true,
                    textLength: 220,
                    assistantCount: 3,
                    latestUserPrompt: "Flights from Hyderabad to Nagpur",
                    latestUserFingerprint: "33#Flights from Hyderabad to Nagpur",
                    replyFingerprint: "62#Here are flight options from Hyderabad (HYD) to Nagpur (NAG)",
                    replyAnchoredToLatestUser: true
                )
            ) == nil
        )
    }

    @Test func geminiWebRequestCompletionPushIsNotMistakenForLoadedHistory() throws {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 33, windowIndex: 1, tabIndex: 4, provider: .gemini)
        let completed = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "Gemini response ready",
            foundDOM: true,
            textLength: 21,
            assistantCount: 1,
            latestUserPrompt: "Explain the result",
            latestUserFingerprint: "18#Explain the result",
            replyFingerprint: "gemini-request#8123",
            replyAnchoredToLatestUser: true,
            networkCompletionToken: "webRequest#8123"
        )

        let received = tracker.ingestPush(completed)
        let event = try #require(received)
        #expect(event.preview == "Gemini response ready")
        #expect(event.networkCompletionToken == "webRequest#8123")
        #expect(tracker.ingestPush(completed) == nil)
    }

    @Test func geminiPushWithoutUserPromptDoesNotNotify() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 35, windowIndex: 1, tabIndex: 6, provider: .gemini)
        #expect(
            tracker.ingestPush(
                ClaudeTabSnapshot(
                    tab: tab,
                    isGenerating: false,
                    preview: "Friday Delhi Temperature Precipitation Wind 31 C",
                    foundDOM: true,
                    textLength: 52,
                    assistantCount: 1,
                    networkCompletionToken: "webRequest#1"
                )
            ) == nil
        )
    }

    @Test func geminiPlaceholderPushDoesNotDuplicateAfterRealReply() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 34, windowIndex: 1, tabIndex: 5, provider: .gemini)
        let real = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "Thursday weather in Dindori is 27 C with light rain.",
            foundDOM: true,
            textLength: 52,
            assistantCount: 1,
            latestUserPrompt: "check weather in dindori",
            latestUserFingerprint: "24#check weather in dindori",
            replyFingerprint: "52#Thursday weather in Dindori is 27 C with light rain.",
            replyAnchoredToLatestUser: true,
            networkCompletionToken: "1788427986682:end"
        )
        #expect(tracker.ingestPush(real) != nil)

        let placeholder = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "Gemini response ready",
            foundDOM: true,
            textLength: 21,
            assistantCount: 1,
            replyFingerprint: "gemini-request#148599",
            replyAnchoredToLatestUser: true,
            networkCompletionToken: "webRequest#148599"
        )
        #expect(tracker.ingestPush(placeholder) == nil)

        let grown = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "Thursday weather in Dindori is 27 C with light rain this evening.",
            foundDOM: true,
            textLength: 66,
            assistantCount: 1,
            latestUserPrompt: "check weather in dindori",
            latestUserFingerprint: "24#check weather in dindori",
            replyFingerprint: "66#Thursday weather in Dindori is 27 C with light rain this evening.",
            replyAnchoredToLatestUser: true,
            networkCompletionToken: "297807800:304536700"
        )
        #expect(tracker.ingest([grown]) == nil)
    }

    @Test func tabAppearingAfterEmptyBaselineDoesNotNotifyOldClaude() {
        var tracker = ClaudeTabTracker()
        #expect(tracker.ingest([]) == nil)
        let tab = ClaudeTabInfo(tabID: 70, windowIndex: 1, tabIndex: 4, provider: .claude)
        let old = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: false,
            preview: "Long existing Claude conversation",
            foundDOM: true,
            textLength: 500,
            assistantCount: 4
        )
        #expect(tracker.ingest([old]) == nil)
        #expect(tracker.ingest([old]) == nil)
    }

    @Test func processStageEmptyIsNotGenerating() {
        #expect(!ClaudeTabTracker.isProcessStage(""))
        #expect(!ClaudeTabTracker.isLiveGenerating(
            ClaudeTabSnapshot(
                tab: ClaudeTabInfo(tabID: 1, windowIndex: 1, tabIndex: 1),
                isGenerating: false,
                preview: "",
                foundDOM: true
            )
        ))
    }

    @Test func youtubePickerPrefersNowPlayingTabNotTheFirstPausedTab() {
        let anuv = YouTubeTabPicker.Tab(
            tabID: 2,
            url: "https://www.youtube.com/watch?v=anuv",
            playerTitle: "Arz Kiya Hai",
            playerArtist: "Anuv Jain",
            paused: true
        )
        let other = YouTubeTabPicker.Tab(
            tabID: 1,
            url: "https://www.youtube.com/watch?v=other",
            playerTitle: "Random mix",
            playerArtist: "Someone",
            paused: true
        )
        let picked = YouTubeTabPicker.pick(
            from: [other, anuv],
            nowPlayingTitle: "Aarz Kia Hai",
            nowPlayingArtist: "Anuv Jain",
            preferredURL: "",
            bias: .play
        )
        #expect(picked?.url.contains("anuv") == true)
    }

    @Test func youtubePickerPlayWithoutMatchDoesNotGrabARandomTab() {
        let other = YouTubeTabPicker.Tab(
            tabID: 1,
            url: "https://www.youtube.com/watch?v=other",
            playerTitle: "Random mix",
            playerArtist: "Someone",
            paused: true
        )
        let picked = YouTubeTabPicker.pick(
            from: [other],
            nowPlayingTitle: "Arz Kiya Hai",
            nowPlayingArtist: "Anuv Jain",
            preferredURL: "",
            bias: .play
        )
        #expect(picked == nil)
    }

    @Test func youtubePickerResumeUsesLastControlledURL() {
        let anuv = YouTubeTabPicker.Tab(
            tabID: 2,
            url: "https://music.youtube.com/watch?v=anuv",
            playerTitle: "Arz Kiya Hai",
            playerArtist: "Anuv Jain",
            paused: true
        )
        let other = YouTubeTabPicker.Tab(
            tabID: 1,
            url: "https://music.youtube.com/watch?v=other",
            playerTitle: "Something else",
            playerArtist: "X",
            paused: true
        )
        let picked = YouTubeTabPicker.pick(
            from: [other, anuv],
            nowPlayingTitle: "Arz Kiya Hai",
            nowPlayingArtist: "Anuv Jain",
            preferredURL: "https://music.youtube.com/watch?v=anuv&list=RD",
            bias: .play
        )
        #expect(picked?.url.contains("anuv") == true)
    }

    @Test func pluggingInEmitsChargingOnce() {
        var state = PowerAlertState()
        #expect(state.ingest(percent: 40, isCharging: false) == nil)
        #expect(state.ingest(percent: 41, isCharging: true) == .chargingStarted(percent: 41))
        #expect(state.ingest(percent: 45, isCharging: true) == nil)
    }

    @Test func lowBatteryWarnsAtTenOnly() {
        var state = PowerAlertState()
        #expect(state.ingest(percent: 40, isCharging: false) == nil)
        #expect(state.ingest(percent: 20, isCharging: false) == nil)
        #expect(state.ingest(percent: 18, isCharging: false) == nil)
        #expect(state.ingest(percent: 10, isCharging: false) == .lowBattery(percent: 10))
        #expect(state.ingest(percent: 8, isCharging: false) == nil)
    }

    @Test func lowBatteryBannerDismissesAfterThreeSeconds() {
        #expect(IslandMetrics.lowBatteryOverlayTimeout == 3)
        #expect(IslandMetrics.overlayTimeout == 12)
        #expect(IslandMetrics.chargingOverlayTimeout == 4)
        #expect(IslandMetrics.levelHUDTimeout == 2)
    }

    @Test func chargingClearsLowBatteryWarnings() {
        var state = PowerAlertState()
        _ = state.ingest(percent: 10, isCharging: false)
        #expect(state.ingest(percent: 16, isCharging: true) == .chargingStarted(percent: 16))
        #expect(state.ingest(percent: 10, isCharging: false) == .lowBattery(percent: 10))
    }

    @Test func launchAlreadyLowShowsLowBattery() {
        var state = PowerAlertState()
        #expect(state.ingest(percent: 9, isCharging: false) == .lowBattery(percent: 9))
        #expect(state.ingest(percent: 9, isCharging: false) == nil)
    }

    @Test func launchAlreadyPluggedDoesNotShowCharging() {
        var state = PowerAlertState()
        #expect(state.ingest(percent: 80, isCharging: true) == nil)
    }

    @Test func turningFocusOnDoesNotAnnounceOffPulse() {
        var gate = FocusChangeGate()
        gate.baseline(false)
        #expect(gate.noteDisabledConfirmed(fileIsOn: false, at: 0.05) == nil)
        #expect(gate.noteEnabled(at: 0.1) == true)
        #expect(gate.noteDisabledConfirmed(fileIsOn: false, at: 0.2) == nil)
        #expect(gate.noteFileOff(at: 0.4) == nil)
        #expect(gate.noteConfirmedOn() == nil)
    }

    @Test func turningFocusOffAnnouncesOnlyAfterConfirmedOff() {
        var gate = FocusChangeGate()
        gate.baseline(false)
        #expect(gate.noteEnabled(at: 1) == true)
        #expect(gate.noteDisabledConfirmed(fileIsOn: false, at: 1.1) == nil)
        #expect(gate.noteDisabledConfirmed(
            fileIsOn: false,
            at: 1 + FocusChangeGate.disableAfterEnableGrace
        ) == false)
        #expect(gate.noteDisabledConfirmed(fileIsOn: false, at: 5) == nil)
    }

    @Test func briefOffWhileFocusedDoesNotShowOffBanner() {
        var gate = FocusChangeGate()
        gate.baseline(true)
        #expect(gate.noteEnabled(at: 1) == nil)
        #expect(gate.noteFileOff(at: 1.2) == nil)
        #expect(gate.noteConfirmedOn() == nil)
    }

    @Test func launchAlreadyFocusedDoesNotShowFocusBanner() {
        var gate = FocusChangeGate()
        gate.baseline(true)
        #expect(gate.noteConfirmedOn() == nil)
        #expect(gate.noteEnabled(at: 1) == nil)
        #expect(gate.noteDisabledConfirmed(
            fileIsOn: false,
            at: 1 + FocusChangeGate.disableAfterEnableGrace
        ) == false)
    }

    @Test func enabledBannerDoesNotNeedAssertionsFile() {
        var gate = FocusChangeGate()
        gate.baseline(false)
        #expect(gate.noteEnabled(at: 1) == true)
        #expect(gate.noteFileOff(at: 2) == nil)
    }

    @Test func focusAssertionsDetectActiveRecordsOnly() {
        let offJSON = """
        {"data":[{"storeInvalidationRecords":[{"invalidationReason":"user-changed-state"}]}]}
        """.data(using: .utf8)!
        let onJSON = """
        {"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}]}]}
        """.data(using: .utf8)!
        let emptyJSON = """
        {"data":[{}]}
        """.data(using: .utf8)!
        #expect(!FocusDSP.isActive(jsonData: offJSON))
        #expect(FocusDSP.isActive(jsonData: onJSON))
        #expect(!FocusDSP.isActive(jsonData: emptyJSON))
        #expect(!FocusDSP.isActive(jsonData: Data()))
    }

    @Test func simulatedWaveformDoesNotRepeatOnOldSinePeriod() {
        var engine = SimulatedWaveformEngine(seed: 42)
        let dt = 1.0 / 30.0
        /// Old animation was `sin(t * 4)`, period ≈ π/2 seconds.
        let periodFrames = Int((Double.pi / 2) / dt)
        var series: [CGFloat] = []
        series.reserveCapacity(periodFrames * 3)
        for _ in 0..<(periodFrames * 3) {
            series.append(engine.tick(dt: dt, playing: true)[0])
        }
        var meanAbs: CGFloat = 0
        for i in 0..<periodFrames {
            meanAbs += abs(series[i] - series[i + periodFrames])
        }
        meanAbs /= CGFloat(periodFrames)
        #expect(meanAbs > 0.04)
    }

    @Test func simulatedWaveformSmoothesInsteadOfJumping() {
        var engine = SimulatedWaveformEngine(seed: 7)
        let dt = 1.0 / 30.0
        var previous = engine.tick(dt: dt, playing: true)
        for _ in 0..<90 {
            let next = engine.tick(dt: dt, playing: true)
            for i in 0..<SimulatedWaveformEngine.barCount {
                #expect(abs(next[i] - previous[i]) < 0.72)
            }
            previous = next
        }
    }

    @Test func simulatedWaveformPulsesWithinTwoSeconds() {
        var engine = SimulatedWaveformEngine(seed: 99)
        let dt = 1.0 / 30.0
        var peak: CGFloat = 0
        for _ in 0..<60 {
            let levels = engine.tick(dt: dt, playing: true)
            peak = max(peak, levels.max() ?? 0)
        }
        #expect(peak > 0.88)
    }

    @Test func omittedLiveAmplitudeKeepsSimulatedMotion() {
        var engine = SimulatedWaveformEngine(seed: 11)
        var peak: CGFloat = 0
        for _ in 0..<45 {
            peak = max(peak, engine.tick(dt: 1.0 / 30.0, playing: true, liveAmplitude: nil).max() ?? 0)
        }
        #expect(peak > 0.55)
    }

    @Test func simulatedWaveformSettlesWhenPaused() {
        var engine = SimulatedWaveformEngine(seed: 3)
        for _ in 0..<20 {
            _ = engine.tick(dt: 1.0 / 30.0, playing: true)
        }
        var last: [CGFloat] = []
        for _ in 0..<40 {
            last = engine.tick(dt: 1.0 / 30.0, playing: false)
        }
        for level in last {
            #expect(abs(level - SimulatedWaveformEngine.idleLevel) < 0.05)
        }
    }

    @Test func pausedMediaRemoteIsNotKeptPlayingByStalePlaybackRate() {
        #expect(
            !PlaybackPlayingPolicy.isPlaying(reported: false, playbackRate: 1.0)
        )
        #expect(
            PlaybackPlayingPolicy.isPlaying(reported: true, playbackRate: 0)
        )
        #expect(
            PlaybackPlayingPolicy.isPlaying(reported: nil, playbackRate: 1.0)
        )
        #expect(
            !PlaybackPlayingPolicy.isPlaying(reported: nil, playbackRate: 0)
        )
        #expect(
            !PlaybackPlayingPolicy.resolvedPlaying(remote: true, htmlOverride: false)
        )
        #expect(
            PlaybackPlayingPolicy.resolvedPlaying(remote: false, htmlOverride: true)
        )
        #expect(
            PlaybackPlayingPolicy.resolvedPlaying(remote: true, htmlOverride: nil)
        )
    }

    @Test func htmlPlaybackProbeTreatsPagePauseAsStopped() {
        #expect(BrowserMediaNavigator.parsePlaybackProbe("paused") == false)
        #expect(BrowserMediaNavigator.parsePlaybackProbe("playing") == true)
        #expect(BrowserMediaNavigator.parsePlaybackProbe("0") == false)
        #expect(BrowserMediaNavigator.parsePlaybackProbe("1") == true)
        #expect(BrowserMediaNavigator.parsePlaybackProbe("unknown") == nil)
        #expect(BrowserMediaNavigator.parsePlaybackProbe("no-media") == nil)
        #expect(
            BrowserMediaNavigator.classifyJavaScriptReturn("no-tab") == .missingTab
        )
        #expect(
            BrowserMediaNavigator.classifyJavaScriptReturn("paused") == .success("paused")
        )
        #expect(
            BrowserMediaNavigator.classifyJavaScriptReturn("no-player") == .failed
        )
        #expect(
            BrowserMediaNavigator.classifyJavaScriptReturn("err:JavaScript from Apple Events")
                == .needsPermission
        )
    }

    @Test func youtubeSkipScriptsAdvanceOnASingleClick() {
        let nextWatch = BrowserMediaNavigator.youtubeWatchNextJavaScript
        #expect(nextWatch.contains(".ytp-next-button"))
        #expect(nextWatch.contains("b.click()"))
        let prevWatch = BrowserMediaNavigator.youtubeWatchPreviousJavaScript
        #expect(!prevWatch.contains("setTimeout"))
        #expect(prevWatch.contains("if (!nearStart) b.click()"))
        let prevMusic = BrowserMediaNavigator.youtubeMusicPreviousJavaScript
        #expect(!prevMusic.contains("setTimeout"))
        #expect(prevMusic.contains("if (!nearStart) b.click()"))
        #expect(BrowserMediaNavigator.youtubeMusicNextJavaScript.contains("b.click()"))
    }

    @Test func audioAmplitudeRMSOfSilenceIsZero() {
        #expect(AudioAmplitudeDSP.rms(samples: []) == 0)
        #expect(AudioAmplitudeDSP.rms(samples: [0, 0, 0, 0]) == 0)
    }

    @Test func audioAmplitudeRMSOfFullScaleIsOne() {
        let rms = AudioAmplitudeDSP.rms(samples: [1, -1, 1, -1])
        #expect(abs(rms - 1) < 0.0001)
    }

    @Test func audioAmplitudeSmoothAttacksFasterThanRelease() {
        let up = AudioAmplitudeDSP.smooth(current: 0, target: 0.5)
        let down = AudioAmplitudeDSP.smooth(current: 1, target: 0)
        #expect(up > 0.1)
        #expect(down < 0.95)
        #expect(up > (1 - down))
    }

    @Test func highFrequencyRMSHearsDenseTransients() {
        let dc = AudioAmplitudeDSP.highFrequencyRMS(samples: [0.8, 0.8, 0.8, 0.8])
        var rap = [Float]()
        for i in 0..<32 {
            rap.append(i % 2 == 0 ? 0.8 : -0.8)
        }
        let hf = AudioAmplitudeDSP.highFrequencyRMS(samples: rap)
        #expect(dc < 0.05)
        #expect(hf > 0.5)
        let loudBody = AudioAmplitudeDSP.drive(rms: 0.4, highFrequency: 0)
        #expect(loudBody < 0.7)
        #expect(loudBody > 0.25)
        #expect(AudioAmplitudeDSP.drive(rms: 0.4, highFrequency: 0.2) > loudBody + 0.12)
    }

    @Test func driveLeavesHeadroomOnCompressedLoudness() {
        let pinned = AudioAmplitudeDSP.drive(rms: 0.45, highFrequency: 0.02)
        #expect(pinned < 0.85)
        #expect(AudioAmplitudeDSP.drive(rms: 0.45, highFrequency: 0.18) > pinned + 0.08)
    }

    @Test func waveformBarsAreMirrored() {
        var engine = SimulatedWaveformEngine(seed: 4)
        var levels: [CGFloat] = []
        for _ in 0..<30 {
            levels = engine.tick(dt: 1.0 / 30.0, playing: true)
        }
        #expect(abs(levels[0] - levels[6]) < 0.001)
        #expect(abs(levels[1] - levels[5]) < 0.001)
        #expect(abs(levels[2] - levels[4]) < 0.001)
        var live = LiveWaveformMapper()
        for i in 0..<LiveWaveformMapper.weights.count {
            let j = LiveWaveformMapper.weights.count - 1 - i
            #expect(LiveWaveformMapper.weights[i] == LiveWaveformMapper.weights[j])
        }
        var mapped: [CGFloat] = []
        for _ in 0..<20 {
            mapped = live.tick(dt: 1.0 / 30.0, amplitude: 0.7)
        }
        #expect(abs(mapped[0] - mapped[6]) < 0.001)
        #expect(WaveformLayout.level(at: 0, displayCount: 6, stored: mapped)
            == WaveformLayout.level(at: 5, displayCount: 6, stored: mapped))
    }

    @Test func pauseEasesInsteadOfSnapping() {
        var engine = SimulatedWaveformEngine(seed: 8)
        var playing: [CGFloat] = []
        for _ in 0..<40 {
            playing = engine.tick(dt: 1.0 / 30.0, playing: true)
        }
        let before = playing.max() ?? 0
        let first = engine.tick(dt: 1.0 / 30.0, playing: false)
        #expect((first.max() ?? 0) > SimulatedWaveformEngine.idleLevel + 0.04)
        #expect((first.max() ?? 0) < before + 0.01)
        var last = first
        for _ in 0..<20 {
            last = engine.tick(dt: 1.0 / 30.0, playing: false)
        }
        #expect((last.max() ?? 1) < (first.max() ?? 0) - 0.02)
    }

    @Test func liveWaveformFollowsAmplitude() {
        var mapper = LiveWaveformMapper()
        var quiet: [CGFloat] = []
        for _ in 0..<20 {
            quiet = mapper.tick(dt: 1.0 / 30.0, amplitude: 0.05)
        }
        var loud: [CGFloat] = []
        var peak: CGFloat = 0
        for _ in 0..<20 {
            loud = mapper.tick(dt: 1.0 / 30.0, amplitude: 0.95)
            peak = max(peak, loud.max() ?? 0)
        }
        #expect(peak > 0.75)
        #expect((loud.max() ?? 0) > (quiet.max() ?? 0) + 0.15)
        #expect((loud.max() ?? 0) < 0.72)
    }

    @Test func liveWaveformSettlesToMediumAfterAPeak() {
        var mapper = LiveWaveformMapper()
        var peak: CGFloat = 0
        for _ in 0..<6 {
            peak = max(peak, mapper.tick(dt: 1.0 / 30.0, amplitude: 1.0).max() ?? 0)
        }
        var settled: CGFloat = 1
        for _ in 0..<36 {
            settled = mapper.tick(dt: 1.0 / 30.0, amplitude: 0.88).max() ?? 0
        }
        #expect(peak > 0.72)
        #expect(settled < peak - 0.22)
        #expect(settled > 0.22)
        #expect(settled < 0.62)
    }

    @Test func liveWaveformBeatExpandsFromMedium() {
        var mapper = LiveWaveformMapper()
        var rest: CGFloat = 0
        for _ in 0..<40 {
            rest = mapper.tick(dt: 1.0 / 30.0, amplitude: 0.7).max() ?? 0
        }
        var hit: CGFloat = 0
        for _ in 0..<4 {
            hit = max(hit, mapper.tick(dt: 1.0 / 30.0, amplitude: 1.0).max() ?? 0)
        }
        #expect(rest < 0.58)
        #expect(hit > rest + 0.22)
    }

    @Test func liveWaveformUsesSameBarCountAsIsland() {
        #expect(LiveWaveformMapper.barCount == SimulatedWaveformEngine.barCount)
        #expect(LiveWaveformMapper.weights.count == LiveWaveformMapper.barCount)
    }

    @Test func albumArtShadowClampsSaturationAndBrightness() {
        let clamped = AlbumArtShadowColor.clampHSB(hue: 0.12, saturation: 0.95, brightness: 0.9)
        #expect(clamped.saturation <= AlbumArtShadowColor.maxSaturation)
        #expect(clamped.brightness <= AlbumArtShadowColor.maxBrightness)
        #expect(clamped.hue == 0.12)
    }

    @Test func albumArtAverageOfSolidColorStaysInShadowRange() {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        #expect(AlbumArtShadowColor.extract(from: image) != nil)
    }

    @Test func screenshotStillIsNotARecordingMovie() {
        #expect(!ScreenRecordingDSP.isRecordingMovie(filename: "Screenshot 2026-08-30.png"))
        #expect(!ScreenRecordingDSP.isRecordingMovie(filename: "Screen Shot 2026-08-30 at 1.19.48 PM.png"))
        #expect(ScreenRecordingDSP.isRecordingMovie(filename: "capture.mov"))
        #expect(ScreenRecordingDSP.commandLineLooksLikeVideoCapture("/usr/sbin/screencapture -v /tmp/out.mov"))
        #expect(!ScreenRecordingDSP.commandLineLooksLikeVideoCapture("/usr/sbin/screencapture /tmp/shot.png"))
        #expect(!ScreenRecordingDSP.commandLineLooksLikeVideoCapture("/System/Library/CoreServices/screencaptureui"))
        #expect(!ScreenRecordingDSP.isCaptureTempFolder("NSIRD_something_else"))
        #expect(ScreenRecordingDSP.isCaptureTempFolder("NSIRD_screencaptureui_vKQzd7"))
    }

    @Test func recordingTempFolderNeedsAMovie() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("island-rec-test-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("NSIRD_screencaptureui_test")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? Data().write(to: folder.appendingPathComponent("Screenshot.png"))
        #expect(!ScreenRecordingDSP.hasRecordingMovie(inTemporaryItems: root))
        try? Data().write(to: folder.appendingPathComponent("Screen Recording 2026-08-30.mov"))
        #expect(ScreenRecordingDSP.hasRecordingMovie(inTemporaryItems: root))
    }

    @Test func recordingDirectoryDetectsDirectAndHiddenMovies() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("island-rec-direct-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try? Data().write(to: root.appendingPathComponent(".Screen Recording.mov"))
        #expect(ScreenRecordingDSP.hasRecordingMovie(inTemporaryItems: root))
    }

    @Test func screenshotWindowIsNotRecordingControl() {
        #expect(
            !ScreenRecordingDSP.windowLooksLikeRecordingControl(
                owner: "screencaptureui",
                title: "Screenshot"
            )
        )
        #expect(
            ScreenRecordingDSP.windowLooksLikeRecordingControl(
                owner: "screencaptureui",
                title: "Stop Recording"
            )
        )
        #expect(
            !ScreenRecordingDSP.windowLooksLikeRecordingControl(
                owner: "screencaptureui",
                title: ""
            )
        )
    }

    @Test func nativeMenuBarStopControlIsDetectedWithoutMatchingTheToolbar() {
        #expect(
            ScreenRecordingDSP.looksLikeNativeStopControl(
                owner: "screencaptureui",
                title: "Stop Recording",
                bounds: CGRect(x: 1180, y: 6, width: 36, height: 36)
            )
        )
        #expect(
            ScreenRecordingDSP.looksLikeNativeStopControl(
                owner: "Screenshot",
                title: "",
                bounds: CGRect(x: 1200, y: 4, width: 28, height: 24)
            )
        )
        #expect(
            !ScreenRecordingDSP.looksLikeNativeStopControl(
                owner: "screencaptureui",
                title: "Screenshot",
                bounds: CGRect(x: 420, y: 48, width: 420, height: 72)
            )
        )
        #expect(
            !ScreenRecordingDSP.looksLikeNativeStopControl(
                owner: "screencaptureui",
                title: "Click to record this display",
                bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)
            )
        )
        #expect(
            !ScreenRecordingDSP.looksLikeNativeStopControl(
                owner: "Finder",
                title: "Stop Recording",
                bounds: CGRect(x: 1180, y: 6, width: 36, height: 36)
            )
        )
        #expect(
            ScreenRecordingDSP.looksLikeNativeStopControl(
                owner: "Control Center",
                title: "Stop Recording",
                bounds: CGRect(x: 1180, y: 6, width: 36, height: 36)
            )
        )
        #expect(
            !ScreenRecordingDSP.looksLikeNativeStopControl(
                owner: "Control Center",
                title: "",
                bounds: CGRect(x: 1180, y: 6, width: 36, height: 36)
            )
        )
    }

    @Test func recordSelectionHeuristics() {
        #expect(ScreenRecordingDSP.isCaptureUIOwner("screencaptureui"))
        #expect(ScreenRecordingDSP.isCaptureUIOwner("Screenshot"))
        #expect(!ScreenRecordingDSP.isCaptureUIOwner("Finder"))
        #expect(
            ScreenRecordingDSP.isCaptureUIApp(
                bundleID: "com.apple.screencaptureui",
                localizedName: nil
            )
        )
        #expect(ScreenRecordingDSP.textIsRecordAction("Record"))
        #expect(!ScreenRecordingDSP.textIsRecordAction("Capture"))
        #expect(ScreenRecordingDSP.textIsCaptureAction("Capture"))
        #expect(!ScreenRecordingDSP.textIsCaptureAction("Record"))
        #expect(!ScreenRecordingDSP.textIsRecordAction("Record Entire Screen"))
        #expect(ScreenRecordingDSP.textIsRecordTool("Record Entire Screen"))
        #expect(ScreenRecordingDSP.textIsRecordTool("Record Selected Window"))
        #expect(!ScreenRecordingDSP.textIsRecordTool("Capture Entire Screen"))
        #expect(ScreenRecordingDSP.textIndicatesRecordingOverlay("Click to record this display"))
        #expect(!ScreenRecordingDSP.textIndicatesRecordingOverlay("Capture Entire Screen"))
        #expect(ScreenRecordingDSP.textIndicatesStopRecording("Stop Recording"))
        #expect(!ScreenRecordingDSP.textIndicatesStopRecording("Record Entire Screen"))
        #expect(
            !ScreenRecordingDSP.windowLooksLikeSelectionOverlay(
                owner: "screencaptureui",
                title: "",
                bounds: CGRect(x: 100, y: 40, width: 720, height: 78)
            )
        )
        #expect(
            ScreenRecordingDSP.windowLooksLikeSelectionOverlay(
                owner: "screencaptureui",
                title: "",
                bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)
            )
        )
        #expect(
            !ScreenRecordingDSP.windowLooksLikeSelectionOverlay(
                owner: "Finder",
                title: "",
                bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)
            )
        )
    }

    @Test func capturePhaseTransitionsSelectingToRecording() {
        // Armed record tool / overlay → selecting
        let selecting = ScreenRecordingDSP.resolvePhase(
            previewForced: false,
            systemRecording: false,
            captureUIRunning: true,
            screenshotMode: false,
            recordModeOrOverlay: true,
            hadRecordIntent: false
        )
        #expect(selecting.phase == .selecting)
        #expect(selecting.intent == true)

        // Picker gone after intent, capture UI still alive → recording
        let recording = ScreenRecordingDSP.resolvePhase(
            previewForced: false,
            systemRecording: false,
            captureUIRunning: true,
            screenshotMode: false,
            recordModeOrOverlay: false,
            hadRecordIntent: true
        )
        #expect(recording.phase == .recording)

        // Explicit system recording wins
        let system = ScreenRecordingDSP.resolvePhase(
            previewForced: false,
            systemRecording: true,
            captureUIRunning: true,
            screenshotMode: false,
            recordModeOrOverlay: false,
            hadRecordIntent: true
        )
        #expect(system.phase == .recording)

        // Capture UI quit → idle
        let idle = ScreenRecordingDSP.resolvePhase(
            previewForced: false,
            systemRecording: false,
            captureUIRunning: false,
            screenshotMode: false,
            recordModeOrOverlay: false,
            hadRecordIntent: true
        )
        #expect(idle.phase == .idle)

        // Switched back to screenshot tool → idle
        let shot = ScreenRecordingDSP.resolvePhase(
            previewForced: false,
            systemRecording: false,
            captureUIRunning: true,
            screenshotMode: true,
            recordModeOrOverlay: false,
            hadRecordIntent: true
        )
        #expect(shot.phase == .idle)
    }

    @Test func accessibilitySheetIsNeverShownAutomatically() {
        #expect(!IslandSurfacePolicy.shouldShowSystemAccessibilityPrompt)
        #expect(!IslandSurfacePolicy.shouldCreateHIDEventTapOnLaunch)
        #expect(!IslandSurfacePolicy.shouldInstallGlobalPointerMonitor)
        #expect(
            !IslandSurfacePolicy.shouldCreateHIDEventTap(
                isTrusted: false,
                alreadyAttempted: false,
                previousCreateFailed: false
            )
        )
        #expect(
            IslandSurfacePolicy.shouldCreateHIDEventTap(
                isTrusted: true,
                alreadyAttempted: false,
                previousCreateFailed: false
            )
        )
        #expect(
            !IslandSurfacePolicy.shouldCreateHIDEventTap(
                isTrusted: true,
                alreadyAttempted: true,
                previousCreateFailed: false
            )
        )
        #expect(
            !IslandSurfacePolicy.shouldCreateHIDEventTap(
                isTrusted: true,
                alreadyAttempted: false,
                previousCreateFailed: true
            )
        )
        #expect(IslandSurfacePolicy.shouldAttemptMediaKeyTapWhenAlreadyTrusted)
        #expect(IslandSurfacePolicy.shouldRetryMediaKeyTapWhileRunning)
        #expect(!IslandSurfacePolicy.shouldRemapMediaKeysToFunctionKeys)
    }

    @Test func islandBannersReplaceNativeSystemHUDs() {
        let tab = ClaudeTabInfo(tabID: 1, windowIndex: 1, tabIndex: 1, provider: .claude)
        #expect(TransientOverlay.volume(percent: 40, muted: false).replacesSystemHUD)
        #expect(TransientOverlay.brightness(percent: 55).replacesSystemHUD)
        #expect(TransientOverlay.focusMode(isOn: true).replacesSystemHUD)
        #expect(TransientOverlay.charging(percent: 80).replacesSystemHUD)
        #expect(TransientOverlay.lowBattery(percent: 12).replacesSystemHUD)
        #expect(!TransientOverlay.chatReady(preview: "Ready", tab: tab).replacesSystemHUD)
    }

    @Test func nativeLevelHUDWindowsAreTheSmallControlCenterPills() {
        #expect(
            SystemHUDDSP.looksLikeNativeLevelHUD(
                owner: "OSDUIHelper",
                bounds: CGRect(x: 800, y: 400, width: 200, height: 200)
            )
        )
        #expect(
            SystemHUDDSP.looksLikeNativeLevelHUD(
                owner: "Control Center",
                bounds: CGRect(x: 1400, y: 28, width: 220, height: 56)
            )
        )
        #expect(
            !SystemHUDDSP.looksLikeNativeLevelHUD(
                owner: "Control Center",
                bounds: CGRect(x: 1200, y: 28, width: 380, height: 540)
            )
        )
        #expect(
            !SystemHUDDSP.looksLikeNativeLevelHUD(
                owner: "Notification Center",
                bounds: CGRect(x: 1400, y: 28, width: 220, height: 56)
            )
        )
        #expect(SystemHUDDSP.isOSDHelper(bundleID: "com.apple.OSDUIHelper", localizedName: nil))
    }

    @Test func nativeLowBatteryAlertsAreBatteryUIOrTitledBanners() {
        #expect(
            SystemHUDDSP.looksLikeNativeLowBatteryAlert(
                owner: "BatteryUI",
                title: "",
                bounds: CGRect(x: 400, y: 200, width: 360, height: 140)
            )
        )
        #expect(
            SystemHUDDSP.looksLikeNativeLowBatteryAlert(
                owner: "Notification Center",
                title: "Low Battery",
                bounds: CGRect(x: 1400, y: 40, width: 360, height: 88)
            )
        )
        #expect(
            !SystemHUDDSP.looksLikeNativeLowBatteryAlert(
                owner: "Notification Center",
                title: "Claude replied",
                bounds: CGRect(x: 1400, y: 40, width: 360, height: 88)
            )
        )
        #expect(
            SystemHUDDSP.looksLikeNativeLowBatteryAlert(
                owner: "Notification Center",
                title: "",
                bounds: CGRect(x: 1400, y: 40, width: 360, height: 88)
            )
        )
        #expect(
            !SystemHUDDSP.looksLikeNativeLowBatteryAlert(
                owner: "Notification Center",
                title: "",
                bounds: CGRect(x: 1200, y: 28, width: 380, height: 540)
            )
        )
        #expect(
            SystemHUDDSP.isBatteryAlertHelper(
                bundleID: "com.apple.batteryui",
                localizedName: nil
            )
        )
    }

    @Test func hidRedirectMapsVolumeKeysToUnusedFunctionKeysAndLeavesOthers() {
        let volumeUp = SystemHUDDSP.hidUsage(page: 0x0C, usage: 0xE9)
        let f18 = SystemHUDDSP.hidUsage(page: 0x07, usage: 0x6D)
        let caps = SystemHUDDSP.hidUsage(page: 0x07, usage: 0x39)
        let existing: [[String: UInt64]] = [[
            SystemHUDDSP.srcKey: caps,
            SystemHUDDSP.dstKey: SystemHUDDSP.hidUsage(page: 0x07, usage: 0x04)
        ]]
        let merged = SystemHUDDSP.mergeHIDRedirects(existing: existing)
        #expect(merged.contains { $0[SystemHUDDSP.srcKey] == volumeUp && $0[SystemHUDDSP.dstKey] == f18 })
        #expect(merged.contains { $0[SystemHUDDSP.srcKey] == caps })
        let stripped = SystemHUDDSP.stripIslandHIDRedirects(merged)
        #expect(stripped.count == 1)
        #expect(stripped[0][SystemHUDDSP.srcKey] == caps)
        #expect(SystemHUDDSP.stripIslandHIDRedirects(SystemHUDDSP.islandHIDRedirectMaps()).isEmpty)
        #expect(RedirectedMediaKey.fromCGKeyCode(RedirectedMediaKey.cgKeyF18) == .volumeUp)
        #expect(RedirectedMediaKey.fromNXKeyCode(0) == .volumeUp)
        #expect(RedirectedMediaKey.fromCGKeyCode(0) == nil)
    }

    @Test func keyboardArrowsMapToTheSameIslandTransportButtons() {
        #expect(IslandKeyboardTransport.fromNXKeyCode(16) == .playPause)
        #expect(IslandKeyboardTransport.fromNXKeyCode(17) == .skipForward)
        #expect(IslandKeyboardTransport.fromNXKeyCode(18) == .skipBack)
        #expect(IslandKeyboardTransport.fromNXKeyCode(19) == .skipForward)
        #expect(IslandKeyboardTransport.fromNXKeyCode(20) == .skipBack)
        #expect(IslandKeyboardTransport.fromNXKeyCode(0) == nil)
        #expect(IslandKeyboardTransport.fromNXKeyCode(7) == nil)

        let none = CGEventFlags(rawValue: 0)
        #expect(IslandKeyboardTransport.fromCGKeyCode(123, flags: none) == .skipBack)
        #expect(IslandKeyboardTransport.fromCGKeyCode(124, flags: none) == .skipForward)
        #expect(IslandKeyboardTransport.fromCGKeyCode(49, flags: none) == .playPause)
        #expect(IslandKeyboardTransport.fromCGKeyCode(123, flags: .maskCommand) == nil)
        #expect(IslandKeyboardTransport.fromCGKeyCode(124, flags: .maskShift) == nil)
        #expect(IslandKeyboardTransport.fromCGKeyCode(49, flags: .maskAlternate) == nil)
        #expect(IslandKeyboardTransport.fromCGKeyCode(126, flags: none) == nil)

        #expect(
            IslandSurfacePolicy.shouldBindArrowKeysToIsland(
                isExpanded: true,
                hasMedia: true,
                pointerOverIsland: true
            )
        )
        #expect(
            !IslandSurfacePolicy.shouldBindArrowKeysToIsland(
                isExpanded: false,
                hasMedia: true,
                pointerOverIsland: true
            )
        )
        #expect(
            !IslandSurfacePolicy.shouldBindArrowKeysToIsland(
                isExpanded: true,
                hasMedia: true,
                pointerOverIsland: false
            )
        )
        #expect(
            !IslandSurfacePolicy.shouldBindArrowKeysToIsland(
                isExpanded: true,
                hasMedia: false,
                pointerOverIsland: true
            )
        )
    }

    @Test func desktopIslandStaysVisibleWhenABannerIsShowing() {
        #expect(!IslandSurfacePolicy.shouldHideDesktopIsland(lockActive: true, overlayActive: true))
        #expect(IslandSurfacePolicy.shouldHideDesktopIsland(lockActive: true, overlayActive: false))
        #expect(!IslandSurfacePolicy.shouldHideDesktopIsland(lockActive: false, overlayActive: true))
        #expect(!IslandSurfacePolicy.shouldHideDesktopIsland(lockActive: false, overlayActive: false))
        #expect(IslandSurfacePolicy.shouldHandleSpaceSwipe(usesTightLiveActivityWindow: false))
        #expect(IslandSurfacePolicy.shouldHandleSpaceSwipe(usesTightLiveActivityWindow: true))
    }

    @Test func pointerOnIslandTopEdgeStillCountsAsHover() {
        // Logged miss: y == island.maxY, CGRect.contains was false, dist 0.
        let island = CGRect(x: 704, y: 949, width: 235, height: 33)
        #expect(island.maxY == 982)
        #expect(!island.contains(CGPoint(x: 821, y: 982)))
        #expect(
            IslandSurfacePolicy.pointerIsOverIsland(
                point: CGPoint(x: 821, y: 982),
                island: island,
                previous: CGPoint(x: 826, y: 952),
                radius: 17
            )
        )
        #expect(
            IslandSurfacePolicy.pointerIsOverIsland(
                point: CGPoint(x: 821, y: 982),
                island: CGRect(x: 654, y: 804, width: 335, height: 178),
                previous: CGPoint(x: 821, y: 952),
                radius: 89
            )
        )
    }

    @Test func pointerWithinIslandRadiusSlopExpands() {
        let island = CGRect(x: 704, y: 949, width: 235, height: 33)
        #expect(IslandSurfacePolicy.islandHoverSlop(radius: 17) == 1)
        #expect(
            IslandSurfacePolicy.pointerIsOverIsland(
                point: CGPoint(x: 827, y: 948),
                island: island,
                previous: nil,
                radius: 17
            )
        )
        #expect(
            !IslandSurfacePolicy.pointerIsOverIsland(
                point: CGPoint(x: 827, y: 946),
                island: island,
                previous: nil,
                radius: 17
            )
        )
    }

    @Test func pointerLeavingExpandedIslandBelowDoesNotStayHovered() {
        let island = CGRect(x: 654, y: 804, width: 335, height: 178)
        #expect(
            !IslandSurfacePolicy.pointerIsOverIsland(
                point: CGPoint(x: 849, y: 800),
                island: island,
                previous: CGPoint(x: 849, y: 810),
                radius: 89
            )
        )
    }

    @Test func fastSwipeThatTunnelsThroughTheIslandStillHovers() {
        let island = CGRect(x: 704, y: 949, width: 235, height: 33)
        #expect(
            IslandSurfacePolicy.pointerIsOverIsland(
                point: CGPoint(x: 821, y: 1008),
                island: island,
                previous: CGPoint(x: 830, y: 910),
                radius: 17
            )
        )
    }

    @Test func incomingSpacePlateHasNoIslandWhenWindowDoesNotJoinAllSpaces() {
        #expect(
            IslandSurfacePolicy.windowWouldAppearOnIncomingSpacePlate(joinsAllSpaces: true)
        )
        #expect(
            !IslandSurfacePolicy.windowWouldAppearOnIncomingSpacePlate(joinsAllSpaces: false)
        )
        let behavior = IslandSurfacePolicy.desktopIslandCollectionBehavior
        #expect(!behavior.contains(.canJoinAllSpaces))
        #expect(!behavior.contains(.moveToActiveSpace))
        #expect(!behavior.contains(.stationary))
        #expect(behavior.contains(.fullScreenAuxiliary))
        #expect(behavior.contains(.canJoinAllApplications))
        #expect(
            !IslandSurfacePolicy.windowWouldAppearOnIncomingSpacePlate(
                joinsAllSpaces: behavior.contains(.canJoinAllSpaces)
            )
        )
        let arrival = IslandSurfacePolicy.spaceArrivalCollectionBehavior
        #expect(arrival.contains(.canJoinAllSpaces))
        #expect(!arrival.contains(.moveToActiveSpace))
        #expect(!arrival.contains(.stationary))
    }

    @Test @MainActor
    func desktopIslandDoesNotJoinAllSpacesAfterOrderFront() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        controller.window?.orderFrontRegardless()
        let behavior = controller.window?.collectionBehavior ?? []
        #expect(!behavior.contains(.canJoinAllSpaces))
        #expect(!behavior.contains(.moveToActiveSpace))
        #expect(!behavior.contains(.stationary))
        #expect(behavior.contains(.fullScreenAuxiliary))
        controller.window?.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        #expect(controller.window?.collectionBehavior.contains(.canJoinAllSpaces) != true)
        #expect(
            controller.window?
                .collectionBehavior
                .intersection(IslandSurfacePolicy.spaceSwipeSnapshotBehaviors)
                .isEmpty == true
        )
    }

    @Test @MainActor
    func desktopIslandDoesNotConstrainFrameToMenuBar() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        guard let window = controller.window else {
            Issue.record("expected island window")
            return
        }
        let proposed = NSRect(x: 80, y: 4000, width: 420, height: 90)
        let constrained = window.constrainFrameRect(proposed, to: NSScreen.screens.first)
        #expect(constrained == proposed)
        #expect(!window.isMovable)
        #expect(window.animationBehavior == .none)
        #expect(!window.hidesOnDeactivate)
    }

    @Test @MainActor
    func desktopIslandCollectionBehaviorFlagsStickAfterApply() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        guard let window = controller.window else {
            Issue.record("expected island window")
            return
        }
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        let requested = IslandSurfacePolicy.desktopIslandCollectionBehavior
        let applied = window.collectionBehavior
        #expect(!applied.contains(.canJoinAllSpaces))
        #expect(!applied.contains(.stationary))
        #expect(!applied.contains(.moveToActiveSpace))
        #expect(applied.contains(.fullScreenAuxiliary))
        #expect(applied.contains(.ignoresCycle))
        #expect(applied.contains(.canJoinAllApplications))
        #expect(applied.intersection(IslandSurfacePolicy.spaceSwipeSnapshotBehaviors).isEmpty)
        #expect(
            applied.intersection(requested) == requested,
            "AppKit dropped collectionBehavior flags. requested=\(requested.rawValue) applied=\(applied.rawValue)"
        )
    }

    @Test func spaceTransitionOffsetDoesNotAccumulateAndKeepsRestingOrigin() {
        let resting = NSRect(x: 448, y: 704, width: 616, height: 278)
        let hidden = IslandSpaceTransitionMotion.hiddenOffset(islandHeight: 33)
        #expect(hidden == 33)
        let up = IslandSpaceTransitionMotion.displayedFrame(resting: resting, offsetY: hidden)
        #expect(up.origin.x == resting.origin.x)
        #expect(up.origin.y == resting.origin.y + hidden)
        #expect(up.size == resting.size)
        let second = IslandSpaceTransitionMotion.displayedFrame(resting: resting, offsetY: hidden)
        #expect(second.origin.y == up.origin.y)
        let back = IslandSpaceTransitionMotion.displayedFrame(resting: resting, offsetY: 0)
        #expect(back == resting)
        let presented = IslandSpaceTransitionMotion.presentedFrame(
            resting: resting,
            originX: 400,
            offsetY: hidden
        )
        #expect(presented.origin.x == 400)
        #expect(presented.origin.y == resting.origin.y + hidden)
        #expect(presented.size == resting.size)
        #expect(IslandSpaceTransitionMotion.layerTranslationY(offsetY: 33, viewIsFlipped: true) == -33)
        #expect(IslandSpaceTransitionMotion.layerTranslationY(offsetY: 33, viewIsFlipped: false) == 33)
        #expect(IslandSpaceTransitionMotion.layerTranslationY(offsetY: 0, viewIsFlipped: true) == 0)
        #expect(IslandSpaceTransitionMotion.enterFastPhaseDuration == 0.098)
        #expect(IslandSpaceTransitionMotion.enterSlowPhaseDuration == 0.500)
        #expect(IslandSpaceTransitionMotion.enterDuration == 0.098 + 0.500)
        #expect(
            abs(
                Double(IslandSpaceTransitionMotion.enterFastSplit)
                    - (0.098 / (0.098 + 0.500))
            ) < 0.0001
        )
        #expect(IslandSpaceTransitionMotion.enterFirstSample < 0.01)
        let firstLinear = IslandSpaceTransitionMotion.enterFirstSample / IslandSpaceTransitionMotion.enterDuration
        #expect(IslandSpaceTransitionMotion.enterEase(firstLinear) > 0)
        #expect(abs(IslandSpaceTransitionMotion.easeOut(0.5) - 0.75) < 0.01)
        #expect(IslandSpaceTransitionMotion.easeOut(1) == 1)
        #expect(abs(IslandSpaceTransitionMotion.enterEase(0)) < 0.001)
        #expect(abs(IslandSpaceTransitionMotion.enterEase(1) - 1) < 0.001)
        let split = IslandSpaceTransitionMotion.enterFastSplit
        #expect(IslandSpaceTransitionMotion.enterEase(split) > 0.80)
        #expect(IslandSpaceTransitionMotion.enterEase(split) < 0.95)
        #expect(IslandSpaceTransitionMotion.enterEase(0.75) > 0.96)
        var peak: CGFloat = 0
        for i in 0...20 {
            peak = max(peak, IslandSpaceTransitionMotion.enterEase(CGFloat(i) / 20))
        }
        #expect(peak <= 1.001, "drop-in must not bounce past rest. peak=\(peak)")
    }

    @Test func swipeLiftPreservesRestingXAndRestoresWhenIdle() {
        let restX: CGFloat = 448
        let screenWidth: CGFloat = 1512
        let islandHeight: CGFloat = 33
        // 20% swipe, not yet pinned.
        let delta20 = screenWidth * 0.2
        let lifted20 = IslandSpaceTransitionMotion.easeOut(0.2) * islandHeight
        #expect(abs(IslandSpaceTransitionMotion.swipeProgress(deltaX: delta20, screenWidth: screenWidth) - 0.2) < 0.001)
        #expect(abs(IslandSpaceTransitionMotion.liftOffsetY(deltaX: delta20, screenWidth: screenWidth, islandHeight: islandHeight) - lifted20) < 0.05)
        #expect(lifted20 > 0.2 * islandHeight)
        #expect(abs(IslandSpaceTransitionMotion.liftOffsetY(deltaX: 0, screenWidth: screenWidth, islandHeight: islandHeight)) < 0.01)
        #expect(abs(IslandSpaceTransitionMotion.liftOffsetY(deltaX: screenWidth, screenWidth: screenWidth, islandHeight: islandHeight) - islandHeight) < 0.01)
        // WindowServer owns horizontal Space motion. AppKit only moves Y so
        // its live frame cannot alternate with the compositor snapshot on X.
        let lifted = IslandSpaceTransitionMotion.presentedFrame(
            resting: NSRect(x: restX, y: 704, width: 616, height: 278),
            originX: restX,
            offsetY: lifted20
        )
        #expect(lifted.origin.x == restX)
        #expect(abs(lifted.origin.y - (704 + lifted20)) < 0.01)
        let restored = IslandSpaceTransitionMotion.presentedFrame(
            resting: NSRect(x: restX, y: 704, width: 616, height: 278),
            originX: restX,
            offsetY: 0
        )
        #expect(abs(restored.origin.x - restX) < 0.01)
        #expect(restored.origin.y == 704)
        let smoothed = IslandSpaceTransitionMotion.smoothedLift(current: 0, target: 6.6, alpha: 0.42)
        #expect(smoothed > 2 && smoothed < 6.6)
    }

    @Test func stableCompositorDeltaIgnoresOneFrameVisualLag() {
        let kept = IslandSpaceTransitionMotion.stableCompositorDeltaX(
            visualX: 750,
            appKitX: 100,
            lastVisualX: 750,
            lastAppKitX: 448,
            lastDeltaX: 302
        )
        #expect(kept == 302)
        let fresh = IslandSpaceTransitionMotion.stableCompositorDeltaX(
            visualX: 800,
            appKitX: 100,
            lastVisualX: 750,
            lastAppKitX: 448,
            lastDeltaX: 302
        )
        #expect(abs(fresh - 700) < 0.01)
    }

    @Test func swipeTickFollowsThenCancelsOrParks() {
        var session = IslandSpaceSwipeSession()
        let followLift = IslandSpaceTransitionMotion.liftOffsetY(
            deltaX: 302,
            screenWidth: 1512,
            islandHeight: 33
        )
        let follow = session.tick(compositorDeltaX: 302, screenWidth: 1512, islandHeight: 33, smoothing: 1)
        guard case .follow(let dx, let y) = follow else {
            Issue.record("expected follow, got \(follow)")
            return
        }
        #expect(abs(dx - 302) < 0.01)
        #expect(abs(y - followLift) < 0.05)
        #expect(session.phase == .tracking)

        var eased = IslandSpaceSwipeSession()
        let first = eased.tick(
            compositorDeltaX: 302,
            screenWidth: 1512,
            islandHeight: 33,
            smoothing: IslandSpaceTransitionMotion.liftSmoothing
        )
        guard case .follow(_, let easedY) = first else {
            Issue.record("expected eased follow")
            return
        }
        #expect(easedY < followLift)
        #expect(easedY > 2)

        var settled: IslandSpaceSwipeSession.TickAction = .ignore
        for _ in 1...IslandSpaceTransitionMotion.idleConfirmTicks {
            settled = session.tick(compositorDeltaX: 0, screenWidth: 1512, islandHeight: 33)
        }
        #expect(settled == .cancel)
        #expect(session.phase == .hidden)
        #expect(abs(session.offsetY - followLift) < 0.05)

        var commit = IslandSpaceSwipeSession()
        _ = commit.tick(compositorDeltaX: 1400, screenWidth: 1512, islandHeight: 33)
        var park: IslandSpaceSwipeSession.TickAction = .ignore
        for _ in 1...IslandSpaceTransitionMotion.idleConfirmTicks {
            park = commit.tick(compositorDeltaX: 0, screenWidth: 1512, islandHeight: 33)
        }
        #expect(park == .park)
        #expect(commit.phase == .hidden)
        #expect(commit.offsetY == 33)
    }

    @Test func compositorCannotRestartDropInDuringSlowSpaceSettle() {
        var session = IslandSpaceSwipeSession()
        let screenWidth: CGFloat = 1512
        let islandHeight: CGFloat = 33
        session.spaceDidChange(islandHeight: islandHeight)
        session.markEntering()
        session.setEnterOffset(24)

        // WindowServer keeps reporting the tail of a slow Space morph after
        // activeSpaceDidChange. None of those samples may steal ownership from
        // the one drop-in animation.
        for delta in [280, 160, 40, 4, 0] as [CGFloat] {
            let action = session.tick(
                compositorDeltaX: delta,
                screenWidth: screenWidth,
                islandHeight: islandHeight,
                smoothing: IslandSpaceTransitionMotion.liftSmoothing,
                compositorSnapped: delta == 0
            )
            #expect(action == .ignore)
            #expect(session.phase == .entering)
            #expect(session.offsetY == 24)
        }

        session.finishEnter(now: 1)
        #expect(session.phase == .idle)
        #expect(session.offsetY == 0)
    }

    @Test func compositorSnapParksWithoutDroppingToRest() {
        var session = IslandSpaceSwipeSession()
        _ = session.tick(compositorDeltaX: 302, screenWidth: 1512, islandHeight: 33, smoothing: 1)
        let parked = session.tick(
            compositorDeltaX: 0,
            screenWidth: 1512,
            islandHeight: 33,
            compositorSnapped: true
        )
        #expect(parked == .park)
        #expect(session.phase == .hidden)
        #expect(session.offsetY == 33)
        session.markEntering()
        session.spaceDidChange(islandHeight: 33)
        #expect(session.phase == .entering)
        #expect(session.arrivalStarts == 0)
    }

    @Test func rapidSpaceChangesStayHiddenUntilSettled() {
        var session = IslandSpaceSwipeSession()
        session.spaceDidChange(islandHeight: 33)
        #expect(session.phase == .hidden)
        session.spaceDidChange(islandHeight: 33)
        #expect(session.phase == .hidden)
        #expect(session.arrivalStarts == 2)
        #expect(session.offsetY == 33)
        session.markEntering()
        session.spaceDidChange(islandHeight: 33)
        #expect(session.phase == .entering)
        #expect(session.arrivalStarts == 2)
        #expect(IslandSpaceTransitionMotion.arrivalSettle == 0)
        #expect(IslandSpaceTransitionMotion.idleConfirmTicks >= 4)
    }

    @Test @MainActor
    func spaceChangeArrivesOnceAndReturnsToRest() {
        var session = IslandSpaceSwipeSession()
        session.spaceDidChange(islandHeight: 33)
        #expect(session.arrivalStarts == 1)
        #expect(session.offsetY == 33)
        #expect(session.phase == .hidden)
        session.markEntering()
        session.spaceDidChange(islandHeight: 33)
        #expect(session.arrivalStarts == 1)
        #expect(session.phase == .entering)
        session.finishEnter(now: 1)
        #expect(session.offsetY == 0)
        #expect(session.phase == .idle)
    }

    @Test @MainActor
    func islandWindowStaysOnRestingXAfterSpaceLift() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        guard let window = controller.window else {
            Issue.record("expected island window")
            return
        }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let restX = window.frame.origin.x
        controller.test_forceSpaceLift(40)
        window.displayIfNeeded()
        #expect(abs(window.frame.origin.x - restX) < 1, "space lift must not move the window sideways")
        #expect(abs(controller.test_liftTranslationY - 40) < 1, "space lift must move the window up")
        #expect(
            abs(controller.test_liftLayerTranslationY) < 0.25,
            "layer lift draws a second island during Space swipe. ty=\(controller.test_liftLayerTranslationY)"
        )
    }

    @Test @MainActor
    func spaceEnterDropInCompletesWithinEnterDuration() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        guard let window = controller.window else {
            Issue.record("expected island window")
            return
        }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        let restX = window.frame.origin.x
        controller.test_runDropInFromAbove()
        window.displayIfNeeded()
        #expect(abs(controller.test_liftTranslationY) > 10, "drop-in must start from above")
        var minTy = controller.test_liftTranslationY
        let deadline = Date().addingTimeInterval(
            IslandSpaceTransitionMotion.enterDuration
                + IslandSpaceTransitionMotion.onActiveSpacePoll
                + 0.08
        )
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.008))
            minTy = min(minTy, controller.test_liftTranslationY)
        }
        #expect(minTy >= -0.25, "drop-in must not bounce below rest. minTy=\(minTy)")
        #expect(
            abs(controller.test_liftTranslationY) < 1,
            "drop-in should finish in \(IslandSpaceTransitionMotion.enterDuration)s. ty=\(controller.test_liftTranslationY)"
        )
        #expect(abs(window.frame.origin.x - restX) < 2, "drop-in must not slide the window sideways")
    }

    @Test @MainActor
    func spaceChangeParksAboveWithoutJoiningAllSpaces() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        guard let window = controller.window else {
            Issue.record("expected island window")
            return
        }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        controller.test_beginArrivalFromSpaceChange()
        window.displayIfNeeded()
        #expect(
            controller.test_liftTranslationY > 10,
            "space change must park above before any orderFront. ty=\(controller.test_liftTranslationY)"
        )
        #expect(
            abs(window.alphaValue) < 0.01,
            "island must stay invisible through the Space morph so the incoming plate stays blank. alpha=\(window.alphaValue)"
        )
        #expect(
            !controller.test_joinsAllSpaces,
            "canJoinAllSpaces paints a rest-position island on the incoming Space plate"
        )
        #expect(
            window.collectionBehavior.intersection(IslandSurfacePolicy.spaceSwipeSnapshotBehaviors).isEmpty
        )
    }

    @Test @MainActor
    func spaceEnterPinsToActiveSpaceWithoutKeepingJoinAll() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        guard let window = controller.window else {
            Issue.record("expected island window")
            return
        }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        controller.test_beginArrivalFromSpaceChange()
        #expect(abs(window.alphaValue) < 0.01)
        #expect(!controller.test_joinsAllSpaces)
        controller.test_runDropInFromAbove()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        #expect(
            controller.test_isOnActiveSpace,
            "drop-in must run on the Space the user landed on"
        )
        #expect(
            !controller.test_joinsAllSpaces,
            "keeping canJoinAllSpaces after pin bakes a rest island into the next swipe"
        )
        #expect(window.alphaValue > 0.9)
    }

    @Test @MainActor
    func spaceChangeDuringRecordingStillArrivesOnTheNewSpace() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        guard let window = controller.window else {
            Issue.record("expected island window")
            return
        }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        controller.viewModel.isScreenRecording = true
        controller.test_beginArrivalFromSpaceChange()
        window.displayIfNeeded()
        #expect(
            controller.test_liftTranslationY > 10,
            "recording must not skip Space arrival. ty=\(controller.test_liftTranslationY)"
        )
        #expect(
            abs(window.alphaValue) < 0.01,
            "recording arrival must stay invisible through the morph. alpha=\(window.alphaValue)"
        )
        controller.test_runDropInFromAbove()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        #expect(
            controller.test_isOnActiveSpace,
            "recording island must land on the Space the user swiped to"
        )
        #expect(window.alphaValue > 0.9)
        #expect(!controller.test_joinsAllSpaces)
    }

    @Test @MainActor
    func spaceChangeDuringDropInRestartsArrival() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        guard let window = controller.window else {
            Issue.record("expected island window")
            return
        }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        controller.test_runDropInFromAbove()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        controller.test_beginArrivalFromSpaceChange()
        window.displayIfNeeded()
        #expect(
            abs(window.alphaValue) < 0.01,
            "a new Space during drop-in must hide again, not skip the landing. alpha=\(window.alphaValue)"
        )
        #expect(
            controller.test_liftTranslationY > 10,
            "restarted arrival must stay parked above. ty=\(controller.test_liftTranslationY)"
        )
        #expect(!controller.test_joinsAllSpaces)
    }

    @Test @MainActor
    func strandedPinIsRestoredWhenCompositorIsIdle() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        guard let window = controller.window else {
            Issue.record("expected island window")
            return
        }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let restX = window.frame.origin.x
        window.setFrame(window.frame.offsetBy(dx: -1500, dy: 0), display: true, animate: false)
        #expect(abs(window.frame.origin.x - restX) > 100)
        controller.test_runSpaceSwipeTick()
        #expect(
            abs(window.frame.origin.x - restX) < 2,
            "idle compositor must snap the panel back to the notch, not leave it off-screen. x=\(window.frame.origin.x) rest=\(restX)"
        )
    }

    @Test @MainActor
    func islandCompositorBoundsParseMatchesAppKitXAtRest() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        guard let window = controller.window else {
            Issue.record("expected island window")
            return
        }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        let options: CGWindowListOption = [.optionIncludingWindow, .excludeDesktopElements]
        let info = CGWindowListCopyWindowInfo(options, CGWindowID(window.windowNumber)) as? [[String: Any]]
        let parsed = IslandSpaceTransitionMotion.composedBounds(fromWindowInfo: info ?? [])
        #expect(parsed != nil, "CGWindow bounds must parse via dictionary representation, not [String: CGFloat]")
        if let parsed {
            #expect(abs(parsed.origin.x - window.frame.origin.x) < 2)
        }
        let brittle = info?.first?[kCGWindowBounds as String] as? [String: CGFloat]
        if brittle == nil {
            #expect(parsed != nil)
        }
    }

    @Test @MainActor
    func spaceLiftTransformSticksAfterLayoutPass() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }
        guard let window = controller.window else {
            Issue.record("expected island window")
            return
        }
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        controller.test_forceSpaceLift(40)
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        #expect(
            abs(controller.test_liftTranslationY - 40) < 1,
            "window lift was reset by layout. dy=\(controller.test_liftTranslationY)"
        )
        #expect(
            abs(controller.test_liftLayerTranslationY) < 0.25,
            "layer lift must stay identity so Space swipe cannot show two islands. ty=\(controller.test_liftLayerTranslationY)"
        )
    }

    @Test func wallpaperMenuBarBandIsTrueBlack() {
        let screen = CGSize(width: 1512, height: 982)
        let image = NSImage(size: screen, flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let painted = MenuBarWallpaperTint.imageByPaintingMenuBarBlack(
            image,
            screenSize: screen,
            bandHeight: 32
        )
        #expect(painted != nil)
        guard let painted,
              let tiff = painted.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else {
            return
        }
        // Cover both bitmap origins: black must exist in the top band.
        func isBlack(_ y: Int) -> Bool {
            guard let color = rep.colorAt(x: rep.pixelsWide / 2, y: y) else { return false }
            return color.redComponent < 0.08 && color.greenComponent < 0.08 && color.blueComponent < 0.08
        }
        var sawBlack = false
        for y in 0..<min(48, rep.pixelsHigh) where isBlack(y) { sawBlack = true }
        for y in max(rep.pixelsHigh - 48, 0)..<rep.pixelsHigh where isBlack(y) { sawBlack = true }
        #expect(sawBlack)
        let bodySample = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
        #expect((bodySample?.redComponent ?? 0) > 0.8)
    }

    @Test func wallpaperIndexRewritesEverySpaceAndSkipsIdleProvider() throws {
        let original = URL(fileURLWithPath: "/tmp/orig-wallpaper.jpg")
        let processed = URL(fileURLWithPath: "/tmp/proc-wallpaper.jpg")
        let config = MenuBarWallpaperTint.configurationData(forImageFileURL: original)
        #expect(MenuBarWallpaperTint.imageFileURL(fromConfiguration: config) == original)

        let root: [String: Any] = [
            "Spaces": [
                "SPACE-A": [
                    "Displays": [
                        "DISP-1": [
                            "Desktop": [
                                "Content": [
                                    "Choices": [[
                                        "Provider": "com.apple.wallpaper.choice.image",
                                        "Configuration": config,
                                        "Files": [] as [Any]
                                    ]]
                                ]
                            ]
                        ]
                    ]
                ],
                "SPACE-B": [
                    "Default": [
                        "Desktop": [
                            "Content": [
                                "Choices": [[
                                    "Provider": "com.apple.wallpaper.choice.image",
                                    "Configuration": config,
                                    "Files": [] as [Any]
                                ]]
                            ]
                        ]
                    ]
                ]
            ],
            "Displays": [
                "DISP-1": [
                    "Desktop": [
                        "Content": [
                            "Choices": [[
                                "Provider": "com.apple.wallpaper.choice.image",
                                "Configuration": config,
                                "Files": [] as [Any]
                            ]]
                        ]
                    ],
                    "Idle": [
                        "Content": [
                            "Choices": [[
                                "Provider": "com.macwall.ogapps.extension",
                                "Configuration": config
                            ]]
                        ]
                    ]
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let (out, count) = try MenuBarWallpaperTint.rewriteIndexPlist(data) { url, _ in
            url.path.contains("orig-wallpaper") ? processed : nil
        }
        #expect(count == 3)

        let decoded = try PropertyListSerialization.propertyList(from: out, format: nil) as? [String: Any]
        func configData(_ path: [Any]) -> Data? {
            var node: Any? = decoded
            for key in path {
                if let key = key as? String, let dict = node as? [String: Any] {
                    node = dict[key]
                } else if let index = key as? Int, let array = node as? [Any] {
                    node = array[index]
                } else {
                    return nil
                }
            }
            return node as? Data
        }
        let spaceA = configData(["Spaces", "SPACE-A", "Displays", "DISP-1", "Desktop", "Content", "Choices", 0, "Configuration"])
        let spaceB = configData(["Spaces", "SPACE-B", "Default", "Desktop", "Content", "Choices", 0, "Configuration"])
        let display = configData(["Displays", "DISP-1", "Desktop", "Content", "Choices", 0, "Configuration"])
        let idle = configData(["Displays", "DISP-1", "Idle", "Content", "Choices", 0, "Configuration"])
        #expect(spaceA.flatMap(MenuBarWallpaperTint.imageFileURL(fromConfiguration:)) == processed)
        #expect(spaceB.flatMap(MenuBarWallpaperTint.imageFileURL(fromConfiguration:)) == processed)
        #expect(display.flatMap(MenuBarWallpaperTint.imageFileURL(fromConfiguration:)) == processed)
        #expect(idle.flatMap(MenuBarWallpaperTint.imageFileURL(fromConfiguration:)) == original)
        #expect(!MenuBarWallpaperTint.isTintedWallpaperURL(original))
        #expect(
            MenuBarWallpaperTint.isTintedWallpaperURL(
                URL(fileURLWithPath: "/Users/user/Library/Application Support/Dynamic Island/menu-bar-black/abc-processed.jpg")
            )
        )
    }

    @Test func restoreScriptIgnoresChromeNativeHost() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("di-restore-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("restore-menu-bar-wallpaper.sh")
        let script = """
        #!/bin/bash
        if ps aux | grep -F "Dynamic Island.app/Contents/MacOS/Dynamic Island" | grep -v -- "--chrome-native-host" | grep -v grep >/dev/null; then
          exit 0
        fi
        exit 1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        #expect(script.contains("--chrome-native-host"))
    }

    @Test func chatBannerIsNotSuppressedWhenChromeIsInTheBackground() {
        #expect(
            !IslandSurfacePolicy.shouldSuppressChatBanner(chromeFrontmost: false, thisTabVisible: true)
        )
        #expect(
            IslandSurfacePolicy.shouldSuppressChatBanner(chromeFrontmost: true, thisTabVisible: true)
        )
        #expect(
            !IslandSurfacePolicy.shouldSuppressChatBanner(chromeFrontmost: true, thisTabVisible: false)
        )
    }

    @Test func helperConnectionDoesNotPauseChromePolling() {
        #expect(IslandSurfacePolicy.shouldPollChromeTabs(automationDenied: false, helperConnected: true))
        #expect(IslandSurfacePolicy.shouldPollChromeTabs(automationDenied: false, helperConnected: false))
        #expect(!IslandSurfacePolicy.shouldPollChromeTabs(automationDenied: true, helperConnected: true))
    }

    @Test func claudeIdleStreamingAttributeIsNotGenerating() {
        #expect(!IslandSurfacePolicy.isClaudeActivelyStreaming(attributeValues: ["false", "false"]))
        #expect(!IslandSurfacePolicy.isClaudeActivelyStreaming(attributeValues: []))
        #expect(IslandSurfacePolicy.isClaudeActivelyStreaming(attributeValues: ["false", "true"]))
    }

    @Test func recordingSharesTheIslandWithMediaAndChatBanners() {
        let tab = ClaudeTabInfo(tabID: 7, windowIndex: 1, tabIndex: 1, provider: .claude)
        let chat = TransientOverlay.chatReady(preview: "Reply ready", tab: tab)

        #expect(
            IslandSurfacePolicy.dualActivity(
                isScreenRecording: true,
                hasMedia: true,
                overlay: nil
            ) == .mediaAndRecording
        )
        #expect(
            IslandSurfacePolicy.dualActivity(
                isScreenRecording: true,
                hasMedia: false,
                overlay: chat
            ) == .recordingAndChat
        )
        #expect(
            IslandSurfacePolicy.dualActivity(
                isScreenRecording: true,
                hasMedia: true,
                overlay: chat
            ) == .recordingAndChat
        )
        #expect(
            IslandSurfacePolicy.dualActivity(
                isScreenRecording: false,
                hasMedia: true,
                overlay: chat
            ) == .mediaAndChat
        )
        #expect(
            IslandSurfacePolicy.dualActivity(
                isScreenRecording: true,
                hasMedia: false,
                overlay: nil
            ) == .none
        )
        #expect(
            IslandSurfacePolicy.dualActivity(
                isScreenRecording: true,
                hasMedia: true,
                overlay: .volume(percent: 40, muted: false)
            ) == .none
        )

        let dual = CGSize(width: 560, height: 144)
        let mediaRecordingStop = IslandSurfacePolicy.recordingStopRect(
            islandSize: dual,
            notchHeight: 32,
            isScreenRecording: true,
            isExpanded: true,
            dual: .mediaAndRecording
        )
        #expect(mediaRecordingStop.minX > dual.width * 0.5)
        let contentTop = IslandMetrics.expandedContentTopInset(notchHeight: 32)
        let contentBottom = dual.height - IslandMetrics.chatOverlayBottomPadding
        #expect(abs(mediaRecordingStop.midY - (contentTop + contentBottom) / 2) < 1)
        let recordingChatStop = IslandSurfacePolicy.recordingStopRect(
            islandSize: dual,
            notchHeight: 32,
            isScreenRecording: true,
            isExpanded: true,
            dual: .recordingAndChat
        )
        #expect(recordingChatStop.maxX < dual.width * 0.5)
        let actionRowTop = dual.height
            - IslandMetrics.chatOverlayBottomPadding
            - IslandMetrics.dualActionRowHeight
        #expect(recordingChatStop.minY >= actionRowTop - 1)
        #expect(
            IslandSurfacePolicy.recordingStopRect(
                islandSize: dual,
                notchHeight: 32,
                isScreenRecording: true,
                isExpanded: true,
                dual: .mediaAndChat
            ) == .zero
        )
    }

    @Test func claudePushStillNotifiesAfterUserLeavesMidReply() {
        var tracker = ClaudeTabTracker()
        let tab = ClaudeTabInfo(tabID: 90, windowIndex: 1, tabIndex: 1, provider: .claude)
        let thinking = ClaudeTabSnapshot(
            tab: tab,
            isGenerating: true,
            preview: "Thinking",
            foundDOM: true,
            textLength: 8,
            assistantCount: 0,
            latestUserPrompt: "Explain Dynamic Island",
            latestUserFingerprint: "22#Explain Dynamic Island"
        )
        tracker.noteUserIsViewing(thinking)
        let event = tracker.ingestPush(
            ClaudeTabSnapshot(
                tab: tab,
                isGenerating: false,
                preview: "Here is the finished Dynamic Island explanation",
                foundDOM: true,
                textLength: 48,
                assistantCount: 1,
                latestUserPrompt: "Explain Dynamic Island",
                latestUserFingerprint: "22#Explain Dynamic Island",
                replyFingerprint: "48#Here is the finished Dynamic Island explanation"
            )
        )
        #expect(event?.preview == "Here is the finished Dynamic Island explanation")
    }

    @Test func streamingPlatformResolvesPrimeNetflixHotstarAndYouTube() {
        #expect(
            StreamingPlatform.resolve(
                bundleID: "com.google.Chrome",
                artist: "Prime Video",
                title: "Reacher"
            ) == .primeVideo
        )
        #expect(StreamingPlatform.from(url: "https://www.primevideo.com/detail/Reacher") == .primeVideo)
        #expect(StreamingPlatform.from(url: "https://www.amazon.com/gp/video/detail/FOO") == .primeVideo)
        #expect(StreamingPlatform.from(url: "https://www.netflix.com/watch/123") == .netflix)
        #expect(StreamingPlatform.from(url: "https://www.hotstar.com/in/movies/x") == .jioHotstar)
        #expect(StreamingPlatform.from(url: "https://www.jiohotstar.com/in/watch/x") == .jioHotstar)
        #expect(StreamingPlatform.from(url: "https://www.youtube.com/watch?v=abc") == .youtube)
        #expect(StreamingPlatform.from(url: "https://music.youtube.com/watch?v=abc") == .youtubeMusic)
        #expect(StreamingPlatform.from(bundleID: "com.spotify.client") == .spotify)
        #expect(StreamingPlatform.from(url: "https://www.amazon.com/dp/B00") == nil)
    }

    @Test func streamingPlatformCleansPrimeAndNetflixDisplayTitles() {
        #expect(
            StreamingPlatform.displayTitle(
                mediaTitle: "Prime Video: Reacher - Season 4",
                platform: .primeVideo
            ) == "Reacher"
        )
        #expect(
            StreamingPlatform.displayTitle(
                mediaTitle: "Netflix",
                pageTitle: "Watch Stranger Things | Netflix",
                platform: .netflix
            ) == "Stranger Things"
        )
        #expect(
            StreamingPlatform.displayTitle(
                mediaTitle: "Netflix",
                pageTitle: "Watch India's Got Talent | Netflix",
                platform: .netflix
            ) == "India's Got Talent"
        )
        #expect(
            StreamingPlatform.displayTitle(
                mediaTitle: "Netflix",
                metadataTitle: "India's Got Talent",
                platform: .netflix
            ) == "India's Got Talent"
        )
        #expect(
            StreamingPlatform.displayTitle(
                mediaTitle: "Netflix: The Great Flood",
                platform: .netflix
            ) == "The Great Flood"
        )
        #expect(
            StreamingPlatform.displayTitle(
                mediaTitle: "Unchanged YouTube Video Title",
                pageTitle: "YouTube",
                platform: .youtube
            ) == "Unchanged YouTube Video Title"
        )
        #expect(
            StreamingPlatform.displayTitle(
                mediaTitle: "JioHotstar",
                pageTitle: "Watch The Night Manager | JioHotstar",
                platform: .jioHotstar
            ) == "The Night Manager"
        )
        #expect(
            StreamingPlatform.needsContentTitleRefresh(
                mediaTitle: "Netflix",
                pageTitle: "Netflix",
                platform: .netflix
            )
        )
        #expect(
            StreamingPlatform.needsContentTitleRefresh(
                mediaTitle: "Hulu",
                pageTitle: "Hulu",
                platform: .hulu
            )
        )
        #expect(
            !StreamingPlatform.needsContentTitleRefresh(
                mediaTitle: "Netflix",
                pageTitle: "Watch India's Got Talent | Netflix",
                platform: .netflix
            )
        )
        #expect(
            !StreamingPlatform.needsContentTitleRefresh(
                mediaTitle: "Unchanged YouTube Video Title",
                pageTitle: "YouTube",
                platform: .youtube
            )
        )
    }

    @Test func browserOTTControlsDoNotUseYouTubeSpecificRouting() {
        let chrome = "com.google.Chrome"
        #expect(
            BrowserMediaControlPolicy.usesYouTubeSpecificControls(
                bundleID: chrome,
                platform: .youtube
            )
        )
        #expect(
            !BrowserMediaControlPolicy.usesYouTubeSpecificControls(
                bundleID: chrome,
                platform: .primeVideo
            )
        )
        #expect(
            !BrowserMediaControlPolicy.usesYouTubeSpecificControls(
                bundleID: chrome,
                platform: .netflix
            )
        )
        #expect(
            !BrowserMediaControlPolicy.usesYouTubeSpecificControls(
                bundleID: chrome,
                platform: .jioHotstar
            )
        )
    }

    @Test func mediaArtworkPolicyAlwaysUsesResolvedBrowserPlatform() {
        #expect(
            MediaArtworkPolicy.shouldUsePlatformLogo(
                hasArtwork: true,
                longestPixelSide: 128,
                resemblesBrowserIcon: true,
                isBrowser: true,
                platform: .primeVideo
            )
        )
        #expect(
            MediaArtworkPolicy.shouldUsePlatformLogo(
                hasArtwork: true,
                longestPixelSide: 128,
                resemblesBrowserIcon: false,
                isBrowser: true,
                platform: .primeVideo
            )
        )
        #expect(
            MediaArtworkPolicy.shouldUsePlatformLogo(
                hasArtwork: true,
                longestPixelSide: 640,
                resemblesBrowserIcon: false,
                isBrowser: true,
                platform: .primeVideo
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldUsePlatformLogo(
                hasArtwork: true,
                longestPixelSide: 120,
                resemblesBrowserIcon: false,
                isBrowser: true,
                platform: .youtube
            )
        )
        #expect(
            MediaArtworkPolicy.shouldUsePlatformLogo(
                hasArtwork: false,
                longestPixelSide: 0,
                resemblesBrowserIcon: false,
                isBrowser: true,
                platform: .netflix
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldUsePlatformLogo(
                hasArtwork: true,
                longestPixelSide: 640,
                resemblesBrowserIcon: false,
                isBrowser: false,
                platform: .spotify
            )
        )
    }

    @Test func bundledPlatformMarksAreOfficialAssetsAndYouTubeKeepsArtwork() {
        #expect(StreamingPlatformArtwork.image(for: .primeVideo) != nil)
        #expect(StreamingPlatformArtwork.image(for: .netflix) != nil)
        #expect(StreamingPlatformArtwork.image(for: .jioHotstar) != nil)
        #expect(StreamingPlatformArtwork.image(for: .youtube) != nil)
        #expect(
            !MediaArtworkPolicy.shouldUsePlatformLogo(
                hasArtwork: true,
                longestPixelSide: 640,
                resemblesBrowserIcon: false,
                isBrowser: true,
                platform: .youtube
            )
        )
        #expect(MediaArtworkPolicy.isLikelyVideoThumbnail(pixelWidth: 640, pixelHeight: 360))
        #expect(MediaArtworkPolicy.isLikelyVideoThumbnail(pixelWidth: 320, pixelHeight: 180))
        #expect(MediaArtworkPolicy.isLikelyVideoThumbnail(pixelWidth: 480, pixelHeight: 360))
        #expect(MediaArtworkPolicy.isLikelyVideoThumbnail(pixelWidth: 150, pixelHeight: 83))
        #expect(!MediaArtworkPolicy.isLikelyVideoThumbnail(pixelWidth: 256, pixelHeight: 256))
        #expect(MediaArtworkPolicy.isLikelyAlbumArtwork(pixelWidth: 150, pixelHeight: 150))
        #expect(MediaArtworkPolicy.isLikelyAlbumArtwork(pixelWidth: 544, pixelHeight: 544))
        #expect(!MediaArtworkPolicy.isLikelyAlbumArtwork(pixelWidth: 120, pixelHeight: 120))
        #expect(!MediaArtworkPolicy.isLikelyAlbumArtwork(pixelWidth: 64, pixelHeight: 64))
        #expect(!MediaArtworkPolicy.isLikelyVideoThumbnail(pixelWidth: 128, pixelHeight: 128))
        #expect(!MediaArtworkPolicy.isLikelyVideoThumbnail(pixelWidth: 0, pixelHeight: 0))
        #expect(MediaArtworkPolicy.isYouTubePosterToken("ytimg:abc"))
        #expect(MediaArtworkPolicy.isYouTubePosterToken("remote:ytimg:abc"))
        #expect(!MediaArtworkPolicy.isYouTubePosterToken("remote:/9j/4AAQ"))
        #expect(!MediaArtworkPolicy.isYouTubePosterToken("remote:ytmimg:https://lh3.googleusercontent.com/a"))
        #expect(MediaArtworkPolicy.shouldKeepResolvedYouTubeArtwork("remote:ytimg:abc"))
        #expect(MediaArtworkPolicy.shouldKeepResolvedYouTubeArtwork("remote:ytmimg:https://lh3.googleusercontent.com/a"))
        #expect(!MediaArtworkPolicy.shouldKeepResolvedYouTubeArtwork("remote:/9j/4AAQ"))
        #expect(
            MediaArtworkPolicy.isAllowedYouTubeArtworkDownloadHost("lh3.googleusercontent.com")
        )
        #expect(MediaArtworkPolicy.isAllowedYouTubeArtworkDownloadHost("i.ytimg.com"))
        #expect(!MediaArtworkPolicy.isAllowedYouTubeArtworkDownloadHost("yt3.ggpht.com"))
        #expect(!MediaArtworkPolicy.isAllowedYouTubeArtworkDownloadHost("example.com"))
        #expect(
            MediaArtworkPolicy.isAllowedYouTubeMusicArtworkDownloadHost("yt3.googleusercontent.com")
        )
        #expect(
            MediaArtworkPolicy.isAllowedYouTubeMusicArtworkDownloadHost("lh3.googleusercontent.com")
        )
        #expect(
            MediaArtworkPolicy.preferredYouTubeMusicArtworkURL(
                playerBarURL: "https://yt3.googleusercontent.com/avatar",
                sessionURL: "https://lh3.googleusercontent.com/cover=s544"
            ) == "https://lh3.googleusercontent.com/cover=s544"
        )
        #expect(
            MediaArtworkPolicy.preferredYouTubeMusicArtworkURL(
                playerBarURL: "https://lh3.googleusercontent.com/cover=s544",
                sessionURL: "https://yt3.googleusercontent.com/avatar"
            ) == "https://lh3.googleusercontent.com/cover=s544"
        )
        #expect(
            MediaArtworkPolicy.shouldAcceptYouTubeMusicRemoteImage(pixelWidth: 544, pixelHeight: 544)
        )
        #expect(
            MediaArtworkPolicy.shouldAcceptYouTubeMusicRemoteImage(pixelWidth: 320, pixelHeight: 180)
        )
        #expect(
            !MediaArtworkPolicy.shouldAcceptYouTubeMusicRemoteImage(pixelWidth: 64, pixelHeight: 64)
        )
        #expect(
            MediaArtworkPolicy.youtubeMusicShouldTryPlayerBarArtworkBeforeWatchPoster(
                hasPlayerBarImageURL: true,
                hasVideoID: true
            )
        )
        #expect(
            !MediaArtworkPolicy.youtubeMusicShouldTryPlayerBarArtworkBeforeWatchPoster(
                hasPlayerBarImageURL: false,
                hasVideoID: true
            )
        )
        #expect(MediaClient.squareCropRect(pixelWidth: 480, pixelHeight: 360).side == 270)
        #expect(MediaClient.squareCropRect(pixelWidth: 480, pixelHeight: 360).x == 105)
        #expect(MediaClient.squareCropRect(pixelWidth: 480, pixelHeight: 360).y == 45)
        #expect(MediaClient.squareCropRect(pixelWidth: 320, pixelHeight: 180).side == 180)
        #expect(MediaClient.squareCropRect(pixelWidth: 256, pixelHeight: 256).side == 256)
        #expect(
            MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: nil,
                resemblesBrowserIcon: false,
                isLikelyVideoThumbnail: true,
                hasRemote: true,
                pixelWidth: 150,
                pixelHeight: 83
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: nil,
                resemblesBrowserIcon: false,
                isLikelyVideoThumbnail: false,
                hasRemote: true
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: nil,
                resemblesBrowserIcon: false,
                isLikelyVideoThumbnail: false,
                hasRemote: true,
                pixelWidth: 256,
                pixelHeight: 256
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: .youtube,
                resemblesBrowserIcon: false,
                isLikelyVideoThumbnail: false,
                hasRemote: true
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: .youtube,
                resemblesBrowserIcon: true,
                isLikelyVideoThumbnail: false,
                hasRemote: true
            )
        )
        #expect(
            MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: .youtubeMusic,
                resemblesBrowserIcon: false,
                isLikelyVideoThumbnail: false,
                hasRemote: true,
                pixelWidth: 150,
                pixelHeight: 150
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: .youtubeMusic,
                resemblesBrowserIcon: false,
                isLikelyVideoThumbnail: true,
                hasRemote: true,
                pixelWidth: 320,
                pixelHeight: 180
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: .youtube,
                resemblesBrowserIcon: false,
                isLikelyVideoThumbnail: false,
                hasRemote: true,
                pixelWidth: 150,
                pixelHeight: 150
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: nil,
                resemblesBrowserIcon: false,
                isLikelyVideoThumbnail: false,
                hasRemote: true,
                pixelWidth: 256,
                pixelHeight: 256,
                sourceURL: "https://www.youtube.com/watch?v=abc"
            )
        )
        #expect(
            MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: .youtube,
                resemblesBrowserIcon: false,
                isLikelyVideoThumbnail: true,
                hasRemote: true,
                pixelWidth: 320,
                pixelHeight: 180,
                sourceURL: "https://www.youtube.com/watch?v=abc"
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: nil,
                resemblesBrowserIcon: false,
                isLikelyVideoThumbnail: false,
                hasRemote: true,
                pixelWidth: 256,
                pixelHeight: 256
            )
        )
        #expect(
            MediaArtworkPolicy.shouldShowBrowserRemoteArtwork(
                platform: .youtubeMusic,
                resemblesBrowserIcon: false,
                isLikelyVideoThumbnail: false,
                hasRemote: true,
                pixelWidth: 256,
                pixelHeight: 256,
                sourceURL: "https://music.youtube.com/"
            )
        )
    }

    @Test func pendingBrowserArtworkDoesNotFallBackToChromeJPEG() {
        #expect(
            !MediaArtworkPolicy.allowsRemoteArtworkFallback(
                isBrowser: true,
                policyToken: "pending:browser"
            )
        )
        #expect(
            MediaArtworkPolicy.allowsRemoteArtworkFallback(
                isBrowser: false,
                policyToken: "pending:browser"
            )
        )
        #expect(
            MediaArtworkPolicy.shouldHoldArtworkWhilePosterLoads(
                previousToken: "platform:primeVideo",
                policyToken: "pending:browser"
            )
        )
        #expect(
            MediaArtworkPolicy.shouldHoldArtworkWhilePosterLoads(
                previousToken: "remote:/9j/4AAQ",
                policyToken: "pending:browser"
            )
        )
        #expect(
            MediaArtworkPolicy.upgradedYouTubeMusicArtworkURL(
                "https://lh3.googleusercontent.com/cover=s60"
            ).contains("=s544")
        )
        #expect(
            MediaArtworkPolicy.upgradedYouTubeMusicArtworkURL(
                "https://lh3.googleusercontent.com/cover=w60-h60-l90-rj"
            ).contains("=w544-h544")
        )
        #expect(
            MediaArtworkPolicy.shouldHoldArtworkWhilePosterLoads(
                previousToken: "remote:ytimg:5YBHLwNuM9Y",
                policyToken: "pending:youtube"
            )
        )
        #expect(
            MediaArtworkPolicy.shouldHoldArtworkWhilePosterLoads(
                previousToken: "remote:ytmimg:https://lh3.googleusercontent.com/cover",
                policyToken: "pending:youtube"
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldHoldArtworkWhilePosterLoads(
                previousToken: "remote:ytimg:trailer",
                policyToken: "pending:youtube",
                identityChanged: true
            )
        )
        #expect(
            MediaArtworkPolicy.shouldDropHeldYouTubeArtwork(
                identityChanged: true,
                sameYouTubeVideo: true,
                previousTitle: "The Greatest Comeback Ever? (Arslan Ash)",
                nextTitle: "Gucci Gang"
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldDropHeldYouTubeArtwork(
                identityChanged: true,
                sameYouTubeVideo: true,
                previousTitle: "Some Video Title",
                nextTitle: "YouTube"
            )
        )
        #expect(
            !MediaArtworkPolicy.shouldDropHeldYouTubeArtwork(
                identityChanged: false,
                sameYouTubeVideo: true,
                previousTitle: "Same Track",
                nextTitle: "Same Track"
            )
        )
        #expect(
            MediaArtworkPolicy.shouldDropHeldYouTubeArtwork(
                identityChanged: true,
                sameYouTubeVideo: false,
                previousTitle: "Old Track",
                nextTitle: "New Track"
            )
        )
        // Stale youtube.com binding after a title change must not keep Chrome's
        // 16:9 JPEG; Music cover fetch happens after the Music tab binds.
        #expect(
            MediaArtworkPolicy.shouldDropHeldYouTubeArtwork(
                identityChanged: true,
                sameYouTubeVideo: true,
                previousTitle: "Trailer Title Here",
                nextTitle: "Gucci Gang"
            )
        )
        #expect(
            !MediaArtworkPolicy.remoteArtworkAlreadyMatchesBoundTab(
                tabPlatform: .youtubeMusic,
                pixelWidth: 320,
                pixelHeight: 180
            )
        )
        #expect(
            MediaArtworkPolicy.remoteArtworkAlreadyMatchesBoundTab(
                tabPlatform: .youtubeMusic,
                pixelWidth: 150,
                pixelHeight: 150
            )
        )
        #expect(
            MediaArtworkPolicy.remoteArtworkAlreadyMatchesBoundTab(
                tabPlatform: .youtube,
                pixelWidth: 320,
                pixelHeight: 180
            )
        )
    }

    @Test func browserMediaPickerOpensTheMatchingPlatformTab() {
        let prime = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 2,
            tabID: 44,
            title: "Watch Reacher | Prime Video",
            url: "https://www.primevideo.com/detail/Reacher"
        )
        let other = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 1,
            tabID: 12,
            title: "Gmail",
            url: "https://mail.google.com"
        )
        let youtube = BrowserMediaNavigator.Tab(
            windowIndex: 2,
            tabIndex: 1,
            tabID: 90,
            title: "Some video - YouTube",
            url: "https://www.youtube.com/watch?v=other"
        )
        let picked = BrowserMediaNavigator.pick(
            from: [other, youtube, prime],
            nowPlayingTitle: "Reacher",
            nowPlayingArtist: "Prime Video",
            preferredURL: "",
            platform: .primeVideo
        )
        #expect(picked?.url.contains("primevideo.com") == true)

        let ytPicked = BrowserMediaNavigator.pick(
            from: [other, youtube, prime],
            nowPlayingTitle: "Some video",
            nowPlayingArtist: "A Channel",
            preferredURL: "",
            platform: .youtube
        )
        #expect(ytPicked?.url.contains("youtube.com") == true)
    }

    @Test func browserMediaPickerDoesNotBindPrimeTitleToYouTubeTabWithSharedWords() {
        let youtube = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 1,
            tabID: 11,
            title: "TRAITORS LEAKED FOOTAGE?!?!",
            url: "https://www.youtube.com/watch?v=traitorsClip"
        )
        let prime = BrowserMediaNavigator.Tab(
            windowIndex: 2,
            tabIndex: 4,
            tabID: 71,
            title: "Prime Video: The Traitors - Season 2",
            url: "https://www.primevideo.com/detail/0NPUDV12CFZ3EA8Z5WJZFNIDIS"
        )
        #expect(
            !YouTubeTabPicker.titlesMatchSameTrack(youtube.title, prime.title)
        )
        #expect(
            !StreamingPlatform.sourceURLCompatible(
                youtube.url,
                withTitleHint: .primeVideo
            )
        )
        let pickedPrime = BrowserMediaNavigator.pick(
            from: [youtube, prime],
            nowPlayingTitle: "Prime Video: The Traitors - Season 2",
            nowPlayingArtist: "Tanmay Bhat",
            preferredURL: youtube.url,
            platform: .primeVideo
        )
        #expect(pickedPrime?.url.contains("primevideo.com") == true)

        let pickedYouTube = BrowserMediaNavigator.pick(
            from: [youtube, prime],
            nowPlayingTitle: "TRAITORS LEAKED FOOTAGE?!?!",
            nowPlayingArtist: "Tanmay Bhat",
            preferredURL: prime.url,
            platform: .youtube
        )
        #expect(pickedYouTube?.url.contains("youtube.com/watch") == true)
    }

    @Test func streamingPlatformFamiliesDoNotCrossServices() {
        #expect(StreamingPlatform.isSameFamily(.youtube, .youtubeMusic))
        #expect(StreamingPlatform.isSameFamily(.primeVideo, .primeVideo))
        #expect(!StreamingPlatform.isSameFamily(.primeVideo, .youtube))
        #expect(!StreamingPlatform.isSameFamily(.netflix, .primeVideo))
        #expect(
            StreamingPlatform.titleHint(title: "Prime Video: The Traitors - Season 2")
                == .primeVideo
        )
        #expect(
            StreamingPlatform.titleHint(title: "TRAITORS LEAKED FOOTAGE?!?!") == nil
        )
        #expect(
            StreamingPlatform.sourceURLCompatible(
                "https://www.youtube.com/watch?v=abc",
                withTitleHint: nil
            )
        )
        #expect(
            !StreamingPlatform.sourceURLCompatible(
                "https://www.primevideo.com/detail/0NPUDV12CFZ3EA8Z5WJZFNIDIS",
                withTitleHint: nil
            )
        )
    }

    @Test func browserActivationSelectsTheMatchedWindowNotWindowListPositionOne() {
        let tab = BrowserMediaNavigator.Tab(
            windowIndex: 2,
            tabIndex: 4,
            tabID: 1530773650,
            title: "Prime Video: The Traitors - Season 2",
            url: "https://www.primevideo.com/detail/0NPUDV12CFZ3EA8Z5WJZFNIDIS"
        )
        let chrome = BrowserMediaNavigator.activationAppleScript(
            tab: tab,
            bundleID: "com.google.Chrome"
        )
        #expect(chrome.contains("set active tab index of window id winID to tabIdx"))
        #expect(chrome.contains("set index of window id winID to 1"))
        #expect(chrome.contains("set winID to (id of window w) as integer"))
        #expect(chrome.contains("set minimized of window id winID to false"))
        #expect(chrome.contains("tell application \"System Events\""))
        #expect(chrome.contains("set frontmost to true"))
        #expect(!chrome.contains("perform action \"AXRaise\" of w"))
        #expect(!chrome.contains("repeat with w in windows"))
        #expect(chrome.contains("return \"ok:\" & ((index of window id winID) as text)"))
        #expect(!chrome.contains("set active tab index of window 1 to t"))
        #expect(!chrome.contains("set active tab index of window w to t"))
        #expect(chrome.contains("if targetID is not \"0\" then"))
        #expect(!chrome.contains("candidateID is targetID) or u is targetURL"))
        #expect(
            BrowserMediaNavigator.accessibilityWindowNeedle(
                from: "O'Sullivan's SIXTH 1️⃣4️⃣7️⃣ 🔥 | World Championship 2003"
            ).contains("O'Sullivan")
        )
        let safari = BrowserMediaNavigator.activationAppleScript(
            tab: tab,
            bundleID: "com.apple.Safari"
        )
        #expect(safari.contains("tell window id winID to set current tab to tab tabIdx"))
        #expect(!safari.contains("tell window 1 to set current tab"))
    }

    @Test func browserMediaPickerPrefersYouTubeMusicHomeOverUnrelatedTabs() {
        let gmail = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 1,
            tabID: 12,
            title: "Inbox (3) - Gmail",
            url: "https://mail.google.com/mail/u/0/#inbox"
        )
        let azure = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 2,
            tabID: 13,
            title: "Work item 52800",
            url: "https://dev.azure.com/org/project/_workitems/edit/52800"
        )
        let music = BrowserMediaNavigator.Tab(
            windowIndex: 2,
            tabIndex: 1,
            tabID: 90,
            title: "YouTube Music",
            url: "https://music.youtube.com/"
        )
        #expect(
            BrowserMediaNavigator.isLikelyPlaybackURL(
                "https://music.youtube.com/",
                platform: .youtubeMusic
            )
        )
        let picked = BrowserMediaNavigator.pick(
            from: [gmail, azure, music],
            nowPlayingTitle: "Arz Kiya Hai",
            nowPlayingArtist: "Anuv Jain",
            preferredURL: "",
            platform: nil
        )
        #expect(picked?.url.contains("music.youtube.com") == true)
    }

    @Test func browserMediaPickerDropsStaleYouTubeWatchWhenMusicStarts() {
        let watch = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 1,
            tabID: 11,
            title: "(14128) HE'S TOO GOOD! | Zhao Xintong vs Michael Holt",
            url: "https://www.youtube.com/watch?v=MyHUI_r79Ws"
        )
        let music = BrowserMediaNavigator.Tab(
            windowIndex: 2,
            tabIndex: 1,
            tabID: 90,
            title: "YouTube Music",
            url: "https://music.youtube.com/"
        )
        let picked = BrowserMediaNavigator.pick(
            from: [watch, music],
            nowPlayingTitle: "Sanson Ki Mala Pe Rock/Metal Remix",
            nowPlayingArtist: "The Introvert Boy",
            preferredURL: watch.url,
            platform: .youtube
        )
        #expect(picked?.url.contains("music.youtube.com") == true)

        let stillWatching = BrowserMediaNavigator.pick(
            from: [watch, music],
            nowPlayingTitle: "HE'S TOO GOOD!",
            nowPlayingArtist: "WST",
            preferredURL: watch.url,
            platform: .youtube
        )
        #expect(stillWatching?.url.contains("watch?v=MyHUI_r79Ws") == true)
    }

    @Test func youtubeTrailerDoesNotStayBoundWhenMusicTrackStarts() {
        let trailer = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 1,
            tabID: 11,
            title: "Official Trailer | Some Movie - YouTube",
            url: "https://www.youtube.com/watch?v=TrailerID12"
        )
        let music = BrowserMediaNavigator.Tab(
            windowIndex: 2,
            tabIndex: 1,
            tabID: 90,
            title: "YouTube Music",
            url: "https://music.youtube.com/"
        )
        let song = "Sanson Ki Mala Pe Guitar Version"
        let picked = BrowserMediaNavigator.pick(
            from: [trailer, music],
            nowPlayingTitle: song,
            nowPlayingArtist: "The Introvert Boy",
            preferredURL: trailer.url,
            platform: .youtube
        )
        #expect(picked?.url.contains("music.youtube.com") == true)
        #expect(
            !YouTubeTabPicker.chromeTabCanBindToNowPlaying(
                tabTitle: trailer.title,
                tabURL: trailer.url,
                nowPlayingTitle: song
            )
        )
        #expect(
            !YouTubeTabPicker.chromeTabCanBindToNowPlaying(
                tabTitle: trailer.title,
                tabURL: trailer.url,
                nowPlayingTitle: song,
                allowStaleDocumentTitle: true
            )
        )
        #expect(
            !YouTubeTabPicker.cachedFamilyTabCanServeNowPlaying(
                tabTitle: trailer.title,
                tabURL: trailer.url,
                nowPlayingTitle: song
            )
        )
    }

    @Test func browserMediaPickerPrefersNewYouTubeWatchOverPausedMusicHome() {
        let watch = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 1,
            tabID: 11,
            title: "(14135) YouTube",
            url: "https://www.youtube.com/watch?v=sYWpPlR6Cd8"
        )
        let music = BrowserMediaNavigator.Tab(
            windowIndex: 2,
            tabIndex: 1,
            tabID: 90,
            title: "YouTube Music",
            url: "https://music.youtube.com/"
        )
        let picked = BrowserMediaNavigator.pick(
            from: [watch, music],
            nowPlayingTitle: "THAT'S WHY HE'LL BE NUMBER ONE! | Zhao X",
            nowPlayingArtist: "WST",
            preferredURL: music.url,
            platform: .youtube
        )
        #expect(picked?.url.contains("watch?v=sYWpPlR6Cd8") == true)
        #expect(
            !YouTubeTabPicker.cachedFamilyTabCanServeNowPlaying(
                tabTitle: music.title,
                tabURL: music.url,
                nowPlayingTitle: "THAT'S WHY HE'LL BE NUMBER ONE! | Zhao X"
            )
        )
        #expect(
            YouTubeTabPicker.cachedFamilyTabCanServeNowPlaying(
                tabTitle: watch.title,
                tabURL: watch.url,
                nowPlayingTitle: "THAT'S WHY HE'LL BE NUMBER ONE! | Zhao X"
            )
        )
        #expect(
            !YouTubeTabPicker.chromeTabCanBindToNowPlaying(
                tabTitle: "YouTube Music",
                tabURL: "https://music.youtube.com/",
                nowPlayingTitle: "THAT'S WHY HE'LL BE NUMBER ONE! | Zhao X"
            )
        )
    }

    @Test func youtubeSameTrackDoesNotBindMusicTitleToUnrelatedWatchTab() {
        let watch = "(14128) HE'S TOO GOOD! 🔥 | Zhao Xintong vs Michael Holt"
        let music = "Sanson Ki Mala Pe Rock/Metal Remix Legendary Ust"
        #expect(!YouTubeTabPicker.titlesMatchSameTrack(watch, music))
        #expect(
            YouTubeTabPicker.titlesMatchSameTrack(
                watch,
                "HE'S TOO GOOD! 🔥 | Zhao Xintong vs Michael Holt"
            )
        )
        #expect(
            !YouTubeTabPicker.titlesMatchSameTrack(
                "INCREDIBLE PERFORMANCE! Barry Hawkins vs Liam Davies | 2026 British Open",
                "THAT WAS A FUN FRAME 😊! Zhao Xintong vs Oliver Brown | Unibet British Open 2026"
            )
        )
        #expect(YouTubeTabPicker.isGenericYouTubeDocumentTitle("(14135) YouTube"))
        #expect(YouTubeTabPicker.isGenericYouTubeDocumentTitle("(1) YouTube Music"))
        #expect(
            YouTubeTabPicker.chromeTabCanBindToNowPlaying(
                tabTitle: "(14135) YouTube",
                tabURL: "https://www.youtube.com/watch?v=sYWpPlR6Cd8",
                nowPlayingTitle: "THAT'S WHY HE'LL BE NUMBER ONE! | Zhao X"
            )
        )
        #expect(
            YouTubeTabPicker.chromeTabCanBindToNowPlaying(
                tabTitle: "WHO HOLDS THEIR NERVE? Chris Wakelin vs Ronnie",
                tabURL: "https://www.youtube.com/watch?v=6p179tTNPxQ",
                nowPlayingTitle: "WINNING IS HARD! Wu Yize vs Liu Hongyu",
                allowStaleDocumentTitle: true
            )
        )
        #expect(
            !YouTubeTabPicker.chromeTabCanBindToNowPlaying(
                tabTitle: "WHO HOLDS THEIR NERVE? Chris Wakelin vs Ronnie",
                tabURL: "https://www.youtube.com/watch?v=6p179tTNPxQ",
                nowPlayingTitle: "WINNING IS HARD! Wu Yize vs Liu Hongyu"
            )
        )
        let watchA = "https://www.youtube.com/watch?v=3KQc0LmCaaE"
        let watchB = "https://www.youtube.com/watch?v=KNAGNQeu5J8"
        #expect(YouTubeTabPicker.videoIDsMatch(watchA, watchA))
        #expect(!YouTubeTabPicker.videoIDsMatch(watchA, watchB))
        #expect(
            YouTubeTabPicker.snapshotCanAcceptYouTubePoster(
                snapshotTitle: "YouTube",
                snapshotURL: watchA,
                snapshotBundle: "com.google.Chrome",
                requestedTitle: "WORLD #1 IN TROUBLE! Oliver Lines vs Zhao Xintong",
                requestedURL: watchA,
                requestedBundle: "com.google.Chrome"
            )
        )
        #expect(
            !YouTubeTabPicker.snapshotCanAcceptYouTubePoster(
                snapshotTitle: "YouTube",
                snapshotURL: watchB,
                snapshotBundle: "com.google.Chrome",
                requestedTitle: "WORLD #1 IN TROUBLE! Oliver Lines vs Zhao Xintong",
                requestedURL: watchA,
                requestedBundle: "com.google.Chrome"
            )
        )
    }

    @Test func browserMediaPickerUsesPlaybackURLWhenPageTitleIsGeneric() {
        let primePlayback = BrowserMediaNavigator.Tab(
            windowIndex: 2,
            tabIndex: 4,
            tabID: 71,
            title: "Prime Video",
            url: "https://www.primevideo.com/detail/0ABC/ref=atv_dp"
        )
        let youtubeHome = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 2,
            tabID: 12,
            title: "YouTube",
            url: "https://www.youtube.com/"
        )
        let picked = BrowserMediaNavigator.pick(
            from: [youtubeHome, primePlayback],
            nowPlayingTitle: "A New Episode",
            nowPlayingArtist: "Season 1",
            preferredURL: "",
            platform: nil
        )
        #expect(picked == primePlayback)
    }

    @Test func youtubeShortsIsAPlaybackURLAndMatchesWatchURLs() {
        #expect(
            BrowserMediaNavigator.isLikelyPlaybackURL(
                "https://www.youtube.com/shorts/dQw4w9WgXcQ",
                platform: .youtube
            )
        )
        #expect(
            YouTubeTabPicker.youtubeVideoID(from: "https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share")
                == "dQw4w9WgXcQ"
        )
        #expect(
            YouTubeTabPicker.urlsMatch(
                "https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share",
                "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
            )
        )
        #expect(
            !YouTubeTabPicker.urlsMatch(
                "https://www.youtube.com/shorts/dQw4w9WgXcQ",
                "https://www.youtube.com/shorts/otherShort"
            )
        )
    }

    @Test func browserMediaPickerOpensYouTubeShortsInsteadOfHome() {
        let shorts = BrowserMediaNavigator.Tab(
            windowIndex: 2,
            tabIndex: 1,
            tabID: 88,
            title: "YouTube",
            url: "https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share"
        )
        let home = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 1,
            tabID: 12,
            title: "YouTube",
            url: "https://www.youtube.com/"
        )
        let picked = BrowserMediaNavigator.pick(
            from: [home, shorts],
            nowPlayingTitle: "Never Gonna Give You Up",
            nowPlayingArtist: "YouTube",
            preferredURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            platform: .youtube
        )
        #expect(picked == shorts)

        let stale = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 3,
            tabID: 88,
            title: "Old short - YouTube",
            url: "https://www.youtube.com/shorts/oldClip"
        )
        let live = BrowserMediaNavigator.resolveLiveTab(stale, from: [home, shorts])
        #expect(live == shorts)
    }

    @Test func staleYouTubeTabIDCanNeverActivateGoogleDrive() {
        let expected = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 3,
            tabID: 88,
            title: "Current video - YouTube",
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
        let reusedByDrive = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 3,
            tabID: 88,
            title: "Access Denied - Google Drive",
            url: "https://drive.google.com/drive/folders/example"
        )
        let liveYouTube = BrowserMediaNavigator.Tab(
            windowIndex: 2,
            tabIndex: 1,
            tabID: 99,
            title: "Current video - YouTube",
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=share"
        )

        #expect(
            !BrowserMediaNavigator.activationURLIsCompatible(
                expectedURL: expected.url,
                liveURL: reusedByDrive.url
            )
        )
        #expect(
            !StreamingPlatform.sourceURLCompatible(
                reusedByDrive.url,
                withTitleHint: .youtube
            )
        )
        #expect(
            !BrowserMediaNavigator.canFastBindActiveTab(
                reusedByDrive,
                titleHint: nil
            )
        )
        #expect(
            BrowserMediaNavigator.canFastBindActiveTab(
                liveYouTube,
                titleHint: .youtube
            )
        )
        #expect(
            BrowserMediaNavigator.activationURLIsCompatible(
                expectedURL: expected.url,
                liveURL: "https://music.youtube.com/watch?v=dQw4w9WgXcQ"
            )
        )
        #expect(
            !BrowserMediaNavigator.activationURLIsCompatible(
                expectedURL: expected.url,
                liveURL: "https://www.youtube.com/watch?v=9bZkp7q19f0"
            )
        )
        #expect(
            BrowserMediaNavigator.resolveLiveTab(
                expected,
                from: [reusedByDrive, liveYouTube]
            ) == liveYouTube
        )
        #expect(
            BrowserMediaNavigator.resolveLiveTab(
                expected,
                from: [reusedByDrive]
            ) == nil
        )

        let script = BrowserMediaNavigator.activationAppleScript(
            tab: expected,
            bundleID: "com.google.Chrome"
        )
        #expect(script.contains("set liveURL to URL of tab t of window w"))
        #expect(script.contains("liveURL contains \"v=dQw4w9WgXcQ\""))
        #expect(!script.contains("perform action \"AXRaise\" of w"))

        let titleCollisionOnDrive = BrowserMediaNavigator.Tab(
            windowIndex: 1,
            tabIndex: 4,
            tabID: 100,
            title: "Current video - YouTube Campaign - Google Drive",
            url: "https://drive.google.com/file/d/example/view"
        )
        let genericYouTube = BrowserMediaNavigator.Tab(
            windowIndex: 2,
            tabIndex: 2,
            tabID: 101,
            title: "(14181) YouTube",
            url: expected.url
        )
        #expect(
            BrowserMediaNavigator.pick(
                from: [titleCollisionOnDrive, genericYouTube],
                nowPlayingTitle: "Current video - YouTube Campaign",
                nowPlayingArtist: "Creator",
                preferredURL: expected.url,
                platform: .youtube
            ) == genericYouTube
        )
    }

    @Test func islandClickRevealsMediaAndLeavesTransportForControls() {
        let expanded = CGSize(width: 335, height: 178)
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 160, y: 20),
                islandSize: expanded,
                notchHeight: 32,
                isExpanded: true,
                overlay: nil,
                hasMedia: true,
                persistentIsMusic: true
            ) == .revealNowPlaying
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 168, y: 160),
                islandSize: expanded,
                notchHeight: 32,
                isExpanded: true,
                overlay: nil,
                hasMedia: true,
                persistentIsMusic: true
            ) == .playPause
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 168, y: 118),
                islandSize: expanded,
                notchHeight: 32,
                isExpanded: true,
                overlay: nil,
                hasMedia: true,
                persistentIsMusic: true
            ) == .playPause
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 100, y: 160),
                islandSize: expanded,
                notchHeight: 32,
                isExpanded: true,
                overlay: nil,
                hasMedia: true,
                persistentIsMusic: true
            ) == .skipBack
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 230, y: 160),
                islandSize: expanded,
                notchHeight: 32,
                isExpanded: true,
                overlay: nil,
                hasMedia: true,
                persistentIsMusic: true
            ) == .skipForward
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 168, y: 110),
                islandSize: expanded,
                notchHeight: 32,
                isExpanded: true,
                overlay: nil,
                hasMedia: true,
                persistentIsMusic: true
            ) == .seek
        )
        #expect(
            abs(
                IslandClickPolicy.seekFraction(x: 58, islandWidth: 335)
                    - 0
            ) < 0.02
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 110, y: 8),
                islandSize: CGSize(width: 235, height: 33),
                notchHeight: 32,
                isExpanded: false,
                overlay: nil,
                hasMedia: true,
                persistentIsMusic: true
            ) == .revealNowPlaying
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 110, y: 8),
                islandSize: CGSize(width: 235, height: 33),
                notchHeight: 32,
                isExpanded: false,
                overlay: nil,
                hasMedia: false,
                persistentIsMusic: false
            ) == .passthrough
        )
    }

    @Test func islandClickOpensChatAndLeavesChargingAlone() {
        let tab = ClaudeTabInfo(tabID: 4, windowIndex: 1, tabIndex: 1, provider: .claude)
        let dual = CGSize(width: 560, height: 144)
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 420, y: 70),
                islandSize: dual,
                notchHeight: 32,
                isExpanded: true,
                overlay: .chatReady(preview: "Ready", tab: tab),
                hasMedia: true,
                persistentIsMusic: true
            ) == .openChat
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 80, y: 40),
                islandSize: dual,
                notchHeight: 32,
                isExpanded: true,
                overlay: .chatReady(preview: "Ready", tab: tab),
                hasMedia: true,
                persistentIsMusic: true
            ) == .revealNowPlaying
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 200, y: 20),
                islandSize: CGSize(width: 400, height: 50),
                notchHeight: 32,
                isExpanded: true,
                overlay: .volume(percent: 40, muted: false),
                hasMedia: true,
                persistentIsMusic: true
            ) == .passthrough
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 200, y: 20),
                islandSize: CGSize(width: 400, height: 50),
                notchHeight: 32,
                isExpanded: true,
                overlay: .focusMode(isOn: true),
                hasMedia: true,
                persistentIsMusic: true
            ) == .passthrough
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 200, y: 20),
                islandSize: CGSize(width: 400, height: 50),
                notchHeight: 32,
                isExpanded: true,
                overlay: .lowBattery(percent: 12),
                hasMedia: false,
                persistentIsMusic: false
            ) == .openBatterySettings
        )
    }

    @Test func islandClickSplitsRecordingWithMediaAndChat() {
        let tab = ClaudeTabInfo(tabID: 4, windowIndex: 1, tabIndex: 1, provider: .claude)
        let dual = CGSize(width: 560, height: 144)
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 420, y: 70),
                islandSize: dual,
                notchHeight: 32,
                isExpanded: true,
                overlay: .chatReady(preview: "Ready", tab: tab),
                hasMedia: false,
                persistentIsMusic: false,
                isScreenRecording: true
            ) == .openChat
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 80, y: 70),
                islandSize: dual,
                notchHeight: 32,
                isExpanded: true,
                overlay: .chatReady(preview: "Ready", tab: tab),
                hasMedia: true,
                persistentIsMusic: true,
                isScreenRecording: true
            ) == .passthrough
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 80, y: 40),
                islandSize: dual,
                notchHeight: 32,
                isExpanded: true,
                overlay: nil,
                hasMedia: true,
                persistentIsMusic: true,
                isScreenRecording: true
            ) == .revealNowPlaying
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 420, y: 70),
                islandSize: dual,
                notchHeight: 32,
                isExpanded: true,
                overlay: nil,
                hasMedia: true,
                persistentIsMusic: true,
                isScreenRecording: true
            ) == .passthrough
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 110, y: 8),
                islandSize: CGSize(width: 235, height: 33),
                notchHeight: 32,
                isExpanded: false,
                overlay: nil,
                hasMedia: true,
                persistentIsMusic: true,
                isScreenRecording: true
            ) == .expandRecording
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 26, y: 22),
                islandSize: CGSize(width: 235, height: 33),
                notchHeight: 32,
                isExpanded: false,
                overlay: nil,
                hasMedia: false,
                persistentIsMusic: false,
                isScreenRecording: true
            ) == .expandRecording
        )
    }

    @Test func idleDestinationRankerPrefersFrequentAndRecent() {
        let now = Date()
        let ranked = IslandIdleDestinationRanker.ranked(
            stats: [
                .youtube: (2, now.addingTimeInterval(-3600 * 40)),
                .claude: (3, now.addingTimeInterval(-600)),
                .chatgpt: (1, nil),
                .gemini: (0, nil),
                .youtubeMusic: (5, now.addingTimeInterval(-3600 * 100))
            ],
            limit: 4,
            now: now
        )
        #expect(ranked.first == .claude)
        #expect(ranked.contains(.youtubeMusic))
        #expect(ranked.count == 4)
    }

    @Test func idleDestinationMatchesCatalogURLs() {
        #expect(IslandIdleDestination.from(url: "https://music.youtube.com/watch?v=abc") == .youtubeMusic)
        #expect(IslandIdleDestination.from(url: "https://www.youtube.com/watch?v=abc") == .youtube)
        #expect(IslandIdleDestination.from(url: "https://claude.ai/chat/123") == .claude)
        #expect(IslandIdleDestination.from(url: "https://chatgpt.com/c/xyz") == .chatgpt)
        #expect(IslandIdleDestination.from(url: "https://gemini.google.com/app") == .gemini)
        #expect(IslandIdleDestination.from(platform: .youtubeMusic) == .youtubeMusic)
        #expect(IslandIdleDestination.from(provider: .gemini) == .gemini)
    }

    @Test func idleGlanceClicksMapToDestinationSlots() {
        let notch: CGFloat = 180
        let compactW = IslandMetrics.idleGlanceCompactWidth(notchWidth: notch)
        #expect(
            IslandClickPolicy.idleGlanceAction(
                point: CGPoint(x: 40, y: 16),
                islandWidth: compactW,
                destinationCount: 2
            ) == .passthrough
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: compactW - 20, y: 16),
                islandSize: CGSize(width: compactW, height: 33),
                notchHeight: 32,
                isExpanded: false,
                overlay: nil,
                hasMedia: false,
                persistentIsMusic: false,
                showsIdleGlance: true,
                idleDestinationCount: 2
            ) == .openIdleDestination(1)
        )
        // Expanded idle uses the same shell as Now Playing (335×178).
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 280, y: 70),
                islandSize: CGSize(
                    width: IslandMetrics.expandedWidthFixed,
                    height: IslandMetrics.expandedHeight
                ),
                notchHeight: 32,
                isExpanded: true,
                overlay: nil,
                hasMedia: false,
                persistentIsMusic: false,
                showsIdleGlance: true,
                idleDestinationCount: 4
            ) == .openIdleDestination(1)
        )
        // File tray hang must not map to destination slots.
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 280, y: IslandMetrics.expandedHeight + 20),
                islandSize: CGSize(
                    width: IslandMetrics.expandedWidthFixed,
                    height: IslandMetrics.expandedHeight + IslandMetrics.shelfSectionHeight
                ),
                notchHeight: 32,
                isExpanded: true,
                overlay: nil,
                hasMedia: false,
                persistentIsMusic: false,
                showsShelf: true,
                showsIdleGlance: true,
                idleDestinationCount: 4
            ) == .passthrough
        )
        // Music / recording still win over idle glance.
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: compactW - 20, y: 16),
                islandSize: CGSize(width: compactW, height: 33),
                notchHeight: 32,
                isExpanded: false,
                overlay: nil,
                hasMedia: true,
                persistentIsMusic: true,
                showsIdleGlance: true,
                idleDestinationCount: 2
            ) == .revealNowPlaying
        )
        #expect(
            IslandClickPolicy.action(
                pointFromTopLeft: CGPoint(x: 26, y: 16),
                islandSize: CGSize(width: compactW, height: 33),
                notchHeight: 32,
                isExpanded: false,
                overlay: nil,
                hasMedia: false,
                persistentIsMusic: false,
                isScreenRecording: true,
                showsIdleGlance: true,
                idleDestinationCount: 2
            ) == .expandRecording
        )
    }

    @Test func idleGlanceUsesStandardIslandMetrics() {
        let notch: CGFloat = 32
        let camera: CGFloat = 180
        #expect(IslandMetrics.compactWidth(notchWidth: 180) == IslandMetrics.compactWidthFixed)
        #expect(IslandMetrics.compactHeight(notchHeight: notch) == notch + IslandMetrics.compactHeightExtra)
        #expect(
            IslandMetrics.idleGlanceCompactWidth(notchWidth: camera)
                == camera + IslandMetrics.idleGlanceCompactLeftEar + IslandMetrics.idleGlanceCompactRightEar
        )
        #expect(IslandMetrics.expandedWidth(notchWidth: 180) == IslandMetrics.expandedWidthFixed)
        #expect(IslandMetrics.expandedHeight == 178)
        #expect(IslandMetrics.expandedRadius == 48)
        let islandW = IslandMetrics.expandedWidthFixed
        let column = IslandClickPolicy.idleGlanceExpandedColumnWidth(islandWidth: islandW)
        let gridLeading = IslandClickPolicy.idleGlanceExpandedGridLeadingX(islandWidth: islandW)
        let gridTrailing = islandW - IslandMetrics.expandedHorizontalPadding
        #expect(column == 143)
        #expect(gridLeading == 178)
        #expect(gridTrailing == 321)
        #expect(gridTrailing - gridLeading == column)
    }

    @Test func idleGlanceExpandedUsesMusicExpandedHeight() {
        // Idle hover must not invent a taller shell than Now Playing.
        #expect(IslandMetrics.expandedHeight == 178)
        #expect(IslandMetrics.shelfSectionHeight > 0)
    }

    @Test func idleGlanceCompactContentStaysOutsideCameraBand() {
        let camera: CGFloat = 180
        let width = IslandMetrics.idleGlanceCompactWidth(notchWidth: camera)
        let left = IslandMetrics.idleGlanceCompactLeftEar
        let right = IslandMetrics.idleGlanceCompactRightEar
        // Left + right ears never overlap the physical camera band.
        #expect(left + camera + right == width)
        #expect(left > 0)
        #expect(right > 0)
    }

    @Test func screenshotFreezeDetectsCaptureUIApps() {
        #expect(
            ScreenRecordingDSP.isCaptureUIApp(
                bundleID: "com.apple.screencaptureui",
                localizedName: nil
            )
        )
        #expect(
            ScreenRecordingDSP.isCaptureUIApp(
                bundleID: "com.apple.Screenshot",
                localizedName: "Screenshot"
            )
        )
        #expect(
            !ScreenRecordingDSP.isCaptureUIApp(
                bundleID: "com.google.Chrome",
                localizedName: "Chrome"
            )
        )
    }

    @Test func idleNavigatorPrefersMatchingChromeTab() {
        let tabs = [
            BrowserMediaNavigator.Tab(
                windowIndex: 1,
                tabIndex: 1,
                tabID: 11,
                title: "Home",
                url: "https://www.youtube.com/"
            ),
            BrowserMediaNavigator.Tab(
                windowIndex: 1,
                tabIndex: 2,
                tabID: 22,
                title: "Video",
                url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
            )
        ]
        let picked = IslandIdleNavigator.pickTab(for: .youtube, from: tabs)
        #expect(picked?.tabID == 22)
    }

    @Test func recordingExpandIgnoresStuckChatHoverLock() {
        #expect(
            IslandSurfacePolicy.shouldAllowRecordingExpand(
                isScreenRecording: true,
                fromClick: true,
                suppressHoverExpand: true,
                suppressUntil: Date().addingTimeInterval(2.5)
            )
        )
        #expect(
            !IslandSurfacePolicy.shouldAllowRecordingExpand(
                isScreenRecording: true,
                fromClick: false,
                suppressHoverExpand: true,
                suppressUntil: Date().addingTimeInterval(2.5)
            )
        )
        #expect(
            IslandSurfacePolicy.shouldAllowRecordingExpand(
                isScreenRecording: true,
                fromClick: false,
                suppressHoverExpand: true,
                suppressUntil: Date().addingTimeInterval(-1)
            )
        )
        #expect(
            !IslandSurfacePolicy.shouldAllowRecordingExpand(
                isScreenRecording: false,
                fromClick: true,
                suppressHoverExpand: true,
                suppressUntil: nil
            )
        )
    }

    @Test func recordingWindowKeepsYouTubeShadowBleed() {
        #expect(IslandMetrics.islandShadowBleed == 28)
        let dual = IslandMetrics.liveActivityWindowSize(islandWidth: 560, islandHeight: 144)
        #expect(dual.width == 616)
        #expect(dual.height == 172)
        let compact = IslandMetrics.liveActivityWindowSize(islandWidth: 235, islandHeight: 33)
        #expect(compact.width == 291)
        #expect(compact.height == 61)
    }

    @Test func browserMediaTabListParserKeepsNumericIndices() {
        let output = """
        1\t3\t44\tPrime Video\thttps://www.primevideo.com/detail/Reacher
        2\t1\t90\tYouTube\thttps://www.youtube.com/
        """
        let tabs = BrowserMediaNavigator.parseTabList(output)
        #expect(tabs.count == 2)
        #expect(tabs[0].windowIndex == 1)
        #expect(tabs[0].tabIndex == 3)
        #expect(tabs[0].tabID == 44)
    }

    @Test func browserMediaActiveTabParserReadsSingleChromeRow() {
        let tab = BrowserMediaNavigator.parseTabList(
            "1\t2\t88\tSome video - YouTube\thttps://www.youtube.com/watch?v=dQw4w9WgXcQ"
        ).first
        #expect(tab?.windowIndex == 1)
        #expect(tab?.tabIndex == 2)
        #expect(tab?.tabID == 88)
        #expect(YouTubeTabPicker.youtubeVideoID(from: tab?.url ?? "") == "dQw4w9WgXcQ")
    }

    @Test func shelfInsertsUpToCapAndDropsOldest() {
        let first = ShelfLogic.makeItem(url: URL(fileURLWithPath: "/tmp/shelf-a.png"))
        var items = ShelfLogic.inserting(first, into: [])
        #expect(items.count == 1)
        items = ShelfLogic.inserting(first, into: items)
        #expect(items.count == 1)

        for index in 1...ShelfLogic.maxItems {
            let extra = ShelfLogic.makeItem(url: URL(fileURLWithPath: "/tmp/shelf-\(index).png"))
            items = ShelfLogic.inserting(extra, into: items)
        }
        #expect(items.count == ShelfLogic.maxItems)
        #expect(!items.contains(where: { $0.standardizedPath == first.standardizedPath }))
    }

    @Test func shelfRemoveKeepsTheFileURLUntouched() {
        let url = URL(fileURLWithPath: "/tmp/shelf-keep.mov")
        let item = ShelfLogic.makeItem(url: url)
        let remaining = ShelfLogic.removing(id: item.id, from: [item])
        #expect(remaining.isEmpty)
        #expect(item.url.path == url.path)
        #expect(ShelfLogic.kind(for: url) == .video)
        #expect(ShelfLogic.kind(for: URL(fileURLWithPath: "/tmp/photo.png")) == .image)
    }

    @Test func shelfCancelBadgeUsesAppleDismissSymbolOnTheTopTrailingCorner() {
        let bounds = NSRect(x: 0, y: 0, width: IslandMetrics.shelfThumbSize, height: IslandMetrics.shelfThumbSize)
        let badge = ShelfCancelBadge.rect(in: bounds)
        let hit = ShelfCancelBadge.hitRect(in: bounds)
        #expect(ShelfCancelBadge.symbolName == "xmark.circle.fill")
        #expect(NSImage(systemSymbolName: ShelfCancelBadge.symbolName, accessibilityDescription: nil) != nil)
        #expect(badge.maxX <= bounds.maxX)
        #expect(badge.minY >= bounds.minY)
        #expect(badge.minX > bounds.midX)
        #expect(badge.maxY < bounds.midY)
        #expect(hit.contains(NSPoint(x: badge.midX, y: badge.midY)))
        #expect(!hit.contains(NSPoint(x: bounds.midX, y: bounds.midY)))
    }

    @Test func shelfAutoExpireSelectsOldItemsOnly() {
        let old = ShelfLogic.makeItem(
            url: URL(fileURLWithPath: "/tmp/old.png"),
            addedAt: Date(timeIntervalSinceNow: -120)
        )
        let fresh = ShelfLogic.makeItem(
            url: URL(fileURLWithPath: "/tmp/fresh.png"),
            addedAt: Date()
        )
        let expired = ShelfLogic.expiredIDs(in: [old, fresh], now: Date(), interval: 60)
        #expect(expired == [old.id])
        #expect(ShelfLogic.expiredIDs(in: [old, fresh], now: Date(), interval: nil).isEmpty)
    }

    @Test @MainActor
    func shelfPreviewWritesRealFilesFinderCanCopy() {
        let items = ShelfPreview.sampleItems()
        #expect(items.count == 3)
        for item in items {
            #expect(
                FileManager.default.fileExists(atPath: item.url.path),
                "Preview file missing: \(item.filename) at \(item.url.path)"
            )
            let writer = ShelfFileURLWriter(url: item.url)
            let board = NSPasteboard(name: .init("island.shelf.writer.\(item.id.uuidString)"))
            board.clearContents()
            #expect(board.writeObjects([writer]))
            let urls = board.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
            #expect(
                urls?.map(\.standardizedFileURL) == [item.url.standardizedFileURL],
                "Finder-style pasteboard missing \(item.filename)"
            )
            let names = writer.pasteboardPropertyList(
                forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
            ) as? [String]
            #expect(names == [item.url.path])
        }
    }

    @Test @MainActor
    func shelfKeepsTheMusicIslandWidth() {
        let model = NotchViewModel()
        model.notchWidth = 180
        model.notchHeight = 32
        model.hasPhysicalNotch = false
        model.expand()
        let musicWidth = model.islandShapeWidth
        let musicHeight = model.islandShapeHeight
        model.shelfItems = ShelfPreview.sampleItems()
        #expect(model.islandShapeWidth == musicWidth)
        #expect(model.islandShapeHeight == musicHeight + IslandMetrics.shelfSectionHeight)
        #expect(model.showsShelfRow)
    }

    @Test @MainActor
    func shelfThumbsAreHittableInsideTheRealIslandWindow() {
        let controller = NotchWindowController()
        defer { controller.window?.close() }

        controller.viewModel.notchWidth = 180
        controller.viewModel.notchHeight = 32
        controller.viewModel.hasPhysicalNotch = false
        controller.viewModel.shelfItems = ShelfPreview.sampleItems()
        controller.viewModel.expand()
        controller.window?.ignoresMouseEvents = false
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 640, height: 280), display: true)
        controller.window?.orderFrontRegardless()
        controller.window?.layoutIfNeeded()

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))

        guard let host = controller.window?.contentView else {
            Issue.record("Island window has no content view")
            return
        }

        func collect(_ view: NSView) -> [ShelfThumbView] {
            var found: [ShelfThumbView] = []
            if let shelf = view as? ShelfThumbView {
                found.append(shelf)
            }
            for child in view.subviews {
                found.append(contentsOf: collect(child))
            }
            return found
        }

        let thumbs = collect(host).filter { thumb in
            thumb.window != nil && thumb.bounds.width >= 2 && thumb.bounds.height >= 2
        }
        let uniquePaths = Set(thumbs.map { $0.item.url.standardizedFileURL.path })
        #expect(
            uniquePaths.count == 3,
            "Shelf tray never created file thumbs (visible \(thumbs.count), unique \(uniquePaths.count))"
        )

        for thumb in thumbs {
            #expect(FileManager.default.fileExists(atPath: thumb.item.url.path))
            let local = NSPoint(x: thumb.bounds.midX, y: thumb.bounds.midY)
            let inHost = host.convert(local, from: thumb)
            let hit = host.hitTest(inHost)
            #expect(
                hit === thumb,
                "Click at file thumb hit \(String(describing: type(of: hit))) instead of ShelfThumbView"
            )
        }
    }

    @Test func ftueStorePlaysOncePerDefaults() {
        let suite = "island.ftue.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create FTUE defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        #expect(NotchFTUEStore.shouldPlay(defaults: defaults))
        NotchFTUEStore.markSeen(defaults: defaults)
        #expect(!NotchFTUEStore.shouldPlay(defaults: defaults))
        defaults.removePersistentDomain(forName: suite)
    }

    @Test @MainActor
    func firstLaunchStartsFTUEGlowOnce() {
        let suite = "island.ftue.model.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create FTUE defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        let model = NotchViewModel()
        model.noteIslandAppeared(defaults: defaults)
        #expect(model.isFTUEGlowActive)
        #expect(defaults.bool(forKey: NotchFTUEMetrics.defaultsKey))
        model.noteIslandAppeared(defaults: defaults)
        #expect(model.isFTUEGlowActive)
        model.noteFTUEGlowFinished()
        #expect(!model.isFTUEGlowActive)
        model.noteIslandAppeared(defaults: defaults)
        #expect(!model.isFTUEGlowActive)
        defaults.removePersistentDomain(forName: suite)
    }
}
