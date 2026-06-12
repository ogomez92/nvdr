package com.oriolgomez.nvdr.input

/**
 * Windows virtual-key codes — only the subset we actually emit. Mirrors
 * `src/vk.rs` and the Swift `VK.swift` so every port agrees on the wire side.
 * Values are plain [Int] (the wire carries a decimal u16).
 */
object VK {
    const val BACK = 0x08
    const val TAB = 0x09
    const val RETURN = 0x0D
    const val SHIFT = 0x10
    const val CONTROL = 0x11
    const val MENU = 0x12 // Alt
    const val PAUSE = 0x13
    const val CAPITAL = 0x14 // CapsLock
    const val ESCAPE = 0x1B
    const val SPACE = 0x20
    const val PRIOR = 0x21 // PageUp
    const val NEXT = 0x22 // PageDown
    const val END = 0x23
    const val HOME = 0x24
    const val LEFT = 0x25
    const val UP = 0x26
    const val RIGHT = 0x27
    const val DOWN = 0x28
    const val INSERT = 0x2D
    const val DELETE = 0x2E
    const val LWIN = 0x5B
    const val RWIN = 0x5C
    const val APPS = 0x5D
    const val NUMPAD0 = 0x60
    const val MULTIPLY = 0x6A
    const val ADD = 0x6B
    const val SUBTRACT = 0x6D
    const val DECIMAL = 0x6E
    const val DIVIDE = 0x6F
    const val F1 = 0x70
    const val NUMLOCK = 0x90
    const val SCROLL = 0x91
    const val LSHIFT = 0xA0
    const val RSHIFT = 0xA1
    const val LCONTROL = 0xA2
    const val RCONTROL = 0xA3
    const val LMENU = 0xA4 // Left Alt
    const val RMENU = 0xA5 // Right Alt
    const val OEM_1 = 0xBA      // ; :
    const val OEM_PLUS = 0xBB   // = +
    const val OEM_COMMA = 0xBC  // , <
    const val OEM_MINUS = 0xBD  // - _
    const val OEM_PERIOD = 0xBE // . >
    const val OEM_2 = 0xBF      // / ?
    const val OEM_3 = 0xC0      // ` ~
    const val OEM_4 = 0xDB      // [ {
    const val OEM_5 = 0xDC      // \ |
    const val OEM_6 = 0xDD      // ] }
    const val OEM_7 = 0xDE      // ' "
}
