package app.brege.companion

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import app.brege.service.BregeService
import java.util.UUID

/**
 * While a paired Mac is not connected, the phone advertises a rotating Bluetooth LE id so that Mac
 * can tell the phone is nearby, and only then asks about a new network (network privacy plan).
 * The id is keyed per pairing and changes every 15 minutes, so it does not identify the phone to
 * anyone else. Low-power, non-connectable advertising.
 */
object PresenceBeacon {
    private const val REFRESH_MS = 60_000L
    private val handler = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var callback: AdvertiseCallback? = null
    private var advertised: String? = null
    private val refresh = Runnable { appContext?.let(::update) }

    /** Starts, rotates or stops advertising to match the connection state. */
    @Synchronized
    fun update(context: Context) {
        // Only while the service runs; its onDestroy stops the beacon (a late refresh must not restart it).
        if (!BregeService.isRunning) return
        val app = context.applicationContext
        appContext = app
        handler.removeCallbacks(refresh)
        val uuids = runCatching { Core.node?.presenceUuids() }.getOrNull().orEmpty()
        // One 128-bit id fits in an advertisement; with several Macs away, take turns per minute.
        val uuid = uuids.getOrNull(((System.currentTimeMillis() / REFRESH_MS) % uuids.size.coerceAtLeast(1)).toInt())
        if (uuid != null) handler.postDelayed(refresh, REFRESH_MS)
        if (uuid == advertised && callback != null) return
        stopAdvertising(app)
        if (uuid == null) return
        if (Build.VERSION.SDK_INT >= 31 &&
            app.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED
        ) return
        val advertiser = app.getSystemService(BluetoothManager::class.java)?.adapter
            ?.takeIf { it.isEnabled }?.bluetoothLeAdvertiser ?: return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(false)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(UUID.fromString(uuid)))
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .build()
        val started = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                UptimeLog.record("presence beacon failed: $errorCode")
                synchronized(this@PresenceBeacon) {
                    if (callback === this) {
                        callback = null
                        advertised = null
                    }
                }
            }
        }
        runCatching { advertiser.startAdvertising(settings, data, started) }
            .onSuccess {
                callback = started
                advertised = uuid
            }
            .onFailure { UptimeLog.record("presence beacon not started: ${it.javaClass.simpleName}") }
    }

    @Synchronized
    fun stop(context: Context) {
        handler.removeCallbacks(refresh)
        stopAdvertising(context)
    }

    private fun stopAdvertising(context: Context) {
        val current = callback ?: return
        callback = null
        advertised = null
        val app = context.applicationContext
        // Without the permission nothing could have been started, and stopping would throw.
        if (Build.VERSION.SDK_INT >= 31 &&
            app.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED
        ) return
        runCatching {
            app.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeAdvertiser?.stopAdvertising(current)
        }
    }
}
