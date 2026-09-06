import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Hides the native macOS volume / brightness / Focus bezel while the island
/// is announcing the same event. Low Battery also hides the Mac's own
/// battery alert. While a capture is in progress, the system Stop Recording
/// control is hidden because the island already provides it. Chat and
/// unrelated Notification Center banners stay.
final class SystemHUDSuppressor {
    static let shared = SystemHUDSuppressor()

    private var started = false
    private var launchObserver: NSObjectProtocol?
    private var lowBatteryHideTimer: Timer?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        hideNativeHUD()
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard SystemHUDDSP.isOSDHelper(
                bundleID: app?.bundleIdentifier,
                localizedName: app?.localizedName
            ) else { return }
            self?.hideNativeHUD()
        }
    }

    func suppressNativeHUD() {
        hideNativeHUD()
        for delay in [0.04, 0.12, 0.28, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.hideNativeHUD()
            }
        }
    }

    func suppressNativeLowBatteryAlert() {
        hideNativeLowBatteryAlert()
        lowBatteryHideTimer?.invalidate()
        var ticks = 0
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            ticks += 1
            self?.hideNativeLowBatteryAlert()
            if ticks >= 24 {
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lowBatteryHideTimer = timer
    }

    /// Hide macOS's menu-bar Stop Recording control while the island shows it.
    func suppressNativeRecordingStop() {
        hideNativeRecordingStop()
        for delay in [0.04, 0.12, 0.28, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.hideNativeRecordingStop()
            }
        }
    }

    func hideNativeRecordingStop() {
        hideMatchingRecordingStopWindows()
        hideCaptureUIStopWindows()
    }

    func hideNativeHUD() {
        hideOSDHelperApps()
        hideMatchingWindows()
    }

    private func hideOSDHelperApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard SystemHUDDSP.isOSDHelper(
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
            ) else { continue }
            app.hide()
            AXUIElementSetAttributeValue(
                AXUIElementCreateApplication(app.processIdentifier),
                kAXHiddenAttribute as CFString,
                kCFBooleanTrue
            )
        }
    }

    private func hideMatchingWindows() {
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        var pids = Set<pid_t>()
        for window in info {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat]
            let bounds = CGRect(
                x: boundsDict?["X"] ?? 0,
                y: boundsDict?["Y"] ?? 0,
                width: boundsDict?["Width"] ?? 0,
                height: boundsDict?["Height"] ?? 0
            )
            guard SystemHUDDSP.looksLikeNativeLevelHUD(owner: owner, bounds: bounds) else { continue }
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t {
                pids.insert(pid)
            }
        }
        guard AXIsProcessTrusted() else { return }
        for pid in pids {
            hideBannerWindows(pid: pid)
        }
    }

    private func hideNativeLowBatteryAlert() {
        hideBatteryAlertApps()
        hideMatchingLowBatteryWindows()
    }

    private func hideBatteryAlertApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard SystemHUDDSP.isBatteryAlertHelper(
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
            ) else { continue }
            app.hide()
            AXUIElementSetAttributeValue(
                AXUIElementCreateApplication(app.processIdentifier),
                kAXHiddenAttribute as CFString,
                kCFBooleanTrue
            )
        }
    }

    private func hideMatchingLowBatteryWindows() {
        var pids = Set<pid_t>()
        if let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
            for window in info {
                let owner = window[kCGWindowOwnerName as String] as? String ?? ""
                let title = window[kCGWindowName as String] as? String ?? ""
                let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat]
                let bounds = CGRect(
                    x: boundsDict?["X"] ?? 0,
                    y: boundsDict?["Y"] ?? 0,
                    width: boundsDict?["Width"] ?? 0,
                    height: boundsDict?["Height"] ?? 0
                )
                guard SystemHUDDSP.looksLikeNativeLowBatteryAlert(
                    owner: owner,
                    title: title,
                    bounds: bounds
                ) else { continue }
                if let pid = window[kCGWindowOwnerPID as String] as? pid_t {
                    pids.insert(pid)
                }
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            if SystemHUDDSP.isBatteryAlertHelper(
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
            ) {
                pids.insert(app.processIdentifier)
                continue
            }
            let id = (app.bundleIdentifier ?? "").lowercased()
            let name = (app.localizedName ?? "").lowercased()
            if id.contains("notificationcenter") || name.contains("notification center")
                || name.contains("notification centre") {
                pids.insert(app.processIdentifier)
            }
        }
        guard AXIsProcessTrusted() else { return }
        for pid in pids {
            hideLowBatteryWindows(pid: pid)
        }
    }

    private func hideLowBatteryWindows(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return }

        for window in windows {
            let title = axString(window, kAXTitleAttribute as CFString)
                ?? axString(window, kAXDescriptionAttribute as CFString)
                ?? ""
            let bounds = axFrame(window)
            let running = NSRunningApplication(processIdentifier: pid)
            let ownerIsBattery = SystemHUDDSP.isBatteryAlertHelper(
                bundleID: running?.bundleIdentifier,
                localizedName: running?.localizedName
            )
            let matches = ownerIsBattery
                || SystemHUDDSP.looksLikeNativeLowBatteryAlert(
                    owner: running?.localizedName ?? "",
                    title: title,
                    bounds: bounds
                )
            guard matches else { continue }
            AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, kCFBooleanTrue)
            closeWindowIfPossible(window)
        }
    }

    private func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func hideBannerWindows(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return }

        for window in windows {
            let bounds = axFrame(window)
            guard SystemHUDDSP.looksLikeControlCenterBannerSize(bounds.size) else { continue }
            AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, kCFBooleanTrue)
            closeWindowIfPossible(window)
        }
    }

    private func closeWindowIfPossible(_ window: AXUIElement) {
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonRef) == .success,
              let button = buttonRef
        else { return }
        AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString)
    }

    private func hideMatchingRecordingStopWindows() {
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        var pids = Set<pid_t>()
        for window in info {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat]
            let bounds = CGRect(
                x: boundsDict?["X"] ?? 0,
                y: boundsDict?["Y"] ?? 0,
                width: boundsDict?["Width"] ?? 0,
                height: boundsDict?["Height"] ?? 0
            )
            guard ScreenRecordingDSP.looksLikeNativeStopControl(
                owner: owner,
                title: title,
                bounds: bounds
            ) else { continue }
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t {
                pids.insert(pid)
            }
        }
        guard AXIsProcessTrusted() else { return }
        for pid in pids {
            hideRecordingStopWindows(pid: pid)
        }
    }

    private func hideCaptureUIStopWindows() {
        guard AXIsProcessTrusted() else { return }
        for app in NSWorkspace.shared.runningApplications {
            guard ScreenRecordingDSP.isCaptureUIApp(
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
            ) else { continue }
            hideRecordingStopWindows(pid: app.processIdentifier)
        }
    }

    private func hideRecordingStopWindows(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return }

        for window in windows {
            let title = axString(window, kAXTitleAttribute as CFString)
                ?? axString(window, kAXDescriptionAttribute as CFString)
                ?? ""
            let bounds = axFrame(window)
            let running = NSRunningApplication(processIdentifier: pid)
            let owner = running?.localizedName ?? ""
            let matches = ScreenRecordingDSP.looksLikeNativeStopControl(
                owner: owner,
                title: title,
                bounds: bounds
            ) || axTreeContainsStopRecordingButton(window, depth: 0)
            guard matches else { continue }
            AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func axTreeContainsStopRecordingButton(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        var roleRef: CFTypeRef?
        var isButton = false
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            isButton = role == (kAXButtonRole as String)
                || role == (kAXRadioButtonRole as String)
                || role == (kAXCheckBoxRole as String)
        }
        if isButton {
            let texts = [
                axString(element, kAXTitleAttribute as CFString),
                axString(element, kAXDescriptionAttribute as CFString),
                axString(element, kAXHelpAttribute as CFString)
            ].compactMap { $0 }
            if texts.contains(where: ScreenRecordingDSP.textIndicatesStopRecording) {
                return true
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return false }
        return children.contains { axTreeContainsStopRecordingButton($0, depth: depth + 1) }
    }

    private func axFrame(_ element: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let posRef {
            AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &origin)
        }
        if let sizeRef {
            AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }
}
