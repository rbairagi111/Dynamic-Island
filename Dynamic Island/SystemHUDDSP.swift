import CoreGraphics
import Foundation

/// Carbon virtual key codes for F16–F20. Volume/brightness consumer keys are
/// redirected here so macOS never sees them and does not post a SystemBanner.
enum RedirectedMediaKey: Equatable {
    case volumeUp
    case volumeDown
    case mute
    case brightnessUp
    case brightnessDown

    static let cgKeyF16: Int64 = 0x6A
    static let cgKeyF17: Int64 = 0x40
    static let cgKeyF18: Int64 = 0x4F
    static let cgKeyF19: Int64 = 0x50
    static let cgKeyF20: Int64 = 0x5A

    static let nxSoundUp: Int64 = 0
    static let nxSoundDown: Int64 = 1
    static let nxBrightnessUp: Int64 = 2
    static let nxBrightnessDown: Int64 = 3
    static let nxMute: Int64 = 7

    static func fromCGKeyCode(_ code: Int64) -> RedirectedMediaKey? {
        switch code {
        case cgKeyF17: return .brightnessUp
        case cgKeyF16: return .brightnessDown
        case cgKeyF18: return .volumeUp
        case cgKeyF19: return .volumeDown
        case cgKeyF20: return .mute
        default: return nil
        }
    }

    static func fromNXKeyCode(_ code: Int64) -> RedirectedMediaKey? {
        switch code {
        case nxSoundUp: return .volumeUp
        case nxSoundDown: return .volumeDown
        case nxMute: return .mute
        case nxBrightnessUp: return .brightnessUp
        case nxBrightnessDown: return .brightnessDown
        default: return nil
        }
    }
}

/// Geometry and HID tables for replacing macOS volume / brightness / Focus HUDs.
enum SystemHUDDSP {
    static let srcKey = "HIDKeyboardModifierMappingSrc"
    static let dstKey = "HIDKeyboardModifierMappingDst"

    static let osdOwnerNames: Set<String> = [
        "OSDUIHelper",
        "OSD UI Helper"
    ]

    static let bannerOwnerNames: Set<String> = [
        "Control Center",
        "Control Centre",
        "Window Manager"
    ]

    static let osdBundleIDs: Set<String> = [
        "com.apple.OSDUIHelper"
    ]

    static func hidUsage(page: UInt64, usage: UInt64) -> UInt64 {
        (page << 32) | usage
    }

    /// Consumer / Apple-vendor usages that trigger the native bezel, mapped to F16–F20.
    static var islandHIDRedirects: [(src: UInt64, dst: UInt64)] {
        let volumeUp = hidUsage(page: 0x0C, usage: 0xE9)
        let volumeDown = hidUsage(page: 0x0C, usage: 0xEA)
        let mute = hidUsage(page: 0x0C, usage: 0xE2)
        let brightnessUp = hidUsage(page: 0x0C, usage: 0x6F)
        let brightnessDown = hidUsage(page: 0x0C, usage: 0x70)
        let appleBrightnessUp = hidUsage(page: 0xFF01, usage: 0x20)
        let appleBrightnessDown = hidUsage(page: 0xFF01, usage: 0x21)
        let appleVendorKeyboardBrightnessUp = hidUsage(page: 0xFF, usage: 0x04)
        let appleVendorKeyboardBrightnessDown = hidUsage(page: 0xFF, usage: 0x05)
        let f16 = hidUsage(page: 0x07, usage: 0x6B)
        let f17 = hidUsage(page: 0x07, usage: 0x6C)
        let f18 = hidUsage(page: 0x07, usage: 0x6D)
        let f19 = hidUsage(page: 0x07, usage: 0x6E)
        let f20 = hidUsage(page: 0x07, usage: 0x6F)
        return [
            (volumeUp, f18),
            (volumeDown, f19),
            (mute, f20),
            (brightnessUp, f17),
            (brightnessDown, f16),
            (appleBrightnessUp, f17),
            (appleBrightnessDown, f16),
            (appleVendorKeyboardBrightnessUp, f17),
            (appleVendorKeyboardBrightnessDown, f16)
        ]
    }

    static func islandHIDRedirectMaps() -> [[String: UInt64]] {
        islandHIDRedirects.map { [srcKey: $0.src, dstKey: $0.dst] }
    }

    static func islandHIDSourceUsages() -> Set<UInt64> {
        Set(islandHIDRedirects.map(\.src))
    }

    static func uint64Value(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int, value >= 0 {
            return UInt64(value)
        }
        return nil
    }

    static func normalizedHIDMaps(_ raw: [[AnyHashable: Any]]) -> [[String: UInt64]] {
        raw.compactMap { entry in
            guard let src = uint64Value(entry[srcKey] ?? entry[srcKey as NSString]),
                  let dst = uint64Value(entry[dstKey] ?? entry[dstKey as NSString])
            else { return nil }
            return [srcKey: src, dstKey: dst]
        }
    }

    /// Keep unrelated remaps (Karabiner / hidutil) and replace our sources.
    static func mergeHIDRedirects(existing: [[String: UInt64]]) -> [[String: UInt64]] {
        let sources = islandHIDSourceUsages()
        let kept = existing.filter { entry in
            guard let src = entry[srcKey] else { return true }
            return !sources.contains(src)
        }
        return kept + islandHIDRedirectMaps()
    }

    static func stripIslandHIDRedirects(_ existing: [[String: UInt64]]) -> [[String: UInt64]] {
        let sources = islandHIDSourceUsages()
        return existing.filter { entry in
            guard let src = entry[srcKey] else { return true }
            return !sources.contains(src)
        }
    }

    /// Classic center OSD, or the Tahoe Control Center pill under the menu bar.
    /// Leave the full Control Center panel and the menu-bar strip alone.
    static func looksLikeNativeLevelHUD(owner: String, bounds: CGRect) -> Bool {
        if osdOwnerNames.contains(owner) {
            return bounds.width > 8 && bounds.height > 8
        }
        guard bannerOwnerNames.contains(owner) else { return false }
        return looksLikeControlCenterBanner(bounds)
    }

    static func looksLikeControlCenterBanner(_ bounds: CGRect) -> Bool {
        looksLikeControlCenterBannerSize(bounds.size) && bounds.minY < 140
    }

    static func looksLikeControlCenterBannerSize(_ size: CGSize) -> Bool {
        size.width > 90 && size.width < 420 && size.height > 32 && size.height < 110
    }

    static func isOSDHelper(bundleID: String?, localizedName: String?) -> Bool {
        if let bundleID, osdBundleIDs.contains(bundleID) { return true }
        if let localizedName, osdOwnerNames.contains(localizedName) { return true }
        return false
    }
}
