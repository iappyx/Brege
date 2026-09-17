package app.brege.core

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import app.brege.diagnostics.UptimeLog
import app.brege.discovery.NetworkPaths
import app.brege.hotspot.HotspotRequests
import app.brege.notifications.BregeNotificationListener
import app.brege.security.SecretStore
import app.brege.storage.SafStorage
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.brege_ffi.BregeEvent
import uniffi.brege_ffi.BregeNode
import uniffi.brege_ffi.Device
import uniffi.brege_ffi.EventListener
import uniffi.brege_ffi.NodeOptions
import uniffi.brege_ffi.Platform
import uniffi.brege_ffi.StatusData
import uniffi.brege_ffi.generateDbKey
import uniffi.brege_ffi.generateIdentitySeed

/**
 * Process-wide owner of the Rust core. The shell only mirrors core state into flows.
 */
object Core {
    private const val TAG = "BregeCore"
    private val DEFAULT_PORT: UShort = 47400u

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private lateinit var appContext: Context
    private val startLock = Mutex()
    private val started = AtomicBoolean(false)

    @Volatile
    var node: BregeNode? = null
        private set

    private val _devices = MutableStateFlow<List<Device>>(emptyList())
    val devices: StateFlow<List<Device>> = _devices.asStateFlow()

    private val _statuses = MutableStateFlow<Map<String, StatusData>>(emptyMap())
    val statuses: StateFlow<Map<String, StatusData>> = _statuses.asStateFlow()

    private val _events = MutableSharedFlow<BregeEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<BregeEvent> = _events.asSharedFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    /** Events for [EventHandler], handled one at a time in arrival order. */
    private val pendingEvents = Channel<BregeEvent>(Channel.UNLIMITED)

    fun init(context: Context) {
        appContext = context.applicationContext
        scope.launch {
            // Slow work (message sync, media) is launched from the handler, so it does not hold the queue.
            for (event in pendingEvents) {
                try {
                    EventHandler.handle(appContext, event)
                } catch (e: Exception) {
                    Log.w(TAG, "event handler failed for ${event.javaClass.simpleName}", e)
                }
            }
        }
    }

    /** Starts the core once; safe to call from the service, the UI and receivers. */
    suspend fun ensureStarted(): BregeNode? = startLock.withLock {
        node?.let { return it }
        // A caller cancelled mid-start must not leave a started node that nobody stored.
        withContext(NonCancellable) { startNode() }
    }

    private suspend fun startNode(): BregeNode? {
        return try {
            val secrets = SecretStore(appContext)
            val seed = secrets.loadOrCreate("identity-seed") { generateIdentitySeed() }
            val dbKey = secrets.loadOrCreate("database-key") { generateDbKey() }
            val downloads = File(appContext.filesDir, "received").apply { mkdirs() }
            val options = { port: UShort ->
                NodeOptions(
                    name = deviceName(),
                    platform = Platform.ANDROID,
                    appVersion = appVersion(),
                    identitySeed = seed,
                    dbPath = File(appContext.noBackupFilesDir, "brege.db").path,
                    dbKey = dbKey,
                    listenPort = port,
                    downloadDir = downloads.path,
                    // Loopback only until the interfaces below are reported (network privacy).
                    restrictNetworkUntilReported = true,
                )
            }
            // A fixed port lets the Mac dial the phone too, which works even when the Mac is on
            // Wi‑Fi and Ethernet at once (it cannot always answer from the address the phone used).
            val started = try {
                BregeNode.start(options(DEFAULT_PORT), Listener)
            } catch (e: Exception) {
                Log.w(TAG, "port $DEFAULT_PORT unavailable, using a random port", e)
                BregeNode.start(options(0u), Listener)
            }
            node = started
            // Report now, not only from BregeService: a core started by a receiver or activity
            // would otherwise stay restricted to loopback.
            runCatching { NetworkPaths.report(appContext) }
                .onFailure { Log.w(TAG, "network report failed", it) }
            started.setPhoneStorage(SafStorage(appContext))
            this.started.set(true)
            refreshDevices()
            UptimeLog.record("core started, id ${started.shortId()}")
            started
        } catch (e: Exception) {
            Log.e(TAG, "core start failed", e)
            _error.value = e.message ?: e.toString()
            null
        }
    }

    fun refreshDevices() {
        _devices.value = runCatching { node?.devices() }.getOrNull() ?: emptyList()
    }

    val connectedDevices: List<Device> get() = _devices.value.filter { it.connected }

    private object Listener : EventListener {
        override fun onEvent(event: BregeEvent) {
            when (event) {
                is BregeEvent.DevicePaired, is BregeEvent.DeviceForgotten,
                is BregeEvent.PeerConnected, is BregeEvent.PeerDisconnected -> refreshDevices()
                is BregeEvent.StatusUpdated -> _statuses.update { it + (event.from to event.status) }
                else -> Unit
            }
            if (event is BregeEvent.PeerConnected) {
                UptimeLog.record("connected to ${event.name}")
                app.brege.controls.PhoneControls.publish()
                Handler(Looper.getMainLooper()).post { BregeNotificationListener.publishOngoingActivities() }
                HotspotRequests.onPeerConnected(appContext, event.deviceId)
            }
            if (event is BregeEvent.PeerConnected || event is BregeEvent.PeerDisconnected) {
                app.brege.companion.PresenceBeacon.update(appContext)
            }
            if (event is BregeEvent.PeerDisconnected) {
                UptimeLog.record("disconnected")
                HotspotRequests.onPeerDisconnected(appContext, event.deviceId)
            }
            // Platform side effects (clipboard, ring, notifications) run outside the core thread, in order.
            pendingEvents.trySend(event)
            _events.tryEmit(event)
        }
    }

    private fun deviceName(): String =
        Settings.Global.getString(appContext.contentResolver, Settings.Global.DEVICE_NAME)
            ?: "${Build.MANUFACTURER} ${Build.MODEL}"

    private fun appVersion(): String =
        runCatching {
            appContext.packageManager.getPackageInfo(appContext.packageName, 0).versionName
        }.getOrNull() ?: "dev"
}
