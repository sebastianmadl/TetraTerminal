package org.tetra.poc_ptt

import android.accessibilityservice.AccessibilityService
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

/**
 * Receives hardware key events system-wide, so the PTT key also works with the
 * app in the background or the screen locked. Only the configured PTT key (or
 * the key being learned) is consumed; every other key passes through.
 */
class PocPttKeyService : AccessibilityService() {
    override fun onServiceConnected() {
        running = true
    }

    override fun onKeyEvent(event: KeyEvent): Boolean = PocPttHub.handleKey(event)

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {
        PocPttHub.releaseIfPressed("key")
    }

    override fun onDestroy() {
        running = false
        PocPttHub.releaseIfPressed("key")
        super.onDestroy()
    }

    companion object {
        @Volatile var running = false
    }
}
