package app.brege.screen

import android.content.Context
import android.content.Intent
import app.brege.core.toPng
import uniffi.brege_ffi.PhoneAppData

/** Launchable apps for the Mac's app launcher. */
object PhoneApps {
    private const val ICON_SIZE = 96

    fun list(context: Context): List<PhoneAppData> {
        val pm = context.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(launcher, 0)
            .asSequence()
            .map { it.activityInfo }
            .filter { it.packageName != context.packageName }
            .distinctBy { it.packageName }
            .map { info ->
                PhoneAppData(
                    `package` = info.packageName,
                    label = info.loadLabel(pm).toString(),
                    iconPng = runCatching { info.loadIcon(pm).toPng(ICON_SIZE) }.getOrDefault(ByteArray(0)),
                )
            }
            .sortedBy { it.label.lowercase() }
            .toList()
    }
}
