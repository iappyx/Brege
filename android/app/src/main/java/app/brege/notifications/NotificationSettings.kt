package app.brege.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Process
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import uniffi.brege_ffi.NotificationChannelData
import uniffi.brege_ffi.NotificationSettingsData

/**
 * An app's notification categories, read and changed from the Mac.
 *
 * Android allows this only for a listener that is also a companion device of this phone, which
 * Brêge is after "Link Mac". Without that pairing the phone answers that it is not allowed.
 */
object NotificationSettings {

    fun onRequested(context: Context, from: String, packageName: String) {
        val node = Core.node ?: return
        val service = BregeNotificationListener.current()
        val label = runCatching {
            val pm = context.packageManager
            pm.getApplicationInfo(packageName, 0).loadLabel(pm).toString()
        }.getOrDefault(packageName)
        if (service == null) {
            runCatching {
                node.sendNotificationSettings(
                    from,
                    NotificationSettingsData(packageName, label, emptyList(), false, allowed = false),
                )
            }
            return
        }
        val channels = runCatching {
            service.getNotificationChannels(packageName, Process.myUserHandle())
                .map { it.toData() }
                .sortedBy { it.name.lowercase() }
        }.onFailure {
            UptimeLog.record("notifications: reading settings failed: ${it.javaClass.simpleName}")
        }.getOrDefault(emptyList())
        val blocked = runCatching {
            // An app with every category off is silenced in practice.
            channels.isNotEmpty() && channels.all { it.importance == 0u }
        }.getOrDefault(false)
        runCatching {
            node.sendNotificationSettings(
                from,
                NotificationSettingsData(packageName, label, channels, blocked, allowed = channels.isNotEmpty()),
            )
        }.onFailure { UptimeLog.record("notifications: sending settings failed: ${it.javaClass.simpleName}") }
    }

    fun onUpdate(context: Context, packageName: String, channelId: String, importance: Int) {
        val service = BregeNotificationListener.current() ?: return
        val channel = runCatching {
            service.getNotificationChannels(packageName, Process.myUserHandle())
                .firstOrNull { it.id == channelId }
        }.getOrNull() ?: return
        // Android only accepts a whole channel back, so the existing one is changed and returned.
        channel.importance = importance.coerceIn(
            NotificationManager.IMPORTANCE_NONE, NotificationManager.IMPORTANCE_HIGH,
        )
        runCatching {
            service.updateNotificationChannel(packageName, Process.myUserHandle(), channel)
            UptimeLog.record("notifications: set $packageName/$channelId to $importance")
        }.onFailure {
            UptimeLog.record("notifications: changing a category failed: ${it.javaClass.simpleName}")
        }
        // Tell the Mac what it looks like now.
        Core.connectedDevices.forEach { onRequested(context, it.id, packageName) }
    }

    private fun NotificationChannel.toData() = NotificationChannelData(
        id = id,
        name = name?.toString().orEmpty().ifEmpty { id },
        group = group.orEmpty(),
        importance = importance.coerceIn(0, 5).toUInt(),
        blocked = importance == NotificationManager.IMPORTANCE_NONE,
    )
}
