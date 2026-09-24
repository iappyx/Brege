package app.brege.service

import android.app.Notification
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import app.brege.BregeApplication
import app.brege.R
import app.brege.calls.CallLogSync
import app.brege.controls.PhoneControls
import app.brege.sensors.Conditions
import app.brege.calls.CallMonitor
import app.brege.clipboard.ClipboardSendActivity
import app.brege.companion.BleWake
import app.brege.companion.PresenceBeacon
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import app.brege.discovery.NetworkPaths
import app.brege.discovery.NsdDiscovery
import app.brege.hotspot.HotspotRequests
import app.brege.media.RecentMedia
import app.brege.messages.MessageSync
import app.brege.ui.MainActivity
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import uniffi.brege_ffi.StatusData

/**
 * Foreground service of type connectedDevice that keeps the core connected.
 */
class BregeService : LifecycleService() {
    private var discovery: NsdDiscovery? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var allNetworksCallback: ConnectivityManager.NetworkCallback? = null
    private var tetherReceiver: BroadcastReceiver? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val reportNetworks = Runnable { NetworkPaths.report(this) }
    private var batteryReceiver: BroadcastReceiver? = null
    private var bluetoothReceiver: BroadcastReceiver? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        UptimeLog.record("service created")
        ServiceCompat.startForeground(
            this, NOTIFICATION_ID, buildNotification("Starting…"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
        lifecycleScope.launch {
            val node = Core.ensureStarted() ?: return@launch
            // Discovery restarts only when the reported interfaces really changed.
            NetworkPaths.onChanged = { restartDiscovery() }
            watchNetwork()
            watchBattery()
            watchBluetooth()
            NetworkPaths.dismiss(this@BregeService)
            NetworkPaths.report(this@BregeService)
            node.networkChanged()
            startFeatures()
            Core.devices.collectLatest { devices ->
                val connected = devices.filter { it.connected }
                val text = when {
                    devices.isEmpty() -> "Not paired"
                    connected.isEmpty() -> "Waiting for ${devices.first().name}"
                    else -> "Connected to ${connected.joinToString { it.name }}"
                }
                updateNotification(text)
                if (connected.isNotEmpty()) sendBattery()
                // Look for Macs only while one is not connected: a running search keeps the Wi‑Fi
                // multicast filter off, so every mDNS packet on the network would wake the phone.
                if (devices.any { !it.connected }) startDiscovery() else stopDiscovery()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        // Re-run after permissions were granted in the app.
        if (Core.node != null) startFeatures()
        return START_STICKY
    }

    /** Starts modules whose permissions are granted; safe to call repeatedly. */
    private fun startFeatures() {
        MessageSync.startObserving()
        CallMonitor.start()
        CallLogSync.startObserving()
        PhoneControls.startWatching()
        Conditions.start()
        HotspotRequests.register(this)
        BleWake.register(this)
        PresenceBeacon.update(this)
        RecentMedia.startWatching(this)
    }

    override fun onDestroy() {
        UptimeLog.record("service destroyed")
        isRunning = false
        NetworkPaths.onChanged = null
        mainHandler.removeCallbacks(reportNetworks)
        PresenceBeacon.stop(this)
        MessageSync.stopObserving()
        CallMonitor.stop()
        CallLogSync.stopObserving()
        PhoneControls.stopWatching()
        Conditions.stop()
        RecentMedia.stopWatching(this)
        stopDiscovery()
        networkCallback?.let { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) }
        allNetworksCallback?.let { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) }
        tetherReceiver?.let { unregisterReceiver(it) }
        batteryReceiver?.let { unregisterReceiver(it) }
        bluetoothReceiver?.let { unregisterReceiver(it) }
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // connectedDevice has no time limit today; log if a future Android version adds one.
        UptimeLog.record("foreground service timeout for type $fgsType")
        stopSelf()
    }

    /** Searches for Macs and holds the multicast lock for as long as the search runs. */
    @Synchronized
    private fun startDiscovery() {
        if (discovery != null) return
        multicastLock = getSystemService(WifiManager::class.java)
            .createMulticastLock("brege-discovery")
            .apply { setReferenceCounted(false); acquire() }
        discovery = NsdDiscovery(this) { tokens, address ->
            runCatching { Core.node?.addressDiscovered(tokens, address) }
        }.also { it.start() }
    }

    @Synchronized
    private fun stopDiscovery() {
        discovery?.stop()
        discovery = null
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    @Synchronized
    private fun restartDiscovery() {
        discovery?.restart()
    }

    private fun watchNetwork() {
        // FLAG_INCLUDE_LOCATION_INFO (Android 12+) lets the capabilities carry the Wi‑Fi name when
        // Brêge has Location access (network privacy plan); without it the name is always hidden.
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val callback = if (Build.VERSION.SDK_INT >= 31) NetworkWatcher(ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO) else NetworkWatcher()
        connectivity.registerDefaultNetworkCallback(callback)
        networkCallback = callback
        // Every network, not only the default one: a second Wi‑Fi, a VPN or a local-only network
        // changes the interfaces without changing the default network.
        val request = NetworkRequest.Builder().apply {
            if (Build.VERSION.SDK_INT >= 31) {
                clearCapabilities()
            } else {
                removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                removeCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)
            }
            addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
        }.build()
        val all = if (Build.VERSION.SDK_INT >= 31) AllNetworksWatcher(ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO) else AllNetworksWatcher()
        runCatching { connectivity.registerNetworkCallback(request, all) }
            .onSuccess { allNetworksCallback = all }
            .onFailure { UptimeLog.record("all-networks callback not registered: ${it.javaClass.simpleName}") }
        // The phone's own hotspot and USB/Bluetooth tethering are not networks: watch tethering.
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = scheduleReport()
        }
        ContextCompat.registerReceiver(
            this, receiver, IntentFilter(ACTION_TETHER_STATE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        tetherReceiver = receiver
    }

    /** Coalesces bursts of callbacks (every network, signal strength) into one report. */
    private fun scheduleReport() {
        mainHandler.removeCallbacks(reportNetworks)
        mainHandler.postDelayed(reportNetworks, 500)
    }

    private inner class NetworkWatcher : ConnectivityManager.NetworkCallback {
        constructor() : super()
        @RequiresApi(31) constructor(flags: Int) : super(flags)

        override fun onAvailable(network: Network) = changed()
        // "Lost" here only means no longer the default network; names are dropped by AllNetworksWatcher.
        override fun onLost(network: Network) = changed()
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            NetworkPaths.report(this@BregeService)
        }
        // Capabilities change often (signal strength); only a real change is passed on.
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            NetworkPaths.capabilitiesChanged(network, capabilities)
            NetworkPaths.report(this@BregeService)
        }
        private fun changed() {
            NetworkPaths.report(this@BregeService)
            Core.node?.networkChanged()
        }
    }

    private inner class AllNetworksWatcher : ConnectivityManager.NetworkCallback {
        constructor() : super()
        @RequiresApi(31) constructor(flags: Int) : super(flags)

        override fun onAvailable(network: Network) = scheduleReport()
        override fun onLost(network: Network) {
            NetworkPaths.networkLost(network)
            scheduleReport()
        }
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = scheduleReport()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            NetworkPaths.capabilitiesChanged(network, capabilities)
            scheduleReport()
        }
    }

    private fun watchBattery() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = sendBattery(intent)
        }
        ContextCompat.registerReceiver(
            this, receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        batteryReceiver = receiver
    }

    /** Turning Bluetooth off drops the PendingIntent scans; register them again once it is back on. */
    private fun watchBluetooth() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_OFF -> {
                        PresenceBeacon.stop(context)
                        HotspotRequests.onScanLost(retryNow = true)
                        BleWake.onScanLost(retryNow = true)
                    }
                    BluetoothAdapter.STATE_ON -> {
                        HotspotRequests.onScanLost(retryNow = true)
                        BleWake.onScanLost(retryNow = true)
                        HotspotRequests.register(context)
                        BleWake.register(context)
                        PresenceBeacon.update(context)
                    }
                }
            }
        }
        ContextCompat.registerReceiver(
            this, receiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        bluetoothReceiver = receiver
    }

    private var lastBattery: Pair<Int, Boolean>? = null

    private fun sendBattery(intent: Intent? = null) {
        val battery = intent ?: registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return
        val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        val pct = if (level >= 0 && scale > 0) level * 100 / scale else return
        if (intent != null && lastBattery == pct to charging) return
        lastBattery = pct to charging
        Core.node?.sendStatus(
            StatusData(
                batteryPct = pct.toUInt(), charging = charging, signalBars = 0u,
                networkType = "", dnd = false, volumePct = 0u,
            ),
        )
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val sendClipboard = PendingIntent.getActivity(
            this, 1,
            Intent(this, ClipboardSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, BregeApplication.CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_brege)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(open)
            .addAction(R.drawable.ic_brege, getString(R.string.tile_send_clipboard), sendClipboard)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(android.app.NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        private const val NOTIFICATION_ID = 1
        /** ConnectivityManager.ACTION_TETHER_STATE_CHANGED, a hidden constant. */
        private const val ACTION_TETHER_STATE_CHANGED = "android.net.conn.TETHER_STATE_CHANGED"

        /** True between onCreate and onDestroy. */
        @Volatile var isRunning = false
            private set

        /** Starts the service; allowed from the UI, boot, and CDM-exempt background paths. */
        fun start(context: Context, reason: String) {
            UptimeLog.record("start requested: $reason")
            runCatching {
                ContextCompat.startForegroundService(context, Intent(context, BregeService::class.java))
            }.onFailure { UptimeLog.record("start refused ($reason): ${it.javaClass.simpleName}") }
        }
    }
}
