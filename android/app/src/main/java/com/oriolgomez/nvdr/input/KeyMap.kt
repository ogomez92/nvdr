package com.oriolgomez.nvdr.input

import android.view.KeyEvent
import com.oriolgomez.nvdr.settings.ModifierMapping

/**
 * Translate an Android [KeyEvent] key code (carried by every hardware-keyboard
 * down/up the focused Activity receives) into a Windows VK code for the `key`
 * IPC command. The Android analog of the macOS `MacKeyVK` / iOS `HIDToVK`.
 *
 * Returns `null` for keys we don't map; the caller lets the system handle them
 * (so Back / Home / volume keep working). We deliberately don't compose shifted
 * characters — each event is one physical key transition and the remote NVDA
 * cares about the physical key. Android delivers modifier keys (Shift, Ctrl,
 * Alt, Meta) as their own down/up events, so they forward like any other key.
 *
 * US layout is assumed, matching `src/vk.rs`.
 */
object KeyMap {
    enum class Side { Left, Right }

    fun remappedModifier(mapping: ModifierMapping, side: Side): Int? = when (mapping) {
        ModifierMapping.Alt -> if (side == Side.Left) VK.LMENU else VK.RMENU
        ModifierMapping.Win -> if (side == Side.Left) VK.LWIN else VK.RWIN
        ModifierMapping.Ctrl -> if (side == Side.Left) VK.LCONTROL else VK.RCONTROL
        ModifierMapping.None -> null
    }

    fun vk(
        keyCode: Int,
        leftAltMapping: ModifierMapping = ModifierMapping.Alt,
        rightAltMapping: ModifierMapping = ModifierMapping.Alt,
        metaMapping: ModifierMapping = ModifierMapping.Win,
    ): Int? {
        // Contiguous ranges first.
        if (keyCode in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z) {
            return 0x41 + (keyCode - KeyEvent.KEYCODE_A) // A..Z -> 0x41..0x5A
        }
        if (keyCode in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9) {
            return 0x30 + (keyCode - KeyEvent.KEYCODE_0) // 0..9 -> 0x30..0x39
        }
        if (keyCode in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12) {
            return VK.F1 + (keyCode - KeyEvent.KEYCODE_F1) // F1..F12 -> 0x70..0x7B
        }
        if (keyCode in KeyEvent.KEYCODE_NUMPAD_0..KeyEvent.KEYCODE_NUMPAD_9) {
            return VK.NUMPAD0 + (keyCode - KeyEvent.KEYCODE_NUMPAD_0)
        }

        return when (keyCode) {
            // Modifiers — distinguish left vs right. Alt / Meta route through the
            // user-chosen mapping (Mac-keyboard friendliness).
            KeyEvent.KEYCODE_SHIFT_LEFT -> VK.LSHIFT
            KeyEvent.KEYCODE_SHIFT_RIGHT -> VK.RSHIFT
            KeyEvent.KEYCODE_CTRL_LEFT -> VK.LCONTROL
            KeyEvent.KEYCODE_CTRL_RIGHT -> VK.RCONTROL
            KeyEvent.KEYCODE_ALT_LEFT -> remappedModifier(leftAltMapping, Side.Left)
            KeyEvent.KEYCODE_ALT_RIGHT -> remappedModifier(rightAltMapping, Side.Right)
            KeyEvent.KEYCODE_META_LEFT -> remappedModifier(metaMapping, Side.Left)
            KeyEvent.KEYCODE_META_RIGHT -> remappedModifier(metaMapping, Side.Right)
            KeyEvent.KEYCODE_CAPS_LOCK -> VK.CAPITAL
            KeyEvent.KEYCODE_FUNCTION -> null // Fn has no Windows analog

            // Whitespace / editing / control
            KeyEvent.KEYCODE_DEL -> VK.BACK            // Android DEL == Backspace
            KeyEvent.KEYCODE_FORWARD_DEL -> VK.DELETE
            KeyEvent.KEYCODE_TAB -> VK.TAB
            KeyEvent.KEYCODE_ENTER -> VK.RETURN
            KeyEvent.KEYCODE_NUMPAD_ENTER -> VK.RETURN
            KeyEvent.KEYCODE_ESCAPE -> VK.ESCAPE
            KeyEvent.KEYCODE_SPACE -> VK.SPACE

            // Navigation
            KeyEvent.KEYCODE_DPAD_UP -> VK.UP
            KeyEvent.KEYCODE_DPAD_DOWN -> VK.DOWN
            KeyEvent.KEYCODE_DPAD_LEFT -> VK.LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> VK.RIGHT
            KeyEvent.KEYCODE_MOVE_HOME -> VK.HOME
            KeyEvent.KEYCODE_MOVE_END -> VK.END
            KeyEvent.KEYCODE_PAGE_UP -> VK.PRIOR
            KeyEvent.KEYCODE_PAGE_DOWN -> VK.NEXT
            KeyEvent.KEYCODE_INSERT -> VK.INSERT

            // Punctuation (US layout positions)
            KeyEvent.KEYCODE_GRAVE -> VK.OEM_3
            KeyEvent.KEYCODE_MINUS -> VK.OEM_MINUS
            KeyEvent.KEYCODE_EQUALS -> VK.OEM_PLUS
            KeyEvent.KEYCODE_LEFT_BRACKET -> VK.OEM_4
            KeyEvent.KEYCODE_RIGHT_BRACKET -> VK.OEM_6
            KeyEvent.KEYCODE_BACKSLASH -> VK.OEM_5
            KeyEvent.KEYCODE_SEMICOLON -> VK.OEM_1
            KeyEvent.KEYCODE_APOSTROPHE -> VK.OEM_7
            KeyEvent.KEYCODE_COMMA -> VK.OEM_COMMA
            KeyEvent.KEYCODE_PERIOD -> VK.OEM_PERIOD
            KeyEvent.KEYCODE_SLASH -> VK.OEM_2

            // Numeric keypad operators
            KeyEvent.KEYCODE_NUMPAD_DOT -> VK.DECIMAL
            KeyEvent.KEYCODE_NUMPAD_ADD -> VK.ADD
            KeyEvent.KEYCODE_NUMPAD_SUBTRACT -> VK.SUBTRACT
            KeyEvent.KEYCODE_NUMPAD_MULTIPLY -> VK.MULTIPLY
            KeyEvent.KEYCODE_NUMPAD_DIVIDE -> VK.DIVIDE

            // Locks / system
            KeyEvent.KEYCODE_NUM_LOCK -> VK.NUMLOCK
            KeyEvent.KEYCODE_SCROLL_LOCK -> VK.SCROLL
            KeyEvent.KEYCODE_BREAK -> VK.PAUSE
            KeyEvent.KEYCODE_MENU -> VK.APPS

            else -> null
        }
    }
}
