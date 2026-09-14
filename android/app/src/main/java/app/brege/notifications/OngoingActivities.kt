package app.brege.notifications

import android.app.Notification
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.notification.StatusBarNotification
import androidx.annotation.RequiresApi
import app.brege.core.Core
import app.brege.core.toPng
import app.brege.diagnostics.UptimeLog
import java.util.concurrent.ConcurrentHashMap
import uniffi.brege_ffi.OngoingActivityData
import uniffi.brege_ffi.NotificationActionData

/**
 * Ongoing activities on the Mac: a curated set of ongoing notifications — timers, stopwatches,
 * navigation, deliveries and rides, Android 16 Live Updates — mirrored with at most one update
 * per second per activity. Media stays with the media controls; plain foreground-service notices are
 * skipped.
 */
object OngoingActivities {
    private const val MIN_INTERVAL_MS = 1_000L
    private const val ICON_SIZE = 64
    private const val EXTRA_SHORT_CRITICAL_TEXT = "android.shortCriticalText"
    private const val PROGRESS_STYLE = "android.app.Notification\$ProgressStyle"
    private const val METRIC_STYLE = "android.app.Notification\$MetricStyle"

    private val categories = setOf(
        Notification.CATEGORY_NAVIGATION,
        Notification.CATEGORY_STOPWATCH,
        Notification.CATEGORY_PROGRESS,
        Notification.CATEGORY_WORKOUT,
        Notification.CATEGORY_LOCATION_SHARING,
    )

    /** Packages whose ongoing notices are noise on the Mac. */
    private val ignoredPackages = setOf("android", "com.android.systemui", "com.android.shell")

    private val shown = ConcurrentHashMap<String, StatusBarNotification>()
    private val lastSent = ConcurrentHashMap<String, Long>()
    /** What was last sent apart from progress, to send state changes (pause, new step) at once. */
    private val lastState = ConcurrentHashMap<String, String>()
    private val pending = ConcurrentHashMap<String, Runnable>()
    private val handler = Handler(Looper.getMainLooper())

    fun isOngoingActivity(context: Context, sbn: StatusBarNotification): Boolean {
        val n = sbn.notification
        val extras = n.extras
        if (sbn.packageName == context.packageName || sbn.packageName in ignoredPackages) return false
        if (extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) return false
        if (n.category == Notification.CATEGORY_CALL || n.category == Notification.CATEGORY_TRANSPORT) return false
        val promoted = Build.VERSION.SDK_INT >= 36 && (n.flags and Notification.FLAG_PROMOTED_ONGOING) != 0
        val progress = extras.getInt(Notification.EXTRA_PROGRESS_MAX, 0) > 0 ||
            extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE) ||
            extras.getString(Notification.EXTRA_TEMPLATE) == PROGRESS_STYLE
        val timer = extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER) && n.`when` != 0L
        return promoted || progress || timer || n.category in categories
    }

    /** Called for every ongoing notification; returns true when it is shown as an ongoing activity. */
    fun onPosted(context: Context, sbn: StatusBarNotification): Boolean {
        if (!isOngoingActivity(context, sbn)) {
            if (shown.containsKey(sbn.key)) onRemoved(sbn.key) // no longer qualifies
            return false
        }
        val first = shown.put(sbn.key, sbn) == null
        schedule(context, sbn.key, first)
        return true
    }

    fun onRemoved(key: String) {
        if (shown.remove(key) == null) return
        pending.remove(key)?.let(handler::removeCallbacks)
        lastSent.remove(key)
        lastState.remove(key)
        Core.node?.endOngoingActivity(key)
    }

    fun find(key: String): StatusBarNotification? = shown[key]

    /** A Mac connected: send everything that is running now, with icons. */
    fun resendAll(context: Context) {
        lastSent.clear()
        shown.keys.forEach { schedule(context, it, first = true) }
    }

    private fun schedule(context: Context, key: String, first: Boolean) {
        val sbn = shown[key] ?: return
        val state = stateOf(sbn)
        val changed = lastState.put(key, state) != state
        val wait = if (changed) 0L else (lastSent[key] ?: 0L) + MIN_INTERVAL_MS - System.currentTimeMillis()
        pending.remove(key)?.let(handler::removeCallbacks)
        val send = Runnable {
            pending.remove(key)
            val sbn = shown[key] ?: return@Runnable
            lastSent[key] = System.currentTimeMillis()
            val data = data(context, sbn, first)
            if (first) {
                UptimeLog.record("live: ${sbn.packageName} (timer=${data.chronometerBaseMs != 0L}, progress=${data.progressMax > 0})")
            }
            runCatching { Core.node?.publishOngoingActivity(data) }
        }
        if (first || wait <= 0) send.run() else {
            pending[key] = send
            handler.postDelayed(send, wait)
        }
    }

    /** Everything except progress numbers: a change here is sent without waiting. */
    private fun stateOf(sbn: StatusBarNotification): String {
        val n = sbn.notification
        val extras = n.extras
        return listOf(
            extras.getCharSequence(Notification.EXTRA_TITLE), extras.getCharSequence(Notification.EXTRA_TEXT),
            extras.getCharSequence(EXTRA_SHORT_CRITICAL_TEXT), extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER),
            n.`when`, n.actions?.size, extras.get("android.metrics"),
        ).joinToString("|")
    }

    /** What an Android 17 `MetricStyle` notification shows (e.g. Clock's timer). */
    private data class Metrics(val title: String, val text: String, val shortText: String, val timerBaseMs: Long, val countsDown: Boolean)

    @RequiresApi(37)
    private fun metrics(context: Context, n: Notification): Metrics? {
        if (n.extras.getString(Notification.EXTRA_TEMPLATE) != METRIC_STYLE) return null
        val style = runCatching { Notification.Builder.recoverBuilder(context, n).style as? Notification.MetricStyle }
            .getOrNull() ?: return null
        val metrics = style.metrics.takeIf { it.isNotEmpty() } ?: return null
        val main = style.criticalMetric ?: metrics.first()
        var timerBaseMs = 0L
        var countsDown = false
        var shortText = ""
        when (val value = main.value) {
            is Notification.Metric.TimeDifference -> {
                val paused = value.pausedDuration
                if (paused != null) {
                    shortText = formatDuration(paused.toMillis())
                } else {
                    timerBaseMs = value.zeroTime?.toEpochMilli()
                        ?: value.zeroElapsedRealtime?.let { System.currentTimeMillis() - SystemClock.elapsedRealtime() + it }
                        ?: 0L
                    countsDown = value.isTimer
                }
            }
            else -> shortText = metricText(value)
        }
        val paused = (main.value as? Notification.Metric.TimeDifference)?.pausedDuration != null
        val others = metrics.filter { it !== main }.joinToString(" · ") { "${it.label}: ${metricText(it.value)}" }
        return Metrics(
            title = main.label?.toString().orEmpty(),
            text = listOfNotNull(if (paused) "Paused" else null, others.ifEmpty { null }).joinToString(" · "),
            shortText = shortText,
            timerBaseMs = timerBaseMs,
            countsDown = countsDown,
        )
    }

    @RequiresApi(37)
    private fun metricText(value: Notification.Metric.MetricValue): String = when (value) {
        is Notification.Metric.FixedInt -> listOfNotNull("${value.value}", value.unit?.toString()).joinToString(" ")
        is Notification.Metric.FixedFloat -> listOfNotNull("%.${value.maxFractionDigits}f".format(value.value), value.unit?.toString()).joinToString(" ")
        is Notification.Metric.FixedText -> listOfNotNull(value.value?.toString(), value.unit?.toString()).joinToString(" ")
        is Notification.Metric.FixedDate -> value.value.toString()
        is Notification.Metric.FixedTime -> value.value.toString()
        is Notification.Metric.TimeDifference -> value.pausedDuration?.let { formatDuration(it.toMillis()) } ?: ""
        else -> ""
    }

    private fun formatDuration(ms: Long): String {
        val seconds = ms / 1000
        val (h, m, s) = Triple(seconds / 3600, seconds / 60 % 60, seconds % 60)
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }

    private fun data(context: Context, sbn: StatusBarNotification, withIcon: Boolean): OngoingActivityData {
        val n = sbn.notification
        val extras = n.extras
        val metrics = if (Build.VERSION.SDK_INT >= 37) metrics(context, n) else null
        val timer = extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER) && n.`when` != 0L
        val pm = context.packageManager
        return OngoingActivityData(
            key = sbn.key,
            `package` = sbn.packageName,
            appLabel = runCatching { pm.getApplicationLabel(pm.getApplicationInfo(sbn.packageName, 0)).toString() }
                .getOrDefault(sbn.packageName),
            title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: metrics?.title.orEmpty(),
            text = (extras.getCharSequence(Notification.EXTRA_TEXT) ?: extras.getCharSequence(Notification.EXTRA_SUB_TEXT))
                ?.toString() ?: metrics?.text.orEmpty(),
            shortText = extras.getCharSequence(EXTRA_SHORT_CRITICAL_TEXT)?.toString() ?: metrics?.shortText.orEmpty(),
            progress = extras.getInt(Notification.EXTRA_PROGRESS, 0),
            progressMax = extras.getInt(Notification.EXTRA_PROGRESS_MAX, 0),
            indeterminate = extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE),
            chronometerBaseMs = if (timer) n.`when` else metrics?.timerBaseMs ?: 0L,
            countsDown = if (timer) extras.getBoolean(Notification.EXTRA_CHRONOMETER_COUNT_DOWN) else metrics?.countsDown == true,
            iconPng = if (withIcon) {
                runCatching { pm.getApplicationIcon(sbn.packageName).toPng(ICON_SIZE) }.getOrDefault(ByteArray(0))
            } else {
                ByteArray(0)
            },
            actions = n.actions.orEmpty().take(3).map {
                NotificationActionData(label = it.title?.toString().orEmpty(), acceptsReply = false)
            },
            updatedMs = System.currentTimeMillis(),
        )
    }
}
