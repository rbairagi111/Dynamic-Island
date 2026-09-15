import Foundation
import CoreAudio
import CoreGraphics
import Darwin
import IOKit
import ApplicationServices
import AppKit

enum LevelHUDKind: Equatable {
    case volume
    case brightness
}

struct LevelHUDEvent: Equatable {
    var kind: LevelHUDKind
    var percent: Int
    var muted: Bool
}

private let nxSysDefinedEvent: UInt32 = 14
private let nxAuxControlSubtype: Int16 = 8
private let nxKeyUpState = 0x0B
private let volumeStep: Float = 1.0 / 16.0
private let brightnessStep: Float = 1.0 / 16.0

/// Reads default-output volume and main-display brightness, swallows the
/// hardware keys, and remaps them at the HID layer so macOS 26 cannot post
/// the Control Center SystemBanner alongside the island.
final class VolumeBrightnessMonitor {
    static let shared = VolumeBrightnessMonitor()

    var onEvent: ((LevelHUDEvent) -> Void)?
    var onTransport: ((IslandKeyboardTransport) -> Void)?

    private var volumeBaseline = true
    private var brightnessBaseline = true
    private var lastVolumePercent: Int?
    private var lastMuted: Bool?
    private var lastBrightnessPercent: Int?

    private var defaultDeviceID: AudioDeviceID = 0
    private var pollTimer: Timer?
    private var started = false
    private var displayServices: UnsafeMutableRawPointer?
    private var getBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)?
    private var setBrightness: (@convention(c) (CGDirectDisplayID, Float) -> Int32)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// After a failed tap install, do not retry automatically. Hammering
    /// `CGEvent.tapCreate` re-triggers the Accessibility / Input Monitoring sheet.
    private var didFailTapInstall = false
    private var didAttemptTapCreate = false
    private var hidRedirectActive = false
    private var lastRedirectAt: TimeInterval = 0
    private var lastRedirectKey: RedirectedMediaKey?
    private var lastTransportAt: TimeInterval = 0
    private var lastTransportKey: IslandKeyboardTransport?
    private var lastHIDApplyAt: TimeInterval = 0
    private var wakeObserver: NSObjectProtocol?
    private let bindingLock = NSLock()
    private var captureMediaKeys = false
    private var captureArrowKeys = false

    private let listenerQueue = DispatchQueue(label: "island.audio-level")

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        restoreMediaKeyMappings()
        loadDisplayServices()
        attachAudioListeners()
        poll(emitVolume: false, emitBrightness: false)
        SystemHUDSuppressor.shared.start()
        if IslandSurfacePolicy.shouldAttemptMediaKeyTapWhenAlreadyTrusted {
            installMediaKeyTap()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.didFailTapInstall = false
            self?.didAttemptTapCreate = false
            self?.restoreMediaKeyMappings()
            self?.installMediaKeyTap()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.poll(emitVolume: true, emitBrightness: false)
            if IslandSurfacePolicy.shouldRetryMediaKeyTapWhileRunning {
                self?.installMediaKeyTap()
            }
        }
    }

    func retryMediaKeyTap() {
        didFailTapInstall = false
        didAttemptTapCreate = false
        installMediaKeyTap()
    }

    func updateKeyboardBinding(mediaKeys: Bool, arrowKeys: Bool) {
        bindingLock.lock()
        let needsTap = mediaKeys || arrowKeys
        captureMediaKeys = mediaKeys
        captureArrowKeys = arrowKeys
        bindingLock.unlock()
        // Re-enable a timed-out tap as soon as we need F7–F9 again — otherwise
        // play/pause looks dead until the next poll cycle.
        guard needsTap else { return }
        if Thread.isMainThread {
            installMediaKeyTap()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.installMediaKeyTap()
            }
        }
    }

    private func keyboardBinding() -> (mediaKeys: Bool, arrowKeys: Bool) {
        bindingLock.lock()
        defer { bindingLock.unlock() }
        return (captureMediaKeys, captureArrowKeys)
    }

    /// Put volume/brightness keys back so they are not left as F-keys.
    func restoreMediaKeyMappings() {
        HIDMediaKeyRedirect.shared.restore()
        hidRedirectActive = false
    }

    /// Put volume/brightness keys back before quit so they are not left as F-keys.
    func restoreForTermination() {
        restoreMediaKeyMappings()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        AppSettings.shared.mediaKeysCaptured = false
    }

    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            didFailTapInstall = true
            hidRedirectActive = false
            HIDMediaKeyRedirect.shared.restore()
            AppSettings.shared.mediaKeysCaptured = false
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if hidRedirectActive || HIDMediaKeyRedirect.shared.isApplied,
               let key = RedirectedMediaKey.fromCGKeyCode(code) {
                if type == .keyDown {
                    _ = perform(key)
                }
                return nil
            }
            let flags = event.flags
            // F7–F9 as standard function keys (System Settings) — macOS will
            // not play/pause those; the island must. Dedicated NX media keys
            // are never swallowed (passed through to MediaRemote below).
            if let transport = IslandKeyboardTransport.fromCGMediaFunctionKeyCode(
                code,
                flags: flags
            ) {
                guard keyboardBinding().mediaKeys else {
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown,
                   event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    emitTransport(transport)
                }
                return nil
            }
            if let transport = IslandKeyboardTransport.fromCGKeyCode(code, flags: flags) {
                let binding = keyboardBinding()
                guard binding.arrowKeys else {
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown,
                   event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    emitTransport(transport)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == nxSysDefinedEvent else {
            return Unmanaged.passUnretained(event)
        }
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == nxAuxControlSubtype else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int64((nsEvent.data1 & 0xFFFF0000) >> 16)
        let keyState = (nsEvent.data1 & 0x0000FF00) >> 8
        // NX play/pause/next/prev: never swallow. Capturing these and then
        // missing YouTube JS left the key dead for both the island and macOS.
        // System MediaRemote handles them; the island UI follows the adapter.
        if IslandKeyboardTransport.fromNXKeyCode(keyCode) != nil {
            return Unmanaged.passUnretained(event)
        }
        guard let key = RedirectedMediaKey.fromNXKeyCode(keyCode) else {
            return Unmanaged.passUnretained(event)
        }
        if keyState == nxKeyUpState {
            return nil
        }
        if !perform(key), key == .brightnessUp || key == .brightnessDown {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func emitTransport(_ key: IslandKeyboardTransport) {
        let now = ProcessInfo.processInfo.systemUptime
        if lastTransportKey == key, now - lastTransportAt < 0.18 {
            return
        }
        lastTransportKey = key
        lastTransportAt = now
        if Thread.isMainThread {
            onTransport?(key)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onTransport?(key)
            }
        }
    }

    @discardableResult
    private func perform(_ key: RedirectedMediaKey) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if lastRedirectKey == key, now - lastRedirectAt < 0.012 {
            return true
        }
        lastRedirectKey = key
        lastRedirectAt = now
        SystemHUDSuppressor.shared.suppressNativeHUD()
        switch key {
        case .volumeUp:
            return adjustVolume(steps: 1)
        case .volumeDown:
            return adjustVolume(steps: -1)
        case .mute:
            return toggleMute()
        case .brightnessUp:
            return adjustBrightness(steps: 1)
        case .brightnessDown:
            return adjustBrightness(steps: -1)
        }
    }

    private func installMediaKeyTap() {
        if let eventTap {
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            if CGEvent.tapIsEnabled(tap: eventTap) {
                AppSettings.shared.mediaKeysCaptured = true
                if IslandSurfacePolicy.shouldRemapMediaKeysToFunctionKeys {
                    activateHIDRedirectIfNeeded()
                }
                return
            }
            AppSettings.shared.mediaKeysCaptured = false
            return
        }

        let trusted = AXIsProcessTrusted()
        guard IslandSurfacePolicy.shouldCreateHIDEventTap(
            isTrusted: trusted,
            alreadyAttempted: didAttemptTapCreate,
            previousCreateFailed: didFailTapInstall
        ) else {
            AppSettings.shared.mediaKeysCaptured = false
            return
        }

        didAttemptTapCreate = true
        var mask = CGEventMask(1 << nxSysDefinedEvent)
        mask |= CGEventMask(1 << CGEventType.keyDown.rawValue)
        mask |= CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: islandMediaKeyTap,
            userInfo: nil
        ) else {
            didFailTapInstall = true
            AppSettings.shared.mediaKeysCaptured = false
            return
        }

        didFailTapInstall = false

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppSettings.shared.mediaKeysCaptured = true
        activateHIDRedirectIfNeeded()
    }

    private func activateHIDRedirectIfNeeded() {
        guard IslandSurfacePolicy.shouldRemapMediaKeysToFunctionKeys else {
            if HIDMediaKeyRedirect.shared.isApplied {
                restoreMediaKeyMappings()
            }
            return
        }
        guard let eventTap, CGEvent.tapIsEnabled(tap: eventTap) else { return }
        if HIDMediaKeyRedirect.shared.isApplied {
            hidRedirectActive = true
            return
        }
        hidRedirectActive = HIDMediaKeyRedirect.shared.applyIfNeeded()
        if hidRedirectActive {
            lastHIDApplyAt = ProcessInfo.processInfo.systemUptime
        }
    }

    private func loadDisplayServices() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return }
        displayServices = handle
        if let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightness = unsafeBitCast(
                symbol,
                to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self
            )
        }
        if let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightness = unsafeBitCast(
                symbol,
                to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self
            )
        }
    }

    private func attachAudioListeners() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue
        ) { [weak self] _, _ in
            self?.reattachDeviceListeners()
            self?.poll(emitVolume: true, emitBrightness: false)
        }
        reattachDeviceListeners()
    }

    private func reattachDeviceListeners() {
        guard let device = Self.defaultOutputDevice() else { return }
        defaultDeviceID = device
        var volumeAddress = Self.volumeAddress()
        var muteAddress = Self.muteAddress()
        AudioObjectAddPropertyListenerBlock(device, &volumeAddress, listenerQueue) { [weak self] _, _ in
            self?.poll(emitVolume: true, emitBrightness: false)
        }
        AudioObjectAddPropertyListenerBlock(device, &muteAddress, listenerQueue) { [weak self] _, _ in
            self?.poll(emitVolume: true, emitBrightness: false)
        }
    }

    @discardableResult
    private func adjustVolume(steps: Int) -> Bool {
        guard let device = Self.defaultOutputDevice() else { return false }
        let muted = Self.readMute(device: device)
        if muted, steps > 0 {
            Self.setMute(false, device: device)
        }
        guard let current = Self.readVolumeScalar(device: device) else { return false }
        let next = min(max(current + Float(steps) * volumeStep, 0), 1)
        Self.setVolumeScalar(next, device: device)
        poll(emitVolume: true, emitBrightness: false)
        return true
    }

    @discardableResult
    private func toggleMute() -> Bool {
        guard let device = Self.defaultOutputDevice() else { return false }
        Self.setMute(!Self.readMute(device: device), device: device)
        poll(emitVolume: true, emitBrightness: false)
        return true
    }

    @discardableResult
    private func adjustBrightness(steps: Int) -> Bool {
        guard let current = readBrightness() else { return false }
        let next = min(max(current + Float(steps) * brightnessStep, 0), 1)
        guard writeBrightness(next) else { return false }
        poll(emitVolume: false, emitBrightness: true)
        return true
    }

    private func poll(emitVolume: Bool, emitBrightness: Bool) {
        let snapshot = currentSnapshot()
        let work = { [weak self] in
            guard let self else { return }
            if let volume = snapshot.volume {
                let changed = self.lastVolumePercent != volume.percent || self.lastMuted != volume.muted
                self.lastVolumePercent = volume.percent
                self.lastMuted = volume.muted
                if self.volumeBaseline {
                    self.volumeBaseline = false
                } else if emitVolume, changed {
                    self.onEvent?(
                        LevelHUDEvent(kind: .volume, percent: volume.percent, muted: volume.muted)
                    )
                }
            }
            if let brightness = snapshot.brightness {
                let changed = self.lastBrightnessPercent != brightness
                self.lastBrightnessPercent = brightness
                if self.brightnessBaseline {
                    self.brightnessBaseline = false
                } else if emitBrightness, changed {
                    self.onEvent?(
                        LevelHUDEvent(kind: .brightness, percent: brightness, muted: false)
                    )
                }
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private struct Snapshot {
        var volume: (percent: Int, muted: Bool)?
        var brightness: Int?
    }

    private func currentSnapshot() -> Snapshot {
        Snapshot(
            volume: Self.readVolume(),
            brightness: Self.percent(from: readBrightness())
        )
    }

    private func readBrightness() -> Float? {
        if let getBrightness {
            var value: Float = 0
            if getBrightness(CGMainDisplayID(), &value) == 0, value >= 0, value <= 1.05 {
                return min(max(value, 0), 1)
            }
        }
        return Self.ioKitBrightness()
    }

    private func writeBrightness(_ value: Float) -> Bool {
        let clamped = min(max(value, 0), 1)
        if let setBrightness, setBrightness(CGMainDisplayID(), clamped) == 0 {
            return true
        }
        return Self.ioKitSetBrightness(clamped)
    }

    private static func percent(from scalar: Float?) -> Int? {
        guard let scalar else { return nil }
        return min(max(Int((scalar * 100).rounded()), 0), 100)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        return status == noErr && device != 0 ? device : nil
    }

    private static func volumeAddress(element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readVolume() -> (percent: Int, muted: Bool)? {
        guard let device = defaultOutputDevice() else { return nil }
        let muted = readMute(device: device)
        guard let scalar = readVolumeScalar(device: device) else {
            return (muted ? 0 : 0, muted)
        }
        let percent = muted ? 0 : (percent(from: scalar) ?? 0)
        return (percent, muted)
    }

    private static func readVolumeScalar(device: AudioDeviceID) -> Float? {
        if let master = floatProperty(device: device, address: volumeAddress()) {
            return master
        }
        let channels: [UInt32] = [1, 2]
        let values = channels.compactMap {
            floatProperty(device: device, address: volumeAddress(element: $0))
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    private static func setVolumeScalar(_ value: Float, device: AudioDeviceID) {
        let clamped = min(max(value, 0), 1)
        let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]
        for element in elements {
            var address = volumeAddress(element: element)
            if AudioObjectHasProperty(device, &address) {
                setFloatProperty(device: device, address: address, value: clamped)
            }
        }
    }

    private static func readMute(device: AudioDeviceID) -> Bool {
        var address = muteAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func setMute(_ muted: Bool, device: AudioDeviceID) {
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }

    private static func floatProperty(
        device: AudioDeviceID,
        address: AudioObjectPropertyAddress
    ) -> Float? {
        var address = address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func setFloatProperty(
        device: AudioDeviceID,
        address: AudioObjectPropertyAddress,
        value: Float
    ) {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<Float32>.size)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }

    private static func ioKitBrightness() -> Float? {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var value: Float = 0
            let name = "brightness" as CFString
            if IODisplayGetFloatParameter(service, 0, name, &value) == KERN_SUCCESS {
                return min(max(value, 0), 1)
            }
        }
        return nil
    }

    private static func ioKitSetBrightness(_ value: Float) -> Bool {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        var wrote = false
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var next = value
            let name = "brightness" as CFString
            if IODisplaySetFloatParameter(service, 0, name, next) == KERN_SUCCESS {
                wrote = true
            }
        }
        return wrote
    }
}

private func islandMediaKeyTap(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    VolumeBrightnessMonitor.shared.handleTap(type: type, event: event)
}
