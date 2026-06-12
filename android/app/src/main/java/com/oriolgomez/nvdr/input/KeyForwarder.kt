package com.oriolgomez.nvdr.input

import android.view.KeyEvent
import com.oriolgomez.nvdr.AppContainer
import com.oriolgomez.nvdr.settings.NvdaModifier

/**
 * Shared hardware-key handling, used by both [com.oriolgomez.nvdr.MainActivity]
 * (focused-only, via dispatchKeyEvent) and
 * [NvdrAccessibilityService] (system-wide, via onKeyEvent). Only one drives at a
 * time — the Activity defers when the accessibility service is running — so a
 * single held-key set is fine.
 */
object KeyForwarder {
    private val downKeys = HashSet<Int>()

    fun reset() = downKeys.clear()

    /** True if the event was consumed (forwarded / toggled); false to let the system handle it. */
    fun handle(container: AppContainer, event: KeyEvent): Boolean {
        val bridge = container.bridge
        val settings = container.settings
        val action = event.action
        val keyCode = event.keyCode

        // Forwarding toggle: NVDA-modifier base held + F11 (mirrors NVDA+F11).
        if (action == KeyEvent.ACTION_DOWN &&
            keyCode == KeyEvent.KEYCODE_F11 &&
            event.repeatCount == 0
        ) {
            val baseDown = when (settings.nvdaModifier) {
                NvdaModifier.CapsLock ->
                    downKeys.contains(KeyEvent.KEYCODE_CAPS_LOCK) || event.isCapsLockOn
                NvdaModifier.Insert ->
                    downKeys.contains(KeyEvent.KEYCODE_INSERT)
            }
            if (baseDown) {
                bridge.setForwarding(!bridge.forwarding.value)
                return true
            }
        }

        when (action) {
            KeyEvent.ACTION_DOWN -> downKeys.add(keyCode)
            KeyEvent.ACTION_UP -> downKeys.remove(keyCode)
        }

        if (!bridge.forwarding.value) return false

        val vk = KeyMap.vk(
            keyCode,
            leftAltMapping = settings.leftAltMapping,
            rightAltMapping = settings.rightAltMapping,
            metaMapping = settings.metaMapping,
        ) ?: return false // unmapped — let the system handle it

        when (action) {
            KeyEvent.ACTION_DOWN -> if (event.repeatCount == 0) bridge.sendKey(vk, true)
            KeyEvent.ACTION_UP -> bridge.sendKey(vk, false)
            else -> return false
        }
        return true // consume so neither the phone nor other apps act on the forwarded key
    }
}
