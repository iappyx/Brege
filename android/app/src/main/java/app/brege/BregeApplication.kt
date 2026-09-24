package app.brege

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import app.brege.calls.CallLogSync
import app.brege.controls.PhoneControls
import app.brege.sensors.Conditions
import app.brege.calls.CallMonitor
import app.brege.core.Core
import app.brege.messages.MessageSync
import app.brege.diagnostics.UptimeLog

class BregeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_SERVICE, getString(R.string.channel_service), NotificationManager.IMPORTANCE_MIN)
                .apply { setShowBadge(false) },
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_EVENTS, getString(R.string.channel_events), NotificationManager.IMPORTANCE_HIGH),
        )
        UptimeLog.init(this)
        Core.init(this)
        MessageSync.init(this)
        CallMonitor.init(this)
        CallLogSync.init(this)
        PhoneControls.init(this)
        Conditions.init(this)
    }

    companion object {
        const val CHANNEL_SERVICE = "service"
        const val CHANNEL_EVENTS = "events"
    }
}
