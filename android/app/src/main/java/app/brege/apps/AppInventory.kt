package app.brege.apps

import android.app.AppOpsManager
import android.app.PendingIntent
import android.app.usage.StorageStatsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Process
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import app.brege.BregeApplication
import app.brege.R
import app.brege.core.Core
import app.brege.core.toPng
import app.brege.diagnostics.UptimeLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import uniffi.brege_ffi.AppActionKind
import uniffi.brege_ffi.InstalledAppData

/**
 * The phone's installed apps for the inventory on the Mac: what is there, how big, how long unused.
 * Sizes and last use need the usage-access grant; without it the rest still works.
 *
 * Uninstalling and opening settings always happen on the phone, with Android's own confirmation:
 * a background app may not start those screens, so Brêge asks with a notification.
 */
object AppInventory {
    private const val ICON_SIZE = 96
    private const val NOTIFICATION_ID = 4822

    suspend fun onRequested(context: Context, from: String, includeSystem: Boolean) =
        withContext(Dispatchers.IO) {
            val node = Core.node ?: return@withContext
            val pm = context.packageManager
            val usage = usageAccess(context)
            val stats = if (usage) lastUsed(context) else emptyMap()
            val storage = context.getSystemService(StorageStatsManager::class.java)
            val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
                .asSequence()
                .filter { includeSystem || (it.flags and ApplicationInfo.FLAG_SYSTEM) == 0 }
                .filter { it.packageName != context.packageName }
                .map { info ->
                    val packageInfo = runCatching { pm.getPackageInfo(info.packageName, 0) }.getOrNull()
                    InstalledAppData(
                        `package` = info.packageName,
                        label = runCatching { info.loadLabel(pm).toString() }.getOrDefault(info.packageName),
                        version = packageInfo?.versionName.orEmpty(),
                        sizeBytes = if (usage) size(storage, info) else 0uL,
                        lastUsedMs = stats[info.packageName] ?: 0L,
                        system = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0,
                        installedMs = packageInfo?.firstInstallTime ?: 0L,
                        iconPng = runCatching { info.loadIcon(pm).toPng(ICON_SIZE) }.getOrDefault(ByteArray(0)),
                    )
                }
                .sortedByDescending { it.sizeBytes }
                .take(500)
                .toList()
            UptimeLog.record("apps: sent ${apps.size} installed apps${if (usage) "" else " (no usage access)"}")
            runCatching { node.sendAppInventory(from, apps, usage) }
                .onFailure { UptimeLog.record("apps: sending the inventory failed: ${it.javaClass.simpleName}") }
        }

    /** Uninstalling or opening settings needs the user; the phone asks with a notification. */
    fun onAction(context: Context, kind: AppActionKind, packageName: String) {
        val pm = context.packageManager
        val label = runCatching {
            pm.getApplicationInfo(packageName, 0).loadLabel(pm).toString()
        }.getOrDefault(packageName)
        val uri = Uri.fromParts("package", packageName, null)
        val (title, intent) = when (kind) {
            AppActionKind.UNINSTALL ->
                "Uninstall $label?" to Intent(Intent.ACTION_DELETE, uri)
            AppActionKind.APP_SETTINGS ->
                "Settings for $label" to Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, uri)
            AppActionKind.NOTIFICATION_SETTINGS ->
                "Notifications for $label" to Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            AppActionKind.USAGE_ACCESS ->
                "Allow Brêge to see app sizes" to Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val text = if (kind == AppActionKind.USAGE_ACCESS) {
            "Tap, then choose Brêge and turn on “Permit usage access”."
        } else {
            "Asked from your Mac. Tap to continue here."
        }
        val notification = NotificationCompat.Builder(context, BregeApplication.CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_brege)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(
                PendingIntent.getActivity(
                    context, packageName.hashCode(), intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            )
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification) }
        UptimeLog.record("apps: ${kind.name.lowercase()} requested for $packageName")
    }

    /** Sizes and last-used times need "usage access", which the user grants once in settings. */
    fun usageAccess(context: Context): Boolean {
        val ops = context.getSystemService(AppOpsManager::class.java) ?: return false
        val mode = runCatching {
            ops.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName,
            )
        }.getOrDefault(AppOpsManager.MODE_ERRORED)
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun lastUsed(context: Context): Map<String, Long> {
        val usage = context.getSystemService(UsageStatsManager::class.java) ?: return emptyMap()
        val now = System.currentTimeMillis()
        val year = now - 365L * 24 * 60 * 60 * 1000
        return runCatching {
            usage.queryUsageStats(UsageStatsManager.INTERVAL_YEARLY, year, now)
                .groupBy { it.packageName }
                .mapValues { (_, stats) -> stats.maxOf { it.lastTimeUsed } }
        }.getOrDefault(emptyMap())
    }

    private fun size(storage: StorageStatsManager?, info: ApplicationInfo): ULong {
        storage ?: return 0uL
        return runCatching {
            val stats = storage.queryStatsForPackage(
                android.os.storage.StorageManager.UUID_DEFAULT, info.packageName, Process.myUserHandle(),
            )
            (stats.appBytes + stats.dataBytes + stats.cacheBytes).coerceAtLeast(0).toULong()
        }.getOrDefault(0uL)
    }
}
