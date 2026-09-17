package app.brege.controls

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import app.brege.BregeApplication
import app.brege.R

/**
 * Silencing the phone from the Mac needs Do Not Disturb access, and a background app cannot open
 * the settings itself. So the phone asks with a notification that opens the right screen.
 */
object ControlsAccessNotice {
    private const val ID = 4821
    private var lastShownMs = 0L

    fun show(context: Context) {
        // One reminder per minute is plenty, however often the Mac tries.
        val now = System.currentTimeMillis()
        if (now - lastShownMs < 60_000) return
        lastShownMs = now
        val intent = Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val notification = NotificationCompat.Builder(context, BregeApplication.CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_brege)
            .setContentTitle("Allow Brêge to silence this phone")
            .setContentText("Your Mac asked to change the sound. Tap to allow Do Not Disturb access.")
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(
                PendingIntent.getActivity(
                    context, ID, intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            )
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(ID, notification) }
    }
}
