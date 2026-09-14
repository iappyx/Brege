package app.brege.screen

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import app.brege.diagnostics.UptimeLog

/**
 * Wireless debugging carries the phone screen to the Mac. Once the Mac has adb
 * access it grants WRITE_SECURE_SETTINGS, so later the phone can switch wireless debugging back
 * on by itself when the Mac asks (it turns off after a reboot or a network change).
 */
object WirelessDebugging {
    private const val ADB_WIFI_ENABLED = "adb_wifi_enabled"

    fun developerOptionsEnabled(context: Context): Boolean =
        Settings.Global.getInt(context.contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) == 1

    fun isOn(context: Context): Boolean =
        Settings.Global.getInt(context.contentResolver, ADB_WIFI_ENABLED, 0) == 1

    fun canSwitchOn(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    /** Returns false when the Mac has not granted the permission yet. */
    fun switchOn(context: Context): Boolean {
        if (isOn(context)) return true
        if (!canSwitchOn(context)) {
            UptimeLog.record("screen: cannot switch on wireless debugging (permission not granted)")
            return false
        }
        return runCatching {
            Settings.Global.putInt(context.contentResolver, ADB_WIFI_ENABLED, 1)
        }.onSuccess { UptimeLog.record("screen: switched on wireless debugging for the Mac") }
            .getOrDefault(false)
    }

    /** Developer options when enabled, else About phone (tap Build number seven times). */
    fun openSettings(context: Context) {
        val action = if (developerOptionsEnabled(context)) {
            Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS
        } else {
            Settings.ACTION_DEVICE_INFO_SETTINGS
        }
        try {
            context.startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: ActivityNotFoundException) {
            context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
}
