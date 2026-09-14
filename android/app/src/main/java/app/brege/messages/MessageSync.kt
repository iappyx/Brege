package app.brege.messages

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import app.brege.notifications.BregeNotificationListener
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.brege_ffi.MessageData
import uniffi.brege_ffi.MessageStatus
import uniffi.brege_ffi.ThreadData

/** Answers sync requests from the Mac, pushes new messages live and sends SMS. */
object MessageSync {
    private const val TAG = "BregeMessages"
    private const val LIVE_OVERLAP_MS = 2 * 60 * 1000L
    private const val HISTORY_MAX = 200

    private lateinit var app: Context
    private val repo by lazy { SmsRepository(app) }
    private var observer: ContentObserver? = null
    private val handler = Handler(Looper.getMainLooper())
    /** Newest message timestamp already pushed; live pushes resend a small overlap for status updates. */
    private val watermark = AtomicLong(System.currentTimeMillis())

    fun init(context: Context) {
        app = context.applicationContext
    }

    // --- sync ---------------------------------------------------------------------------------

    suspend fun onSyncRequested(sinceMs: Long, maxThreads: Int, perThread: Int) = withContext(Dispatchers.IO) {
        val node = Core.node ?: return@withContext
        node.publishSims(repo.sims())
        if (!repo.canRead()) {
            UptimeLog.record("messages: sync requested but SMS permission not granted")
            return@withContext
        }
        val started = System.currentTimeMillis()
        val threads = repo.threads(maxThreads, sinceMs)
        val messages = if (sinceMs <= 0) {
            threads.flatMap { t -> repo.messages(t.numericId(), 0, Long.MAX_VALUE, perThread) }
        } else {
            repo.messages(null, sinceMs, Long.MAX_VALUE, maxThreads * perThread)
        }
        node.publishMessageThreads(threads + RcsMirror.threads())
        node.publishMessages(messages + RcsMirror.messages(), history = false)
        messages.maxOfOrNull { it.tsMs }?.let { newest -> watermark.updateAndGet { maxOf(it, newest) } }
        // Counts only: message content never goes into logs.
        UptimeLog.record(
            "messages: synced ${threads.size} threads, ${messages.size} messages (since=$sinceMs) " +
                "in ${System.currentTimeMillis() - started} ms",
        )
    }

    suspend fun onHistoryRequested(threadId: String, beforeMs: Long, limit: Int) = withContext(Dispatchers.IO) {
        val node = Core.node ?: return@withContext
        val numeric = threadId.removePrefix("sms:").toLongOrNull() ?: return@withContext
        val messages = repo.messages(numeric, 0, beforeMs, limit.coerceIn(1, HISTORY_MAX))
        node.publishMessages(messages, history = true)
    }

    // --- live updates -------------------------------------------------------------------------

    /** Watches the provider while the service runs and SMS access is granted. */
    fun startObserving() {
        if (observer != null || !repo.canRead()) return
        val o = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) {
                handler.removeCallbacks(pushRunnable)
                handler.postDelayed(pushRunnable, 1_500)
            }
        }
        app.contentResolver.registerContentObserver(Uri.parse("content://mms-sms/"), true, o)
        app.contentResolver.registerContentObserver(Uri.parse("content://sms/"), true, o)
        observer = o
        UptimeLog.record("messages: observing SMS/MMS provider")
    }

    fun stopObserving() {
        observer?.let { app.contentResolver.unregisterContentObserver(it) }
        observer = null
    }

    private val pushRunnable = Runnable { Core.scope.launch { pushRecent() } }

    private suspend fun pushRecent() = withContext(Dispatchers.IO) {
        val node = Core.node ?: return@withContext
        if (Core.connectedDevices.isEmpty()) return@withContext
        val since = watermark.get() - LIVE_OVERLAP_MS
        val messages = repo.messages(null, since, Long.MAX_VALUE, 500)
        if (messages.isEmpty()) return@withContext
        val threadIds = messages.mapNotNull { it.threadId.removePrefix("sms:").toLongOrNull() }.toSet()
        node.publishMessageThreads(repo.threads(threadIds.size + 10, onlyIds = threadIds))
        node.publishMessages(messages, history = false)
        watermark.updateAndGet { maxOf(it, messages.maxOf(MessageData::tsMs)) }
    }

    // --- sending ------------------------------------------------------------------------------

    fun send(from: String, clientId: String, threadId: String, address: String, body: String, subId: Int) {
        val node = Core.node ?: return
        fun status(s: MessageStatus, error: String = "") =
            runCatching { node.publishSendStatus(from, clientId, s, error) }

        if (threadId.startsWith("rcs:")) {
            val ok = BregeNotificationListener.replyToConversation(threadId, body)
            UptimeLog.record("messages: RCS reply ${if (ok) "sent" else "failed (no live notification)"}")
            status(if (ok) MessageStatus.SENT else MessageStatus.FAILED, if (ok) "" else "Open the conversation on your phone to reply")
            return
        }
        if (ContextCompat.checkSelfPermission(app, Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            status(MessageStatus.FAILED, "SMS permission not granted on the phone")
            return
        }
        try {
            val manager = smsManager(subId)
            val parts = manager.divideMessage(body)
            val intents = ArrayList(
                parts.indices.map { index ->
                    PendingIntent.getBroadcast(
                        app, (clientId.hashCode() * 31) + index,
                        Intent(app, SmsSentReceiver::class.java)
                            .putExtra(EXTRA_FROM, from).putExtra(EXTRA_CLIENT, clientId)
                            .putExtra(EXTRA_PART, index).putExtra(EXTRA_PARTS, parts.size),
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT,
                    )
                },
            )
            pendingSends[clientId] = PendingSend(from, threadId, address, body, subId, System.currentTimeMillis())
            manager.sendMultipartTextMessage(address, null, parts, intents, null)
            UptimeLog.record("messages: SMS send started (${parts.size} part(s))")
            status(MessageStatus.SENDING)
        } catch (e: Exception) {
            Log.w(TAG, "send failed", e)
            status(MessageStatus.FAILED, e.message ?: "Could not send")
        }
    }

    @Suppress("DEPRECATION")
    private fun smsManager(subId: Int): SmsManager = when {
        Build.VERSION.SDK_INT >= 31 -> app.getSystemService(SmsManager::class.java).let {
            if (subId >= 0) it.createForSubscriptionId(subId) else it
        }
        subId >= 0 -> SmsManager.getSmsManagerForSubscriptionId(subId)
        else -> SmsManager.getDefault()
    }

    private data class PendingSend(
        val from: String,
        val threadId: String,
        val address: String,
        val body: String,
        val subId: Int,
        val startedMs: Long,
    )

    private val pendingSends = java.util.concurrent.ConcurrentHashMap<String, PendingSend>()

    /**
     * Called when the last part was sent. The system is supposed to record messages sent by
     * non-default SMS apps, but not every messaging app / Android version does; if the provider
     * has no matching entry, publish the message ourselves so it stays in the Mac's conversation.
     */
    internal fun onSent(clientId: String) {
        val send = pendingSends.remove(clientId) ?: return
        Core.scope.launch(Dispatchers.IO) {
            kotlinx.coroutines.delay(3_000) // give the system time to write the provider entry
            if (repo.hasSentSms(send.body, send.startedMs)) {
                pushRecent()
                return@launch
            }
            val threadId = send.threadId.ifEmpty {
                runCatching { "sms:" + android.provider.Telephony.Threads.getOrCreateThreadId(app, send.address) }
                    .getOrDefault("")
            }
            if (threadId.isEmpty()) return@launch
            UptimeLog.record("messages: provider has no entry for the sent SMS; publishing it directly")
            Core.node?.publishMessages(
                listOf(
                    MessageData(
                        id = "sent:$clientId",
                        threadId = threadId,
                        address = send.address,
                        senderName = "",
                        body = send.body,
                        tsMs = send.startedMs,
                        outgoing = true,
                        subId = send.subId,
                        status = MessageStatus.SENT,
                        hasMedia = false,
                        kind = uniffi.brege_ffi.MessageKind.SMS,
                    ),
                ),
                history = false,
            )
        }
    }

    internal fun onSendFailed(clientId: String) {
        pendingSends.remove(clientId)
    }

    internal const val EXTRA_FROM = "from"
    internal const val EXTRA_CLIENT = "client"
    internal const val EXTRA_PART = "part"
    internal const val EXTRA_PARTS = "parts"
}

/** Receives the sent result of each SMS part. */
class SmsSentReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val node = Core.node ?: return
        val from = intent.getStringExtra(MessageSync.EXTRA_FROM) ?: return
        val client = intent.getStringExtra(MessageSync.EXTRA_CLIENT) ?: return
        val part = intent.getIntExtra(MessageSync.EXTRA_PART, 0)
        val parts = intent.getIntExtra(MessageSync.EXTRA_PARTS, 1)
        if (resultCode != android.app.Activity.RESULT_OK) {
            UptimeLog.record("messages: SMS part ${part + 1}/$parts failed, result $resultCode")
            MessageSync.onSendFailed(client)
            runCatching { node.publishSendStatus(from, client, MessageStatus.FAILED, "Carrier error $resultCode") }
        } else if (part == parts - 1) {
            UptimeLog.record("messages: SMS sent ($parts part(s))")
            runCatching { node.publishSendStatus(from, client, MessageStatus.SENT, "") }
            MessageSync.onSent(client)
        }
    }
}

private fun ThreadData.numericId(): Long? = id.removePrefix("sms:").toLongOrNull()
