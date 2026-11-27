package org.tetra.call

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.util.Log

/** The Decline button of the call notification. */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == CallNotification.ACTION_DECLINE) {
            TetraCallPlugin.decline(context, intent.getStringExtra(CallNotification.EXTRA_ID))
        }
    }
}

/**
 * The ringing call notification. Sound and vibration come from the
 * notification channel (the phone's ring tone, repeated until the call is
 * answered, declined or over), so the ringer mode and Do Not Disturb apply and
 * a channel keeps the sound it was created with: every chosen ring tone gets
 * its own channel and the previous one is removed.
 */
object CallNotification {
    const val ACTION_ANSWER = "org.tetra.call.ANSWER"
    const val ACTION_DECLINE = "org.tetra.call.DECLINE"
    const val EXTRA_ID = "org.tetra.call.ID"
    private const val TAG = "TetraCall"
    private const val ID = 4712
    private const val CHANNEL = "tetra_call"
    /** Stops by itself in case the app dies while it rings. */
    private const val TIMEOUT_MS = 90_000L

    private fun sound(ringtone: String?): Uri =
        ringtone?.let { Uri.parse(it) } ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)

    private fun channelId(ringtone: String?) =
        if (ringtone == null) CHANNEL else CHANNEL + "_" + Integer.toHexString(ringtone.hashCode())

    private fun ensureChannel(ctx: Context, ringtone: String?): String {
        val id = channelId(ringtone)
        if (Build.VERSION.SDK_INT < 26) return id
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return id
        for (c in nm.notificationChannels) {
            if (c.id != id && c.id.startsWith(CHANNEL)) nm.deleteNotificationChannel(c.id)
        }
        if (nm.getNotificationChannel(id) != null) return id
        nm.createNotificationChannel(NotificationChannel(id, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Rings for incoming private calls"
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            enableVibration(true)
            vibrationPattern = VIBRATION
            setSound(
                sound(ringtone),
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
        })
        return id
    }

    private val VIBRATION = longArrayOf(0, 800, 600, 800, 1200)

    private fun flags() = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

    /** Opens the app; with [action] set the app also answers the call. */
    private fun openApp(ctx: Context, requestCode: Int, id: String, action: String?): PendingIntent? {
        val i = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: return null
        i.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        if (action != null) {
            i.action = action
            i.removeCategory(Intent.CATEGORY_LAUNCHER)
            i.putExtra(EXTRA_ID, id)
        }
        return PendingIntent.getActivity(ctx, requestCode, i, flags())
    }

    /**
     * Shows the ringing notification; false when the system did not take it.
     * The buttons of the system call layout (Android 12+) are labelled by the
     * system in the device language.
     */
    fun show(ctx: Context, id: String, name: String, sub: String?, emergency: Boolean, ringtone: String?, labels: List<String>?): Boolean {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return false
        val channel = ensureChannel(ctx, ringtone)
        val open = openApp(ctx, 1, id, null)
        val answer = openApp(ctx, 2, id, ACTION_ANSWER)
        val decline = PendingIntent.getBroadcast(
            ctx, 3, Intent(ctx, CallActionReceiver::class.java).setAction(ACTION_DECLINE).putExtra(EXTRA_ID, id), flags())
        if (open == null || answer == null) return false
        // Texts in the app's language: headline, Answer, Decline.
        val headline = labels?.getOrNull(0) ?: if (emergency) "Emergency call" else "Incoming call"
        val answerLabel = labels?.getOrNull(1) ?: "Answer"
        val declineLabel = labels?.getOrNull(2) ?: "Decline"
        val text = listOfNotNull(headline, sub).joinToString(" · ")

        fun base(): Notification.Builder {
            @Suppress("DEPRECATION")
            val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, channel) else Notification.Builder(ctx)
            b.setSmallIcon(R.drawable.tetra_call_ic_phone)
                .setContentTitle(name)
                .setContentText(text)
                .setOngoing(true)
                .setAutoCancel(false)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_CALL)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setColor(if (emergency) Color.rgb(0xD7, 0x00, 0x15) else Color.rgb(0x1F, 0x8A, 0x70))
                .setContentIntent(open)
                .setFullScreenIntent(open, true)
            if (Build.VERSION.SDK_INT >= 26) {
                b.setTimeoutAfter(TIMEOUT_MS)
            } else {
                @Suppress("DEPRECATION")
                b.setPriority(Notification.PRIORITY_MAX)
                    .setVibrate(VIBRATION)
                    .setSound(sound(ringtone))
            }
            return b
        }

        fun post(n: Notification): Boolean = try {
            // Ring until the notification goes away.
            n.flags = n.flags or Notification.FLAG_INSISTENT
            nm.notify(ID, n)
            true
        } catch (e: Exception) {
            Log.w(TAG, "call notification refused: $e")
            false
        }

        // Android 12+: the system call layout with its Answer / Decline buttons.
        if (Build.VERSION.SDK_INT >= 31) {
            try {
                val person = Person.Builder().setName(name).setImportant(true).build()
                val n = base().setStyle(Notification.CallStyle.forIncomingCall(person, decline, answer)).build()
                if (post(n)) return true
            } catch (e: Exception) {
                Log.w(TAG, "no call style: $e")
            }
        }
        @Suppress("DEPRECATION")
        val n = base()
            .addAction(Notification.Action.Builder(null, declineLabel, decline).build())
            .addAction(Notification.Action.Builder(null, answerLabel, answer).build())
            .build()
        return post(n)
    }

    fun cancel(ctx: Context) {
        ctx.getSystemService(NotificationManager::class.java)?.cancel(ID)
    }
}
