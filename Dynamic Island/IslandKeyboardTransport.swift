import CoreGraphics
import Foundation

/// Maps Mac keyboard media keys and cursor arrows onto the same transport
/// actions as the expanded island buttons (previous / play-pause / next).
enum IslandKeyboardTransport: Equatable {
    case playPause
    case skipBack
    case skipForward

    /// F7 rewind / F8 play / F9 forward on Apple keyboards (`ev_keymap.h`).
    static let nxPlay: Int64 = 16
    static let nxNext: Int64 = 17
    static let nxPrevious: Int64 = 18
    static let nxFast: Int64 = 19
    static let nxRewind: Int64 = 20

    /// When “Use F1, F2, etc. keys as standard function keys” is on, the same
    /// physical keys arrive as CG keycodes — not NX media events.
    static let cgF7: Int64 = 98
    static let cgF8: Int64 = 100
    static let cgF9: Int64 = 101

    static let cgLeftArrow: Int64 = 123
    static let cgRightArrow: Int64 = 124
    static let cgSpace: Int64 = 49

    static func fromNXKeyCode(_ code: Int64) -> IslandKeyboardTransport? {
        switch code {
        case nxPlay: return .playPause
        case nxNext, nxFast: return .skipForward
        case nxPrevious, nxRewind: return .skipBack
        default: return nil
        }
    }

    /// F7 / F8 / F9 as standard function keys. Gated by media-key binding
    /// (not arrow/hover binding) in the event tap.
    static func fromCGMediaFunctionKeyCode(
        _ code: Int64,
        flags: CGEventFlags
    ) -> IslandKeyboardTransport? {
        let blocking: CGEventFlags = [
            .maskCommand, .maskControl, .maskAlternate, .maskShift
        ]
        if !flags.intersection(blocking).isEmpty { return nil }
        switch code {
        case cgF7: return .skipBack
        case cgF8: return .playPause
        case cgF9: return .skipForward
        default: return nil
        }
    }

    /// Left / right / space — only when the caller has already decided the
    /// island owns the keyboard. Modifier chords stay with the front app.
    static func fromCGKeyCode(_ code: Int64, flags: CGEventFlags) -> IslandKeyboardTransport? {
        let blocking: CGEventFlags = [
            .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn
        ]
        if !flags.intersection(blocking).isEmpty { return nil }
        switch code {
        case cgLeftArrow: return .skipBack
        case cgRightArrow: return .skipForward
        case cgSpace: return .playPause
        default: return nil
        }
    }
}
