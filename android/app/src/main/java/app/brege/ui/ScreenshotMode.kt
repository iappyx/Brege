package app.brege.ui

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import uniffi.brege_ffi.Device
import uniffi.brege_ffi.KnownNetworkData
import uniffi.brege_ffi.NetworkPathData
import uniffi.brege_ffi.Platform

/**
 * README screenshots with made-up data (debug builds only):
 * `adb shell am start -n app.brege/.ui.MainActivity --es brege.screenshots connected` (or `new-network`).
 * The screen then shows a fictional Mac and networks instead of anything real.
 */
object ScreenshotMode {
    var scene: String? = null
        private set

    val active: Boolean get() = scene != null

    fun apply(context: Context, intent: Intent?) {
        val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        scene = intent?.getStringExtra("brege.screenshots")?.takeIf { debuggable }
    }

    private val mac get() = Device(
        id = "screenshot-mac", shortId = "", name = "Home Mac", platform = Platform.MAC_OS,
        connected = scene != "new-network", lastSeenMs = System.currentTimeMillis(),
    )

    val devices: List<Device> get() = listOf(mac)

    val undecided: List<NetworkPathData>
        get() = if (scene == "new-network") {
            listOf(NetworkPathData("cafe", false, "Wi‑Fi “Café Central”", "Café Central", false, false, emptyList()))
        } else {
            emptyList()
        }

    val known: List<KnownNetworkData>
        get() = listOf(
            KnownNetworkData("home", false, "Wi‑Fi “Home”", System.currentTimeMillis(), true),
            KnownNetworkData("vpn", true, "VPN 10.8.0.2 (tun0)", System.currentTimeMillis(), true),
        )

    val folders = listOf("DCIM", "Documents")
}
