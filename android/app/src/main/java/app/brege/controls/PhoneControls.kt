package app.brege.controls

import android.app.AlarmManager
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.content.ContextCompat
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import app.brege.notifications.BregeNotificationListener
import uniffi.brege_ffi.ControlKind
import uniffi.brege_ffi.DndMode
import uniffi.brege_ffi.PhoneControlsData
import uniffi.brege_ffi.RingerMode
import uniffi.brege_ffi.VolumeStream

/**
 * Phone controls for the Mac: torch, ringer mode, volumes, Do Not Disturb, a short buzz and
 * clearing notifications. Only what a normal app may do; Wi‑Fi, Bluetooth and the like are
 * system-only and are not offered.
 *
 * State is published while a Mac is connected, so nothing runs in the background otherwise.
 */
object PhoneControls {
    /** A torch switched on from the Mac turns itself off again, so it cannot drain the phone. */
    private const val TORCH_AUTO_OFF_MS = 10 * 60 * 1000L

    private lateinit var app: Context
    private val handler = Handler(Looper.getMainLooper())
    private var receiver: BroadcastReceiver? = null
    private var torchCallback: CameraManager.TorchCallback? = null
    private var torchOn = false
    private var torchCameraId: String? = null
    private val torchOff = Runnable { setTorch(false) }

    private val camera by lazy { app.getSystemService(CameraManager::class.java) }
    private val audio by lazy { app.getSystemService(AudioManager::class.java) }
    private val notifications by lazy { app.getSystemService(NotificationManager::class.java) }

    fun init(context: Context) {
        app = context.applicationContext
    }

    // --- applying ---------------------------------------------------------------------------

    fun perform(from: String, kind: ControlKind, value: Int, stream: VolumeStream?) {
        UptimeLog.record("controls: ${kind.name.lowercase()} $value${stream?.let { " ${it.name.lowercase()}" } ?: ""}")
        when (kind) {
            ControlKind.TORCH -> setTorch(value == 1)
            ControlKind.TORCH_LEVEL -> setTorchLevel(value)
            ControlKind.RINGER_MODE -> setRingerMode(value, from)
            ControlKind.STREAM_VOLUME -> setVolume(stream, value, from)
            ControlKind.DND -> setDnd(value, from)
            ControlKind.VIBRATE -> vibrate(value.toLong())
            ControlKind.CLEAR_NOTIFICATIONS -> clearNotifications()
        }
        publish()
    }

    private fun torchCamera(): String? {
        torchCameraId?.let { return it }
        val id = runCatching {
            camera.cameraIdList.firstOrNull {
                camera.getCameraCharacteristics(it)[CameraCharacteristics.FLASH_INFO_AVAILABLE] == true
            }
        }.getOrNull()
        torchCameraId = id
        return id
    }

    private fun setTorch(on: Boolean) {
        val id = torchCamera() ?: return
        runCatching { camera.setTorchMode(id, on) }
            .onFailure { UptimeLog.record("controls: torch failed: ${it.javaClass.simpleName}") }
        handler.removeCallbacks(torchOff)
        if (on) handler.postDelayed(torchOff, TORCH_AUTO_OFF_MS)
    }

    private fun setTorchLevel(level: Int) {
        val id = torchCamera() ?: return
        if (Build.VERSION.SDK_INT < 33) return setTorch(level > 0)
        val max = maxTorchLevel()
        runCatching { camera.turnOnTorchWithStrengthLevel(id, level.coerceIn(1, max.coerceAtLeast(1))) }
            .onFailure { UptimeLog.record("controls: torch level failed: ${it.javaClass.simpleName}") }
        handler.removeCallbacks(torchOff)
        handler.postDelayed(torchOff, TORCH_AUTO_OFF_MS)
    }

    /** What the torch is set to right now; 0 when it is off or the phone has no levels. */
    private fun currentTorchLevel(): Int {
        if (Build.VERSION.SDK_INT < 33 || !torchOn) return 0
        val id = torchCamera() ?: return 0
        return runCatching { camera.getTorchStrengthLevel(id) }.getOrDefault(0)
    }

    private fun maxTorchLevel(): Int {
        if (Build.VERSION.SDK_INT < 33) return 0
        val id = torchCamera() ?: return 0
        return runCatching {
            camera.getCameraCharacteristics(id)[CameraCharacteristics.FLASH_INFO_STRENGTH_MAXIMUM_LEVEL] ?: 0
        }.getOrDefault(0)
    }

    private fun setRingerMode(value: Int, from: String) {
        val mode = when (RingerMode.entries.getOrNull(value - 1) ?: RingerMode.NORMAL) {
            RingerMode.SILENT -> AudioManager.RINGER_MODE_SILENT
            RingerMode.VIBRATE -> AudioManager.RINGER_MODE_VIBRATE
            RingerMode.NORMAL -> AudioManager.RINGER_MODE_NORMAL
        }
        // Silencing the phone needs Do Not Disturb access.
        if (mode == AudioManager.RINGER_MODE_SILENT && !hasDndAccess()) return askForDndAccess(from)
        runCatching { audio.ringerMode = mode }
            .onFailure { UptimeLog.record("controls: ringer mode failed: ${it.javaClass.simpleName}") }
    }

    private fun setVolume(stream: VolumeStream?, value: Int, from: String) {
        val id = when (stream) {
            VolumeStream.RING -> AudioManager.STREAM_RING
            VolumeStream.MEDIA -> AudioManager.STREAM_MUSIC
            VolumeStream.ALARM -> AudioManager.STREAM_ALARM
            VolumeStream.NOTIFICATION -> AudioManager.STREAM_NOTIFICATION
            null -> return
        }
        val max = audio.getStreamMaxVolume(id)
        val level = (value * max / 100).coerceIn(0, max)
        // Muting the ringer counts as a Do Not Disturb change.
        if (level == 0 && (id == AudioManager.STREAM_RING || id == AudioManager.STREAM_NOTIFICATION) &&
            !hasDndAccess()
        ) {
            return askForDndAccess(from)
        }
        runCatching { audio.setStreamVolume(id, level, 0) }
            .onFailure { UptimeLog.record("controls: volume failed: ${it.javaClass.simpleName}") }
    }

    private fun setDnd(value: Int, from: String) {
        if (!hasDndAccess()) return askForDndAccess(from)
        val filter = when (DndMode.entries.getOrNull(value - 1) ?: DndMode.OFF) {
            DndMode.OFF -> NotificationManager.INTERRUPTION_FILTER_ALL
            DndMode.PRIORITY -> NotificationManager.INTERRUPTION_FILTER_PRIORITY
            DndMode.ALARMS -> NotificationManager.INTERRUPTION_FILTER_ALARMS
            DndMode.NONE -> NotificationManager.INTERRUPTION_FILTER_NONE
        }
        runCatching { notifications.setInterruptionFilter(filter) }
            .onFailure { UptimeLog.record("controls: Do Not Disturb failed: ${it.javaClass.simpleName}") }
    }

    private fun vibrate(ms: Long) {
        val vibrator = if (Build.VERSION.SDK_INT >= 31) {
            app.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            app.getSystemService(Vibrator::class.java)
        } ?: return UptimeLog.record("controls: buzz failed, no vibrator")
        if (!vibrator.hasVibrator()) return UptimeLog.record("controls: buzz failed, no vibrator")
        val effect = VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE)
        // Without a usage Android drops the buzz when the phone is silent or haptics are limited.
        // Alarm usage is what "ring my phone" already relies on, so the buzz is felt either way.
        runCatching {
            if (Build.VERSION.SDK_INT >= 33) {
                vibrator.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(
                    effect,
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
            }
        }.onFailure { UptimeLog.record("controls: buzz failed: ${it.javaClass.simpleName}") }
    }

    private fun clearNotifications() {
        val cleared = BregeNotificationListener.clearAll()
        UptimeLog.record(if (cleared) "controls: cleared notifications" else "controls: clearing notifications needs access")
    }

    private fun hasDndAccess() = runCatching { notifications.isNotificationPolicyAccessGranted }.getOrDefault(false)

    /** The phone cannot open its settings by itself, so it asks with a notification. */
    private fun askForDndAccess(from: String) {
        UptimeLog.record("controls: Do Not Disturb access not granted")
        ControlsAccessNotice.show(app)
        publish()
    }

    // --- state ------------------------------------------------------------------------------

    /** Starts watching while the service runs; state goes out whenever something changes. */
    fun startWatching() {
        if (receiver == null) {
            val r = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) = publish()
            }
            val filter = IntentFilter().apply {
                addAction(AudioManager.RINGER_MODE_CHANGED_ACTION)
                addAction("android.media.VOLUME_CHANGED_ACTION")
                addAction(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
                addAction(AlarmManager.ACTION_NEXT_ALARM_CLOCK_CHANGED)
            }
            ContextCompat.registerReceiver(app, r, filter, ContextCompat.RECEIVER_EXPORTED)
            receiver = r
        }
        if (torchCallback == null) {
            val callback = object : CameraManager.TorchCallback() {
                override fun onTorchModeChanged(cameraId: String, enabled: Boolean) {
                    if (cameraId != torchCamera()) return
                    torchOn = enabled
                    if (!enabled) handler.removeCallbacks(torchOff)
                    publish()
                }
            }
            runCatching { camera.registerTorchCallback(callback, handler) }
                .onSuccess { torchCallback = callback }
        }
        publish()
    }

    fun stopWatching() {
        receiver?.let { runCatching { app.unregisterReceiver(it) } }
        receiver = null
        torchCallback?.let { runCatching { camera.unregisterTorchCallback(it) } }
        torchCallback = null
        handler.removeCallbacks(torchOff)
    }

    /** Sends the current state to the connected Macs. */
    fun publish() {
        val node = Core.node ?: return
        if (Core.connectedDevices.isEmpty()) return
        runCatching { node.publishControlState(state()) }
    }

    private fun state(): PhoneControlsData {
        fun percent(stream: Int): Pair<UInt, UInt> {
            val max = runCatching { audio.getStreamMaxVolume(stream) }.getOrDefault(0)
            val now = runCatching { audio.getStreamVolume(stream) }.getOrDefault(0)
            return (if (max > 0) (now * 100 / max).toUInt() else 0u) to max.toUInt()
        }
        val (ring, ringMax) = percent(AudioManager.STREAM_RING)
        val (media, mediaMax) = percent(AudioManager.STREAM_MUSIC)
        val (alarm, alarmMax) = percent(AudioManager.STREAM_ALARM)
        val battery = runCatching {
            app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        }.getOrNull()
        val stat = runCatching { StatFs(Environment.getDataDirectory().path) }.getOrNull()
        return PhoneControlsData(
            hasTorch = torchCamera() != null,
            torchOn = torchOn,
            torchLevel = currentTorchLevel().toUInt(),
            torchMaxLevel = maxTorchLevel().coerceAtLeast(0).toUInt(),
            ringerMode = when (runCatching { audio.ringerMode }.getOrDefault(AudioManager.RINGER_MODE_NORMAL)) {
                AudioManager.RINGER_MODE_SILENT -> RingerMode.SILENT
                AudioManager.RINGER_MODE_VIBRATE -> RingerMode.VIBRATE
                else -> RingerMode.NORMAL
            },
            volumeRing = ring, volumeRingMax = ringMax,
            volumeMedia = media, volumeMediaMax = mediaMax,
            volumeAlarm = alarm, volumeAlarmMax = alarmMax,
            dnd = when (runCatching { notifications.currentInterruptionFilter }.getOrDefault(0)) {
                NotificationManager.INTERRUPTION_FILTER_PRIORITY -> DndMode.PRIORITY
                NotificationManager.INTERRUPTION_FILTER_ALARMS -> DndMode.ALARMS
                NotificationManager.INTERRUPTION_FILTER_NONE -> DndMode.NONE
                else -> DndMode.OFF
            },
            needsDndAccess = !hasDndAccess(),
            nextAlarmMs = runCatching {
                app.getSystemService(AlarmManager::class.java)?.nextAlarmClock?.triggerTime ?: 0L
            }.getOrDefault(0L),
            storageFreeBytes = stat?.let { it.availableBlocksLong * it.blockSizeLong }?.toULong() ?: 0uL,
            storageTotalBytes = stat?.let { it.blockCountLong * it.blockSizeLong }?.toULong() ?: 0uL,
            batteryTemperatureDc = battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0,
            batteryHealth = health(battery?.getIntExtra(BatteryManager.EXTRA_HEALTH, 0) ?: 0),
            chargingSource = source(battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0),
        )
    }

    private fun health(value: Int) = when (value) {
        BatteryManager.BATTERY_HEALTH_GOOD -> "Good"
        BatteryManager.BATTERY_HEALTH_OVERHEAT -> "Overheating"
        BatteryManager.BATTERY_HEALTH_DEAD -> "Dead"
        BatteryManager.BATTERY_HEALTH_OVER_VOLTAGE -> "Over voltage"
        BatteryManager.BATTERY_HEALTH_COLD -> "Cold"
        else -> ""
    }

    private fun source(value: Int) = when (value) {
        BatteryManager.BATTERY_PLUGGED_AC -> "Power adapter"
        BatteryManager.BATTERY_PLUGGED_USB -> "USB"
        BatteryManager.BATTERY_PLUGGED_WIRELESS -> "Wireless"
        else -> ""
    }
}
