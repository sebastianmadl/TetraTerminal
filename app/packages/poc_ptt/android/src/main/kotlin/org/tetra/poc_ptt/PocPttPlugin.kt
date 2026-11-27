package org.tetra.poc_ptt

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.view.KeyEvent
import android.view.Window
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Hardware PTT on Android PoC radios. Three inputs, all optional:
 *  - a key code (learned in the settings): seen by the app window while it is
 *    in front, and by [PocPttKeyService] when the user enabled it;
 *  - a pair of broadcast actions some radios send for their PTT key;
 *  - the app's own actions [ACTION_DOWN] / [ACTION_UP] for automation tools.
 * "Wake" brings the app to the front (and over the lock screen) on a press.
 */
class PocPttPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var activity: Activity? = null
    private var wrappedWindow: Window? = null
    private var receiver: BroadcastReceiver? = null
    private var downAction: String? = null
    private var upAction: String? = null
    private var wake = false

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        methods = MethodChannel(b.binaryMessenger, "org.tetra/poc_ptt")
        methods.setMethodCallHandler(this)
        events = EventChannel(b.binaryMessenger, "org.tetra/poc_ptt/events")
        events.setStreamHandler(this)
        PocPttHub.onPress = { if (wake) bringToFront() }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        stop()
        PocPttHub.onPress = null
        PocPttHub.emit = null
        tts?.shutdown()
        tts = null
        ttsReady = false
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    override fun onListen(args: Any?, s: EventChannel.EventSink) {
        PocPttHub.emit = { m -> s.success(m) }
    }

    override fun onCancel(args: Any?) {
        PocPttHub.emit = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> {
                configure(
                    call.argument<Int>("keyCode") ?: 0,
                    call.argument<String>("downAction"),
                    call.argument<String>("upAction"),
                    call.argument<Boolean>("wake") ?: false,
                )
                PocPttHub.knobNextKey = call.argument<Int>("knobNextKey") ?: 0
                PocPttHub.knobPrevKey = call.argument<Int>("knobPrevKey") ?: 0
                result.success(null)
            }
            "stop" -> { stop(); result.success(null) }
            "learn" -> { PocPttHub.learning = call.argument<Boolean>("on") ?: false; result.success(null) }
            "keyServiceEnabled" -> result.success(keyServiceEnabled())
            "keyServiceAvailable" -> result.success(keyServiceAvailable())
            "lastSeen" -> result.success(PocPttHub.lastSeen)
            "speak" -> { speak(call.argument<String>("text") ?: ""); result.success(null) }
            "led" -> result.success(setLed(call.argument<String>("state") ?: "off"))
            "openKeyServiceSettings" -> {
                context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun configure(keyCode: Int, down: String?, up: String?, wakeOnPress: Boolean) {
        PocPttHub.keyCode = keyCode
        PocPttHub.enabled = true
        wake = wakeOnPress
        applyWake()
        val d = down?.trim()?.takeIf { it.isNotEmpty() }
        val u = up?.trim()?.takeIf { it.isNotEmpty() }
        if (receiver != null && d == downAction && u == upAction) return
        unregister()
        downAction = d
        upAction = u
        val filter = IntentFilter().apply {
            addAction(ACTION_DOWN)
            addAction(ACTION_UP)
            d?.let { addAction(it) }
            u?.let { addAction(it) }
            KEY_BROADCASTS.forEach { addAction(it) }
            KNOB_NEXT_BROADCASTS.forEach { addAction(it) }
            KNOB_PREV_BROADCASTS.forEach { addAction(it) }
        }
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                val action = i.action ?: return
                when (action) {
                    ACTION_DOWN, downAction -> PocPttHub.setPressed(true, "broadcast")
                    ACTION_UP, upAction -> PocPttHub.setPressed(false, "broadcast")
                    in KNOB_NEXT_BROADCASTS -> PocPttHub.knobStep(1)
                    in KNOB_PREV_BROADCASTS -> PocPttHub.knobStep(-1)
                    in KEY_BROADCASTS -> {
                        // Key code and KeyEvent action (0 = down, 1 = up) as int extras.
                        // The channel knob reports its direction in "action" instead.
                        val code = i.getIntExtra("keycode", 0).takeIf { it != 0 } ?: i.getIntExtra("keyCode", 0)
                        val keyAction = i.getIntExtra("action", -1)
                        PocPttHub.lastSeen = "broadcast key $code action $keyAction"
                        if (keyAction in PocPttHub.KNOB_NEXT_CODES) {
                            PocPttHub.knobStep(1)
                        } else if (keyAction in PocPttHub.KNOB_PREV_CODES) {
                            PocPttHub.knobStep(-1)
                        } else if (code != 0 && (keyAction == KeyEvent.ACTION_DOWN || keyAction == KeyEvent.ACTION_UP)) {
                            PocPttHub.handleBroadcastKey(code, keyAction == KeyEvent.ACTION_DOWN)
                        }
                    }
                }
            }
        }
        // Exported: the radio's own system app sends these.
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(r, filter, Context.RECEIVER_EXPORTED)
        else context.registerReceiver(r, filter)
        receiver = r
    }

    private fun stop() {
        PocPttHub.enabled = false
        PocPttHub.learning = false
        PocPttHub.releaseIfPressed("stop")
        setLed("off")
        wake = false
        applyWake()
        unregister()
    }

    private fun unregister() {
        receiver?.let { runCatching { context.unregisterReceiver(it) } }
        receiver = null
        downAction = null
        upAction = null
    }

    // ── Spoken talkgroup name ────────────────────────────────────────────────

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsPending: String? = null

    /** Speaks [text] with the device's text-to-speech engine, in the device language. A newer text replaces the one being spoken. */
    private fun speak(text: String) {
        if (text.isEmpty()) return
        if (tts == null) {
            ttsPending = text
            tts = TextToSpeech(context) { status ->
                ttsReady = status == TextToSpeech.SUCCESS
                if (ttsReady) {
                    runCatching { tts?.setLanguage(Locale.getDefault()) }
                    ttsPending?.let { say(it) }
                }
                ttsPending = null
            }
        } else if (ttsReady) {
            say(text)
        } else {
            ttsPending = text
        }
    }

    private fun say(text: String) {
        runCatching { tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "talkgroup") }
    }

    // ── Status LED (Hytera PoC radios) ───────────────────────────────────────

    private var ledManager: Any? = null
    private var ledSet: java.lang.reflect.Method? = null
    private var ledUnavailable = false
    private var ledOn = 0

    /**
     * Shows transmit ("tx") / receive ("rx") on the radio's status LED, "off"
     * otherwise. Uses the vendor's settings manager of Hytera PoC firmware
     * through reflection; returns false where that does not exist or refuses.
     */
    private fun setLed(state: String): Boolean {
        if (ledUnavailable) return false
        val want = when (state) { "tx" -> LED_POC_SEND; "rx" -> LED_POC_RECEIVE; else -> 0 }
        return try {
            if (ledSet == null) {
                val cls = Class.forName("com.dream.autosdk.UserSettingManager")
                ledManager = cls.getDeclaredMethod("getInstance").apply { isAccessible = true }.invoke(null)
                ledSet = cls.getDeclaredMethod("setLedFlashingMode", Int::class.javaPrimitiveType, Boolean::class.javaPrimitiveType)
                    .apply { isAccessible = true }
            }
            if (want != ledOn) {
                if (ledOn != 0) ledSet!!.invoke(ledManager, ledOn, false)
                if (want != 0) ledSet!!.invoke(ledManager, want, true)
                ledOn = want
            }
            true
        } catch (e: Throwable) {
            ledUnavailable = true
            false
        }
    }

    /** False in the phone build, which ships without the Accessibility service. */
    private fun keyServiceAvailable(): Boolean = try {
        context.packageManager.getServiceInfo(ComponentName(context, PocPttKeyService::class.java), 0)
        true
    } catch (e: Throwable) {
        false
    }

    private fun keyServiceEnabled(): Boolean {
        val me = ComponentName(context, PocPttKeyService::class.java).flattenToString()
        val list = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return list.split(':').any { it.equals(me, ignoreCase = true) }
    }

    // ── Wake & focus ─────────────────────────────────────────────────────────

    private fun applyWake() {
        val a = activity ?: return
        if (Build.VERSION.SDK_INT >= 27) {
            a.setShowWhenLocked(wake)
            a.setTurnScreenOn(wake)
        }
    }

    private fun bringToFront() {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        // Allowed from the background while our accessibility service is bound.
        runCatching { context.startActivity(launch) }
    }

    // ── Key events while the app window has focus ────────────────────────────

    override fun onAttachedToActivity(b: ActivityPluginBinding) = attach(b.activity)
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = attach(b.activity)
    override fun onDetachedFromActivityForConfigChanges() = detach()
    override fun onDetachedFromActivity() = detach()

    private fun attach(a: Activity) {
        activity = a
        val w = a.window
        val base = w.callback
        if (base !is KeyCallback) w.callback = KeyCallback(base)
        wrappedWindow = w
        applyWake()
    }

    private fun detach() {
        val w = wrappedWindow
        val cb = w?.callback
        if (cb is KeyCallback) w.callback = cb.base
        wrappedWindow = null
        activity = null
    }

    private class KeyCallback(val base: Window.Callback) : Window.Callback by base {
        override fun dispatchKeyEvent(event: KeyEvent): Boolean =
            PocPttHub.handleKey(event) || base.dispatchKeyEvent(event)
    }

    companion object {
        const val ACTION_DOWN = "org.tetra.terminal.ptt.DOWN"
        const val ACTION_UP = "org.tetra.terminal.ptt.UP"

        /** Radios whose firmware reports every hardware key as a broadcast (Hytera P60 and relatives). */
        val KEY_BROADCASTS = setOf(
            "com.meigsmart.meigkeyaccessibility.onkeyevent",
            "key.intent.action.onkeyevent",
            "dream.intent.action.KEY_SW",
        )
        /** Radios that send one broadcast per knob click. */
        val KNOB_NEXT_BROADCASTS = setOf("com.android.knob.add")
        val KNOB_PREV_BROADCASTS = setOf("com.android.knob.sub")
        // LED modes of the vendor settings manager.
        private const val LED_POC_SEND = 19
        private const val LED_POC_RECEIVE = 20
    }
}
