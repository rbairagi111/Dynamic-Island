import AppKit
import Combine

/// Hides the notch for the locked session and restores it on unlock.
/// Does not draw anything over loginwindow — WindowServer occludes third-party
/// windows once the session is locked.
final class LockScreenWindowController {
    private let viewModel: NotchViewModel
    private weak var notch: NotchWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var isHiddenForLock = false

    init(viewModel: NotchViewModel, notch: NotchWindowController) {
        self.viewModel = viewModel
        self.notch = notch
        Self.terminateLegacyHelperIfRunning()
        observeSession()
    }

    /// Older builds spawned a helper that cannot draw on the lock screen.
    private static func terminateLegacyHelperIfRunning() {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.rohitbairagi.Dynamic-Island.LockScreenHelper"
        )
        for app in running {
            app.forceTerminate()
        }
    }

    private func observeSession() {
        LockScreenMonitor.shared.$isLocked
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in
                if locked {
                    NSLog("[LockScreen] Lock notification received (screenIsLocked)")
                    self?.hideNotchImmediately()
                } else {
                    NSLog("[LockScreen] Unlock notification received (screenIsUnlocked)")
                    self?.restoreNotch()
                }
            }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                NSLog("[LockScreen] Lock notification received (sessionDidResignActive)")
                self?.hideNotchImmediately()
            }
            .store(in: &cancellables)

        workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                NSLog("[LockScreen] Unlock notification received (sessionDidBecomeActive)")
                self?.restoreNotch()
            }
            .store(in: &cancellables)
    }

    private func hideNotchImmediately() {
        if isHiddenForLock {
            NSLog(
                "[LockScreen] orderOut skipped (already hidden), window.isVisible=%@",
                notch?.isNotchWindowVisible == true ? "true" : "false"
            )
            return
        }
        isHiddenForLock = true
        viewModel.setHoldLastMedia(true)
        notch?.setHiddenForLockScreen(true)
    }

    private func restoreNotch() {
        if LockScreenMonitor.shared.isLocked {
            NSLog(
                "[LockScreen] orderFront skipped (still locked), window.isVisible=%@",
                notch?.isNotchWindowVisible == true ? "true" : "false"
            )
            return
        }
        isHiddenForLock = false
        viewModel.setHoldLastMedia(false)
        notch?.setHiddenForLockScreen(false)
    }
}
