package app.brege.media

import android.Manifest
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.launch
import uniffi.brege_ffi.CaptureStatus
import uniffi.brege_ffi.MediaItemData

/**
 * Recent photos and screenshots for the Mac's menu: the newest images with thumbnails, the full
 * file on request, and a push when a new screenshot is taken.
 */
object RecentMedia {
    private const val THUMBNAIL_SIZE = 240
    private val collection: Uri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI

    private var observer: ContentObserver? = null
    private var lastPushedId: Long = -1

    fun hasPermission(context: Context): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED ||
            (Build.VERSION.SDK_INT >= 34 &&
                context.checkSelfPermission(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED)
    }

    private data class Row(val id: Long, val name: String, val takenMs: Long, val addedMs: Long, val path: String, val mime: String)

    private fun query(context: Context, limit: Int): List<Row> {
        if (!hasPermission(context)) return emptyList()
        val projection = arrayOf(
            MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.DATE_TAKEN,
            MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.RELATIVE_PATH, MediaStore.Images.Media.MIME_TYPE,
        )
        val args = Bundle().apply {
            // RAW originals (Pixel saves a DNG next to each JPEG) are tens of megabytes; they stay
            // reachable through the phone folders in Finder.
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, "${MediaStore.Images.Media.MIME_TYPE} NOT IN ('image/x-adobe-dng', 'image/dng')")
            putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.Images.Media.DATE_ADDED))
            putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
        }
        return runCatching {
            context.contentResolver.query(collection, projection, args, null)?.use { c ->
                buildList {
                    while (c.moveToNext()) {
                        val added = c.getLong(3) * 1000
                        add(Row(c.getLong(0), c.getString(1).orEmpty(), if (c.isNull(2)) added else c.getLong(2), added,
                            c.getString(4).orEmpty(), c.getString(5) ?: "image/jpeg"))
                    }
                }
            }
        }.getOrNull().orEmpty()
    }

    private fun item(context: Context, row: Row): MediaItemData {
        val uri = ContentUris.withAppendedId(collection, row.id)
        val thumbnail = runCatching {
            val bitmap = context.contentResolver.loadThumbnail(uri, Size(THUMBNAIL_SIZE, THUMBNAIL_SIZE), null)
            ByteArrayOutputStream().use {
                bitmap.compress(Bitmap.CompressFormat.JPEG, 80, it)
                it.toByteArray()
            }
        }.getOrDefault(ByteArray(0))
        return MediaItemData(
            id = row.id.toString(), name = row.name, takenMs = row.takenMs,
            screenshot = row.path.contains("Screenshots", ignoreCase = true), mime = row.mime, thumbnailJpeg = thumbnail,
        )
    }

    fun list(context: Context, limit: Int): List<MediaItemData> = query(context, limit).map { item(context, it) }

    /** Sends the full image as a transfer and reports it like a capture. */
    suspend fun fetch(context: Context, mac: String, requestId: String, mediaId: String) {
        val node = Core.ensureStarted() ?: return
        val row = query(context, 60).firstOrNull { it.id.toString() == mediaId }
        if (row == null) {
            runCatching { node.sendCaptureResult(mac, requestId, CaptureStatus.FAILED, "", "The photo is no longer on the phone") }
            return
        }
        val dir = File(context.cacheDir, "outgoing").apply { mkdirs() }
        val file = File(dir, row.name.ifEmpty { "Photo $mediaId.jpg" })
        val copied = runCatching {
            context.contentResolver.openInputStream(ContentUris.withAppendedId(collection, row.id))!!.use { input ->
                file.outputStream().use { input.copyTo(it) }
            }
        }
        if (copied.isFailure) {
            runCatching { node.sendCaptureResult(mac, requestId, CaptureStatus.FAILED, "", "Could not read the photo") }
            return
        }
        runCatching {
            val transferId = node.sendFile(mac, file.path)
            node.sendCaptureResult(mac, requestId, CaptureStatus.SENDING, transferId, "")
        }.onFailure { runCatching { node.sendCaptureResult(mac, requestId, CaptureStatus.FAILED, "", "The Mac is not connected") } }
    }

    /** Pushes new screenshots to connected Macs while Brêge's service runs. */
    fun startWatching(context: Context) {
        if (observer != null || !hasPermission(context)) return
        val app = context.applicationContext
        val handler = Handler(Looper.getMainLooper())
        val check = Runnable {
            Core.scope.launch {
                val newest = query(app, 1).firstOrNull() ?: return@launch
                val fresh = System.currentTimeMillis() - newest.addedMs < 30_000
                if (newest.id == lastPushedId || !fresh || !newest.path.contains("Screenshots", ignoreCase = true)) return@launch
                lastPushedId = newest.id
                if (Core.connectedDevices.isEmpty()) return@launch
                runCatching { Core.node?.sendRecentMedia(null, listOf(item(app, newest)), true, false) }
                UptimeLog.record("media: pushed a new screenshot to the Mac")
            }
        }
        observer = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) {
                // A screenshot arrives in several steps (pending, then written): wait for it to settle.
                handler.removeCallbacks(check)
                handler.postDelayed(check, 1_500)
            }
        }.also { app.contentResolver.registerContentObserver(collection, true, it) }
    }

    fun stopWatching(context: Context) {
        observer?.let { context.applicationContext.contentResolver.unregisterContentObserver(it) }
        observer = null
    }
}
