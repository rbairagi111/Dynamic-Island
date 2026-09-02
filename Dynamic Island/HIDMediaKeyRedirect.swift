import CoreFoundation
import Darwin
import Foundation
import IOKit

/// Remaps volume / brightness consumer keys to unused F-keys at the HID filter.
/// On macOS 26 the system posts Control Center banners from those keys before a
/// `CGEvent` tap can swallow them. F16–F20 never trigger that HUD.
final class HIDMediaKeyRedirect {
    static let shared = HIDMediaKeyRedirect()

    private var applied = false
    private var symbols = HIDSymbols()

    private init() {
        atexit {
            HIDMediaKeyRedirect.shared.restore()
        }
    }

    var isApplied: Bool { applied }

    @discardableResult
    func applyIfNeeded() -> Bool {
        guard let symbols else { return false }
        guard let client = symbols.create(nil) else { return false }
        defer { Unmanaged<AnyObject>.fromOpaque(client).release() }

        let existing = currentMaps(client: client, symbols: symbols)
        let merged = SystemHUDDSP.mergeHIDRedirects(existing: existing)
        guard writeMaps(merged, client: client, symbols: symbols) else { return false }
        applied = true
        return true
    }

    func restore() {
        applied = false
        guard let symbols else { return }
        guard let client = symbols.create(nil) else { return }
        defer { Unmanaged<AnyObject>.fromOpaque(client).release() }
        let existing = currentMaps(client: client, symbols: symbols)
        _ = writeMaps(SystemHUDDSP.stripIslandHIDRedirects(existing), client: client, symbols: symbols)
    }

    private func currentMaps(client: UnsafeMutableRawPointer, symbols: HIDSymbols) -> [[String: UInt64]] {
        var combined: [[String: UInt64]] = []
        if let property = symbols.copyProperty(client, "UserKeyMapping" as CFString)?.takeRetainedValue(),
           let array = property as? [[AnyHashable: Any]] {
            combined.append(contentsOf: SystemHUDDSP.normalizedHIDMaps(array))
        }
        guard let services = symbols.copyServices(client)?.takeRetainedValue() as? [AnyObject] else {
            return uniqueMaps(combined)
        }
        for service in services {
            let pointer = Unmanaged.passUnretained(service).toOpaque()
            let isKeyboard = symbols.conformsTo(pointer, 0x01, 0x06).boolValue
            let isConsumer = symbols.conformsTo(pointer, 0x0C, 0x01).boolValue
            guard isKeyboard || isConsumer else { continue }
            guard let property = symbols.copyServiceProperty(pointer, "UserKeyMapping" as CFString)?.takeRetainedValue(),
                  let array = property as? [[AnyHashable: Any]]
            else { continue }
            combined.append(contentsOf: SystemHUDDSP.normalizedHIDMaps(array))
        }
        return uniqueMaps(combined)
    }

    private func writeMaps(
        _ maps: [[String: UInt64]],
        client: UnsafeMutableRawPointer,
        symbols: HIDSymbols
    ) -> Bool {
        let payload = maps as CFArray
        var wrote = symbols.setProperty(client, "UserKeyMapping" as CFString, payload).boolValue
        guard let services = symbols.copyServices(client)?.takeRetainedValue() as? [AnyObject] else {
            return wrote
        }
        for service in services {
            let pointer = Unmanaged.passUnretained(service).toOpaque()
            let isKeyboard = symbols.conformsTo(pointer, 0x01, 0x06).boolValue
            let isConsumer = symbols.conformsTo(pointer, 0x0C, 0x01).boolValue
            guard isKeyboard || isConsumer else { continue }
            if symbols.setServiceProperty(pointer, "UserKeyMapping" as CFString, payload).boolValue {
                wrote = true
            }
        }
        return wrote
    }

    private func uniqueMaps(_ maps: [[String: UInt64]]) -> [[String: UInt64]] {
        var seen = Set<UInt64>()
        var result: [[String: UInt64]] = []
        for map in maps {
            guard let src = map[SystemHUDDSP.srcKey], !seen.contains(src) else { continue }
            seen.insert(src)
            result.append(map)
        }
        return result
    }
}

private struct HIDSymbols {
    typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    typealias SetPropertyFn = @convention(c) (UnsafeMutableRawPointer, CFString, CFTypeRef) -> DarwinBoolean
    typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<CFTypeRef>?
    typealias ConformsToFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> DarwinBoolean

    let create: CreateFn
    let copyServices: CopyServicesFn
    let setProperty: SetPropertyFn
    let copyProperty: CopyPropertyFn
    let setServiceProperty: SetPropertyFn
    let copyServiceProperty: CopyPropertyFn
    let conformsTo: ConformsToFn

    init?() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        guard let handle else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard
            let create = symbol("IOHIDEventSystemClientCreateSimpleClient", as: CreateFn.self),
            let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
            let setProperty = symbol("IOHIDEventSystemClientSetProperty", as: SetPropertyFn.self),
            let copyProperty = symbol("IOHIDEventSystemClientCopyProperty", as: CopyPropertyFn.self),
            let setServiceProperty = symbol("IOHIDServiceClientSetProperty", as: SetPropertyFn.self),
            let copyServiceProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
            let conformsTo = symbol("IOHIDServiceClientConformsTo", as: ConformsToFn.self)
        else { return nil }
        self.create = create
        self.copyServices = copyServices
        self.setProperty = setProperty
        self.copyProperty = copyProperty
        self.setServiceProperty = setServiceProperty
        self.copyServiceProperty = copyServiceProperty
        self.conformsTo = conformsTo
    }
}
