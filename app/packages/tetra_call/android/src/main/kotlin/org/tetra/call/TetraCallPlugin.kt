package org.tetra.call

import android.app.Activity
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
 * App -> native: incoming, connected, ended, pickRingtone.
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
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "incoming" -> {
                inCall = true
                overLockScreen(true)
                val shown = CallNotification.show(
                    context,
                    id = call.argument<String>("id") ?: "",
                    name = call.argument<String>("name") ?: "",
                    sub = call.argument<String>("sub"),
                    emergency = call.argument<Boolean>("emergency") ?: false,
                    ringtone = call.argument<String>("ringtone"),
                )
                result.success(shown)
            }
            // Answered (here or in the app): stop ringing, the app shows the call.
            "connected" -> {
                CallNotification.cancel(context)
                result.success(null)
            }
            "ended" -> {
                CallNotification.cancel(context)
                inCall = false
                overLockScreen(false)
                result.success(null)
            }
            "pickRingtone" -> pickRingtone(call.argument<String>("current"), result)
            else -> result.notImplemented()
        }
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
        if (inCall) overLockScreen(true)
        handle(binding.activity.intent)
    }

    override fun onDetachedFromActivity() {
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
            CallNotification.cancel(ctx)
            main.post { channel?.invokeMethod("answer", id) }
        }

        fun decline(ctx: Context, id: String?) {
            CallNotification.cancel(ctx)
            main.post { channel?.invokeMethod("end", id) }
        }
    }
}
