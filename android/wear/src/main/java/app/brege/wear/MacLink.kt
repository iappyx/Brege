package app.brege.wear

import android.content.Context
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

/** How the Mac stands, as the phone last told this watch. */
data class MacState(
    val connected: Boolean = false,
    val name: String = "",
    val volume: Int = 0,
    val muted: Boolean = false,
    val hasBattery: Boolean = false,
    val battery: Int = 0,
    val charging: Boolean = false,
    val ringing: Boolean = false,
    val keyControl: Boolean = false,
)

/**
 * The watch's only line to the world: the phone. Messages go out when you tap something and when a
 * screen opens; nothing is kept open in between, because Wear OS would suspend it anyway.
 */
object MacLink {
    const val PATH_ACTION = "/brege/mac/action"
    const val PATH_STATE = "/brege/mac/state"
    const val PATH_ASK = "/brege/mac/ask"
    const val PATH_ALERT = "/brege/mac/alert"

    val state = MutableStateFlow(MacState())
    /** False once a phone has answered, so the watch can say "phone not reachable" honestly. */
    val waiting = MutableStateFlow(true)

    fun ask(context: Context) {
        waiting.value = true
        send(context, PATH_ASK, ByteArray(0))
    }

    fun act(context: Context, kind: String, value: Int = 0) {
        val body = JSONObject().put("kind", kind).put("value", value).toString().toByteArray()
        send(context, PATH_ACTION, body)
    }

    fun received(data: ByteArray) {
        val body = runCatching { JSONObject(String(data)) }.getOrNull() ?: return
        state.value = MacState(
            connected = body.optBoolean("connected"),
            name = body.optString("name"),
            volume = body.optInt("volume"),
            muted = body.optBoolean("muted"),
            hasBattery = body.optBoolean("hasBattery"),
            battery = body.optInt("battery"),
            charging = body.optBoolean("charging"),
            ringing = body.optBoolean("ringing"),
            keyControl = body.optBoolean("keyControl"),
        )
        waiting.value = false
    }

    private fun send(context: Context, path: String, body: ByteArray) {
        CoroutineScope(Dispatchers.IO).launch {
            runCatching {
                val nodes = Tasks.await(Wearable.getNodeClient(context).connectedNodes)
                val messages = Wearable.getMessageClient(context)
                for (node in nodes) {
                    Tasks.await(messages.sendMessage(node.id, path, body))
                }
            }
        }
    }
}

/** The phone's answers arrive here, whether the app is open or only the tile is showing. */
class StateListener : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        when (event.path) {
            MacLink.PATH_STATE -> {
                MacLink.received(event.data)
                MacTileService.refresh(this)
            }
            MacLink.PATH_ALERT -> showAlert(event.data)
        }
    }

    /// What the Mac wanted to say, as an ordinary watch notification you can swipe away.
    private fun showAlert(data: ByteArray) {
        val body = runCatching { JSONObject(String(data)) }.getOrNull() ?: return
        val manager = getSystemService(android.app.NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            android.app.NotificationChannel(
                CHANNEL, "From your Mac", android.app.NotificationManager.IMPORTANCE_DEFAULT
            )
        )
        val notification = android.app.Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(body.optString("title"))
            .setContentText(body.optString("body"))
            .setAutoCancel(true)
            .build()
        manager.notify(body.optString("title").hashCode(), notification)
    }

    private companion object {
        const val CHANNEL = "mac-alerts"
    }
}
