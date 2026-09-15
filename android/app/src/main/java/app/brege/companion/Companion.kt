package app.brege.companion

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanSettings
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.companion.CompanionDeviceService
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import app.brege.diagnostics.UptimeLog
import app.brege.service.BregeService
import java.util.UUID
import java.util.concurrent.Executor

/**
 * CompanionDeviceManager association with the Mac. The Mac advertises
 * [SERVICE_UUID]; the association lets Brêge start its foreground service from the background.
 */
object CompanionSetup {
    val SERVICE_UUID: UUID = UUID.fromString("B7E60001-5A1C-4E0B-9C43-8D2F6E1B7E60")

    fun isAssociated(context: Context): Boolean {
        val cdm = context.getSystemService(CompanionDeviceManager::class.java) ?: return false
        return if (Build.VERSION.SDK_INT >= 33) {
            cdm.myAssociations.isNotEmpty()
        } else {
            @Suppress("DEPRECATION")
            cdm.associations.isNotEmpty()
        }
    }

    /** Shows the system association dialog; [launch] must start the IntentSender for a result. */
    fun associate(context: Context, executor: Executor, launch: (IntentSender) -> Unit, onError: (String) -> Unit) {
        val cdm = context.getSystemService(CompanionDeviceManager::class.java)
            ?: return onError("Companion device setup is not available on this phone")
        val filter = BluetoothLeDeviceFilter.Builder()
            .setScanFilter(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build())
            .build()
        val request = AssociationRequest.Builder()
            .addDeviceFilter(filter)
            .setSingleDevice(true)
            .build()
        val callback = object : CompanionDeviceManager.Callback() {
            override fun onAssociationPending(intentSender: IntentSender) = launch(intentSender)

            @Deprecated("Replaced by onAssociationPending on API 33")
            override fun onDeviceFound(intentSender: IntentSender) = launch(intentSender)

            override fun onAssociationCreated(associationInfo: AssociationInfo) {
                UptimeLog.record("companion association created")
                onAssociated(context)
            }

            override fun onFailure(error: CharSequence?) = onError(error?.toString() ?: "Association failed")
        }
        if (Build.VERSION.SDK_INT >= 33) {
            cdm.associate(request, executor, callback)
        } else {
            @Suppress("DEPRECATION")
            cdm.associate(request, callback, null)
        }
    }

    /** Called after the association dialog completes. */
    fun onAssociated(context: Context) {
        observePresence(context)
        BleWake.register(context)
    }

    @SuppressLint("MissingPermission")
    private fun observePresence(context: Context) {
        if (Build.VERSION.SDK_INT < 31) return
        val cdm = context.getSystemService(CompanionDeviceManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 33) {
            cdm.myAssociations.forEach { info ->
                info.deviceMacAddress?.toString()?.let { address ->
                    @Suppress("DEPRECATION")
                    runCatching { cdm.startObservingDevicePresence(address) }
                }
            }
        } else {
            @Suppress("DEPRECATION")
            cdm.associations.forEach { runCatching { cdm.startObservingDevicePresence(it) } }
        }
    }
}

/**
 * CDM presence callbacks: the Mac came into BLE range, so make sure the service runs. The Mac's
 * advertising flaps between appeared and disappeared every few seconds, so "disappeared" is only
 * informational (nothing is stopped) and the log only notes presence that lasted a while.
 */
@RequiresApi(31)
class PresenceService : CompanionDeviceService() {
    @Deprecated("Deprecated in API 33")
    override fun onDeviceAppeared(address: String) = appeared("address")

    @Deprecated("Deprecated in API 33")
    override fun onDeviceDisappeared(address: String) = disappeared()

    @RequiresApi(33)
    override fun onDeviceAppeared(associationInfo: AssociationInfo) = appeared("association")

    private fun appeared(how: String) {
        record(present = true, detail = how)
        // Already running: nothing to do (and no "start requested" line every few seconds).
        if (!BregeService.isRunning) BregeService.start(this, "companion presence")
    }

    private fun disappeared() = record(present = false, detail = "")

    private companion object {
        /** A presence state is logged once it lasted this long, and at most once per interval. */
        const val STABLE_MS = 30_000L
        const val LOG_INTERVAL_MS = 60_000L

        @Volatile var present: Boolean? = null
        @Volatile var changedAt = 0L
        @Volatile var logged: Boolean? = null
        @Volatile var loggedAt = 0L

        @Synchronized
        fun record(present: Boolean, detail: String) {
            val now = System.currentTimeMillis()
            if (this.present != present) {
                // The previous state lasted long enough to be real: log it now, once.
                val previous = this.present
                if (previous != null && previous != logged && now - changedAt >= STABLE_MS && now - loggedAt >= LOG_INTERVAL_MS) {
                    UptimeLog.record("companion ${if (previous) "appeared" else "disappeared"} (lasted ${(now - changedAt) / 1000} s)")
                    logged = previous
                    loggedAt = now
                }
                this.present = present
                changedAt = now
            } else if (present != logged && now - changedAt >= STABLE_MS && now - loggedAt >= LOG_INTERVAL_MS) {
                UptimeLog.record("companion ${if (present) "appeared" else "disappeared"}" + if (detail.isEmpty()) "" else " ($detail)")
                logged = present
                loggedAt = now
            }
        }
    }
}

/**
 * BLE scan with a PendingIntent: the system wakes Brêge when it sees the Mac's service UUID,
 * even if the process was killed. Only used on Android 12+ (no location permission needed).
 */
object BleWake {
    @Volatile private var registered = false
    @Volatile private var failedAt = 0L

    /**
     * Registers the scan once per process while a Mac is associated. It does not survive a reboot
     * or Bluetooth turning off, so the service, boot and Bluetooth changes call this again.
     */
    @SuppressLint("MissingPermission")
    fun register(context: Context) {
        if (registered || Build.VERSION.SDK_INT < 31) return
        if (System.currentTimeMillis() - failedAt < 60_000) return
        if (!CompanionSetup.isAssociated(context)) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
            UptimeLog.record("BLE wake not registered: BLUETOOTH_SCAN not granted")
            return
        }
        val scanner = context.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner ?: return
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(CompanionSetup.SERVICE_UUID)).build())
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_FIRST_MATCH)
            .build()
        runCatching { scanner.stopScan(pendingIntent(context)) }
        // 0 is success; anything else is a ScanCallback.SCAN_FAILED_* code.
        val code = runCatching { scanner.startScan(filters, settings, pendingIntent(context)) }.getOrDefault(-1)
        registered = code == 0
        if (!registered) failedAt = System.currentTimeMillis()
        UptimeLog.record("BLE wake registered: $registered" + if (registered) "" else " (error $code)")
    }

    /** The scan reported an error, or Bluetooth went off (which drops PendingIntent scans). */
    fun onScanLost(retryNow: Boolean) {
        registered = false
        failedAt = if (retryNow) 0L else System.currentTimeMillis()
    }

    fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, 0, Intent(context, BleWakeReceiver::class.java),
        // Mutable: the system adds scan results to the intent.
        PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
}

class BleWakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val error = intent.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, 0)
        if (error != 0) {
            UptimeLog.record("BLE wake scan error $error")
            BleWake.onScanLost(retryNow = false)
            return
        }
        // Every sighting of the Mac is delivered; only a stopped service needs starting.
        if (!BregeService.isRunning) BregeService.start(context, "BLE wake")
    }
}
