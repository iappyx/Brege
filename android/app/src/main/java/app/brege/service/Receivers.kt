package app.brege.service

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.content.edit
import app.brege.BregeApplication
import app.brege.R
import app.brege.companion.BleWake
import app.brege.hotspot.HotspotRequests

/** Starts the service after boot and app updates (both allowed for connectedDevice). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                // Background scans do not survive a reboot; register them even if the service start is refused.
                HotspotRequests.register(context)
                BleWake.register(context)
                BregeService.start(context, intent.action!!.substringAfterLast('.'))
            }
        }
    }
}

/** Notification actions such as "Stop ringing". */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_STOP_RING) RingPlayer.stop(context)
    }

    companion object {
        const val ACTION_STOP_RING = "app.brege.STOP_RING"
    }
}

/** "Ring my phone": alarm stream at full volume for 30 s. */
object RingPlayer {
    private const val PREFS = "ring"
    /** The alarm volume before ringing, kept on disk so a restarted process can still restore it. */
    private const val KEY_PREVIOUS_VOLUME = "previous_alarm_volume"
    private var player: MediaPlayer? = null
    private var appContext: Context? = null
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { appContext?.let(::stopNow) }

    fun start(context: Context) = handler.post {
        if (player != null) return@post
        val context = context.applicationContext
        appContext = context
        val audio = context.getSystemService(AudioManager::class.java)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // A value left by a ring that never stopped (process killed) is the real previous volume.
        if (!prefs.contains(KEY_PREVIOUS_VOLUME)) {
            prefs.edit(commit = true) { putInt(KEY_PREVIOUS_VOLUME, audio.getStreamVolume(AudioManager.STREAM_ALARM)) }
        }
        runCatching {
            audio.setStreamVolume(AudioManager.STREAM_ALARM, audio.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        }
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val started = runCatching {
            MediaPlayer().apply {
                player = this
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(context, uri ?: Settings.System.DEFAULT_RINGTONE_URI)
                isLooping = true
                prepare()
                start()
            }
        }
        if (started.isFailure) {
            // No playable alarm or ringtone: put the volume back instead of crashing.
            stopNow(context)
            return@post
        }
        handler.postDelayed(timeout, 30_000)
        showNotification(context)
    }

    /** Lets the person who found the phone silence it. */
    private fun showNotification(context: Context) {
        val stop = PendingIntent.getBroadcast(
            context, 0,
            Intent(context, ActionReceiver::class.java).setAction(ActionReceiver.ACTION_STOP_RING),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, BregeApplication.CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_brege)
            .setContentTitle("Ringing from your Mac")
            .setContentText("Tap Stop to silence this phone")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setOngoing(true)
            .setContentIntent(stop)
            .addAction(R.drawable.ic_brege, "Stop", stop)
            .build()
        runCatching { context.getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification) }
    }

    /** Stops ringing (from the Mac, the notification or after 30 s) and restores the alarm volume. */
    fun stop(context: Context) {
        val app = context.applicationContext
        handler.post { stopNow(app) }
    }

    private fun stopNow(context: Context) {
        handler.removeCallbacks(timeout)
        player?.run { runCatching { stop() }; release() }
        player = null
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.contains(KEY_PREVIOUS_VOLUME)) {
            val volume = prefs.getInt(KEY_PREVIOUS_VOLUME, 0)
            runCatching {
                context.getSystemService(AudioManager::class.java)
                    .setStreamVolume(AudioManager.STREAM_ALARM, volume, 0)
            }
            prefs.edit { remove(KEY_PREVIOUS_VOLUME) }
        }
        runCatching { context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID) }
    }

    private const val NOTIFICATION_ID = 15
}
