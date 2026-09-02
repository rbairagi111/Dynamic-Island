import AppKit
import Combine
import CoreGraphics

/// Observes lock / unlock. Default distributed-notification delivery is held
/// while the app is inactive, which is exactly when the Mac is locked — so
/// observers must use `.deliverImmediately`, with a CGSession poll as backup.
final class LockScreenMonitor: NSObject, ObservableObject {
    static let shared = LockScreenMonitor()

    @Published private(set) var isLocked = false

    private var pollTimer: Timer?

    private override init() {
        super.init()
        observeDistributed("com.apple.screenIsLocked", locked: true)
        observeDistributed("com.apple.screenIsUnlocked", locked: false)
        observeDistributed("com.apple.screensaver.didstart", locked: true)
        observeDistributed("com.apple.screensaver.didstop", locked: false)

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.syncFromSession()
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        syncFromSession()
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
        DistributedNotificationCenter.default().removeObserver(self)
        pollTimer?.invalidate()
    }

    private func observeDistributed(_ name: String, locked: Bool) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: locked ? #selector(handleLocked) : #selector(handleUnlocked),
            name: Notification.Name(name),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        let callback: CFNotificationCallback = { _, observer, cfName, _, _ in
            guard let observer, let cfName else { return }
            let monitor = Unmanaged<LockScreenMonitor>.fromOpaque(observer)
                .takeUnretainedValue()
            let key = cfName.rawValue as String
            DispatchQueue.main.async {
                if key == "com.apple.screenIsLocked"
                    || key == "com.apple.screensaver.didstart" {
                    monitor.setLocked(true)
                } else if key == "com.apple.screenIsUnlocked"
                    || key == "com.apple.screensaver.didstop" {
                    monitor.setLocked(false)
                }
            }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            callback,
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    @objc func handleLocked() {
        DispatchQueue.main.async { self.setLocked(true) }
    }

    @objc func handleUnlocked() {
        DispatchQueue.main.async { self.setLocked(false) }
    }

    private func setLocked(_ locked: Bool) {
        guard isLocked != locked else { return }
        isLocked = locked
        NSLog("[LockScreen] isLocked=%@", locked ? "true" : "false")
    }

    private func syncFromSession() {
        guard let locked = Self.sessionLockState() else { return }
        setLocked(locked)
    }

    /// `nil` when the session dictionary has no lock key — don't guess.
    static func sessionLockState() -> Bool? {
        guard let cfDict = CGSessionCopyCurrentDictionary() else { return nil }
        let dict = cfDict as NSDictionary
        if let locked = dict.object(forKey: "CGSSessionScreenIsLocked") as? Bool {
            return locked
        }
        if let number = dict.object(forKey: "CGSSessionScreenIsLocked") as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    static func sessionIsLocked() -> Bool {
        sessionLockState() ?? false
    }
}
