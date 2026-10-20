package app.brege.watch

import android.content.Context
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import android.os.Handler
import android.os.Looper
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Node
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONObject
import uniffi.brege_ffi.MacActionKind
import uniffi.brege_ffi.MacStateData

/**
 * The watch's half of Brêge: it has no connection of its own, it asks the phone, and the phone asks
 * the Mac. Started by Android only when a message arrives, so nothing runs on either device in
 * between.
 */
class WatchRelay : WearableListenerService() {

    /**
     * The watch left Bluetooth range, which means you did: the Mac is asked to sleep, if that is
     * what its owner asked for in Settings. Coming back does not unlock it — macOS asks for the
     * password, as it should.
     */
    override fun onPeerDisconnected(peer: Node) {
        if (!lockWhenWatchAway) return
        UptimeLog.record("watch: out of range, locking the Mac in ${AWAY_GRACE_MS / 1000}s")
        Handler(Looper.getMainLooper()).postDelayed({
            if (!stillAway(applicationContext)) {
                UptimeLog.record("watch: back in range, the Mac stays awake")
                return@postDelayed
            }
            val node = Core.node ?: return@postDelayed
            val mac = Core.connectedDevices.firstOrNull() ?: return@postDelayed
            runCatching { node.sendMacAction(mac.id, MacActionKind.LOCK, 0) }
                .onSuccess { UptimeLog.record("watch: the Mac was asked to sleep") }
        }, AWAY_GRACE_MS)
    }

    override fun onPeerConnected(peer: Node) {
        sendState()
    }

    override fun onMessageReceived(event: MessageEvent) {
        if (!fromConnectedWatch(event.sourceNodeId)) return
        when (event.path) {
            PATH_ACTION -> onAction(event.data)
            PATH_ASK -> sendState()
            else -> Unit
        }
    }

    /**
     * Whether this really came from a watch, which is the only thing allowed to press the Mac's keys
     * through here.
     *
     * This service is exported because Play Services, a different app, is what delivers wearable
     * messages to it — so any app on the phone can aim an intent at the component and ask for a
     * ring, a lock or a keystroke on the Mac. Play Services may well check its callers before
     * dispatching, but that is its business and not visible from here, so the question is settled
     * where the answer can be seen: a message whose sender is not a node this phone is currently
     * talking to did not come from your watch, whoever sent it.
     */
    private fun fromConnectedWatch(nodeId: String): Boolean {
        if (nodeId.isEmpty()) return false
        val known = runCatching {
            com.google.android.gms.tasks.Tasks
                .await(Wearable.getNodeClient(applicationContext).connectedNodes)
                .any { it.id == nodeId }
        }.getOrDefault(false)
        if (!known) UptimeLog.record("watch: ignored a message that no connected watch sent")
        return known
    }

    private fun onAction(data: ByteArray) {
        val body = runCatching { JSONObject(String(data)) }.getOrNull() ?: return
        val kind = when (body.optString("kind")) {
            "ring" -> MacActionKind.RING
            "lock" -> MacActionKind.LOCK
            "volume" -> MacActionKind.VOLUME
            "mute" -> MacActionKind.MUTE
            "playpause" -> MacActionKind.MEDIA_PLAY_PAUSE
            "next" -> MacActionKind.MEDIA_NEXT
            "previous" -> MacActionKind.MEDIA_PREVIOUS
            "slidenext" -> MacActionKind.SLIDE_NEXT
            "slideprev" -> MacActionKind.SLIDE_PREVIOUS
            else -> MacActionKind.STATE
        }
        val value = body.optInt("value", 0)
        val node = Core.node ?: return
        val mac = Core.connectedDevices.firstOrNull() ?: run {
            UptimeLog.record("watch: ${kind.name.lowercase()} asked for, but no Mac is connected")
            sendState()
            return
        }
        runCatching { node.sendMacAction(mac.id, kind, value) }
            .onSuccess { UptimeLog.record("watch: ${kind.name.lowercase()} sent to the Mac") }
            .onFailure { UptimeLog.record("watch: sending failed: ${it.javaClass.simpleName}") }
    }

    private fun sendState() = send(applicationContext, lastState)

    companion object {
        /// Stepping away for a moment should not lock you out.
        private const val AWAY_GRACE_MS = 30_000L

        const val PATH_ACTION = "/brege/mac/action"
        const val PATH_ALERT = "/brege/mac/alert"
        const val PATH_STATE = "/brege/mac/state"
        const val PATH_ASK = "/brege/mac/ask"

        /** The last thing a Mac said about itself; the watch shows this while it waits. */
        @Volatile
        private var lastState: MacStateData? = null

        /** What the Mac asked this phone to do for it; the Mac owns these settings. */
        @Volatile
        private var lockWhenWatchAway = false

        fun onWatchSettings(settings: uniffi.brege_ffi.WatchSettingsData) {
            lockWhenWatchAway = settings.lockWhenWatchAway
        }

        /** Something the Mac wants to say while you are away from it. */
        fun onMacAlert(context: Context, title: String, body: String) {
            val payload = JSONObject().put("title", title).put("body", body).toString().toByteArray()
            CoroutineScope(Dispatchers.IO).launch {
                runCatching {
                    val nodes = com.google.android.gms.tasks.Tasks
                        .await(Wearable.getNodeClient(context).connectedNodes)
                    val messages = Wearable.getMessageClient(context)
                    for (node in nodes) {
                        com.google.android.gms.tasks.Tasks
                            .await(messages.sendMessage(node.id, PATH_ALERT, payload))
                    }
                }
            }
        }

        /** True when no watch is within reach any more. */
        private fun stillAway(context: Context): Boolean = runCatching {
            com.google.android.gms.tasks.Tasks
                .await(Wearable.getNodeClient(context).connectedNodes)
                .isEmpty()
        }.getOrDefault(false)

        /** Called from the event handler when a Mac reports its volume, battery or ringing. */
        fun onMacState(context: Context, state: MacStateData) {
            lastState = state
            send(context, state)
        }

        private fun send(context: Context, state: MacStateData?) {
            val body = JSONObject().apply {
                put("connected", state != null && Core.connectedDevices.isNotEmpty())
                put("name", state?.name ?: "")
                put("volume", state?.volume?.toInt() ?: 0)
                put("muted", state?.muted ?: false)
                put("hasBattery", state?.hasBattery ?: false)
                put("battery", state?.battery?.toInt() ?: 0)
                put("charging", state?.charging ?: false)
                put("ringing", state?.ringing ?: false)
                put("keyControl", state?.keyControl ?: false)
            }.toString().toByteArray()

            // Every watch that is paired to this phone, which is normally exactly one.
            CoroutineScope(Dispatchers.IO).launch {
                runCatching {
                    val client = Wearable.getNodeClient(context)
                    val nodes = com.google.android.gms.tasks.Tasks.await(client.connectedNodes)
                    val messages = Wearable.getMessageClient(context)
                    for (node in nodes) {
                        com.google.android.gms.tasks.Tasks.await(
                            messages.sendMessage(node.id, PATH_STATE, body)
                        )
                    }
                }
            }
        }
    }
}
