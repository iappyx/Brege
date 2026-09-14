package app.brege.notifications

import android.Manifest
import android.app.ActivityOptions
import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.CallLog
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.app.NotificationCompat
import app.brege.core.Core
import app.brege.core.toPng
import app.brege.media.MediaBridge
import app.brege.messages.RcsMirror
import java.util.concurrent.ConcurrentHashMap
import uniffi.brege_ffi.ConversationLineData
import uniffi.brege_ffi.NotificationActKind
import uniffi.brege_ffi.NotificationActionData
import uniffi.brege_ffi.NotificationData

/** Mirrors notifications to the Mac and performs actions sent back. */
class BregeNotificationListener : NotificationListenerService() {

    override fun onListenerConnected() {
        instance = this
        MediaBridge.attach(this)
    }

    override fun onListenerDisconnected() {
        MediaBridge.detach()
        instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val n = sbn.notification
        val ongoing = sbn.isOngoing || (n.flags and Notification.FLAG_FOREGROUND_SERVICE) != 0
        if (sbn.packageName == packageName) return
        if (ongoing) {
            // A notification that became ongoing moves from the Mac's list to its ongoing activities.
            if (active.remove(sbn.key) != null) Core.node?.removeNotification(sbn.key)
            if (Core.connectedDevices.isNotEmpty()) OngoingActivities.onPosted(this, sbn)
            return
        }
        // …and one that stopped being ongoing (e.g. a delivery's final "Arrived") ends its activity.
        OngoingActivities.onRemoved(sbn.key)
        RcsMirror.onNotification(this, sbn)
        if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        val node = Core.node ?: return
        if (Core.connectedDevices.isEmpty()) return

        active[sbn.key] = sbn
        val extras = n.extras
        val data = NotificationData(
            key = sbn.key,
            `package` = sbn.packageName,
            appLabel = appLabel(sbn.packageName),
            title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty(),
            text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty(),
            bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString().orEmpty(),
            postedMs = sbn.postTime,
            groupKey = sbn.groupKey.orEmpty(),
            actions = n.actions.orEmpty().map { action ->
                NotificationActionData(
                    label = action.title?.toString().orEmpty(),
                    acceptsReply = action.remoteInputs?.any { it.allowFreeFormInput } == true,
                )
            },
            conversation = conversation(n),
            iconRef = "",
            iconPng = ByteArray(0),
            picture = ByteArray(0),
            senderIcon = senderIcon(n),
            callNumber = missedCallNumber(sbn),
        )
        runCatching { node.postNotification(data, appIcon(sbn.packageName)) }
            .onFailure { Log.w(TAG, "post failed", it) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        OngoingActivities.onRemoved(sbn.key)
        RcsMirror.onNotificationRemoved(sbn.key)
        if (active.remove(sbn.key) != null) {
            Core.node?.removeNotification(sbn.key)
        }
    }

    private fun conversation(n: Notification): List<ConversationLineData> {
        val style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n) ?: return emptyList()
        return style.messages.takeLast(10).map {
            ConversationLineData(
                sender = it.person?.name?.toString().orEmpty(),
                text = it.text?.toString().orEmpty(),
                tsMs = it.timestamp,
            )
        }
    }

    /** The number of a missed-call notification, so the Mac can call back or message it itself. */
    private fun missedCallNumber(sbn: StatusBarNotification): String {
        if (sbn.notification.category != CATEGORY_MISSED_CALL) return ""
        // Google's Phone app tags the notification with the number.
        Regex("""MissedCall_(\+?[0-9]+)""").find(sbn.tag.orEmpty())?.let { return it.groupValues[1] }
        // Other phone apps: the latest missed call in the call log.
        if (checkSelfPermission(Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) return ""
        return runCatching {
            contentResolver.query(
                CallLog.Calls.CONTENT_URI, arrayOf(CallLog.Calls.NUMBER),
                "${CallLog.Calls.TYPE} = ? AND ${CallLog.Calls.DATE} > ?",
                arrayOf(CallLog.Calls.MISSED_TYPE.toString(), (System.currentTimeMillis() - 10 * 60_000L).toString()),
                "${CallLog.Calls.DATE} DESC",
            )?.use { if (it.moveToFirst()) it.getString(0) else null }
        }.getOrNull().orEmpty()
    }

    /** The sender's avatar: the large icon, else the icon of the latest MessagingStyle sender. */
    private fun senderIcon(n: Notification): ByteArray = runCatching {
        val icon = n.getLargeIcon()
            ?: NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)
                ?.messages?.lastOrNull()?.person?.icon?.toIcon(this)
        icon?.loadDrawable(this)?.toPng(SENDER_ICON_SIZE)
    }.getOrNull() ?: ByteArray(0)

    private fun appLabel(pkg: String): String = runCatching {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    }.getOrDefault(pkg)

    private fun appIcon(pkg: String): ByteArray? = iconCache.getOrPut(pkg) {
        runCatching { packageManager.getApplicationIcon(pkg).toPng(96) }.getOrNull() ?: ByteArray(0)
    }.takeIf { it.isNotEmpty() }

    companion object {
        private const val TAG = "BregeNotifications"
        private const val SENDER_ICON_SIZE = 128
        private const val CATEGORY_MISSED_CALL = "missed_call" // Notification.CATEGORY_MISSED_CALL, API 30

        /**
         * Presses a notification button for the Mac. Buttons that open a screen are blocked for a
         * background sender unless it opts in (Android 14+); Brêge may start activities because of
         * its companion-device association.
         */
        private fun sendAllowingActivityStart(context: Context, pending: PendingIntent, fillIn: Intent?) {
            val options = if (Build.VERSION.SDK_INT >= 34) {
                val mode = if (Build.VERSION.SDK_INT >= 36) {
                    ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS
                } else {
                    @Suppress("DEPRECATION")
                    ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                }
                ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(mode).toBundle()
            } else {
                null
            }
            pending.send(context, 0, fillIn, null, null, null, options)
        }

        @Volatile
        private var instance: BregeNotificationListener? = null
        private val active = ConcurrentHashMap<String, StatusBarNotification>()
        private val iconCache = ConcurrentHashMap<String, ByteArray>()

        val isConnected: Boolean get() = instance != null

        /** A Mac connected: mirror the ongoing activities that are already running. */
        fun publishOngoingActivities() {
            val service = instance ?: return
            runCatching { service.activeNotifications }.getOrNull().orEmpty()
                .filter { it.isOngoing }
                .forEach { OngoingActivities.onPosted(service, it) }
            OngoingActivities.resendAll(service)
        }

        /** Replies to a mirrored RCS conversation through its live notification. */
        fun replyToConversation(threadId: String, text: String): Boolean {
            val key = RcsMirror.notificationKeyFor(threadId) ?: return false
            val sbn = lookup(key) ?: return false
            val index = sbn.notification.actions.orEmpty()
                .indexOfFirst { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }
            if (index < 0) return false
            return perform(key, NotificationActKind.Reply(index.toUInt(), text))
        }

        /**
         * A notification by key: mirrored ones, ongoing activities, and any other still showing (an
         * RCS message that arrived while no Mac was connected is not in the mirrored list).
         */
        private fun lookup(key: String): StatusBarNotification? =
            active[key] ?: OngoingActivities.find(key)
                ?: runCatching { instance?.activeNotifications?.firstOrNull { it.key == key } }.getOrNull()

        /** Runs an action, reply or dismissal requested from the Mac; false if it could not. */
        fun perform(key: String, act: NotificationActKind): Boolean {
            val service = instance ?: return false
            val sbn = lookup(key) ?: return false
            return when (act) {
                is NotificationActKind.Dismiss -> runCatching { service.cancelNotification(key) }.isSuccess
                is NotificationActKind.Action -> {
                    val intent = sbn.notification.actions?.getOrNull(act.index.toInt())?.actionIntent ?: return false
                    runCatching { sendAllowingActivityStart(service, intent, null) }.isSuccess
                }
                is NotificationActKind.Reply -> {
                    val action = sbn.notification.actions?.getOrNull(act.index.toInt()) ?: return false
                    val inputs = action.remoteInputs ?: return false
                    val intent = Intent()
                    val results = Bundle().apply { inputs.forEach { putCharSequence(it.resultKey, act.text) } }
                    RemoteInput.addResultsToIntent(inputs, intent, results)
                    runCatching { sendAllowingActivityStart(service, action.actionIntent, intent) }
                        .onFailure { Log.w(TAG, "reply failed", it) }
                        .isSuccess
                }
            }
        }
    }
}
