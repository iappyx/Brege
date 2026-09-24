package app.brege.sensors

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.BatteryManager
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import uniffi.brege_ffi.ConditionsData
import uniffi.brege_ffi.PressurePointData
import kotlin.math.abs

/**
 * What the phone's own sensors say about where it is: air pressure and its trend, how light the
 * room is, how warm the battery runs and how the phone lies on the table.
 *
 * Every reading here comes from a sensor that needs no permission. Sampling only runs while a Mac
 * is connected, once a minute, and the readings are batched by the sensor hub, so the main chip
 * stays asleep between them.
 */
object Conditions {
    /** A day of pressure at one point a minute. */
    private const val HISTORY_MS = 24 * 60 * 60 * 1000L
    private const val SAMPLE_US = 60 * 1_000_000          // one reading a minute
    private const val BATCH_US = 5 * 60 * 1_000_000       // delivered in five-minute batches
    private const val MOTION_US = 2 * 1_000_000           // how the phone lies, every two seconds
    private const val MOTION_BATCH_US = 20 * 1_000_000
    private const val LIGHT_BATCH_US = 60 * 1_000_000

    /** Below this, for this long, counts as "the room went dark". */
    private const val DARK_LUX = 20f
    private const val DARK_FOR_MS = 2 * 60 * 1000L

    /** A fall of this much over three hours is what the forecast calls falling. */
    private const val FALLING_HPA = 1.0f

    private lateinit var app: Context
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var listener: SensorEventListener? = null
    private var motionOn = false
    private var thermal: PowerManager.OnThermalStatusChangedListener? = null

    private val sensors by lazy { app.getSystemService(SensorManager::class.java) }
    private val power by lazy { app.getSystemService(PowerManager::class.java) }

    private val history = ArrayDeque<PressurePointData>()
    private var lastSampleMs = 0L
    private var lux = -1f
    private var darkSinceMs = 0L
    private var darkRoom = false
    private var faceDown = false
    private var faceDownSinceMs = 0L

    fun init(context: Context) {
        app = context.applicationContext
    }

    // --- sampling ---------------------------------------------------------------------------

    /** Starts sampling; safe to call repeatedly. Nothing runs while no Mac is connected. */
    fun start() {
        if (!::app.isInitialized || listener != null) return
        val manager = sensors ?: return
        val pressure = manager.getDefaultSensor(Sensor.TYPE_PRESSURE)
        val light = manager.getDefaultSensor(Sensor.TYPE_LIGHT)
        if (pressure == null && light == null) return

        val worker = HandlerThread("brege-sensors").apply { start() }
        thread = worker
        handler = Handler(worker.looper)
        val target = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) = onReading(event)
            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        listener = target
        pressure?.let { manager.registerListener(target, it, SAMPLE_US, BATCH_US, handler) }
        // The light sensor only reports when the value changes, so it is kept lively.
        light?.let { manager.registerListener(target, it, SAMPLE_US, LIGHT_BATCH_US, handler) }

        val onThermal = PowerManager.OnThermalStatusChangedListener { publish() }
        runCatching { power?.addThermalStatusListener(onThermal) }.onSuccess { thermal = onThermal }
        UptimeLog.record(
            "sensors: watching" +
                (if (pressure != null) " pressure" else "") +
                (if (light != null) " light" else "")
        )
    }

    /**
     * How the phone lies is the one reading that keeps a sensor running all the time, so it is
     * watched only while a Mac says it uses it (the face-down automation).
     */
    private fun watchMotion(wanted: Boolean) {
        if (wanted == motionOn) return
        val manager = sensors ?: return
        val target = listener ?: return
        val gravity = manager.getDefaultSensor(Sensor.TYPE_GRAVITY)
            ?: manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return
        if (wanted) {
            manager.registerListener(target, gravity, MOTION_US, MOTION_BATCH_US, handler)
        } else {
            manager.unregisterListener(target, gravity)
            faceDown = false
            faceDownSinceMs = 0L
        }
        motionOn = wanted
        UptimeLog.record("sensors: motion ${if (wanted) "on" else "off"}")
    }

    fun stop() {
        listener?.let { runCatching { sensors?.unregisterListener(it) } }
        listener = null
        motionOn = false
        thermal?.let { runCatching { power?.removeThermalStatusListener(it) } }
        thermal = null
        thread?.quitSafely()
        thread = null
        handler = null
    }

    private fun onReading(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_PRESSURE -> recordPressure(event.values[0])
            Sensor.TYPE_LIGHT -> recordLight(event.values[0])
            Sensor.TYPE_GRAVITY, Sensor.TYPE_ACCELEROMETER -> recordTilt(event.values[2])
        }
    }

    private fun recordPressure(hpa: Float) {
        if (!hpa.isFinite() || hpa <= 0f) return
        val now = System.currentTimeMillis()
        // Batched readings arrive in bursts; one point a minute is enough for the chart.
        if (now - lastSampleMs < 55_000L) return
        lastSampleMs = now
        synchronized(history) {
            history.addLast(PressurePointData(atMs = now, hpa = hpa))
            while (history.isNotEmpty() && now - history.first().atMs > HISTORY_MS) history.removeFirst()
        }
    }

    private fun recordLight(value: Float) {
        if (!value.isFinite()) return
        lux = value
        val now = System.currentTimeMillis()
        if (value < DARK_LUX) {
            if (darkSinceMs == 0L) darkSinceMs = now
            if (!darkRoom && now - darkSinceMs >= DARK_FOR_MS) {
                darkRoom = true
                publish()
            }
        } else {
            darkSinceMs = 0L
            if (darkRoom) {
                darkRoom = false
                publish()
            }
        }
    }

    /** Gravity on the z axis: clearly negative means the screen looks at the table. */
    private fun recordTilt(z: Float) {
        val now = System.currentTimeMillis()
        val down = z < -8.0f
        if (down == faceDown) {
            faceDownSinceMs = 0L
            return
        }
        // A phone being picked up passes through every angle, so wait for it to settle.
        if (faceDownSinceMs == 0L) faceDownSinceMs = now
        if (now - faceDownSinceMs < 3_000L) return
        faceDown = down
        faceDownSinceMs = 0L
        publish()
    }

    // --- reporting --------------------------------------------------------------------------

    /** Answers one Mac that asked. */
    fun onRequested(from: String, historyHours: UInt, watchMotion: Boolean) {
        val node = Core.node ?: return
        handler?.post { runCatching { watchMotion(watchMotion) } }
        runCatching { node.sendConditions(from, read(historyHours.toInt())) }
            .onFailure { UptimeLog.record("sensors: sending conditions failed: ${it.javaClass.simpleName}") }
    }

    /** Tells the connected Macs, when the phone is turned over or the room darkens. */
    fun publish() {
        val node = Core.node ?: return
        if (Core.connectedDevices.isEmpty()) return
        // A push carries no history; the window asks for that itself.
        runCatching { node.publishConditions(read(0)) }
    }

    private fun read(historyHours: Int): ConditionsData {
        val manager = sensors
        val now = System.currentTimeMillis()
        val points = synchronized(history) {
            if (historyHours <= 0) emptyList()
            else history.filter { now - it.atMs <= historyHours * 60L * 60_000L }
        }
        val all = synchronized(history) { history.toList() }
        val latest = all.lastOrNull()
        val threeHoursAgo = all.firstOrNull { now - it.atMs <= 3 * 60 * 60_000L }
        val delta = if (latest != null && threeHoursAgo != null) latest.hpa - threeHoursAgo.hpa else 0f
        val battery = runCatching {
            app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        }.getOrNull()
        val batteryManager = app.getSystemService(BatteryManager::class.java)
        val amps = runCatching {
            // Reported in microamperes, negative while discharging on most phones.
            (batteryManager?.getLongProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW) ?: 0L) / 1_000_000f
        }.getOrDefault(0f)
        val volts = (battery?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, 0) ?: 0) / 1000f
        val charging = (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        return ConditionsData(
            hasBarometer = manager?.getDefaultSensor(Sensor.TYPE_PRESSURE) != null,
            pressureHpa = latest?.hpa ?: 0f,
            pressureDelta3h = delta,
            fallingSinceMs = if (delta <= -FALLING_HPA) threeHoursAgo?.atMs ?: 0L else 0L,
            altitudeDeltaM = altitudeChange(all),
            history = points,
            hasLight = manager?.getDefaultSensor(Sensor.TYPE_LIGHT) != null,
            lightLux = lux.coerceAtLeast(0f),
            darkRoom = darkRoom,
            batteryTempC = (battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0) / 10f,
            chargeWatts = if (charging) abs(amps) * volts else 0f,
            chargeAmps = amps,
            chargeVolts = volts,
            thermalStatus = runCatching { power?.currentThermalStatus ?: 0 }.getOrDefault(0).toUInt(),
            hasAccelerometer = manager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) != null,
            faceDown = faceDown,
        )
    }

    /**
     * How much the phone rose or fell since the oldest reading, from pressure alone:
     * about 12 metres for every hectopascal near sea level.
     */
    private fun altitudeChange(points: List<PressurePointData>): Float {
        val first = points.firstOrNull() ?: return 0f
        val last = points.lastOrNull() ?: return 0f
        if (first === last) return 0f
        return SensorManager.getAltitude(first.hpa, last.hpa)
    }
}
