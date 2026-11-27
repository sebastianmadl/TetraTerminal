package org.tetra.call

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.PowerManager
import android.content.Context
import android.content.Intent
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Channel "tetra/call": an incoming private call rings like a phone call, with
 * a call notification (Answer / Decline) that opens full screen over the lock
 * screen. Works while the app is running; the ongoing radio notification keeps
 * it running in the background.
 *
 * While the app is on screen it only rings (RingPlayer) and the app's call
 * screen shows the call. An incoming text message plays the notification
 * tone, with a notification when the app is not on screen.
 *
 * App -> native: incoming, connected, ended, message, pickRingtone.
 * Native -> app: answer, end.
 */
class TetraCallPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, PluginRegistry.NewIntentListener,
    PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    /** A call is ringing or running: the app may show over the lock screen. */
    private var inCall = false
    private var pickResult: MethodChannel.Result? = null

    private class Ring(val id: String, val name: String, val sub: String?, val emergency: Boolean, val ringtone: String?, val labels: List<String>?)
    /** The call that is ringing right now. */
    private var ring: Ring? = null
    /** The app's screen is in front. */
    private var resumed = false
    private var silenced = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        val ch = MethodChannel(binding.binaryMessenger, "tetra/call")
        ch.setMethodCallHandler(this)
        channel = ch
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        CallNotification.cancel(context)
        RingPlayer.stop()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "incoming" -> {
                inCall = true
                overLockScreen(true)
                ring = Ring(
                    id = call.argument<String>("id") ?: "",
                    name = call.argument<String>("name") ?: "",
                    sub = call.argument<String>("sub"),
                    emergency = call.argument<Boolean>("emergency") ?: false,
                    ringtone = call.argument<String>("ringtone"),
                    labels = call.argument<List<String>>("labels"),
                )
                silenced = false
                result.success(startRinging())
            }
            // Answered (here or in the app): stop ringing, the app shows the call.
            "connected" -> {
                stopRinging()
                result.success(null)
            }
            "ended" -> {
                stopRinging()
                inCall = false
                overLockScreen(false)
                result.success(null)
            }
            "message" -> {
                val title = call.argument<String>("title") ?: ""
                val text = call.argument<String>("text") ?: ""
                if (resumed) MessageNotification.sound(context) else MessageNotification.show(context, call.argument<Int>("peer") ?: 0, title, text)
                result.success(null)
            }
            "messagePermission" -> result.success(null)
            "pickRingtone" -> pickRingtone(call.argument<String>("current"), result)
            else -> result.notImplemented()
        }
    }

    /**
     * App on screen: it shows the call itself, so it only rings. Otherwise
     * the call notification rings and opens the app over the lock screen.
     */
    private fun startRinging(): Boolean {
        val r = ring ?: return false
        if (resumed) {
            CallNotification.cancel(context)
            RingPlayer.start(context, r.ringtone)
            return true
        }
        RingPlayer.stop()
        return CallNotification.show(context, r.id, r.name, r.sub, r.emergency, r.ringtone, r.labels)
    }

    private fun stopRinging() {
        ring = null
        RingPlayer.stop()
        CallNotification.cancel(context)
    }

    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(a: Activity) {
            if (a !== activity) return
            resumed = true
            // Opened from the notification: the call screen takes over.
            if (ring != null && !silenced) startRinging()
        }

        override fun onActivityPaused(a: Activity) {
            if (a !== activity) return
            resumed = false
            if (ring == null || silenced) return
            val interactive = (context.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.isInteractive ?: true
            if (interactive) {
                // The user left the app while it rings: carry on as a notification.
                startRinging()
            } else {
                // Power key while ringing: silence it, like a phone does.
                silenced = true
                RingPlayer.stop()
            }
        }

        override fun onActivityCreated(a: Activity, b: Bundle?) {}
        override fun onActivityStarted(a: Activity) {}
        override fun onActivityStopped(a: Activity) {}
        override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
        override fun onActivityDestroyed(a: Activity) {}
    }

    /** The system's ring tone picker; answers {uri, title} or null when cancelled. */
    private fun pickRingtone(current: String?, result: MethodChannel.Result) {
        val a = activity ?: return result.error("unavailable", "no screen", null)
        pickResult?.success(null)
        pickResult = result
        val existing = current?.let { Uri.parse(it) } ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val i = Intent(RingtoneManager.ACTION_RINGTONE_PICKER)
            .putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, RingtoneManager.TYPE_RINGTONE)
            .putExtra(RingtoneManager.EXTRA_RINGTONE_TITLE, "Ring tone")
            .putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
            .putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, false)
            .putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, existing)
        try {
            a.startActivityForResult(i, PICK_REQUEST)
        } catch (e: Exception) {
            // Some radios ship without the picker.
            pickResult = null
            result.error("unavailable", "This device has no ring tone picker", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST) return false
        val result = pickResult ?: return true
        pickResult = null
        @Suppress("DEPRECATION")
        val uri: Uri? = if (resultCode == Activity.RESULT_OK) data?.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI) else null
        if (uri == null) {
            result.success(null)
            return true
        }
        val title = try {
            RingtoneManager.getRingtone(context, uri)?.getTitle(context)
        } catch (_: Exception) {
            null
        }
        result.success(mapOf("uri" to uri.toString(), "title" to (title ?: "Ring tone")))
        return true
    }

    /** Lets the app's screen come up over the lock screen for the call. */
    private fun overLockScreen(on: Boolean) {
        val a = activity ?: return
        try {
            if (Build.VERSION.SDK_INT >= 27) {
                a.setShowWhenLocked(on)
                a.setTurnScreenOn(on)
            } else {
                @Suppress("DEPRECATION")
                val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                if (on) a.window.addFlags(flags) else a.window.clearFlags(flags)
            }
        } catch (_: Exception) {}
    }

    // The Answer button opens the app with ACTION_ANSWER.
    override fun onNewIntent(intent: Intent): Boolean = handle(intent)

    private fun handle(intent: Intent?): Boolean {
        if (intent?.action != CallNotification.ACTION_ANSWER) return false
        val id = intent.getStringExtra(CallNotification.EXTRA_ID)
        // Handle it once, also when the activity is created again later.
        intent.action = Intent.ACTION_MAIN
        answer(context, id)
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        activity = binding.activity
        binding.addOnNewIntentListener(this)
        binding.addActivityResultListener(this)
        binding.activity.application.registerActivityLifecycleCallbacks(lifecycle)
        if (inCall) overLockScreen(true)
        handle(binding.activity.intent)
    }

    override fun onDetachedFromActivity() {
        activity?.application?.unregisterActivityLifecycleCallbacks(lifecycle)
        resumed = false
        binding?.removeOnNewIntentListener(this)
        binding?.removeActivityResultListener(this)
        binding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    companion object {
        private const val PICK_REQUEST = 4713
        private val main = Handler(Looper.getMainLooper())
        @Volatile var channel: MethodChannel? = null

        fun answer(ctx: Context, id: String?) {
            RingPlayer.stop()
            CallNotification.cancel(ctx)
            main.post { channel?.invokeMethod("answer", id) }
        }

        fun decline(ctx: Context, id: String?) {
            RingPlayer.stop()
            CallNotification.cancel(ctx)
            main.post { channel?.invokeMethod("end", id) }
        }
    }
}
