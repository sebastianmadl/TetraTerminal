package org.tetra.poc_ptt

import android.os.Handler
import android.os.Looper
import android.view.KeyEvent

/**
 * Shared state between the plugin (Flutter side) and the accessibility
 * service (system side): which key is the PTT, whether we are learning a key,
 * and where press/release events go. Everything runs on the main thread.
 */
object PocPttHub {
    private val main = Handler(Looper.getMainLooper())

    /** Android key code of the PTT key; 0 = no key configured. */
    @Volatile var keyCode: Int = 0
    /** Key codes a rotary knob sends per detent (next / previous talkgroup); 0 = none. */
    @Volatile var knobNextKey: Int = 0
    @Volatile var knobPrevKey: Int = 0
    /** True while the settings screen waits for "press your PTT key now". */
    @Volatile var learning: Boolean = false
    @Volatile var enabled: Boolean = false

    /** Sends one event map to Dart (set by the plugin while it listens). */
    var emit: ((Map<String, Any?>) -> Unit)? = null
    /** Called on every press, before it is emitted (wake & focus). */
    var onPress: (() -> Unit)? = null

    private var pressed = false

    /** Returns true if the key event was ours and must not reach other apps. */
    fun handleKey(event: KeyEvent): Boolean =
        handleKeyCode(event.keyCode, event.action == KeyEvent.ACTION_DOWN, event.repeatCount > 0, event.action == KeyEvent.ACTION_UP)

    /**
     * One key transition, from a [KeyEvent] or from a radio's key broadcast
     * (see [PocPttPlugin.KEY_BROADCASTS]). Returns true if the key was ours.
     */
    fun handleKeyCode(code: Int, down: Boolean, repeat: Boolean = false, up: Boolean = !down): Boolean {
        if (learning) {
            if (down && !repeat && isLearnable(code)) {
                learning = false
                send(mapOf("type" to "learned", "keyCode" to code))
                return true
            }
            return false
        }
        if (!enabled || code == 0) return false
        if (code == knobNextKey || code == knobPrevKey) {
            if (down) send(mapOf("type" to "knob", "step" to if (code == knobNextKey) 1 else -1))
            return true
        }
        if (code != keyCode) return false
        if (down && !repeat) setPressed(true, "key") else if (up) setPressed(false, "key")
        return true
    }

    /**
     * A key reported by the radio's firmware as a broadcast. Until the user
     * has taught other keys, the firmware's own codes for the PTT key and the
     * channel knob work as they are, so such a radio needs no setup.
     */
    fun handleBroadcastKey(code: Int, down: Boolean) {
        if (!learning && enabled) {
            if (keyCode == 0 && code == FIRMWARE_PTT_KEY) {
                setPressed(down, "key")
                return
            }
            if (knobNextKey == 0 && knobPrevKey == 0 && (code in FIRMWARE_KNOB_NEXT || code in FIRMWARE_KNOB_PREV)) {
                if (down) send(mapOf("type" to "knob", "step" to if (code in FIRMWARE_KNOB_NEXT) 1 else -1))
                return
            }
        }
        handleKeyCode(code, down)
    }

    // Key codes of Hytera PoC firmware: PTT, channel up / down (two generations).
    private const val FIRMWARE_PTT_KEY = 142
    private val FIRMWARE_KNOB_NEXT = setOf(166, 292)
    private val FIRMWARE_KNOB_PREV = setOf(167, 293)

    /** Press/release from any source; repeated presses are dropped. */
    fun setPressed(down: Boolean, source: String) {
        main.post {
            if (down == pressed) return@post
            pressed = down
            if (down) onPress?.invoke()
            emit?.invoke(mapOf("type" to "ptt", "pressed" to down, "source" to source))
        }
    }

    /** A source went away mid-press: let go so we never stay keyed. */
    fun releaseIfPressed(source: String) = setPressed(false, source)

    private fun send(m: Map<String, Any?>) = main.post { emit?.invoke(m) }

    // Keys that would make the phone unusable if taken over.
    private fun isLearnable(code: Int) = code != KeyEvent.KEYCODE_BACK && code != KeyEvent.KEYCODE_HOME &&
        code != KeyEvent.KEYCODE_POWER && code != KeyEvent.KEYCODE_APP_SWITCH && code != KeyEvent.KEYCODE_UNKNOWN
}
