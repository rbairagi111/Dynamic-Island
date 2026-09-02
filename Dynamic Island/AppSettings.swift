import Foundation
import Combine
import AppKit

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let automationDenied = "chromeAutomationDenied"
        static let needsJS = "chromeNeedsJavaScriptFromAppleEvents"
        static let pollInterval = "chromeTabPollInterval"
        static let geminiMonitoringEnabled = "geminiMonitoringEnabled"
        static let shelfEnabled = "shelfEnabled"
        static let shelfAutoExpireEnabled = "shelfAutoExpireEnabled"
        static let shelfAutoExpireMinutes = "shelfAutoExpireMinutes"
    }

    @Published var automationDenied: Bool {
        didSet { UserDefaults.standard.set(automationDenied, forKey: Keys.automationDenied) }
    }

    @Published var needsChromeJavaScriptFromAppleEvents: Bool {
        didSet { UserDefaults.standard.set(needsChromeJavaScriptFromAppleEvents, forKey: Keys.needsJS) }
    }

    /// Seconds between Chrome tab polls (2–3s).
    @Published var chromePollInterval: TimeInterval {
        didSet { UserDefaults.standard.set(chromePollInterval, forKey: Keys.pollInterval) }
    }

    /// Gemini uses latest-turn matching. Keep this on unless a later reliability issue requires a kill switch.
    @Published var geminiMonitoringEnabled: Bool {
        didSet { UserDefaults.standard.set(geminiMonitoringEnabled, forKey: Keys.geminiMonitoringEnabled) }
    }

    /// Drop files onto the notch to hold them, then drag them out later.
    @Published var shelfEnabled: Bool {
        didSet { UserDefaults.standard.set(shelfEnabled, forKey: Keys.shelfEnabled) }
    }

    @Published var shelfAutoExpireEnabled: Bool {
        didSet { UserDefaults.standard.set(shelfAutoExpireEnabled, forKey: Keys.shelfAutoExpireEnabled) }
    }

    /// Minutes before unused shelf items are removed (files are never deleted).
    @Published var shelfAutoExpireMinutes: Int {
        didSet { UserDefaults.standard.set(shelfAutoExpireMinutes, forKey: Keys.shelfAutoExpireMinutes) }
    }

    var shelfAutoExpireInterval: TimeInterval {
        TimeInterval(max(shelfAutoExpireMinutes, 1) * 60)
    }

    /// True after a successful Automation grant. Unknown until the first probe.
    @Published private(set) var automationGranted: Bool = false

    /// Latest monitor status for Settings. Never includes message preview text.
    @Published var chromePollStatus: String = "Not polled yet"

    /// Chrome extension native-messaging helper is connected.
    @Published var chromeHelperConnected: Bool = false

    /// Helper install / connection status for Settings (no message preview text).
    @Published var chromeHelperStatus: String = "Polling (enable Chrome helper for instant alerts)"

    /// True when the island is swallowing volume/brightness keys (no system bezel).
    @Published var mediaKeysCaptured: Bool = false

    func updateChromePollStatus(_ value: String) {
        guard chromePollStatus != value else { return }
        chromePollStatus = value
    }

    func updateChromeHelperStatus(_ value: String) {
        guard chromeHelperStatus != value else { return }
        chromeHelperStatus = value
    }

    private init() {
        automationDenied = UserDefaults.standard.bool(forKey: Keys.automationDenied)
        needsChromeJavaScriptFromAppleEvents = UserDefaults.standard.bool(forKey: Keys.needsJS)
        let storedInterval = UserDefaults.standard.double(forKey: Keys.pollInterval)
        chromePollInterval = storedInterval >= 2 && storedInterval <= 3 ? storedInterval : 2.5
        geminiMonitoringEnabled = true
        if UserDefaults.standard.object(forKey: Keys.shelfEnabled) == nil {
            shelfEnabled = true
        } else {
            shelfEnabled = UserDefaults.standard.bool(forKey: Keys.shelfEnabled)
        }
        shelfAutoExpireEnabled = UserDefaults.standard.bool(forKey: Keys.shelfAutoExpireEnabled)
        let storedExpire = UserDefaults.standard.integer(forKey: Keys.shelfAutoExpireMinutes)
        shelfAutoExpireMinutes = storedExpire > 0 ? storedExpire : 60
    }

    func markAutomationGranted() {
        if !automationDenied, automationGranted { return }
        automationDenied = false
        automationGranted = true
    }

    func markAutomationDenied() {
        automationDenied = true
        automationGranted = false
    }

    func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func openAutomationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}


