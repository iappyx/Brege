package app.brege.hotspot

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import app.brege.BregeApplication
import app.brege.R
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import app.brege.discovery.NetworkPaths
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Phone hotspot for the Mac. A Mac without Wi‑Fi cannot reach the phone over the
 * network, so it advertises a Bluetooth LE service UUID signed with the pairing's presence key.
 * A background scan wakes Brêge, which asks the user to turn on the hotspot: Android does not let
 * apps switch it on themselves.
 */
object HotspotRequests {
    /** `B7E60002-…`: the first four bytes are fixed, the rest is the signed, rotating tag. */
    private val PREFIX = ParcelUuid(UUID.fromString("B7E60002-0000-0000-0000-000000000000"))
    private val MASK = ParcelUuid(UUID.fromString("FFFFFFFF-0000-0000-0000-000000000000"))
    private const val TETHER_SETTINGS = "android.settings.TETHER_SETTINGS"
    private const val REQUEST_NOTIFICATION = 11
    private const val DONE_NOTIFICATION = 12
    /** How long after a request a Mac that connects counts as using the hotspot. */
    private const val USING_WINDOW_MS = 10 * 60_000L
    /** How long to keep checking the interfaces after asking for the hotspot (it has no network callback). */
    private const val WATCH_MS = 3 * 60_000L
    private const val WATCH_INTERVAL_MS = 3_000L
    /** A Mac that reconnects within this time did not really leave the hotspot. */
    private const val LEFT_DELAY_MS = 10_000L

    private val requestedAt = ConcurrentHashMap<String, Long>() // Mac id → last request
    @Volatile private var lastWake = 0L
    private val usingHotspot = ConcurrentHashMap.newKeySet<String>()
    private val leaving = ConcurrentHashMap<String, Job>() // Mac id → pending "left the hotspot"
    @Volatile private var watchJob: Job? = null

    @Volatile private var registered = false
    @Volatile private var failedAt = 0L

    /**
     * Registers the background scan once per process. It outlives the process in the Bluetooth
     * stack; re-registering on every service start (presence callbacks arrive every few seconds)
     * only churned the scanner. After a failure it retries at most once a minute.
     */
    @SuppressLint("MissingPermission")
    fun register(context: Context) {
        if (registered || Build.VERSION.SDK_INT < 31) return
        if (System.currentTimeMillis() - failedAt < 60_000) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) return
        val scanner = context.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner ?: return
        val filter = ScanFilter.Builder().setServiceUuid(PREFIX, MASK).build()
        // Every match, not just the first: FIRST_MATCH stays quiet for a Mac it already reported, so
        // a second request would never arrive. The Mac only advertises this while it asks.
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()
        runCatching { scanner.stopScan(pendingIntent(context)) }
        // 0 is success; anything else is a ScanCallback.SCAN_FAILED_* code.
        val code = runCatching { scanner.startScan(listOf(filter), settings, pendingIntent(context)) }.getOrDefault(-1)
        registered = code == 0
        if (!registered) failedAt = System.currentTimeMillis()
        UptimeLog.record("hotspot: request scan registered: $registered" + if (registered) "" else " (error $code)")
    }

    /** The scan reported an error, or Bluetooth went off (which drops PendingIntent scans). */
    fun onScanLost(retryNow: Boolean) {
        registered = false
        failedAt = if (retryNow) 0L else System.currentTimeMillis()
    }

    private fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, 1, Intent(context, HotspotRequestReceiver::class.java),
        // Mutable: the system adds scan results to the intent.
        PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun requestIds(results: List<ScanResult>): List<String> =
        results.flatMap { it.scanRecord?.serviceUuids.orEmpty() }
            .map { it.uuid.toString() }
            .filter { it.startsWith("b7e60002", ignoreCase = true) }
            .distinct()

    /** Scan results from the receiver: find a request from a paired Mac. */
    suspend fun onScanResults(context: Context, results: List<ScanResult>) {
        val notifications = context.getSystemService(NotificationManager::class.java)
        if (notifications.activeNotifications.any { it.id == REQUEST_NOTIFICATION }) return
        val now = System.currentTimeMillis()
        if (now - lastWake < 5_000) return // matches arrive for every advertisement
        lastWake = now
        var uuids = requestIds(results)
        if (uuids.isEmpty()) {
            // Filtered in the Bluetooth chip, the wake-up comes without the advertisement: read it
            // with a short regular scan.
            uuids = scanBriefly(context)
        }
        UptimeLog.record("hotspot: woken by a request, ${uuids.size} request id(s) read")
        if (uuids.isEmpty()) return
        val node = Core.ensureStarted() ?: return
        val mac = uuids.firstNotNullOfOrNull { node.matchHotspotRequest(it) }
        if (mac == null) {
            UptimeLog.record("hotspot: request id not from a paired Mac")
            return
        }
        requestedAt[mac] = System.currentTimeMillis()
        val name = runCatching { node.devices().firstOrNull { it.id == mac }?.name }.getOrNull() ?: "your Mac"
        notify(context, REQUEST_NOTIFICATION, "Turn on hotspot for $name", "$name has no Wi‑Fi. Tap, then switch on the hotspot.")
        UptimeLog.record("hotspot: request from $name")
        watchInterfaces(context, mac)
    }

    /**
     * Turning the hotspot on changes no network, so no callback reports it reliably: check the
     * interfaces every few seconds for a while after the request (until that Mac connects).
     */
    private fun watchInterfaces(context: Context, mac: String) {
        watchJob?.cancel()
        watchJob = Core.scope.launch {
            val until = System.currentTimeMillis() + WATCH_MS
            while (System.currentTimeMillis() < until && mac !in usingHotspot) {
                runCatching { NetworkPaths.report(context) }
                delay(WATCH_INTERVAL_MS)
            }
        }
    }

    @SuppressLint("MissingPermission")
    private suspend fun scanBriefly(context: Context): List<String> {
        val scanner = context.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner ?: return emptyList()
        val found = ConcurrentHashMap.newKeySet<String>()
        val done = CompletableDeferred<Unit>()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                found += requestIds(listOf(result))
                if (found.isNotEmpty()) done.complete(Unit)
            }

            override fun onScanFailed(errorCode: Int) {
                UptimeLog.record("hotspot: follow-up scan failed ($errorCode)")
                done.complete(Unit)
            }
        }
        val filter = ScanFilter.Builder().setServiceUuid(PREFIX, MASK).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        runCatching { scanner.startScan(listOf(filter), settings, callback) }.onFailure { return emptyList() }
        withTimeoutOrNull(8_000) { done.await() }
        runCatching { scanner.stopScan(callback) }
        return found.toList()
    }

    /** A Mac connected soon after asking: it is probably online through the hotspot. */
    fun onPeerConnected(context: Context, mac: String) {
        leaving.remove(mac)?.let {
            // Back within a few seconds: still on the hotspot.
            it.cancel()
            usingHotspot += mac
            return
        }
        val at = requestedAt[mac] ?: return
        if (System.currentTimeMillis() - at > USING_WINDOW_MS) return
        usingHotspot += mac
        context.getSystemService(NotificationManager::class.java).cancel(REQUEST_NOTIFICATION)
    }

    /** That Mac left again (back on its own Wi‑Fi, or asleep): suggest turning the hotspot off. */
    fun onPeerDisconnected(context: Context, mac: String) {
        if (!usingHotspot.remove(mac)) return
        requestedAt.remove(mac)
        // Short drops (roaming, a reconnect) are not leaving: only notify if it stays away.
        val job = Core.scope.launch {
            delay(LEFT_DELAY_MS)
            if (!leaving.remove(mac, coroutineContext.job)) return@launch
            if (Core.connectedDevices.any { it.id == mac }) return@launch
            notify(context, DONE_NOTIFICATION, "Your Mac left the hotspot", "Tap to turn off the hotspot if you no longer need it.")
        }
        leaving.put(mac, job)?.cancel()
    }

    private fun notify(context: Context, id: Int, title: String, text: String) {
        val tap = PendingIntent.getActivity(
            context, id, settingsIntent(context), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, BregeApplication.CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_brege)
            .setContentTitle(title)
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(tap)
            .setTimeoutAfter(5 * 60_000L)
            .build()
        context.getSystemService(NotificationManager::class.java).notify(id, notification)
    }

    /** Hotspot & tethering settings; the wireless settings where that screen does not exist. */
    private fun settingsIntent(context: Context): Intent {
        val tether = Intent(TETHER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return if (tether.resolveActivity(context.packageManager) != null) tether
        else Intent(Settings.ACTION_WIRELESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}

class HotspotRequestReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val error = intent.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, 0)
        if (error != 0) {
            UptimeLog.record("hotspot: scan error $error")
            HotspotRequests.onScanLost(retryNow = false)
        }
        val results: List<ScanResult> = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableArrayListExtra(BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT, ScanResult::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra(BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT)
        }.orEmpty()
        if (results.isEmpty()) return
        val pending = goAsync()
        Core.scope.launch {
            try {
                HotspotRequests.onScanResults(context.applicationContext, results)
            } finally {
                pending.finish()
            }
        }
    }
}
