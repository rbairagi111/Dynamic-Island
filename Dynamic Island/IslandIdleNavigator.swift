import AppKit
import Foundation

/// Opens an idle destination as quickly as possible.
/// Prefers launching/activating Chrome with the destination URL so an existing
/// tab for that host is typically reused by the browser — without scanning tabs
/// via AppleScript (that path is reserved for Now Playing on `AppleScriptRunLoop.media`).
enum IslandIdleNavigator {
    static func open(
        _ destination: IslandIdleDestination,
        chromeBundleID: String = ChromeTabMonitor.chromeBundleID
    ) {
        let urls = [destination.homeURL]
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleID) {
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config) { _, error in
                if let error {
                    NSLog(
                        "[IslandIdle] Chrome open failed destination=%@ error=%@",
                        destination.rawValue,
                        error.localizedDescription
                    )
                    NSWorkspace.shared.open(destination.homeURL)
                }
            }
            return
        }

        NSWorkspace.shared.open(destination.homeURL)
    }

    /// Pure helper for tests / optional callers — not used on the click hot path.
    static func pickTab(
        for destination: IslandIdleDestination,
        from tabs: [BrowserMediaNavigator.Tab]
    ) -> BrowserMediaNavigator.Tab? {
        let matches = tabs.filter { destination.matches(url: $0.url) }
        guard !matches.isEmpty else { return nil }
        if let rich = matches.first(where: { urlLooksActive($0.url, destination: destination) }) {
            return rich
        }
        return matches.first
    }

    private static func urlLooksActive(_ url: String, destination: IslandIdleDestination) -> Bool {
        let lowered = url.lowercased()
        switch destination {
        case .youtube:
            return lowered.contains("/watch") || lowered.contains("/shorts/") || lowered.contains("v=")
        case .youtubeMusic:
            return lowered.contains("watch") || lowered.contains("v=") || lowered.contains("/playlist")
        case .claude, .chatgpt, .gemini:
            return lowered.split(separator: "/").count >= 4
        }
    }
}
