package app.brege.messages

import android.app.Notification
import android.content.Context
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationCompat
import app.brege.core.Core
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import uniffi.brege_ffi.MessageData
import uniffi.brege_ffi.MessageKind
import uniffi.brege_ffi.MessageStatus
import uniffi.brege_ffi.ThreadData

/**
 * RCS has no public API, so recent RCS messages are mirrored from the messaging app's
 * conversation notifications. Messages that also exist in the SMS provider are
 * skipped, so SMS shown by the same app are not duplicated.
 */
object RcsMirror {
    val MESSAGING_PACKAGES = setOf("com.google.android.apps.messaging", "com.samsung.android.messaging")
    private const val MAX_THREADS = 50
    private const val MAX_MESSAGES = 50

    private val threads = ConcurrentHashMap<String, ThreadData>()
    private val messages = ConcurrentHashMap<String, MutableMap<String, MessageData>>()
    /** Live notification per RCS thread, for replies from the Mac. */
    private val replyTargets = ConcurrentHashMap<String, String>()

    fun threads(): List<ThreadData> = threads.values.toList()

    fun messages(): List<MessageData> = messages.values.flatMap { it.values }

    fun notificationKeyFor(threadId: String): String? = replyTargets[threadId]

    fun onNotificationRemoved(key: String) {
        replyTargets.entries.removeIf { it.value == key }
    }

    fun onNotification(context: Context, sbn: StatusBarNotification) {
        if (sbn.packageName !in MESSAGING_PACKAGES) return
        val repo = SmsRepository(context)
        if (!repo.canRead()) return // cannot tell RCS from SMS without SMS access
        val style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(sbn.notification) ?: return
        val extras = sbn.notification.extras
        val key = sbn.notification.shortcutId
            ?: style.conversationTitle?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
            ?: return
        val threadId = "rcs:" + hash(sbn.packageName + "|" + key).take(20)
        val userName = style.user.name?.toString()
        val canReply = sbn.notification.actions.orEmpty().any { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }
        if (canReply) replyTargets[threadId] = sbn.key

        Core.scope.launch(Dispatchers.IO) {
            val fresh = style.messages.takeLast(MAX_MESSAGES).mapNotNull { m ->
                val text = m.text?.toString().orEmpty()
                if (text.isEmpty() || repo.hasSmsLike(text, m.timestamp)) return@mapNotNull null
                val sender = m.person?.name?.toString().orEmpty()
                val outgoing = m.person == null || m.person?.key == style.user.key || (userName != null && sender == userName)
                MessageData(
                    id = "rcs:" + hash("$threadId|$sender|${m.timestamp}|$text").take(24),
                    threadId = threadId,
                    address = "",
                    senderName = if (outgoing) "" else sender,
                    body = text,
                    tsMs = m.timestamp,
                    outgoing = outgoing,
                    subId = -1,
                    status = if (outgoing) MessageStatus.SENT else MessageStatus.RECEIVED,
                    hasMedia = m.dataUri != null,
                    kind = MessageKind.RCS,
                )
            }
            if (fresh.isEmpty()) return@launch
            val participants = fresh.filter { !it.outgoing }.map { it.senderName }.filter { it.isNotEmpty() }.distinct()
            val thread = ThreadData(
                id = threadId,
                addresses = emptyList(),
                names = participants,
                title = style.conversationTitle?.toString() ?: participants.joinToString().ifEmpty { key },
                snippet = fresh.last().body,
                lastMs = fresh.maxOf { it.tsMs },
                kind = MessageKind.RCS,
                canReply = canReply,
                unread = false,
            )
            threads[threadId] = thread
            messages.getOrPut(threadId) { ConcurrentHashMap() }.apply { fresh.forEach { put(it.id, it) } }
            trim()
            val node = Core.node ?: return@launch
            if (Core.connectedDevices.isEmpty()) return@launch
            node.publishMessageThreads(listOf(thread))
            node.publishMessages(fresh, history = false)
        }
    }

    private fun trim() {
        if (threads.size <= MAX_THREADS) return
        threads.values.sortedBy { it.lastMs }.take(threads.size - MAX_THREADS).forEach {
            threads.remove(it.id)
            messages.remove(it.id)
        }
    }

    private fun hash(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
}
