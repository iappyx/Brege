package app.brege.core

import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData as AndroidClip
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PersistableBundle
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import app.brege.BregeApplication
import app.brege.R
import app.brege.calls.CallLogSync
import app.brege.controls.PhoneControls
import app.brege.calls.CallMonitor
import app.brege.camera.CameraService
import app.brege.capture.CaptureActivity
import app.brege.companion.CompanionSetup
import app.brege.diagnostics.UptimeLog
import app.brege.media.MediaBridge
import app.brege.apps.AppInventory
import app.brege.media.MediaLibrary
import app.brege.media.RecentMedia
import app.brege.messages.ContactPhotos
import app.brege.messages.MessageSync
import app.brege.mic.MicService
import app.brege.notifications.BregeNotificationListener
import app.brege.notifications.NotificationSettings
import app.brege.screen.PhoneApps
import app.brege.screen.WirelessDebugging
import app.brege.service.RingPlayer
import app.brege.share.ShareActivity
import java.io.File
import kotlinx.coroutines.launch
import uniffi.brege_ffi.BregeEvent
import uniffi.brege_ffi.ClipData
import uniffi.brege_ffi.CommandKind
import uniffi.brege_ffi.OpenRequestData

/** Applies core events to the phone: clipboard writes, notification actions, ring, open requests. */
object EventHandler {
    fun handle(context: Context, event: BregeEvent) {
        when (event) {
            is BregeEvent.ClipboardReceived -> writeClipboard(context, event.clip)
            is BregeEvent.NotificationAction -> BregeNotificationListener.perform(event.key, event.act)
            is BregeEvent.CommandReceived -> when (event.command) {
                CommandKind.RING -> RingPlayer.start(context)
                CommandKind.STOP_RING -> RingPlayer.stop(context)
                CommandKind.MIC_START -> MicService.requestFromMac(context, event.from)
                CommandKind.MIC_STOP -> MicService.stopFromMac(context, event.from)
                CommandKind.ENABLE_WIRELESS_DEBUGGING -> WirelessDebugging.switchOn(context)
                else -> MediaBridge.command(event.command)
            }
            is BregeEvent.OpenRequestReceived -> showOpenRequest(context, event.request)
            is BregeEvent.TransferCompleted ->
                if (event.incoming) showFileReceived(context, File(event.path)) else ShareActivity.sent(context, File(event.path))
            is BregeEvent.MessageSyncRequested -> Core.scope.launch {
                MessageSync.onSyncRequested(event.sinceMs, event.maxThreads.toInt(), event.messagesPerThread.toInt())
            }
            is BregeEvent.MessageHistoryRequested -> Core.scope.launch {
                MessageSync.onHistoryRequested(event.threadId, event.beforeMs, event.limit.toInt())
            }
            is BregeEvent.MessageSendRequested ->
                MessageSync.send(event.from, event.clientId, event.threadId, event.address, event.body, event.subId)
            is BregeEvent.CameraRequested ->
                CameraService.request(context, event.from, event.start, event.front, event.torch, event.audio)
            is BregeEvent.RecentMediaRequested -> Core.scope.launch {
                val items = RecentMedia.list(context, event.limit.toInt())
                runCatching { Core.node?.sendRecentMedia(event.from, items, false, !RecentMedia.hasPermission(context)) }
            }
            is BregeEvent.AppInventoryRequested -> Core.scope.launch {
                AppInventory.onRequested(context, event.from, event.includeSystem)
            }
            is BregeEvent.AppActionRequested -> AppInventory.onAction(context, event.kind, event.`package`)
            is BregeEvent.NotificationSettingsRequested ->
                NotificationSettings.onRequested(context, event.from, event.`package`)
            is BregeEvent.NotificationChannelUpdateRequested ->
                NotificationSettings.onUpdate(context, event.`package`, event.channelId, event.importance.toInt())
            is BregeEvent.MediaLibraryRequested -> Core.scope.launch {
                MediaLibrary.onPageRequested(
                    context, event.from, event.beforeMs, event.limit.toInt(), event.album, event.includeVideos,
                )
            }
            is BregeEvent.MediaAlbumsRequested -> Core.scope.launch {
                MediaLibrary.onAlbumsRequested(context, event.from, event.includeVideos)
            }
            is BregeEvent.MediaFetchRequested -> Core.scope.launch {
                RecentMedia.fetch(context, event.from, event.requestId, event.mediaId)
            }
            is BregeEvent.CaptureRequested -> CaptureActivity.request(context, event.from, event.requestId, event.kind)
            is BregeEvent.AppListRequested -> Core.scope.launch {
                val apps = PhoneApps.list(context)
                runCatching { Core.node?.sendAppList(event.from, apps) }
            }
            is BregeEvent.ContactPhotosRequested -> Core.scope.launch {
                val photos = ContactPhotos.lookup(context, event.addresses)
                runCatching { Core.node?.sendContactPhotos(event.from, photos) }
            }
            is BregeEvent.CallActionRequested -> CallMonitor.perform(event.action, event.number, event.subId)
            is BregeEvent.PhoneControlRequested ->
                PhoneControls.perform(event.from, event.kind, event.value, event.stream)
            is BregeEvent.CallLogRequested -> Core.scope.launch {
                CallLogSync.onRequested(event.from, event.sinceMs, event.beforeMs, event.limit.toInt())
            }
            else -> Unit
        }
    }

    /** Background clipboard writes are allowed on Android 10+. */
    private fun writeClipboard(context: Context, clip: ClipData) {
        val cm = context.getSystemService(ClipboardManager::class.java)
        when (clip) {
            is ClipData.Text -> cm.setPrimaryClip(AndroidClip.newPlainText("Brêge", clip.text))
            is ClipData.Png -> {
                val dir = File(context.cacheDir, "outgoing").apply { mkdirs() }
                val file = File(dir, "clipboard.png").apply { writeBytes(clip.data) }
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                val androidClip = AndroidClip.newUri(context.contentResolver, "Brêge", uri)
                cm.setPrimaryClip(androidClip)
            }
        }
    }

    /**
     * Android blocks activity starts from the background, so links open from a notification tap.
     */
    private fun showOpenRequest(context: Context, request: OpenRequestData) {
        val (title, text, intent) = when (request) {
            is OpenRequestData.Url -> {
                val view = Intent(Intent.ACTION_VIEW, Uri.parse(request.url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                // The user asked for this on the Mac; the companion-device association (or Brêge
                // being on screen) lets it open from the background. Otherwise, or over the lock
                // screen, it notifies: a blocked start does not throw, so it cannot be detected.
                if (canOpenDirectly(context) && runCatching { context.startActivity(view) }.isSuccess) {
                    UptimeLog.record("open request: opened a link from the Mac")
                    return
                }
                Triple("Open link from Mac", request.title.ifEmpty { request.url }, view)
            }
            is OpenRequestData.Text -> {
                val cm = context.getSystemService(ClipboardManager::class.java)
                cm.setPrimaryClip(AndroidClip.newPlainText("Brêge", request.text).apply {
                    if (Build.VERSION.SDK_INT >= 33) {
                        description.extras = PersistableBundle().apply {
                            putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, false)
                        }
                    }
                })
                Triple("Text from Mac copied", request.text.take(200), null)
            }
            is OpenRequestData.UnsafeUrl -> Triple("Link from Mac", request.url, null)
            is OpenRequestData.File -> return
        }
        notify(context, title, text, intent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun canOpenDirectly(context: Context): Boolean {
        if (context.getSystemService(KeyguardManager::class.java).isKeyguardLocked) return false
        if (!context.getSystemService(PowerManager::class.java).isInteractive) return false
        val visible = ActivityManager.RunningAppProcessInfo().also { ActivityManager.getMyMemoryState(it) }
            .importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        return visible || CompanionSetup.isAssociated(context)
    }

    private fun showFileReceived(context: Context, file: File) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        val mime = context.contentResolver.getType(uri) ?: "*/*"
        val view = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        notify(context, "File from Mac", file.name, Intent.createChooser(view, file.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun notify(context: Context, title: String, text: String, intent: Intent?) {
        val builder = NotificationCompat.Builder(context, BregeApplication.CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_brege)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
        if (intent != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    context, text.hashCode(), intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        }
        val nm = context.getSystemService(NotificationManager::class.java)
        runCatching { nm.notify(System.nanoTime().toInt(), builder.build()) }
    }
}
