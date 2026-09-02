import Foundation
import AppKit

/// Copies the bundled Chrome extension and registers the native messaging host.
enum ChromeHelperInstaller {
    @discardableResult
    static func install(openExtensionsPage: Bool) -> URL? {
        let fm = FileManager.default
        let dest = ChromeNativeMessaging.extensionInstallDirectory
        do {
            try fm.createDirectory(at: ChromeNativeMessaging.supportDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            // Xcode copies ChromeHelper/*.js into Resources/ flat; reassemble a folder for Load unpacked.
            try writeExtensionFromBundleResources(to: dest)
            try writeNativeMessagingHostManifest()
            if openExtensionsPage {
                openChromeExtensions()
                // Reveal the folder so Load unpacked is one click away.
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
            AppSettings.shared.updateChromeHelperStatus("Extension copied — load unpacked folder in Chrome")
            return dest
        } catch {
            NSLog("[ChromeHelper] install failed: %@", error.localizedDescription)
            AppSettings.shared.updateChromeHelperStatus("Install failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func ensureNativeHostRegistered() {
        do {
            try writeNativeMessagingHostManifest()
            try refreshInstalledExtensionFiles()
        } catch {
            NSLog("[ChromeHelper] native host register failed: %@", error.localizedDescription)
        }
    }

    /// Keep the unpacked Load-unpacked folder in sync with the app bundle so
    /// Claude selector fixes apply after a Chrome tab refresh.
    private static func refreshInstalledExtensionFiles() throws {
        let dest = ChromeNativeMessaging.extensionInstallDirectory
        guard FileManager.default.fileExists(atPath: dest.path) else { return }
        try writeExtensionFromBundleResourcesOverwriting(to: dest)
    }

    private static func writeExtensionFromBundleResourcesOverwriting(to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let names = [
            "manifest.json",
            "background.js",
            "shared.js",
            "content-claude.js",
            "content-chatgpt.js",
            "content-gemini.js",
            "content-gemini-page.js"
        ]
        for name in names {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "ChromeHelper")
                    ?? Bundle.main.url(forResource: base, withExtension: ext) else {
                continue
            }
            let target = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: url, to: target)
        }
    }

    private static func writeExtensionFromBundleResources(to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let names = [
            "manifest.json",
            "background.js",
            "shared.js",
            "content-claude.js",
            "content-chatgpt.js",
            "content-gemini.js",
            "content-gemini-page.js"
        ]
        for name in names {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "ChromeHelper")
                    ?? Bundle.main.url(forResource: base, withExtension: ext) else {
                throw NSError(
                    domain: "ChromeHelper",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing \(name) in app bundle"]
                )
            }
            try fm.copyItem(at: url, to: dest.appendingPathComponent(name))
        }
    }

    private static func writeNativeMessagingHostManifest() throws {
        let fm = FileManager.default
        let exe = Bundle.main.executableURL?.path
            ?? Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS")
                .appendingPathComponent(
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
                        ?? "Dynamic Island"
                )
                .path

        let hostJSON: [String: Any] = [
            "name": ChromeNativeMessaging.hostName,
            "description": "Dynamic Island AI reply bridge",
            "path": exe,
            "type": "stdio",
            "allowed_origins": [
                "chrome-extension://\(ChromeNativeMessaging.extensionID)/"
            ]
        ]

        // Chrome looks here for user-level native messaging hosts.
        let chromeHosts = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        try fm.createDirectory(at: chromeHosts, withIntermediateDirectories: true)
        let manifestURL = chromeHosts.appendingPathComponent("\(ChromeNativeMessaging.hostName).json")

        // Wrapper script so Chrome launches the app in host mode without opening the island UI.
        let wrapper = ChromeNativeMessaging.supportDirectory.appendingPathComponent("chrome-native-host.sh")
        let script = """
        #!/bin/bash
        exec "\(exe)" \(ChromeNativeMessaging.hostArg)
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        var hostWithWrapper = hostJSON
        hostWithWrapper["path"] = wrapper.path

        let data = try JSONSerialization.data(withJSONObject: hostWithWrapper, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
    }

    static func openChromeExtensions() {
        let candidates = [
            "chrome://extensions",
            "https://chrome://extensions"
        ]
        // Chrome ignores chrome:// from openURL sometimes; use AppleScript activate + open.
        let script = """
        tell application "Google Chrome"
          activate
          open location "chrome://extensions"
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if error == nil { return }
        }
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
