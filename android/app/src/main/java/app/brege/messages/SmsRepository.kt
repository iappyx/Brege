package app.brege.messages

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.SystemClock
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SubscriptionManager
import androidx.core.content.ContextCompat
import java.util.concurrent.ConcurrentHashMap
import uniffi.brege_ffi.MessageData
import uniffi.brege_ffi.MessageKind
import uniffi.brege_ffi.MessageStatus
import uniffi.brege_ffi.SimData
import uniffi.brege_ffi.ThreadData

/**
 * Reads SMS/MMS threads and messages from the telephony provider as a non-default SMS app.
 * Nothing is written to the provider; the system records sent messages itself.
 */
class SmsRepository(private val context: Context) {
    private val resolver = context.contentResolver
    /** Number → (name, elapsed realtime when looked up); expires so contact edits show up. */
    private val contactNames = ConcurrentHashMap<String, Pair<String, Long>>()
    private val canonicalAddresses = ConcurrentHashMap<Long, String>()

    fun canRead(): Boolean = granted(Manifest.permission.READ_SMS)

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    // --- threads ----------------------------------------------------------------------------

    /** Newest threads first; stops at `sinceMs` when it is positive. */
    fun threads(maxThreads: Int, sinceMs: Long = 0, onlyIds: Set<Long>? = null): List<ThreadData> {
        if (!canRead()) return emptyList()
        val result = ArrayList<ThreadData>()
        resolver.query(
            CONVERSATIONS, arrayOf("_id", "date", "recipient_ids", "snippet"), null, null, "date DESC",
        )?.use { c ->
            while (c.moveToNext() && result.size < maxThreads) {
                val id = c.getLong(0)
                val date = c.getLong(1)
                if (sinceMs > 0 && date < sinceMs) break
                if (onlyIds != null && id !in onlyIds) continue
                val addresses = c.getString(2).orEmpty().split(' ')
                    .mapNotNull { it.toLongOrNull()?.let(::canonicalAddress) }
                    .filter { it.isNotBlank() }
                if (addresses.isEmpty()) continue
                val names = addresses.map(::contactName)
                result += ThreadData(
                    id = "sms:$id",
                    addresses = addresses,
                    names = names,
                    title = if (addresses.size > 1) names.zip(addresses) { n, a -> n.ifEmpty { a } }.joinToString() else "",
                    snippet = c.getString(3).orEmpty(),
                    lastMs = date,
                    kind = MessageKind.SMS,
                    // Group SMS/MMS and alphanumeric senders cannot be answered from the Mac in v1.
                    canReply = addresses.size == 1 && isDialable(addresses[0]),
                    unread = false,
                )
            }
        }
        return result
    }

    private fun canonicalAddress(id: Long): String? = canonicalAddresses[id] ?: run {
        resolver.query(
            Uri.withAppendedPath(CANONICAL_ADDRESSES, id.toString()), arrayOf("address"), null, null, null,
        )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }?.also { canonicalAddresses[id] = it }
    }

    // --- messages ---------------------------------------------------------------------------

    /**
     * Messages of one thread (or all threads when `threadId` is null) with `sinceMs < date <= beforeMs`,
     * newest first, at most `limit`. History pages include `beforeMs` itself: several messages can
     * share the oldest timestamp the Mac has (MMS dates are whole seconds), and the Mac's store
     * de-duplicates by message id.
     */
    fun messages(threadId: Long?, sinceMs: Long, beforeMs: Long, limit: Int): List<MessageData> {
        if (!canRead()) return emptyList()
        val sms = smsMessages(threadId, sinceMs, beforeMs, limit)
        val mms = mmsMessages(threadId, sinceMs, beforeMs, limit)
        return (sms + mms).sortedByDescending { it.tsMs }.take(limit)
    }

    private fun smsMessages(threadId: Long?, sinceMs: Long, beforeMs: Long, limit: Int): List<MessageData> {
        val selection = buildString {
            append("date > ? AND date <= ? AND type != ${Telephony.Sms.MESSAGE_TYPE_DRAFT}")
            if (threadId != null) append(" AND thread_id = ?")
        }
        val args = listOfNotNull(sinceMs.toString(), beforeMs.toString(), threadId?.toString()).toTypedArray()
        val out = ArrayList<MessageData>()
        resolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf("_id", "thread_id", "address", "body", "date", "type", "sub_id"),
            selection, args, "date DESC",
        )?.use { c ->
            while (c.moveToNext() && out.size < limit) {
                val type = c.getInt(5)
                val outgoing = type != Telephony.Sms.MESSAGE_TYPE_INBOX
                val address = c.getString(2).orEmpty()
                out += MessageData(
                    id = "sms:${c.getLong(0)}",
                    threadId = "sms:${c.getLong(1)}",
                    address = address,
                    senderName = if (outgoing) "" else contactName(address),
                    body = c.getString(3).orEmpty(),
                    tsMs = c.getLong(4),
                    outgoing = outgoing,
                    subId = c.getIntOrDefault(6, -1),
                    status = when (type) {
                        Telephony.Sms.MESSAGE_TYPE_INBOX -> MessageStatus.RECEIVED
                        Telephony.Sms.MESSAGE_TYPE_FAILED -> MessageStatus.FAILED
                        Telephony.Sms.MESSAGE_TYPE_OUTBOX, Telephony.Sms.MESSAGE_TYPE_QUEUED -> MessageStatus.SENDING
                        else -> MessageStatus.SENT
                    },
                    hasMedia = false,
                    kind = MessageKind.SMS,
                )
            }
        }
        return out
    }

    private fun mmsMessages(threadId: Long?, sinceMs: Long, beforeMs: Long, limit: Int): List<MessageData> {
        // The MMS table stores dates in seconds.
        val selection = buildString {
            append("date > ? AND date <= ? AND msg_box != ${Telephony.Mms.MESSAGE_BOX_DRAFTS}")
            if (threadId != null) append(" AND thread_id = ?")
        }
        val args = listOfNotNull(
            (sinceMs / 1000).toString(),
            (beforeMs / 1000).toString(),
            threadId?.toString(),
        ).toTypedArray()
        val out = ArrayList<MessageData>()
        resolver.query(
            Telephony.Mms.CONTENT_URI, arrayOf("_id", "thread_id", "date", "msg_box", "sub_id"),
            selection, args, "date DESC",
        )?.use { c ->
            while (c.moveToNext() && out.size < limit) {
                val id = c.getLong(0)
                val box = c.getInt(3)
                val outgoing = box != Telephony.Mms.MESSAGE_BOX_INBOX
                val (text, hasMedia) = mmsParts(id)
                val address = if (outgoing) "" else mmsSender(id)
                out += MessageData(
                    id = "mms:$id",
                    threadId = "sms:${c.getLong(1)}",
                    address = address,
                    senderName = if (address.isEmpty()) "" else contactName(address),
                    body = text,
                    tsMs = c.getLong(2) * 1000,
                    outgoing = outgoing,
                    subId = c.getIntOrDefault(4, -1),
                    status = when (box) {
                        Telephony.Mms.MESSAGE_BOX_INBOX -> MessageStatus.RECEIVED
                        Telephony.Mms.MESSAGE_BOX_FAILED -> MessageStatus.FAILED
                        Telephony.Mms.MESSAGE_BOX_OUTBOX -> MessageStatus.SENDING
                        else -> MessageStatus.SENT
                    },
                    hasMedia = hasMedia,
                    kind = MessageKind.SMS,
                )
            }
        }
        return out
    }

    private fun mmsParts(id: Long): Pair<String, Boolean> {
        val text = StringBuilder()
        var media = false
        resolver.query(MMS_PARTS, arrayOf("ct", "text"), "mid = ?", arrayOf(id.toString()), null)?.use { c ->
            while (c.moveToNext()) {
                val type = c.getString(0).orEmpty()
                when {
                    type == "text/plain" -> c.getString(1)?.let { if (text.isNotEmpty()) text.append('\n'); text.append(it) }
                    type.startsWith("image/") || type.startsWith("video/") || type.startsWith("audio/") -> media = true
                }
            }
        }
        return text.toString() to media
    }

    private fun mmsSender(id: Long): String =
        resolver.query(
            Uri.parse("content://mms/$id/addr"), arrayOf("address"), "type = $PDU_FROM", null, null,
        )?.use { c -> if (c.moveToFirst()) c.getString(0).orEmpty() else "" } ?: ""

    /** True if an SMS or text MMS with this body exists within ±5 minutes (used to tell SMS from RCS). */
    fun hasSmsLike(body: String, tsMs: Long): Boolean {
        if (!canRead() || body.isEmpty()) return false
        val sms = resolver.query(
            Telephony.Sms.CONTENT_URI, arrayOf("_id"), "body = ? AND date > ? AND date < ?",
            arrayOf(body, (tsMs - 300_000).toString(), (tsMs + 300_000).toString()), null,
        )?.use { it.count > 0 } ?: false
        return sms || hasMmsLike(body, tsMs)
    }

    private fun hasMmsLike(body: String, tsMs: Long): Boolean = runCatching {
        // MMS dates are in seconds; the text lives in the part table.
        val ids = resolver.query(
            Telephony.Mms.CONTENT_URI, arrayOf("_id"), "date > ? AND date < ?",
            arrayOf(((tsMs - 300_000) / 1000).toString(), ((tsMs + 300_000) / 1000 + 1).toString()), null,
        )?.use { c -> buildList { while (c.moveToNext()) add(c.getLong(0)) } }.orEmpty()
        if (ids.isEmpty()) return@runCatching false
        resolver.query(
            MMS_PARTS, arrayOf("_id"), "mid IN (${ids.joinToString()}) AND ct = 'text/plain' AND text = ?",
            arrayOf(body), null,
        )?.use { it.count > 0 } ?: false
    }.getOrDefault(false)

    /** True if a sent (or sending) SMS with this body was recorded after `sinceMs - 60 s`. */
    fun hasSentSms(body: String, sinceMs: Long): Boolean {
        if (!canRead() || body.isEmpty()) return false
        return resolver.query(
            Telephony.Sms.CONTENT_URI, arrayOf("_id"), "body = ? AND date > ? AND type != ${Telephony.Sms.MESSAGE_TYPE_INBOX}",
            arrayOf(body, (sinceMs - 60_000).toString()), null,
        )?.use { it.count > 0 } ?: false
    }

    // --- contacts and SIMs -------------------------------------------------------------------

    fun contactName(number: String): String {
        if (number.isBlank() || !granted(Manifest.permission.READ_CONTACTS)) return ""
        val now = SystemClock.elapsedRealtime()
        contactNames[number]?.let { (name, at) -> if (now - at < CONTACT_CACHE_MS) return name }
        val name = runCatching {
            resolver.query(
                Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number)),
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null,
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        }.getOrNull().orEmpty()
        contactNames[number] = name to now
        return name
    }

    @SuppressLint("MissingPermission") // checked on the first line
    fun sims(): List<SimData> {
        if (!granted(Manifest.permission.READ_PHONE_STATE)) return emptyList()
        val manager = context.getSystemService(SubscriptionManager::class.java) ?: return emptyList()
        return runCatching {
            manager.activeSubscriptionInfoList.orEmpty().map {
                SimData(subId = it.subscriptionId, label = it.displayName?.toString().orEmpty(), slot = it.simSlotIndex)
            }
        }.getOrDefault(emptyList())
    }

    fun clearContactCache() = contactNames.clear()

    companion object {
        private val CONVERSATIONS: Uri = Uri.parse("content://mms-sms/conversations?simple=true")
        private val CANONICAL_ADDRESSES: Uri = Uri.parse("content://mms-sms/canonical-address")
        private val MMS_PARTS: Uri = Uri.parse("content://mms/part")
        private const val PDU_FROM = 137
        private const val CONTACT_CACHE_MS = 5 * 60_000L

        fun isDialable(number: String): Boolean =
            number.any(Char::isDigit) && number.all { it.isDigit() || it in "+*# -()." } && number.length <= 32
    }
}

private fun Cursor.getIntOrDefault(index: Int, default: Int): Int =
    if (isNull(index)) default else getInt(index)
