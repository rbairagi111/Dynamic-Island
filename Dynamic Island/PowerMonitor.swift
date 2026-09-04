import Foundation
import IOKit.ps

/// Pure crossing logic for charger / low-battery island banners.
struct PowerAlertState: Equatable {
    enum Event: Equatable {
        case chargingStarted(percent: Int)
        case lowBattery(percent: Int)
    }

    /// macOS's own Low Battery alert is 10%. The island matches that and
    /// does not also fire at 20%.
    static let lowBatteryPercent = 10

    var didBaseline = false
    var lastPercent = 100
    var wasCharging = false
    var didWarnLowBattery = false

    mutating func ingest(percent: Int, isCharging: Bool) -> Event? {
        let clamped = min(max(percent, 0), 100)
        defer {
            lastPercent = clamped
            wasCharging = isCharging
            didBaseline = true
        }

        if isCharging {
            if didBaseline, !wasCharging {
                didWarnLowBattery = false
                return .chargingStarted(percent: clamped)
            }
            return nil
        }

        if clamped <= Self.lowBatteryPercent, !didWarnLowBattery {
            didWarnLowBattery = true
            return .lowBattery(percent: clamped)
        }
        if clamped > Self.lowBatteryPercent {
            didWarnLowBattery = false
        }
        return nil
    }
}

/// Internal-battery capacity and AC/charging via IOKit power sources.
final class PowerMonitor {
    static let shared = PowerMonitor()

    var onEvent: ((PowerAlertState.Event) -> Void)?
    /// Unplugged and at or below 10%. Used to hide the Mac alert immediately,
    /// including on later polls after the island already warned.
    var onLowBatteryProximity: (() -> Void)?

    private(set) var percent: Int = 100
    private(set) var isCharging = false
    private(set) var hasInternalBattery = false

    private var alertState = PowerAlertState()
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { pointer in
            guard let pointer else { return }
            Unmanaged<PowerMonitor>.fromOpaque(pointer).takeUnretainedValue().poll()
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func poll() {
        guard let snapshot = Self.readBattery() else {
            hasInternalBattery = false
            return
        }
        hasInternalBattery = true
        percent = snapshot.percent
        isCharging = snapshot.isCharging
        if let event = alertState.ingest(percent: snapshot.percent, isCharging: snapshot.isCharging) {
            onEvent?(event)
        }
        if !snapshot.isCharging, snapshot.percent <= PowerAlertState.lowBatteryPercent {
            onLowBatteryProximity?()
        }
    }

    /// Settings / tests: fire the same overlay path without waiting on hardware.
    func emitPreview(_ event: PowerAlertState.Event) {
        onEvent?(event)
    }

    private struct BatterySnapshot {
        var percent: Int
        var isCharging: Bool
    }

    private static func readBattery() -> BatterySnapshot? {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard
                let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any]
            else { continue }
            let type = raw[kIOPSTypeKey] as? String
            guard type == kIOPSInternalBatteryType else { continue }
            let current = raw[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCapacity = Swift.max(raw[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let charging = raw[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (raw[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let percent = min(max(Int(round(Double(current) / Double(maxCapacity) * 100)), 0), 100)
            // Banner is for plugging in, including 100% on AC when isCharging is false.
            return BatterySnapshot(percent: percent, isCharging: onAC || charging)
        }
        return nil
    }
}
