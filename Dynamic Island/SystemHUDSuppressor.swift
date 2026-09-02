import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Hides the native macOS volume / brightness / Focus bezel while the island
/// is announcing the same event. Does not hide Notification Center or chat.
final class SystemHUDSuppressor {
    static let shared = SystemHUDSuppressor()

    private var started = false
    private var launchObserver: NSObjectProtocol?

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
