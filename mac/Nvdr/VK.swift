import Foundation
import CoreGraphics

/// Windows virtual-key codes — only the subset we actually emit. Mirrors
/// `src/vk.rs` so the wire side and the macOS side agree.
enum VK {
    static let back: UInt16 = 0x08
    static let tab: UInt16 = 0x09
    static let `return`: UInt16 = 0x0D
    static let shift: UInt16 = 0x10
    static let control: UInt16 = 0x11
    static let menu: UInt16 = 0x12 // Alt
    static let pause: UInt16 = 0x13
    static let capital: UInt16 = 0x14
    static let escape: UInt16 = 0x1B
    static let space: UInt16 = 0x20
    static let prior: UInt16 = 0x21
    static let next: UInt16 = 0x22
    static let end: UInt16 = 0x23
    static let home: UInt16 = 0x24
    static let left: UInt16 = 0x25
    static let up: UInt16 = 0x26
    static let right: UInt16 = 0x27
    static let down: UInt16 = 0x28
    static let insert: UInt16 = 0x2D
    static let delete: UInt16 = 0x2E
    static let lwin: UInt16 = 0x5B
    static let rwin: UInt16 = 0x5C
    static let apps: UInt16 = 0x5D
    static let numpad0: UInt16 = 0x60
    static let multiply: UInt16 = 0x6A
    static let add: UInt16 = 0x6B
    static let subtract: UInt16 = 0x6D
    static let decimal: UInt16 = 0x6E
    static let divide: UInt16 = 0x6F
    static let f1: UInt16 = 0x70
    static let numlock: UInt16 = 0x90
    static let scroll: UInt16 = 0x91
    static let lshift: UInt16 = 0xA0
    static let rshift: UInt16 = 0xA1
    static let lcontrol: UInt16 = 0xA2
    static let rcontrol: UInt16 = 0xA3
    static let lmenu: UInt16 = 0xA4
    static let rmenu: UInt16 = 0xA5
    static let oem1: UInt16 = 0xBA      // ; :
    static let oemPlus: UInt16 = 0xBB   // = +
    static let oemComma: UInt16 = 0xBC  // , <
    static let oemMinus: UInt16 = 0xBD  // - _
    static let oemPeriod: UInt16 = 0xBE // . >
    static let oem2: UInt16 = 0xBF      // / ?
    static let oem3: UInt16 = 0xC0      // ` ~
    static let oem4: UInt16 = 0xDB      // [ {
    static let oem5: UInt16 = 0xDC      // \ |
    static let oem6: UInt16 = 0xDD      // ] }
    static let oem7: UInt16 = 0xDE      // ' "
}

/// macOS virtual key codes (`kVK_*` from Carbon/HIToolbox) for the keys nvdr
/// references by name — the rest live in `MacKeyVK.table`. These are layout
/// *positions*, independent of the active keyboard layout.
enum MacKeyCode {
    static let capsLock: CGKeyCode = 57
    static let f11: CGKeyCode = 103

    static let leftCommand: CGKeyCode = 55
    static let rightCommand: CGKeyCode = 54
    static let leftShift: CGKeyCode = 56
    static let rightShift: CGKeyCode = 60
    static let leftOption: CGKeyCode = 58
    static let rightOption: CGKeyCode = 61
    static let leftControl: CGKeyCode = 59
    static let rightControl: CGKeyCode = 62
    static let function: CGKeyCode = 63
}

/// Translate a macOS `CGKeyCode` (the keycode carried by every CGEvent
/// keyDown / keyUp / flagsChanged) into a Windows VK code for the `key` IPC
/// command. Mirrors what the old iOS `HIDToVK` did for `UIKey`.
///
/// Returns `nil` for keys we don't map; the caller drops the transition.
/// We deliberately don't compose shifted characters — every CGEvent is one
/// physical key transition and the remote NVDA cares about the physical key.
///
/// The mapping parameters control how the Mac-only Option (⌥) and Command (⌘)
/// modifiers are forwarded — neither exists on Windows, so the user picks
/// which Windows modifier each stands in for. Left and right Option carry
/// independent mappings; Command applies to both ⌘ keys.
enum MacKeyVK {
    enum Side { case left, right }

    static func remappedModifier(_ mapping: ModifierMapping, side: Side) -> UInt16? {
        switch (mapping, side) {
        case (.alt, .left): return VK.lmenu
        case (.alt, .right): return VK.rmenu
        case (.win, .left): return VK.lwin
        case (.win, .right): return VK.rwin
        case (.ctrl, .left): return VK.lcontrol
        case (.ctrl, .right): return VK.rcontrol
        case (.none, _): return nil
        }
    }

    static func vk(
        forKeyCode code: CGKeyCode,
        leftOptionMapping: ModifierMapping = .alt,
        rightOptionMapping: ModifierMapping = .ctrl,
        commandMapping: ModifierMapping = .alt
    ) -> UInt16? {
        switch code {
        // Modifiers — distinguish left vs right. Option / Command route
        // through the user-chosen mapping.
        case MacKeyCode.leftShift: return VK.lshift
        case MacKeyCode.rightShift: return VK.rshift
        case MacKeyCode.leftControl: return VK.lcontrol
        case MacKeyCode.rightControl: return VK.rcontrol
        case MacKeyCode.leftOption: return remappedModifier(leftOptionMapping, side: .left)
        case MacKeyCode.rightOption: return remappedModifier(rightOptionMapping, side: .right)
        case MacKeyCode.leftCommand: return remappedModifier(commandMapping, side: .left)
        case MacKeyCode.rightCommand: return remappedModifier(commandMapping, side: .right)
        case MacKeyCode.capsLock: return VK.capital
        case MacKeyCode.function: return nil // Fn has no Windows analog
        default: return table[code]
        }
    }

    /// Non-modifier keycodes. Keyed by `kVK_*` value (see Carbon's `Events.h`).
    private static let table: [CGKeyCode: UInt16] = [
        // Letters (kVK_ANSI_A … Z) → VK 0x41…0x5A
        0: 0x41, 11: 0x42, 8: 0x43, 2: 0x44, 14: 0x45, 3: 0x46, 5: 0x47,
        4: 0x48, 34: 0x49, 38: 0x4A, 40: 0x4B, 37: 0x4C, 46: 0x4D, 45: 0x4E,
        31: 0x4F, 35: 0x50, 12: 0x51, 15: 0x52, 1: 0x53, 17: 0x54, 32: 0x55,
        9: 0x56, 13: 0x57, 7: 0x58, 16: 0x59, 6: 0x5A,
        // Top-row digits → VK 0x30…0x39
        29: 0x30, 18: 0x31, 19: 0x32, 20: 0x33, 21: 0x34, 23: 0x35,
        22: 0x36, 26: 0x37, 28: 0x38, 25: 0x39,
        // Punctuation (US layout positions)
        27: VK.oemMinus, 24: VK.oemPlus, 33: VK.oem4, 30: VK.oem6,
        42: VK.oem5, 41: VK.oem1, 39: VK.oem7, 50: VK.oem3,
        43: VK.oemComma, 47: VK.oemPeriod, 44: VK.oem2,
        // Whitespace / editing / control
        49: VK.space, 36: VK.return, 48: VK.tab, 51: VK.back, 53: VK.escape,
        117: VK.delete, 114: VK.insert, 115: VK.home, 119: VK.end,
        116: VK.prior, 121: VK.next, 71: VK.numlock,
        // Arrows
        123: VK.left, 124: VK.right, 125: VK.down, 126: VK.up,
        // Function row F1…F20 → VK 0x70…0x83
        122: VK.f1, 120: VK.f1 + 1, 99: VK.f1 + 2, 118: VK.f1 + 3,
        96: VK.f1 + 4, 97: VK.f1 + 5, 98: VK.f1 + 6, 100: VK.f1 + 7,
        101: VK.f1 + 8, 109: VK.f1 + 9, 103: VK.f1 + 10, 111: VK.f1 + 11,
        105: VK.f1 + 12, 107: VK.f1 + 13, 113: VK.f1 + 14, 106: VK.f1 + 15,
        64: VK.f1 + 16, 79: VK.f1 + 17, 80: VK.f1 + 18, 90: VK.f1 + 19,
        // Numeric keypad
        82: VK.numpad0, 83: VK.numpad0 + 1, 84: VK.numpad0 + 2,
        85: VK.numpad0 + 3, 86: VK.numpad0 + 4, 87: VK.numpad0 + 5,
        88: VK.numpad0 + 6, 89: VK.numpad0 + 7, 91: VK.numpad0 + 8,
        92: VK.numpad0 + 9, 76: VK.return, 65: VK.decimal, 67: VK.multiply,
        69: VK.add, 78: VK.subtract, 75: VK.divide,
    ]
}
