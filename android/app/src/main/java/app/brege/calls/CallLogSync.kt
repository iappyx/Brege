package app.brege.calls

import android.Manifest
import android.content.ContentResolver
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.CallLog
import androidx.core.content.ContextCompat
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import app.brege.messages.SmsRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.brege_ffi.CallDirection
import uniffi.brege_ffi.CallLogData

/**
 * Recent calls for the Mac: answers its requests and pushes new calls while a Mac is connected.
 * The Mac keeps the list in its encrypted cache, so it stays readable when the phone is away.
 */
object CallLogSync {
    private const val TAG = "BregeCallLog"
    /** Newest calls sent when a Mac connects without a cache. */
    private const val INITIAL_LIMIT = 200
    /** Largest page of older calls one request can ask for. */
    private const val MAX_LIMIT = 500

    private lateinit var app: Context
    private val repo by lazy { SmsRepository(app) }
    private var observer: ContentObserver? = null
    private val handler = Handler(Looper.getMainLooper())

    fun init(context: Context) {
        app = context.applicationContext
    }

    private fun granted() =
        ContextCompat.checkSelfPermission(app, Manifest.permission.READ_CALL_LOG) ==
            PackageManager.PERMISSION_GRANTED

    // --- requests from the Mac ------------------------------------------------------------------

    /** `beforeMs` 0 asks for calls newer than `sinceMs`; otherwise for older ones (paging). */
    suspend fun onRequested(from: String, sinceMs: Long, beforeMs: Long, limit: Int) =
        withContext(Dispatchers.IO) {
            val node = Core.node ?: return@withContext
            if (!granted()) {
                UptimeLog.record("calls: recent calls requested but call log permission not granted")
                return@withContext
            }
            val history = beforeMs > 0
            val entries = read(
                sinceMs = if (history) 0 else sinceMs,
                beforeMs = if (history) beforeMs else Long.MAX_VALUE,
                limit = limit.coerceIn(1, MAX_LIMIT),
            )
            runCatching { node.sendCallLog(from, entries, history) }
                .onFailure { UptimeLog.record("calls: sending recent calls failed: ${it.javaClass.simpleName}") }
        }

    // --- live updates ---------------------------------------------------------------------------

    /** Watches the call log while the service runs and the permission is granted. */
    fun startObserving() {
        if (observer != null || !granted()) return
        val o = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) {
                handler.removeCallbacks(pushRunnable)
                handler.postDelayed(pushRunnable, 1_500)
            }
        }
        runCatching {
            app.contentResolver.registerContentObserver(CallLog.Calls.CONTENT_URI, true, o)
        }.onSuccess {
            observer = o
            UptimeLog.record("calls: observing the call log")
        }
    }

    fun stopObserving() {
        observer?.let { runCatching { app.contentResolver.unregisterContentObserver(it) } }
        observer = null
    }

    private val pushRunnable = Runnable { Core.scope.launch { pushRecent() } }

    private suspend fun pushRecent() = withContext(Dispatchers.IO) {
        val node = Core.node ?: return@withContext
        if (Core.connectedDevices.isEmpty() || !granted()) return@withContext
        val entries = read(sinceMs = 0, beforeMs = Long.MAX_VALUE, limit = 10)
        if (entries.isEmpty()) return@withContext
        runCatching { node.publishCallLog(entries) }
    }

    /** Called when a call ends, so the finished call reaches the Mac with its duration. */
    fun onCallEnded() {
        handler.removeCallbacks(pushRunnable)
        // The provider writes the row a moment after the call ends.
        handler.postDelayed(pushRunnable, 2_000)
    }

    // --- reading ---------------------------------------------------------------------------------

    private fun read(sinceMs: Long, beforeMs: Long, limit: Int): List<CallLogData> {
        val entries = ArrayList<CallLogData>()
        val columns = arrayOf(
            CallLog.Calls._ID,
            CallLog.Calls.NUMBER,
            CallLog.Calls.CACHED_NAME,
            CallLog.Calls.TYPE,
            CallLog.Calls.DATE,
            CallLog.Calls.DURATION,
            if (Build.VERSION.SDK_INT >= 24) CallLog.Calls.PHONE_ACCOUNT_ID else CallLog.Calls._ID,
        )
        val where = "${CallLog.Calls.DATE} > ? AND ${CallLog.Calls.DATE} < ?"
        val args = arrayOf(sinceMs.toString(), beforeMs.toString())
        val sort = "${CallLog.Calls.DATE} DESC"
        runCatching {
            if (Build.VERSION.SDK_INT >= 30) {
                // The provider rejects a "LIMIT" glued to the sort order, so pass it as an argument.
                val query = Bundle().apply {
                    putString(ContentResolver.QUERY_ARG_SQL_SELECTION, where)
                    putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
                    putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, sort)
                    putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
                }
                app.contentResolver.query(CallLog.Calls.CONTENT_URI, columns, query, null)
            } else {
                app.contentResolver.query(CallLog.Calls.CONTENT_URI, columns, where, args, sort)
            }
        }.onFailure {
            UptimeLog.record("calls: reading the call log failed: ${it.javaClass.simpleName}: ${it.message}")
        }.getOrNull()?.use { c ->
            while (c.moveToNext() && entries.size < limit) {
                val number = c.getString(1).orEmpty()
                val name = c.getString(2).orEmpty().ifEmpty { repo.contactName(number) }
                entries += CallLogData(
                    id = c.getLong(0).toString(),
                    number = number,
                    contactName = name,
                    direction = direction(c.getInt(3)),
                    startedMs = c.getLong(4),
                    durationS = c.getLong(5).coerceIn(0, UInt.MAX_VALUE.toLong()).toUInt(),
                    subId = subId(c.getString(6)),
                )
            }
        }
        return entries
    }

    private fun direction(type: Int): CallDirection = when (type) {
        CallLog.Calls.OUTGOING_TYPE -> CallDirection.OUTGOING
        CallLog.Calls.MISSED_TYPE -> CallDirection.MISSED
        CallLog.Calls.REJECTED_TYPE -> CallDirection.REJECTED
        CallLog.Calls.BLOCKED_TYPE -> CallDirection.BLOCKED
        CallLog.Calls.VOICEMAIL_TYPE -> CallDirection.VOICEMAIL
        else -> CallDirection.INCOMING
    }

    /** The account id is the subscription id on most phones; -1 when it is something else. */
    private fun subId(account: String?): Int = account?.toIntOrNull() ?: -1
}
