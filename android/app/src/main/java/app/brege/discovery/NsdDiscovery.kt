package app.brege.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.Executors

/** Finds Macs advertising `_brege._udp` and reports `(shortId, "ip:port")`. */
class NsdDiscovery(context: Context, private val onFound: (String, String) -> Unit) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val executor = Executors.newSingleThreadExecutor()
    private var listener: NsdManager.DiscoveryListener? = null
    /** Before Android 14 NsdManager resolves one service at a time: the rest wait here. */
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private val handler = Handler(Looper.getMainLooper())

    @Synchronized
    fun start() {
        if (listener != null) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "discovery failed: $errorCode")
                listener = null
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onServiceLost(service: NsdServiceInfo) = Unit
            override fun onServiceFound(service: NsdServiceInfo) = resolve(service)
        }
        listener = l
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
    }

    @Synchronized
    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        resolveQueue.clear()
    }

    @Synchronized
    fun restart() {
        stop()
        start()
    }

    private fun resolve(service: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT >= 34) {
            nsd.registerServiceInfoCallback(service, executor, object : NsdManager.ServiceInfoCallback {
                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) = Unit
                override fun onServiceLost() = Unit
                override fun onServiceInfoCallbackUnregistered() = Unit
                override fun onServiceUpdated(info: NsdServiceInfo) {
                    report(info, info.hostAddresses.map { it.hostAddress.orEmpty() })
                    runCatching { nsd.unregisterServiceInfoCallback(this) }
                }
            })
        } else {
            enqueueResolve(service)
        }
    }

    @Synchronized
    private fun enqueueResolve(service: NsdServiceInfo) {
        if (resolveQueue.any { it.serviceName == service.serviceName }) return
        resolveQueue.addLast(service)
        if (!resolving) resolveNext(attempt = 0)
    }

    @Synchronized
    private fun resolveNext(attempt: Int) {
        val service = resolveQueue.removeFirstOrNull()
        if (service == null) {
            resolving = false
            return
        }
        resolving = true
        val started = runCatching {
            @Suppress("DEPRECATION")
            nsd.resolveService(service, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    if (errorCode == NsdManager.FAILURE_ALREADY_ACTIVE && attempt < MAX_RESOLVE_RETRIES) {
                        // Another resolve still runs: try this one again shortly.
                        synchronized(this@NsdDiscovery) { resolveQueue.addFirst(service) }
                        handler.postDelayed({ resolveNext(attempt + 1) }, RETRY_DELAY_MS)
                    } else {
                        Log.w(TAG, "resolve failed: $errorCode")
                        resolveNext(attempt = 0)
                    }
                }
                override fun onServiceResolved(info: NsdServiceInfo) {
                    report(info, listOfNotNull(info.host?.hostAddress))
                    resolveNext(attempt = 0)
                }
            })
        }
        if (started.isFailure) {
            Log.w(TAG, "resolve not started", started.exceptionOrNull())
            handler.post { resolveNext(attempt = 0) }
        }
    }

    private fun report(info: NsdServiceInfo, hosts: List<String>) {
        // The Mac's rotating keyed ids (network privacy plan); the core checks them.
        val tokens = info.attributes["k"]?.toString(Charsets.UTF_8) ?: return
        for (host in hosts.filter { it.isNotEmpty() }) {
            val address = if (host.contains(':')) "[${host.substringBefore('%')}]:${info.port}" else "$host:${info.port}"
            onFound(tokens, address)
        }
    }

    private companion object {
        const val TAG = "BregeNsd"
        const val SERVICE_TYPE = "_brege._udp"
        const val MAX_RESOLVE_RETRIES = 10
        const val RETRY_DELAY_MS = 300L
    }
}
