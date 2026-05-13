#![allow(dead_code)]

pub const VK_BACK: u16 = 0x08;
pub const VK_TAB: u16 = 0x09;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_SHIFT: u16 = 0x10;
pub const VK_CONTROL: u16 = 0x11;
pub const VK_MENU: u16 = 0x12; // Alt
pub const VK_PAUSE: u16 = 0x13;
pub const VK_CAPITAL: u16 = 0x14; // CapsLock
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_SPACE: u16 = 0x20;
pub const VK_PRIOR: u16 = 0x21; // PageUp
pub const VK_NEXT: u16 = 0x22; // PageDown
pub const VK_END: u16 = 0x23;
pub const VK_HOME: u16 = 0x24;
pub const VK_LEFT: u16 = 0x25;
pub const VK_UP: u16 = 0x26;
pub const VK_RIGHT: u16 = 0x27;
pub const VK_DOWN: u16 = 0x28;
pub const VK_INSERT: u16 = 0x2D;
pub const VK_DELETE: u16 = 0x2E;
pub const VK_LWIN: u16 = 0x5B;
pub const VK_RWIN: u16 = 0x5C;
pub const VK_APPS: u16 = 0x5D;
pub const VK_NUMPAD0: u16 = 0x60;
pub const VK_NUMPAD9: u16 = 0x69;
pub const VK_F1: u16 = 0x70;
pub const VK_F24: u16 = 0x87;
pub const VK_NUMLOCK: u16 = 0x90;
pub const VK_SCROLL: u16 = 0x91;
pub const VK_LSHIFT: u16 = 0xA0;
pub const VK_RSHIFT: u16 = 0xA1;
pub const VK_LCONTROL: u16 = 0xA2;
pub const VK_RCONTROL: u16 = 0xA3;
pub const VK_LMENU: u16 = 0xA4;
pub const VK_RMENU: u16 = 0xA5;

// OEM punctuation for US layout
pub const VK_OEM_1: u16 = 0xBA; // ; :
pub const VK_OEM_PLUS: u16 = 0xBB; // = +
pub const VK_OEM_COMMA: u16 = 0xBC; // , <
pub const VK_OEM_MINUS: u16 = 0xBD; // - _
pub const VK_OEM_PERIOD: u16 = 0xBE; // . >
pub const VK_OEM_2: u16 = 0xBF; // / ?
pub const VK_OEM_3: u16 = 0xC0; // ` ~
pub const VK_OEM_4: u16 = 0xDB; // [ {
pub const VK_OEM_5: u16 = 0xDC; // \ |
pub const VK_OEM_6: u16 = 0xDD; // ] }
pub const VK_OEM_7: u16 = 0xDE; // ' "

/// Given a Windows VK code, return a plausible PS/2 scan code for the US layout
/// so we send something non-zero even though the reference slave ignores it
/// (see client_spec.md §3.2 key note).
pub fn scan_for_vk(vk: u16) -> u32 {
    match vk {
        VK_ESCAPE => 0x01,
        VK_BACK => 0x0E,
        VK_TAB => 0x0F,
        VK_RETURN => 0x1C,
        VK_LCONTROL | VK_CONTROL => 0x1D,
        VK_LSHIFT | VK_SHIFT => 0x2A,
        VK_RSHIFT => 0x36,
        VK_LMENU | VK_MENU => 0x38,
        VK_SPACE => 0x39,
        VK_CAPITAL => 0x3A,
        VK_F1 => 0x3B,
        VK_F1..=0x79 => 0x3B + (vk - VK_F1) as u32,
        VK_NUMLOCK => 0x45,
        VK_SCROLL => 0x46,
        VK_HOME => 0x47,
        VK_UP => 0x48,
        VK_PRIOR => 0x49,
        VK_LEFT => 0x4B,
        VK_RIGHT => 0x4D,
        VK_END => 0x4F,
        VK_DOWN => 0x50,
        VK_NEXT => 0x51,
        VK_INSERT => 0x52,
        VK_DELETE => 0x53,
        VK_RCONTROL => 0x1D,
        VK_RMENU => 0x38,
        // Letters A..Z (0x41..0x5A) — rough PS/2 scan codes
        0x41 => 0x1E, // A
        0x42 => 0x30, // B
        0x43 => 0x2E, // C
        0x44 => 0x20, // D
        0x45 => 0x12, // E
        0x46 => 0x21, // F
        0x47 => 0x22, // G
        0x48 => 0x23, // H
        0x49 => 0x17, // I
        0x4A => 0x24, // J
        0x4B => 0x25, // K
        0x4C => 0x26, // L
        0x4D => 0x32, // M
        0x4E => 0x31, // N
        0x4F => 0x18, // O
        0x50 => 0x19, // P
        0x51 => 0x10, // Q
        0x52 => 0x13, // R
        0x53 => 0x1F, // S
        0x54 => 0x14, // T
        0x55 => 0x16, // U
        0x56 => 0x2F, // V
        0x57 => 0x11, // W
        0x58 => 0x2D, // X
        0x59 => 0x15, // Y
        0x5A => 0x2C, // Z
        // Digits 0..9 (0x30..0x39)
        0x30 => 0x0B,
        0x31..=0x39 => 0x02 + (vk - 0x31) as u32,
        VK_OEM_MINUS => 0x0C,
        VK_OEM_PLUS => 0x0D,
        VK_OEM_4 => 0x1A,
        VK_OEM_6 => 0x1B,
        VK_OEM_1 => 0x27,
        VK_OEM_7 => 0x28,
        VK_OEM_3 => 0x29,
        VK_OEM_5 => 0x2B,
        VK_OEM_COMMA => 0x33,
        VK_OEM_PERIOD => 0x34,
        VK_OEM_2 => 0x35,
        _ => 0,
    }
}

/// Extended-key flag for navigation/right-modifier/numpad-enter/etc.
/// Per client_spec.md §3.2 this flag matters for NVDA key bindings (e.g.
/// numpad Insert vs. extended Insert).
pub fn extended_for_vk(vk: u16) -> bool {
    matches!(
        vk,
        VK_INSERT
            | VK_DELETE
            | VK_HOME
            | VK_END
            | VK_PRIOR
            | VK_NEXT
            | VK_LEFT
            | VK_RIGHT
            | VK_UP
            | VK_DOWN
            | VK_RCONTROL
            | VK_RMENU
            | VK_LWIN
            | VK_RWIN
            | VK_APPS
            | VK_NUMLOCK
    )
}
