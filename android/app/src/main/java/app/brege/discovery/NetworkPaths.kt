package app.brege.discovery

import android.app.NotificationManager
import android.content.Context
import android.Manifest
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import java.net.Inet4Address
import java.net.NetworkInterface
import uniffi.brege_ffi.NetworkInterfaceData
import uniffi.brege_ffi.NetworkInterfaceKind

/**
 * Network privacy: tells the core which interfaces the phone has,
 * so Brêge only connects and answers on networks and VPNs you chose. The phone asks inside the app
 * (the question card), never with a notification.
 */
object NetworkPaths {
    private const val NOTIFICATION_ID = 16
    private const val QUESTION_ID = 17
    /** Tethering-like interface names (hotspot, USB, Bluetooth) that belong to no network. */
    private val TETHERING_PREFIXES = listOf("ap", "swlan", "wlan", "softap", "rndis", "usb", "ncm", "bt-pan")
    private var lastSnapshot: List<NetworkInterfaceData>? = null
    /** Wi‑Fi names per network, from a callback that may include them (Location access). */
    private val wifiNames = java.util.concurrent.ConcurrentHashMap<Network, String>()

    /** Called after a report changed the interfaces (the service restarts discovery). */
    @Volatile var onChanged: (() -> Unit)? = null

    /** From the service's network callbacks. */
    fun capabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
        val name = (capabilities.transportInfo as? WifiInfo)?.ssid?.let(::cleanName).orEmpty()
        // Capabilities come back redacted now and then while the same network stays connected:
        // keep the last known name until the network is lost.
        if (name.isNotEmpty()) wifiNames[network] = name
    }

    /** From the callback that watches all networks (not the default-network one, whose "lost" only means "no longer default"). */
    fun networkLost(network: Network) {
        wifiNames.remove(network)
    }

    fun hasLocation(context: Context) =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun cleanName(raw: String): String? =
        raw.removeSurrounding("\"").takeUnless { it.isBlank() || it == WifiManager.UNKNOWN_SSID.removeSurrounding("\"") || raw == WifiManager.UNKNOWN_SSID }

    @Suppress("DEPRECATION")
    private fun wifiName(context: Context, network: Network): String {
        if (!hasLocation(context)) return ""
        wifiNames[network]?.let { return it }
        // A name that cannot be read only makes the label less helpful; never fail the report.
        return runCatching {
            context.getSystemService(WifiManager::class.java).connectionInfo?.ssid?.let(::cleanName).orEmpty()
        }.getOrDefault("")
    }

    /** Sends the interfaces to the core when they changed; true if they did. */
    fun report(context: Context): Boolean {
        val changed = reportLocked(context)
        if (changed) onChanged?.invoke()
        return changed
    }

    @Synchronized
    private fun reportLocked(context: Context): Boolean {
        val node = Core.node ?: return false
        val snapshot = runCatching { snapshot(context) }.getOrElse {
            UptimeLog.record("network snapshot failed: ${it.javaClass.simpleName}: ${it.message}")
            return false
        }
        if (snapshot == lastSnapshot) return false
        lastSnapshot = snapshot
        node.setNetworkInterfaces(snapshot)
        return true
    }

    private fun snapshot(context: Context): List<NetworkInterfaceData> {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val result = mutableListOf<NetworkInterfaceData>()
        val covered = mutableSetOf<String>()
        @Suppress("DEPRECATION")
        for (network in connectivity.allNetworks) {
            val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
            val link = connectivity.getLinkProperties(network) ?: continue
            val name = link.interfaceName ?: continue
            val kind = when {
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> NetworkInterfaceKind.VPN
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NetworkInterfaceKind.WIFI
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> NetworkInterfaceKind.ETHERNET
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NetworkInterfaceKind.CELLULAR
                else -> NetworkInterfaceKind.OTHER
            }
            val addresses = link.linkAddresses
                .filterNot { it.address.isLinkLocalAddress }
                .map { "${it.address.hostAddress.orEmpty().substringBefore('%')}/${it.prefixLength}" }
            // The IPv4 router: an IPv6 default route's gateway is usually a link-local address.
            val gateway = link.routes
                .filter { it.isDefaultRoute }
                .mapNotNull { it.gateway }
                .firstOrNull { it is Inet4Address && !it.isAnyLocalAddress && !it.isLinkLocalAddress }
                ?.hostAddress.orEmpty()
            covered += name
            val ssid = if (kind == NetworkInterfaceKind.WIFI) wifiName(context, network) else ""
            result += NetworkInterfaceData(name, kind, addresses, gateway, "", ssid)
        }
        // Interfaces that belong to no network: the phone's own hotspot or tethering when the name
        // says so. Anything else (Wi‑Fi Direct "p2p-…", vendor interfaces) is not trusted as a hotspot.
        for (candidate in NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()) {
            if (!candidate.isUp || candidate.isLoopback || candidate.name in covered) continue
            val addresses = candidate.interfaceAddresses
                .filter { it.address is Inet4Address && it.address.isSiteLocalAddress }
                .map { "${it.address.hostAddress}/${it.networkPrefixLength}" }
            if (addresses.isEmpty()) continue
            val kind = if (isTethering(candidate.name)) NetworkInterfaceKind.HOTSPOT else NetworkInterfaceKind.OTHER
            result += NetworkInterfaceData(candidate.name, kind, addresses, "", "", "")
        }
        return result.sortedBy { it.name }
    }

    private fun isTethering(name: String): Boolean =
        !name.startsWith("p2p") && TETHERING_PREFIXES.any { name.startsWith(it) }

    /** Removes network questions left by an earlier version, which asked with notifications. */
    fun dismiss(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.cancel(NOTIFICATION_ID)
        manager.cancel(QUESTION_ID)
    }
}
