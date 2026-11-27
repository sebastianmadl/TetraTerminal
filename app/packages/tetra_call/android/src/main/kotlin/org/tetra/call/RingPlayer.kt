package org.tetra.call

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log

/**
 * Rings inside the app: used while the app is on screen, where the call
 * screen shows the call and a call notification on top would only double it.
 * Follows the ringer mode like the notification does (silent: nothing,
 * vibrate: vibration only).
 */
object RingPlayer {
    private const val TAG = "TetraCall"
    private val PATTERN = longArrayOf(0, 800, 600, 800, 1200)
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null

    val ringing: Boolean get() = player != null || vibrator != null

    private fun attributes() = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    fun start(ctx: Context, ringtone: String?) {
        stop()
        val mode = (ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.ringerMode ?: AudioManager.RINGER_MODE_NORMAL
        if (mode == AudioManager.RINGER_MODE_SILENT) return
        try {
            @Suppress("DEPRECATION")
            val v = ctx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            if (v != null && v.hasVibrator()) {
                if (Build.VERSION.SDK_INT >= 26) {
                    v.vibrate(VibrationEffect.createWaveform(PATTERN, 0), attributes())
                } else {
                    @Suppress("DEPRECATION")
                    v.vibrate(PATTERN, 0)
                }
                vibrator = v
            }
        } catch (e: Exception) {
            Log.w(TAG, "no vibration: $e")
        }
        if (mode != AudioManager.RINGER_MODE_NORMAL) return
        val uri = ringtone?.let { Uri.parse(it) } ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE) ?: return
        try {
            player = MediaPlayer().apply {
                setAudioAttributes(attributes())
                setDataSource(ctx, uri)
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            Log.w(TAG, "ring tone not playable: $e")
            player = null
        }
    }

    fun stop() {
        try {
            player?.stop()
            player?.release()
        } catch (_: Exception) {}
        player = null
        try {
            vibrator?.cancel()
        } catch (_: Exception) {}
        vibrator = null
    }
}
