package app.brege.mic

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Bundle
import android.os.IBinder
import android.os.Process
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.brege.BregeApplication
import app.brege.R
import app.brege.camera.CameraService
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog

/**
 * Phone as Mac microphone: records 48 kHz mono PCM and sends 10 ms frames to the
 * Mac as QUIC datagrams. Android only allows starting microphone capture while the user interacts
 * with the app, so a request from the Mac goes through a notification the user taps.
 */
class MicService : Service() {
    @Volatile private var running = false
    private var thread: Thread? = null
    /// The reason capture stopped, so the final state does not replace it with an empty one.
    @Volatile private var failure: String? = null
    /// The Mac that asked for the microphone; null when started in the app (state and audio go to every Mac).
    @Volatile private var mac: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        val requester = intent?.getStringExtra(EXTRA_MAC)?.ifEmpty { null }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Core.node?.publishMicState(false, 0u, "Allow microphone access for Brêge on your phone", requester)
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } catch (e: Exception) {
            // Started from the background without a user interaction.
            UptimeLog.record("mic: foreground start refused: ${e.javaClass.simpleName}")
            Core.node?.publishMicState(false, 0u, "Tap the Brêge notification on your phone", requester)
            stopSelf()
            return START_NOT_STICKY
        }
        mac = requester
        owner = requester
        running = true
        active = true
        // A camera recording with sound hands the microphone over; see onMicStopped.
        CameraService.onMicStarted()
        thread = Thread(::capture, "brege-mic").apply { start() }
        UptimeLog.record("mic: started")
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        active = false
        owner = null
        thread?.join(500)
        thread = null
        Core.node?.publishMicState(false, 0u, failure ?: "", mac)
        // A camera recording with sound takes the microphone over.
        CameraService.onMicStopped()
        UptimeLog.record("mic: stopped")
        super.onDestroy()
    }

    @SuppressLint("MissingPermission") // checked in onStartCommand
    private fun capture() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val frameBytes = SAMPLE_RATE / 100 * 2 // 10 ms of 16-bit mono
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val record = try {
            // Voice communication enables echo cancellation and noise suppression.
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuffer, frameBytes * 4),
            )
        } catch (e: Exception) {
            UptimeLog.record("mic: AudioRecord failed: ${e.javaClass.simpleName}")
            fail("The phone's microphone is not available")
            stopSelf()
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            fail("The phone's microphone is in use")
            stopSelf()
            return
        }
        val buffer = ByteArray(frameBytes)
        var sentFrames = 0L
        try {
            record.startRecording()
            Core.node?.publishMicState(true, SAMPLE_RATE.toUInt(), "", mac)
            while (running) {
                var filled = 0
                while (filled < frameBytes && running) {
                    val n = record.read(buffer, filled, frameBytes - filled)
                    if (n < 0) throw IllegalStateException("read error $n")
                    filled += n
                }
                if (!running) break
                val node = Core.node ?: break
                if (node.sendMicFrame(buffer, mac) > 0u) sentFrames++
            }
        } catch (e: Exception) {
            UptimeLog.record("mic: capture stopped: ${e.javaClass.simpleName}")
        } finally {
            runCatching { record.stop() }
            record.release()
            UptimeLog.record("mic: sent ${sentFrames / 100} s of audio")
        }
    }

    private fun fail(detail: String) {
        failure = detail
        Core.node?.publishMicState(false, 0u, detail, mac)
        running = false
    }

    private fun notification() = NotificationCompat.Builder(this, BregeApplication.CHANNEL_SERVICE)
        .setSmallIcon(R.drawable.ic_brege)
        .setContentTitle("Microphone in use by your Mac")
        .setContentText("Brêge is sending this phone's microphone to your Mac")
        .setOngoing(true)
        .setSilent(true)
        .addAction(
            R.drawable.ic_brege, "Stop",
            PendingIntent.getService(
                this, 3, Intent(this, MicService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ),
        )
        .build()

    companion object {
        const val SAMPLE_RATE = 48_000
        private const val NOTIFICATION_ID = 7
        private const val REQUEST_NOTIFICATION_ID = 8
        const val ACTION_STOP = "app.brege.MIC_STOP"
        const val EXTRA_MAC = "mac"

        /** True while the phone is sending its microphone to the Mac. */
        @Volatile var active = false
            private set

        /** The Mac the running microphone belongs to; null when started in the app. */
        @Volatile private var owner: String? = null

        /** The Mac whose request notification is showing. */
        @Volatile private var pendingRequester: String? = null

        /** Starts from the Brêge app itself (a user interaction, so no notification is needed). */
        fun startFromApp(context: Context) {
            context.getSystemService(NotificationManager::class.java).cancel(REQUEST_NOTIFICATION_ID)
            pendingRequester = null
            context.startActivity(Intent(context, MicStartActivity::class.java))
        }

        /** The Mac asked for the microphone: start directly if possible, else ask the user. */
        fun requestFromMac(context: Context, mac: String) {
            if (active) {
                val current = owner
                if (current != null && current != mac) {
                    Core.node?.publishMicState(false, 0u, "The microphone is in use by another Mac", mac)
                    UptimeLog.record("mic: request refused, in use by another Mac")
                } else {
                    Core.node?.publishMicState(true, SAMPLE_RATE.toUInt(), "", current)
                }
                return
            }
            pendingRequester = mac
            val intent = Intent(context, MicStartActivity::class.java).putExtra(EXTRA_MAC, mac).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val tap = PendingIntent.getActivity(context, 4, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val notification = NotificationCompat.Builder(context, BregeApplication.CHANNEL_EVENTS)
                .setSmallIcon(R.drawable.ic_brege)
                .setContentTitle("Use this phone as your Mac's microphone?")
                .setContentText("Tap to start the microphone")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setAutoCancel(true)
                .setContentIntent(tap)
                .setTimeoutAfter(5 * 60_000)
                .build()
            context.getSystemService(NotificationManager::class.java).notify(REQUEST_NOTIFICATION_ID, notification)
            Core.node?.publishMicState(false, 0u, "Tap the Brêge notification on your phone to start", mac)
            UptimeLog.record("mic: requested by Mac, waiting for tap")
        }

        fun stop(context: Context) {
            context.getSystemService(NotificationManager::class.java).cancel(REQUEST_NOTIFICATION_ID)
            pendingRequester = null
            context.stopService(Intent(context, MicService::class.java))
        }

        /** A stop from a Mac only applies to its own microphone (or one started in the app). */
        fun stopFromMac(context: Context, mac: String) {
            val current = owner
            if (active && current != null && current != mac) {
                UptimeLog.record("mic: stop from another Mac ignored")
                return
            }
            if (!active) {
                // Only withdraw this Mac's own pending request.
                val pending = pendingRequester
                if (pending != null && pending != mac) return
            }
            stop(context)
        }
    }
}

/**
 * Transparent activity opened from the notification: the user interaction lets the
 * microphone foreground service start, and it can ask for the RECORD_AUDIO permission.
 */
class MicStartActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            startMic()
        } else if (savedInstanceState == null) {
            // Recreated (e.g. rotated) while the dialog shows: its result arrives to this instance.
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // Empty results mean the request was interrupted, not denied; a new one follows.
        if (grantResults.isEmpty()) return
        if (grantResults.first() == PackageManager.PERMISSION_GRANTED) {
            startMic()
        } else {
            Core.node?.publishMicState(
                false, 0u, "Microphone permission was denied on the phone", intent.getStringExtra(MicService.EXTRA_MAC),
            )
            finish()
        }
    }

    private fun startMic() {
        val service = Intent(this, MicService::class.java)
        intent.getStringExtra(MicService.EXTRA_MAC)?.let { service.putExtra(MicService.EXTRA_MAC, it) }
        ContextCompat.startForegroundService(this, service)
        finish()
    }
}
