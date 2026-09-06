import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum ScreenCapturePhase: Equatable {
    case idle
    case selecting
    case recording
}

/// Distinguishes a real screen recording from the screenshot / toolbar UI.
enum ScreenRecordingDSP {
    static let captureTempPrefix = "NSIRD_screencaptureui"

    static func isRecordingMovie(filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext == "mov" || ext == "mp4" || ext == "m4v"
    }

    static func isCaptureTempFolder(_ name: String) -> Bool {
        name.hasPrefix(captureTempPrefix) || name.hasPrefix("NSIRD_Screenshot")
    }

    /// `screencapture -v` / output `.mov` — not `screencaptureui` and not a still PNG.
    static func commandLineLooksLikeVideoCapture(_ commandLine: String) -> Bool {
        let lower = commandLine.lowercased()
        guard lower.contains("screencapture") else { return false }
        if lower.contains("screencaptureui") { return false }
        if lower.contains(".png") || lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".heic") {
            return false
        }
        if lower.contains(".mov") || lower.contains(".mp4") || lower.contains(".m4v") {
            return true
        }
        let tokens = lower.split { $0.isWhitespace || $0 == "\0" }.map(String.init)
        return tokens.contains("-v") || tokens.contains("--video")
    }

    static func hasRecordingMovie(inTemporaryItems directory: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return false }

        // Newer macOS releases can place the in-progress movie directly in
        // ~/Library/ScreenRecordings. Older releases use an NSIRD folder in
        // TemporaryItems. Support both layouts, including hidden movie files.
        if entries.contains(where: { isRecordingMovie(filename: $0.lastPathComponent) }) {
            return true
        }

        for folder in entries where isCaptureTempFolder(folder.lastPathComponent) {
            guard let files = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }
            if files.contains(where: { isRecordingMovie(filename: $0.lastPathComponent) }) {
                return true
            }
        }
        return false
    }

    static func windowLooksLikeRecordingControl(owner: String, title: String) -> Bool {
        guard isCaptureUIOwner(owner) else { return false }
        return textIndicatesStopRecording(title)
    }

    /// The system Stop control that sits in the menu bar while capturing.
    /// Do not match the screenshot toolbar or the click-to-record overlay.
    static func looksLikeNativeStopControl(owner: String, title: String, bounds: CGRect) -> Bool {
        if textIndicatesStopRecording(title) {
            return isCaptureUIOwner(owner)
                || SystemHUDDSP.bannerOwnerNames.contains(owner)
        }
        guard isCaptureUIOwner(owner) else { return false }
        if textIndicatesRecordingOverlay(title) { return false }
        if bounds.width >= 220 || bounds.height >= 80 { return false }
        guard bounds.width >= 18, bounds.height >= 16 else { return false }
        return bounds.minY < 72
    }

    static func isCaptureUIOwner(_ owner: String) -> Bool {
        let ownerL = owner.lowercased()
        return ownerL.contains("screencapture") || ownerL.contains("screenshot")
    }

    static func isCaptureUIApp(bundleID: String?, localizedName: String?) -> Bool {
        if let id = bundleID,
           id == "com.apple.screencaptureui" || id == "com.apple.Screenshot" {
            return true
        }
        if let name = localizedName {
            return isCaptureUIOwner(name)
        }
        return false
    }

    /// Right-side toolbar action while a record tool is selected.
    static func textIsRecordAction(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "record"
    }

    static func textIsCaptureAction(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "capture"
    }

    /// Selected toolbar tool, not merely a sibling Record button in the palette.
    static func textIsRecordTool(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("record entire")
            || t.contains("record selected")
            || t.contains("record screen")
            || t.contains("record window")
            || t.contains("record portion")
    }

    /// Click-a-display / click-a-window overlay copy.
    static func textIndicatesRecordingOverlay(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("click to record")
            || t.contains("record this display")
            || t.contains("record this screen")
            || t.contains("record this window")
            || t.contains("click a screen")
            || t.contains("click to start recording")
    }

    static func textIndicatesStopRecording(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("stop recording") || t.contains("stop capture")
    }

    static func windowLooksLikeSelectionOverlay(owner: String, title: String, bounds: CGRect) -> Bool {
        guard isCaptureUIOwner(owner) else { return false }
        if windowLooksLikeRecordingControl(owner: owner, title: title) { return false }
        if textIndicatesRecordingOverlay(title) { return true }
        // Toolbar is a short floating bar; the display picker covers most of a screen.
        if bounds.height > 0, bounds.height < 140 { return false }
        return bounds.width >= 640 && bounds.height >= 400
    }

    /// Pure phase decision — unit-tested. Keep side-effecting probes out of here.
    static func resolvePhase(
        previewForced: Bool,
        systemRecording: Bool,
        captureUIRunning: Bool,
        screenshotMode: Bool,
        recordModeOrOverlay: Bool,
        hadRecordIntent: Bool
    ) -> (phase: ScreenCapturePhase, intent: Bool) {
        if previewForced || systemRecording {
            return (.recording, false)
        }
        if !captureUIRunning {
            return (.idle, false)
        }
        // Switching back to a still-capture tool cancels record intent.
        if screenshotMode && !recordModeOrOverlay {
            return (.idle, false)
        }
        if recordModeOrOverlay {
            return (.selecting, true)
        }
        // Record was armed, then the picker/toolbar chrome disappeared while
        // capture UI is still alive → recording started (menu-bar stop control).
        // Staying in `.selecting` here blocked hover/expand and looked "dead".
        if hadRecordIntent {
            return (.recording, false)
        }
        return (.idle, false)
    }
}

/// Detects screenshot-toolbar record selection and an in-progress recording.
final class ScreenRecordingMonitor {
    static let shared = ScreenRecordingMonitor()

    var onPhaseChange: ((ScreenCapturePhase) -> Void)?

    private var timer: Timer?
    private var lastPhase: ScreenCapturePhase = .idle
    private var previewForced = false
    /// Stays true after a record tool is chosen so the click-to-select overlay
    /// still counts if the toolbar (and its AX labels) hide.
    private var recordIntentWhileCaptureUI = false
    private let pollQueue = DispatchQueue(
        label: "island.screen-recording.poll",
        qos: .userInitiated
    )

    private init() {}

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setPreview(_ active: Bool) {
        previewForced = active
        poll()
    }

    func stopSystemRecording() {
        NSLog("[ScreenRecording] stopSystemRecording entered")
        if previewForced {
            previewForced = false
            poll()
            return
        }
        if Self.postNativeStopShortcut() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.poll()
            }
            return
        }
        if Self.clickStopRecordingControl() {
            poll()
            return
        }
        // Never SIGTERM screencapture: it can discard the movie. If native
        // input posting is unavailable, leave Apple's recording running until
        // the user grants Accessibility in System Settings or uses macOS's
        // own stop control.
        guard IslandSurfacePolicy.shouldShowSystemAccessibilityPrompt else { return }
    }

    /// Apple's built-in shortcut for stopping a native screen recording:
    /// Control–Command–Escape. This follows the same path as the menu-bar
    /// recording control and lets replayd finalize the movie cleanly.
    private static func postNativeStopShortcut() -> Bool {
        guard AXIsProcessTrusted(),
              let down = CGEvent(
                keyboardEventSource: nil,
                virtualKey: 53, // Escape
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: nil,
                virtualKey: 53,
                keyDown: false
              )
        else { return false }

        let flags: CGEventFlags = [.maskControl, .maskCommand]
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(80_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func poll() {
        let forced = previewForced
        let intent = recordIntentWhileCaptureUI
        pollQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.evaluatePhase(
                previewForced: forced,
                recordIntent: intent
            )
            DispatchQueue.main.async {
                self.recordIntentWhileCaptureUI = result.intent
                self.emit(result.phase)
                if result.phase == .recording {
                    SystemHUDSuppressor.shared.hideNativeRecordingStop()
                }
            }
        }
    }

    private func emit(_ phase: ScreenCapturePhase) {
        let changed = phase != lastPhase
        lastPhase = phase
        if changed, phase == .recording {
            SystemHUDSuppressor.shared.suppressNativeRecordingStop()
        }
        if changed {
            onPhaseChange?(phase)
        }
    }

    private static func evaluatePhase(
        previewForced: Bool,
        recordIntent: Bool
    ) -> (phase: ScreenCapturePhase, intent: Bool) {
        let running = captureUIIsRunning()
        let systemRecording = isSystemRecording()
        let recordModeOrOverlay = running && (
            captureUIIndicatesRecordMode() || hasRecordingOverlayPromptWindow()
        )
        let screenshotMode = running && captureUIIndicatesScreenshotMode()
        return ScreenRecordingDSP.resolvePhase(
            previewForced: previewForced,
            systemRecording: systemRecording,
            captureUIRunning: running,
            screenshotMode: screenshotMode,
            recordModeOrOverlay: recordModeOrOverlay,
            hadRecordIntent: recordIntent
        )
    }

    private static func captureUIIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            ScreenRecordingDSP.isCaptureUIApp(
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
            )
        }
    }

    private static func isSystemRecording() -> Bool {
        if hasRecordingControlWindow() { return true }
        if hasRecordingStopControl() { return true }
        return isVideoCaptureProcessRunning()
    }

    /// Reading window titles triggers Screen Recording TCC. Never request it.
    private static func canReadWindowTitles() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static func captureUIIndicatesRecordMode() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for app in NSWorkspace.shared.runningApplications {
            guard ScreenRecordingDSP.isCaptureUIApp(
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
            ) else { continue }
            if axTreeMatches(
                AXUIElementCreateApplication(app.processIdentifier),
                depth: 0,
                recordMode: true
            ) {
                return true
            }
        }
        return false
    }

    private static func captureUIIndicatesScreenshotMode() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for app in NSWorkspace.shared.runningApplications {
            guard ScreenRecordingDSP.isCaptureUIApp(
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
            ) else { continue }
            if axTreeMatches(
                AXUIElementCreateApplication(app.processIdentifier),
                depth: 0,
                recordMode: false
            ) {
                return true
            }
        }
        return false
    }

    private static func axTreeMatches(
        _ element: AXUIElement,
        depth: Int,
        recordMode: Bool
    ) -> Bool {
        guard depth < 7 else { return false }
        let texts = axTexts(element)
        if recordMode {
            if texts.contains(where: ScreenRecordingDSP.textIndicatesRecordingOverlay) {
                return true
            }
            if axIsButton(element), texts.contains(where: ScreenRecordingDSP.textIsRecordAction) {
                return true
            }
            if axIsSelected(element), texts.contains(where: ScreenRecordingDSP.textIsRecordTool) {
                return true
            }
        } else if axIsButton(element), texts.contains(where: ScreenRecordingDSP.textIsCaptureAction) {
            return true
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return false }
        return children.contains {
            axTreeMatches($0, depth: depth + 1, recordMode: recordMode)
        }
    }

    private static func axTexts(_ element: AXUIElement) -> [String] {
        var texts: [String] = []
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] as [String] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, key as CFString, &ref) == .success,
               let text = ref as? String,
               !text.isEmpty {
                texts.append(text)
            }
        }
        return texts
    }

    private static func axIsButton(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success,
              let role = ref as? String
        else { return false }
        return role == (kAXButtonRole as String)
            || role == (kAXRadioButtonRole as String)
            || role == (kAXCheckBoxRole as String)
    }

    private static func axIsSelected(_ element: AXUIElement) -> Bool {
        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedAttribute as CFString,
            &selectedRef
        ) == .success {
            if let flag = selectedRef as? Bool { return flag }
            if let number = selectedRef as? NSNumber { return number.boolValue }
        }
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success {
            if let flag = valueRef as? Bool { return flag }
            if let number = valueRef as? NSNumber { return number.intValue == 1 }
        }
        return false
    }

    private static func hasRecordingOverlayPromptWindow() -> Bool {
        guard canReadWindowTitles() else { return false }
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return info.contains { window in
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            return ScreenRecordingDSP.isCaptureUIOwner(owner)
                && ScreenRecordingDSP.textIndicatesRecordingOverlay(title)
        }
    }

    static func temporaryItemsDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TemporaryItems")
    }

    private static func darwinTemporaryItemsDirectory() -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        guard n > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).appendingPathComponent("TemporaryItems")
    }

    private static func hasRecordingMovieOnDisk() -> Bool {
        var dirs = [temporaryItemsDirectory()]
        if let darwin = darwinTemporaryItemsDirectory() {
            dirs.append(darwin)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent("Library/ScreenRecordings", isDirectory: true))
        // Observed on macOS 26: replayd writes the active native Cmd+Shift+5
        // movie here, then removes/moves it when recording stops.
        dirs.append(
            home.appendingPathComponent(
                "Library/Group Containers/group.com.apple.screencapture/ScreenRecordings",
                isDirectory: true
            )
        )
        var seen = Set<String>()
        for dir in dirs {
            let path = dir.standardizedFileURL.path
            if seen.insert(path).inserted,
               ScreenRecordingDSP.hasRecordingMovie(inTemporaryItems: dir) {
                return true
            }
        }
        return false
    }

    private static func hasRecordingControlWindow() -> Bool {
        guard canReadWindowTitles() else { return false }
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return info.contains { window in
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            return ScreenRecordingDSP.windowLooksLikeRecordingControl(owner: owner, title: title)
        }
    }

    private static func hasRecordingStopControl() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for app in NSWorkspace.shared.runningApplications {
            guard ScreenRecordingDSP.isCaptureUIApp(
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
            ) else { continue }
            if axFindStopRecordingButton(
                AXUIElementCreateApplication(app.processIdentifier),
                depth: 0
            ) != nil {
                return true
            }
        }
        return false
    }

    @discardableResult
    private static func clickStopRecordingControl() -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            guard ScreenRecordingDSP.isCaptureUIApp(
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
            ) else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            guard let button = axFindStopRecordingButton(root, depth: 0) else { continue }
            if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                return true
            }
        }
        return false
    }

    private static func axFindStopRecordingButton(
        _ element: AXUIElement,
        depth: Int
    ) -> AXUIElement? {
        guard depth < 8 else { return nil }
        let texts = axTexts(element)
        if axIsButton(element), texts.contains(where: ScreenRecordingDSP.textIndicatesStopRecording) {
            return element
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return nil }
        for child in children {
            if let match = axFindStopRecordingButton(child, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    private static func isVideoCaptureProcessRunning() -> Bool {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return false }
        let capacity = Int(bytes) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: max(capacity, 1))
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        let count = Int(filled) / MemoryLayout<pid_t>.stride
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for i in 0..<min(count, pids.count) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let n = proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN))
            guard n > 0 else { continue }
            let name = URL(fileURLWithPath: String(cString: pathBuf)).lastPathComponent.lowercased()
            if name == "replayd" {
                // macOS 26's native recorder keeps its active movie open in
                // group.com.apple.screencapture/ScreenRecordings.
                if processHasOpenRecordingMovie(pid) {
                    return true
                }
                continue
            }
            guard name == "screencapture" else { continue }
            if let args = commandLine(for: pid),
               ScreenRecordingDSP.commandLineLooksLikeVideoCapture(args) {
                return true
            }
            // Cmd+Shift+5 launches `screencapture` with generic interactive
            // arguments. Once Record is pressed, that same process opens a
            // movie file; inspecting its descriptors distinguishes recording
            // from merely having the capture toolbar open.
            if processHasOpenRecordingMovie(pid) {
                return true
            }
        }
        return false
    }

    private static func processHasOpenRecordingMovie(_ pid: pid_t) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }

        let capacity = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: max(capacity, 1)
        )
        let filled = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(
                pid,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard filled > 0 else { return false }

        let count = min(
            Int(filled) / MemoryLayout<proc_fdinfo>.stride,
            descriptors.count
        )
        for descriptor in descriptors.prefix(count) {
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else {
                continue
            }
            var info = vnode_fdinfowithpath()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidfdinfo(
                    pid,
                    descriptor.proc_fd,
                    PROC_PIDFDVNODEPATHINFO,
                    pointer,
                    Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                )
            }
            guard result == MemoryLayout<vnode_fdinfowithpath>.size else {
                continue
            }
            let path = withUnsafePointer(to: &info.pvip.vip_path) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXPATHLEN)
                ) {
                    String(cString: $0)
                }
            }
            if ScreenRecordingDSP.isRecordingMovie(filename: path) {
                return true
            }
        }
        return false
    }

    private static func commandLine(for pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return nil }
            let raw = UnsafeRawPointer(base)
            var argc: Int32 = 0
            memcpy(&argc, raw, 4)
            var offset = MemoryLayout<Int32>.size
            while offset < size, ptr[offset] != 0 { offset += 1 }
            while offset < size, ptr[offset] == 0 { offset += 1 }
            var parts: [String] = []
            for _ in 0..<max(argc, 1) {
                guard offset < size else { break }
                let slice = String(cString: base + offset)
                parts.append(slice)
                offset += slice.utf8.count + 1
            }
            return parts.joined(separator: " ")
        }
    }
}
