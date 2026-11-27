package org.tetra.call

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.RingtoneManager
import android.os.Build
import android.util.Log

/** A received text message (SDS): notification with the phone's notification tone. */
object MessageNotification {
    private const val TAG = "TetraCall"
    private const val CHANNEL = "tetra_message"
    private const val BASE_ID = 4800

    /** App on screen: only the tone, the app shows the message itself. */
    fun sound(ctx: Context) {
        try {
            val mode = (ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.ringerMode
            if (mode != null && mode != AudioManager.RINGER_MODE_NORMAL) return
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION) ?: return
            RingtoneManager.getRingtone(ctx, uri)?.play()
        } catch (e: Exception) {
            Log.w(TAG, "no message tone: $e")
        }
    }

    fun show(ctx: Context, peer: Int, title: String, text: String) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Messages", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Received text messages (SDS)"
            })
        }
        val open = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.let {
            it.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            PendingIntent.getActivity(ctx, 10, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL) else Notification.Builder(ctx).setPriority(Notification.PRIORITY_HIGH).setDefaults(Notification.DEFAULT_ALL)
        val n = b.setSmallIcon(R.drawable.tetra_call_ic_message)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        try {
            // One notification per sender; a new message replaces the old one.
            nm.notify(BASE_ID + (peer and 0xFFFF), n)
        } catch (e: Exception) {
            Log.w(TAG, "message notification refused: $e")
        }
    }
}
