import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ScreenCaptureKit

/// Makes the menu-bar band black the same way Top Notch does: paint the
/// wallpaper, then let WindowServer draw Apple / File / status items on top.
/// That is system-wide (Finder, Xcode, Chrome, Cursor), not per-app.
///
/// `NSWorkspace.setDesktopImageURL` only updates the *current* Space.
/// Chrome and other apps live on other Spaces, so we also rewrite
/// `com.apple.wallpaper` `Index.plist` for every Space and display.
enum MenuBarWallpaperTint {
    private static let folderName = "menu-bar-black"
    private static let originalsKey = "menuBarBlackWallpaperOriginals"
    private static let processedName = "processed.jpg"
    private static let imageProvider = "com.apple.wallpaper.choice.image"
    private static let indexBackupName = "Index.plist.pre-tint"
    private static let activeMarkerName = "tint-active"
    private static let bundlePathFileName = "app-bundle-path.txt"
    private static let restoreScriptName = "restore-menu-bar-wallpaper.sh"
    private static let launchAgentLabel = "com.rohitbairagi.Dynamic-Island.wallpaper-restore"
    private static let originalsJSONName = "originals.json"

    struct Original: Codable, Equatable {
        var displayUUID: String
        var originalURL: URL
        var processedURL: URL
    }

    @MainActor private static var applyTask: Task<Void, Never>?
    @MainActor private static var applyAgain = false
    @MainActor private static var didStartObserving = false
    @MainActor private static var didInstallLifecycleHooks = false
    @MainActor private static var isRestoring = false
    private static var signalSources: [DispatchSourceSignal] = []

    static func bandHeight(for screen: NSScreen) -> CGFloat {
        max(screen.safeAreaInsets.top, 32)
    }

    static func imageByPaintingMenuBarBlack(
        _ image: NSImage,
        screenSize: CGSize,
        bandHeight: CGFloat
    ) -> NSImage? {
        let imgSize = image.size
        let imgW = imgSize.width
        let imgH = imgSize.height
        guard imgW > 1, imgH > 1, screenSize.width > 1, screenSize.height > 1 else { return nil }

        let scale = max(screenSize.width / imgW, screenSize.height / imgH)
        let scaled = CGSize(width: imgW * scale, height: imgH * scale)
        let cropY = max((scaled.height - screenSize.height) / 2, 0)
        let topInImage = cropY / scale
        let bandInImage = max(bandHeight / scale, 1)

        let output = NSImage(size: imgSize)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: imgSize))
        NSColor.black.setFill()
        CGRect(
            x: 0,
            y: imgH - topInImage - bandInImage,
            width: imgW,
            height: bandInImage
        ).fill()
        output.unlockFocus()
        return output
    }

    static func imageFileURL(fromConfiguration data: Data) -> URL? {
        guard let obj = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else { return nil }
        if let urlDict = obj["url"] as? [String: Any],
           let relative = urlDict["relative"] as? String {
            return URL(string: relative)
        }
        if let relative = obj["url"] as? String {
            return URL(string: relative)
        }
        return nil
    }

    static func configurationData(forImageFileURL url: URL) -> Data {
        let plist: [String: Any] = [
            "type": "imageFile",
            "url": ["relative": url.absoluteString]
        ]
        return (try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )) ?? Data()
    }

    static func isTintedWallpaperURL(_ url: URL) -> Bool {
        url.path.contains("/Dynamic Island/menu-bar-black/")
            && url.lastPathComponent.contains("processed")
    }

    static func rewriteIndexPlist(
        _ data: Data,
        replacing: (_ original: URL, _ displayUUID: String?) -> URL?
    ) throws -> (Data, Int) {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let root = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &format
        ) as? NSMutableDictionary else {
            throw TintError.invalidIndex
        }
        var changes = 0
        if let displays = root["Displays"] as? NSMutableDictionary {
            rewriteDisplays(displays, replacing: replacing, changes: &changes)
        }
        if let spaces = root["Spaces"] as? NSMutableDictionary {
            for case let space as NSMutableDictionary in spaces.allValues {
                if let def = space["Default"] as? NSMutableDictionary,
                   let desktop = def["Desktop"] as? NSMutableDictionary {
                    rewriteDesktop(desktop, displayUUID: nil, replacing: replacing, changes: &changes)
                }
                if let displays = space["Displays"] as? NSMutableDictionary {
                    rewriteDisplays(displays, replacing: replacing, changes: &changes)
                }
            }
        }
        if let system = root["SystemDefault"] as? NSMutableDictionary,
           let desktop = system["Desktop"] as? NSMutableDictionary {
            rewriteDesktop(desktop, displayUUID: nil, replacing: replacing, changes: &changes)
        }
        let out = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: format,
            options: 0
        )
        return (out, changes)
    }

    @MainActor
    static func installLifecycleHooks() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        guard !didInstallLifecycleHooks else { return }
        didInstallLifecycleHooks = true

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MenuBarWallpaperTint.restore()
        }

        installSignalHandlers()
    }

    @MainActor
    static func apply(to screens: [NSScreen] = NSScreen.screens) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        installLifecycleHooks()
        startObservingIfNeeded()
        if applyTask != nil {
            applyAgain = true
            return
        }
        applyTask = Task { @MainActor in
            await applyAll(screens: NSScreen.screens)
            applyTask = nil
            if applyAgain {
                applyAgain = false
                apply()
            }
        }
    }

    @MainActor
    static func restore() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        guard !isRestoring else { return }
        guard isTintActive || FileManager.default.fileExists(atPath: indexBackupURL().path) else {
            return
        }
        isRestoring = true
        defer { isRestoring = false }

        restoreWallpaperIndex()
        let stored = loadOriginals()
        for screen in NSScreen.screens {
            guard let displayUUID = screen.displayUUID,
                  let original = stored.first(where: { $0.displayUUID == displayUUID })
            else { continue }
            let current = NSWorkspace.shared.desktopImageURL(for: screen)
            let shouldRestore = current == nil
                || current == original.processedURL
                || current.map(isTintedWallpaperURL) == true
            if shouldRestore {
                let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
                try? NSWorkspace.shared.setDesktopImageURL(original.originalURL, for: screen, options: options)
            }
        }
        reloadWallpaperAgent()
        removeProcessedJPEGs()
        setTintActive(false)
        uninstallUninstallWatcher()
        // Keep original.jpg so the next launch can paint without screencapture.
    }

    @MainActor
    private static func startObservingIfNeeded() {
        guard !didStartObserving else { return }
        didStartObserving = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MenuBarWallpaperTint.apply()
        }
    }

    @MainActor
    private static func applyAll(screens: [NSScreen]) async {
        var stored = loadOriginals()
        var fallbackImage: NSImage?
        var fallbackProcessedURL: URL?
        for screen in screens {
            guard let displayUUID = screen.displayUUID else { continue }
            if let result = await apply(to: screen, displayUUID: displayUUID, stored: &stored) {
                fallbackImage = result.image
                fallbackProcessedURL = result.processedURL
            }
        }
        saveOriginals(stored)
        persistOriginalsForScript(stored)
        applyToAllSpaces(
            screens: screens,
            fallbackImage: fallbackImage,
            fallbackProcessedURL: fallbackProcessedURL
        )
        if !stored.isEmpty {
            setTintActive(true)
            installUninstallWatcherIfNeeded()
        }
    }

    @MainActor
    private static func apply(
        to screen: NSScreen,
        displayUUID: String,
        stored: inout [Original]
    ) async -> (image: NSImage, processedURL: URL)? {
        let directory = processedDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backupURL = directory.appendingPathComponent("\(displayUUID)-original.jpg")
        let processedURL = directory.appendingPathComponent("\(displayUUID)-\(processedName)")
        let currentURL = NSWorkspace.shared.desktopImageURL(for: screen)

        if stored.contains(where: { $0.displayUUID == displayUUID && $0.processedURL == currentURL }),
           let image = NSImage(contentsOf: backupURL) ?? NSImage(contentsOf: processedURL) {
            return (image, processedURL)
        }

        let sourceImage: NSImage
        if let currentURL,
           currentURL != processedURL,
           !isTintedWallpaperURL(currentURL),
           let fromFile = NSImage(contentsOf: currentURL) {
            sourceImage = fromFile
            if currentURL != backupURL,
               !FileManager.default.fileExists(atPath: backupURL.path) {
                writeJPEG(fromFile, to: backupURL)
            }
        } else if FileManager.default.fileExists(atPath: backupURL.path),
                  let backup = NSImage(contentsOf: backupURL) {
            sourceImage = backup
        } else if let captured = await captureWallpaperImage(for: screen) {
            sourceImage = captured
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                writeJPEG(captured, to: backupURL)
            }
        } else {
            NSLog("[MenuBarWallpaper] no wallpaper image for %@", displayUUID)
            return nil
        }

        let band = bandHeight(for: screen)
        guard let painted = imageByPaintingMenuBarBlack(
            sourceImage,
            screenSize: screen.frame.size,
            bandHeight: band
        ) else { return nil }
        guard writeJPEG(painted, to: processedURL) else { return nil }

        if currentURL != processedURL {
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: true
            ]
            do {
                try NSWorkspace.shared.setDesktopImageURL(processedURL, for: screen, options: options)
            } catch {
                NSLog("[MenuBarWallpaper] setDesktopImageURL failed: %@", error.localizedDescription)
            }
        }

        stored.removeAll { $0.displayUUID == displayUUID }
        stored.append(Original(displayUUID: displayUUID, originalURL: backupURL, processedURL: processedURL))
        return (sourceImage, processedURL)
    }

    @MainActor
    private static func applyToAllSpaces(
        screens: [NSScreen],
        fallbackImage: NSImage?,
        fallbackProcessedURL: URL?
    ) {
        let indexURL = wallpaperIndexURL()
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL)
        else { return }
        backupIndexPlistIfNeeded(from: indexURL)

        let directory = processedDirectory()
        var paintedCache: [String: URL] = [:]
        let screenByUUID: [String: NSScreen] = Dictionary(
            uniqueKeysWithValues: screens.compactMap { screen in
                guard let uuid = screen.displayUUID else { return nil }
                return (uuid, screen)
            }
        )
        let defaultScreen = NSScreen.main ?? screens.first

        do {
            let (newData, count) = try rewriteIndexPlist(data) { original, displayUUID in
                if isTintedWallpaperURL(original) { return nil }
                if let cached = paintedCache[original.path] { return cached }
                let screen = displayUUID.flatMap { screenByUUID[$0] } ?? defaultScreen
                guard let screen else { return fallbackProcessedURL }

                let source: NSImage?
                if FileManager.default.fileExists(atPath: original.path),
                   let loaded = NSImage(contentsOf: original),
                   loaded.size.width > 1 {
                    source = loaded
                } else {
                    source = fallbackImage
                }
                guard let source,
                      let painted = imageByPaintingMenuBarBlack(
                        source,
                        screenSize: screen.frame.size,
                        bandHeight: bandHeight(for: screen)
                      )
                else { return fallbackProcessedURL }

                let dest = directory.appendingPathComponent("\(stableHash(original.path))-processed.jpg")
                guard writeJPEG(painted, to: dest) else { return fallbackProcessedURL }
                paintedCache[original.path] = dest
                return dest
            }
            guard count > 0 else { return }
            try newData.write(to: indexURL, options: .atomic)
            reloadWallpaperAgent()
            NSLog("[MenuBarWallpaper] tinted %d wallpaper entries across all Spaces", count)
        } catch {
            NSLog("[MenuBarWallpaper] Index.plist rewrite failed: %@", error.localizedDescription)
        }
    }

    private static func rewriteDisplays(
        _ displays: NSMutableDictionary,
        replacing: (URL, String?) -> URL?,
        changes: inout Int
    ) {
        for (key, value) in displays {
            let uuid = key as? String
            guard let display = value as? NSMutableDictionary,
                  let desktop = display["Desktop"] as? NSMutableDictionary
            else { continue }
            rewriteDesktop(desktop, displayUUID: uuid, replacing: replacing, changes: &changes)
        }
    }

    private static func rewriteDesktop(
        _ desktop: NSMutableDictionary,
        displayUUID: String?,
        replacing: (URL, String?) -> URL?,
        changes: inout Int
    ) {
        guard let content = desktop["Content"] as? NSMutableDictionary,
              let choices = content["Choices"] as? NSMutableArray
        else { return }
        let before = changes
        for case let choice as NSMutableDictionary in choices {
            rewriteChoice(choice, displayUUID: displayUUID, replacing: replacing, changes: &changes)
        }
        if changes > before {
            desktop["LastSet"] = Date()
            desktop["LastUse"] = Date()
        }
    }

    private static func rewriteChoice(
        _ choice: NSMutableDictionary,
        displayUUID: String?,
        replacing: (URL, String?) -> URL?,
        changes: inout Int
    ) {
        guard let provider = choice["Provider"] as? String,
              provider == imageProvider
        else { return }

        if let configData = choice["Configuration"] as? Data,
           let original = imageFileURL(fromConfiguration: configData),
           let replacement = replacing(original, displayUUID),
           replacement.standardizedFileURL != original.standardizedFileURL {
            choice["Configuration"] = configurationData(forImageFileURL: replacement)
            changes += 1
        }

        if let files = choice["Files"] as? NSMutableArray {
            for index in 0..<files.count {
                guard let file = files[index] as? NSMutableDictionary,
                      let relative = file["relative"] as? String
                else { continue }
                let original = URL(string: relative) ?? URL(fileURLWithPath: relative)
                guard let replacement = replacing(original, displayUUID),
                      replacement.standardizedFileURL != original.standardizedFileURL
                else { continue }
                file["relative"] = replacement.absoluteString
                changes += 1
            }
        }
    }

    private static func wallpaperIndexURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private static func indexBackupURL() -> URL {
        processedDirectory().appendingPathComponent(indexBackupName)
    }

    private static func backupIndexPlistIfNeeded(from indexURL: URL) {
        let backup = indexBackupURL()
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.createDirectory(
            at: processedDirectory(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.copyItem(at: indexURL, to: backup)
    }

    private static func restoreWallpaperIndex() {
        let indexURL = wallpaperIndexURL()
        let backup = indexBackupURL()
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        do {
            if FileManager.default.fileExists(atPath: indexURL.path) {
                try FileManager.default.removeItem(at: indexURL)
            }
            try FileManager.default.copyItem(at: backup, to: indexURL)
            try FileManager.default.removeItem(at: backup)
        } catch {
            NSLog("[MenuBarWallpaper] Index.plist restore failed: %@", error.localizedDescription)
        }
    }

    private static func removeProcessedJPEGs() {
        let directory = processedDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.contains("processed") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func reloadWallpaperAgent() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["WallpaperAgent"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("[MenuBarWallpaper] killall WallpaperAgent failed: %@", error.localizedDescription)
        }
    }

    private static func stableHash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func writeJPEG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let jpeg = NSBitmapImageRep(data: tiff)?.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.95]
              )
        else { return false }
        do {
            try jpeg.write(to: url)
            return true
        } catch {
            NSLog("[MenuBarWallpaper] write failed: %@", error.localizedDescription)
            return false
        }
    }

    private static func captureWallpaperImage(for screen: NSScreen) async -> NSImage? {
        if let kit = await captureWallpaperWithScreenCaptureKit(for: screen) {
            return kit
        }
        return captureWallpaperWithScreencapture(for: screen)
    }

    private static func captureWallpaperWithScreenCaptureKit(for screen: NSScreen) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let display = content.displays.first { screenID != nil && $0.displayID == screenID }
                ?? content.displays.first
            guard let display else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: content.windows)
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.capturesAudio = false
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return NSImage(cgImage: cgImage, size: screen.frame.size)
        } catch {
            NSLog("[MenuBarWallpaper] ScreenCaptureKit failed: %@", error.localizedDescription)
            return nil
        }
    }

    private static func captureWallpaperWithScreencapture(for screen: NSScreen) -> NSImage? {
        let options = CGWindowListOption.optionOnScreenOnly
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in info {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let name = window[kCGWindowName as String] as? String ?? ""
            guard owner == "Dock", name.hasPrefix("Wallpaper") else { continue }
            guard let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue else { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let x = (bounds["X"] as? NSNumber)?.doubleValue ?? 0
            let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            if abs(x - screen.frame.minX) > 4 || abs(w - screen.frame.width) > 4 { continue }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("di-wallpaper-\(number).png")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-l", "\(number)", "-o", "-x", tmp.path]
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                continue
            }
            guard proc.terminationStatus == 0, let image = NSImage(contentsOf: tmp), image.size.width > 1 else {
                NSLog("[MenuBarWallpaper] screencapture failed for window %d status=%d", number, proc.terminationStatus)
                continue
            }
            try? FileManager.default.removeItem(at: tmp)
            return image
        }
        return nil
    }

    private static func processedDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("Dynamic Island", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static func loadOriginals() -> [Original] {
        guard let data = UserDefaults.standard.data(forKey: originalsKey) else { return [] }
        return (try? JSONDecoder().decode([Original].self, from: data)) ?? []
    }

    private static func saveOriginals(_ value: [Original]) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: originalsKey)
        }
        persistOriginalsForScript(value)
    }

    private static func persistOriginalsForScript(_ value: [Original]) {
        let url = processedDirectory().appendingPathComponent(originalsJSONName)
        if value.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(
            at: processedDirectory(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static var isTintActive: Bool {
        FileManager.default.fileExists(atPath: activeMarkerURL().path)
    }

    private static func activeMarkerURL() -> URL {
        processedDirectory().appendingPathComponent(activeMarkerName)
    }

    private static func setTintActive(_ active: Bool) {
        let directory = processedDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = activeMarkerURL()
        if active {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
            try? Bundle.main.bundlePath.write(
                to: directory.appendingPathComponent(bundlePathFileName),
                atomically: true,
                encoding: .utf8
            )
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    private static func installSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MenuBarWallpaperTint.restoreFromAnyThread()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func restoreFromAnyThread() {
        let perform = {
            MenuBarWallpaperTint.restore()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(perform)
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated(perform)
            }
        }
    }

    private static func installUninstallWatcherIfNeeded() {
        writeRestoreScriptIfNeeded()
        let agentURL = launchAgentPlistURL()
        guard !FileManager.default.fileExists(atPath: agentURL.path) else { return }
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [
                "/bin/bash",
                restoreScriptURL().path
            ],
            "RunAtLoad": true,
            "StartInterval": 300
        ]
        do {
            try FileManager.default.createDirectory(
                at: agentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: agentURL, options: .atomic)
            bootstrapLaunchAgent(at: agentURL)
        } catch {
            NSLog("[MenuBarWallpaper] LaunchAgent install failed: %@", error.localizedDescription)
        }
    }

    private static func uninstallUninstallWatcher() {
        bootoutLaunchAgent()
        try? FileManager.default.removeItem(at: launchAgentPlistURL())
    }

    private static func launchAgentPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private static func restoreScriptURL() -> URL {
        processedDirectory().appendingPathComponent(restoreScriptName)
    }

    private static func writeRestoreScriptIfNeeded() {
        let scriptURL = restoreScriptURL()
        let directory = processedDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        set -euo pipefail
        SUPPORT="$HOME/Library/Application Support/Dynamic Island/menu-bar-black"
        ACTIVE="$SUPPORT/\(activeMarkerName)"
        INDEX_BACKUP="$SUPPORT/\(indexBackupName)"
        INDEX="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
        LABEL="\(launchAgentLabel)"
        BUNDLE_FILE="$SUPPORT/\(bundlePathFileName)"

        [[ -f "$ACTIVE" ]] || exit 0

        if [[ -f "$BUNDLE_FILE" ]]; then
          BUNDLE="$(cat "$BUNDLE_FILE")"
          if [[ -f "$BUNDLE/Contents/Info.plist" ]]; then
            exit 0
          fi
        fi

        if pgrep -f "Dynamic Island.app/Contents/MacOS/Dynamic Island" >/dev/null 2>&1; then
          if ps aux | grep -F "Dynamic Island.app/Contents/MacOS/Dynamic Island" | grep -v -- "--chrome-native-host" | grep -v grep >/dev/null; then
            exit 0
          fi
        fi

        if [[ -f "$INDEX_BACKUP" ]]; then
          cp "$INDEX_BACKUP" "$INDEX"
          rm -f "$INDEX_BACKUP"
        fi

        /usr/bin/killall WallpaperAgent 2>/dev/null || true
        rm -f "$SUPPORT"/*-processed.jpg "$SUPPORT"/\(processedName) "$ACTIVE"
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
        """
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    private static func bootstrapLaunchAgent(at url: URL) {
        let uid = getuid()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootstrap", "gui/\(uid)", url.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("[MenuBarWallpaper] launchctl bootstrap failed: %@", error.localizedDescription)
        }
    }

    private static func bootoutLaunchAgent() {
        let uid = getuid()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootout", "gui/\(uid)/\(launchAgentLabel)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // Agent may not be loaded.
        }
    }

    private enum TintError: Error {
        case invalidIndex
    }
}

private extension NSScreen {
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let id = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
