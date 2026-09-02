import Darwin
import Foundation

/// Focus banners from Control Center:
/// - Enabled → ON immediately
/// - Disabled during an enable sequence is ignored
/// - OFF only after the Focus store (or a disable with no recent enable) confirms
struct FocusChangeGate: Equatable {
    /// Disabled posts that arrive with Enabled while turning a mode on.
    static let disableAfterEnableGrace: TimeInterval = 0.8
    /// File can lag a couple of seconds after Enabled; don't treat that as off.
    static let fileOffAfterEnableGrace: TimeInterval = 2.5

    private(set) var didBaseline = false
    private(set) var announced = false
    private(set) var sawFileOn = false
    private(set) var lastEnableAt: TimeInterval = -1_000

    mutating func baseline(_ isOn: Bool) {
        announced = isOn
        sawFileOn = isOn
        didBaseline = true
    }

    mutating func noteEnabled(at now: TimeInterval) -> Bool? {
        lastEnableAt = now
        guard didBaseline, announced != true else { return nil }
        announced = true
        return true
    }

    mutating func noteConfirmedOn() -> Bool? {
        sawFileOn = true
        guard didBaseline, announced != true else { return nil }
        announced = true
        return true
    }

    /// Control Center Disabled, after a short wait to let Enabled win.
    mutating func noteDisabledConfirmed(fileIsOn: Bool, at now: TimeInterval) -> Bool? {
        if fileIsOn { return noteConfirmedOn() }
        guard didBaseline, announced else { return nil }
        if now - lastEnableAt < Self.disableAfterEnableGrace { return nil }
        announced = false
        sawFileOn = false
        return false
    }

    /// Poll/file watcher. Ignored until the store has actually shown on, so a
    /// lagging empty file cannot wipe an Enabled banner.
    mutating func noteFileOff(at now: TimeInterval) -> Bool? {
        guard didBaseline, announced, sawFileOn else { return nil }
        if now - lastEnableAt < Self.fileOffAfterEnableGrace { return nil }
        announced = false
        sawFileOn = false
        return false
    }
}

enum FocusDSP {
    static let enabledNotification = Notification.Name("_NSDoNotDisturbEnabledNotification")
    static let disabledNotification = Notification.Name("_NSDoNotDisturbDisabledNotification")
    static let darwinAssertionChanged = "com.apple.donotdisturb.assertion.changed" as CFString
    static let darwinStateChanged = "com.apple.donotdisturb.state.changed" as CFString

    static func assertionsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
    }

    static func databaseDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        assertionsURL(home: home).deletingLastPathComponent()
    }

    /// Live `storeAssertionRecords` means Focus is on. Invalidation history is off.
    static func isActive(jsonObject: Any) -> Bool {
        if let dict = jsonObject as? [String: Any] {
            if let records = dict["storeAssertionRecords"] as? [Any], !records.isEmpty {
                return true
            }
            for value in dict.values where isActive(jsonObject: value) {
                return true
            }
            return false
        }
        if let array = jsonObject as? [Any] {
            return array.contains { isActive(jsonObject: $0) }
        }
        return false
    }

    static func isActive(jsonData: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: jsonData) else {
            return false
        }
        return isActive(jsonObject: object)
    }

    static func isActive(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        return isActive(jsonData: data)
    }
}

/// Focus / Do Not Disturb. Accessory apps must use `.deliverImmediately` or
/// Control Center’s Enabled/Disabled posts never arrive.
final class FocusMonitor: NSObject {
    static let shared = FocusMonitor()

    var onEvent: ((Bool) -> Void)?

    private var gate = FocusChangeGate()
    private var started = false
    private var pollTimer: Timer?
    private var offConfirmTimer: Timer?
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    private override init() {
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        observeDistributed()
        observeDarwin()
        watchDatabaseDirectory()
        gate.baseline(FocusDSP.isActive(at: FocusDSP.assertionsURL()))

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.applyFile()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func observeDistributed() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(handleEnabled),
            name: FocusDSP.enabledNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(handleDisabled),
            name: FocusDSP.disabledNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, cfName, _, _ in
            guard let observer, let cfName else { return }
            let monitor = Unmanaged<FocusMonitor>.fromOpaque(observer).takeUnretainedValue()
            let name = cfName.rawValue as String
            DispatchQueue.main.async {
                if name == FocusDSP.enabledNotification.rawValue {
                    monitor.handleEnabled()
                } else if name == FocusDSP.disabledNotification.rawValue {
                    monitor.handleDisabled()
                }
            }
        }
        for name in [FocusDSP.enabledNotification.rawValue, FocusDSP.disabledNotification.rawValue] {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDistributedCenter(),
                observer,
                callback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    private func observeDarwin() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let monitor = Unmanaged<FocusMonitor>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.applyFile()
            }
        }
        for name in [FocusDSP.darwinAssertionChanged, FocusDSP.darwinStateChanged] {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                observer,
                callback,
                name,
                nil,
                .deliverImmediately
            )
        }
    }

    @objc func handleEnabled() {
        cancelOffConfirm()
        emit(gate.noteEnabled(at: Date().timeIntervalSinceReferenceDate))
        scheduleFileReads()
    }

    @objc func handleDisabled() {
        scheduleOffConfirm()
        scheduleFileReads()
    }

    private func scheduleOffConfirm() {
        offConfirmTimer?.invalidate()
        let timer = Timer(timeInterval: 0.55, repeats: false) { [weak self] _ in
            self?.confirmOffIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        offConfirmTimer = timer
    }

    private func cancelOffConfirm() {
        offConfirmTimer?.invalidate()
        offConfirmTimer = nil
    }

    private func confirmOffIfNeeded() {
        offConfirmTimer = nil
        let isOn = FocusDSP.isActive(at: FocusDSP.assertionsURL())
        emit(gate.noteDisabledConfirmed(
            fileIsOn: isOn,
            at: Date().timeIntervalSinceReferenceDate
        ))
    }

    private func scheduleFileReads() {
        applyFile()
        for delay in [0.2, 0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applyFile()
            }
        }
    }

    private func watchDatabaseDirectory() {
        if fileDescriptor >= 0 {
            fileSource?.cancel()
            fileSource = nil
            close(fileDescriptor)
            fileDescriptor = -1
        }
        let path = FocusDSP.databaseDirectory().path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.applyFile()
        }
        fileSource = source
        source.resume()
    }

    private func applyFile() {
        let isOn = FocusDSP.isActive(at: FocusDSP.assertionsURL())
        if isOn {
            cancelOffConfirm()
            emit(gate.noteConfirmedOn())
        } else {
            emit(gate.noteFileOff(at: Date().timeIntervalSinceReferenceDate))
        }
    }

    private func emit(_ value: Bool?) {
        guard let value else { return }
        onEvent?(value)
    }
}
