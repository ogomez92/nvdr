package com.oriolgomez.nvdr.input

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import com.oriolgomez.nvdr.NvdrApp

/**
 * System-wide hardware-key capture via accessibility key-event filtering
 * (`flagRequestFilterKeyEvents`). This runs at the input-filter layer — earlier
 * than the window manager — so when forwarding is on it can swallow combos
 * Android would otherwise intercept (Alt+Tab, the Meta/Windows key, …) before
 * the system acts on them. The Android analog of the macOS `CGEventTap`.
 *
 * Enabling it is optional; without it the app still does focused-only capture.
 */
class NvdrAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        setRunning(true)
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        val app = application as? NvdrApp ?: return false
        return KeyForwarder.handle(app.container, event)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        setRunning(false)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        setRunning(false)
        super.onDestroy()
    }

    private fun setRunning(running: Boolean) {
        (application as? NvdrApp)?.container?.accessibilityRunning?.value = running
    }
}
