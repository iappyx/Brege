package app.brege.media

import android.Manifest
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.util.Size
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import uniffi.brege_ffi.MediaAlbumData
import uniffi.brege_ffi.MediaItemData

/**
 * The whole photo library for the Mac's Photos window: pages of newest-first items with small
 * thumbnails, and the albums (the gallery's folders). Only answers requests; nothing runs in the
 * background. The full photo or video still travels as a normal transfer ([RecentMedia.fetch]).
 */
object MediaLibrary {
    private const val THUMBNAIL_SIZE = 240
    private const val THUMBNAIL_QUALITY = 60
    /** Rows scanned for the album list; enough for a large library, bounded for a huge one. */
    private const val ALBUM_SCAN_LIMIT = 20_000

    private val images: Uri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    private val videos: Uri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI

    private data class Row(
        val id: Long,
        val name: String,
        val takenMs: Long,
        val bucket: String,
        val path: String,
        val mime: String,
        val size: Long,
        val durationMs: Long,
        val video: Boolean,
    )

    // --- requests from the Mac --------------------------------------------------------------

    suspend fun onPageRequested(
        context: Context,
        from: String,
        beforeMs: Long,
        limit: Int,
        album: String,
        includeVideos: Boolean,
    ) = withContext(Dispatchers.IO) {
        val node = Core.node ?: return@withContext
        if (!RecentMedia.hasPermission(context)) {
            runCatching { node.sendMediaLibraryPage(from, emptyList(), true, album, true, false) }
            return@withContext
        }
        val before = if (beforeMs > 0) beforeMs else Long.MAX_VALUE
        val rows = page(context, before, limit, album, includeVideos)
        val items = rows.map { item(context, it) }
        UptimeLog.record("photos: sent ${items.size} of the library${if (album.isEmpty()) "" else " ($album)"}")
        runCatching {
            node.sendMediaLibraryPage(
                from, items,
                // A short page means the album has no older items.
                rows.size < limit, album, false, partialAccess(context),
            )
        }.onFailure { UptimeLog.record("photos: sending a page failed: ${it.javaClass.simpleName}") }
    }

    suspend fun onAlbumsRequested(context: Context, from: String, includeVideos: Boolean) = withContext(Dispatchers.IO) {
        val node = Core.node ?: return@withContext
        if (!RecentMedia.hasPermission(context)) {
            runCatching { node.sendMediaAlbums(from, emptyList()) }
            return@withContext
        }
        val albums = albums(context, includeVideos)
        UptimeLog.record("photos: sent ${albums.size} albums")
        runCatching { node.sendMediaAlbums(from, albums) }
            .onFailure { UptimeLog.record("photos: sending albums failed: ${it.javaClass.simpleName}") }
    }

    /** Android 14+: the user granted only the photos they picked, not the whole library. */
    private fun partialAccess(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return false
        val full = context.checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) ==
            PackageManager.PERMISSION_GRANTED
        val selected = context.checkSelfPermission(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) ==
            PackageManager.PERMISSION_GRANTED
        return !full && selected
    }

    // --- reading ------------------------------------------------------------------------------

    private fun page(
        context: Context,
        beforeMs: Long,
        limit: Int,
        album: String,
        includeVideos: Boolean,
    ): List<Row> {
        val rows = read(context, images, beforeMs, limit, album, video = false).toMutableList()
        if (includeVideos) rows += read(context, videos, beforeMs, limit, album, video = true)
        return rows.sortedByDescending { it.takenMs }.take(limit)
    }

    private fun read(
        context: Context,
        collection: Uri,
        beforeMs: Long,
        limit: Int,
        album: String,
        video: Boolean,
    ): List<Row> {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.RELATIVE_PATH,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.SIZE,
            if (video) MediaStore.Video.Media.DURATION else MediaStore.MediaColumns._ID,
        )
        // RAW originals are tens of megabytes and are reachable through the phone folders instead.
        val where = StringBuilder("${MediaStore.MediaColumns.MIME_TYPE} NOT IN ('image/x-adobe-dng', 'image/dng')")
        val args = ArrayList<String>()
        if (beforeMs in 1..<Long.MAX_VALUE) {
            where.append(" AND ${MediaStore.MediaColumns.DATE_ADDED} < ?")
            args += (beforeMs / 1000).toString()
        }
        if (album.isNotEmpty()) {
            where.append(" AND ${MediaStore.MediaColumns.BUCKET_DISPLAY_NAME} = ?")
            args += album
        }
        val query = Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, where.toString())
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args.toTypedArray())
            putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.MediaColumns.DATE_ADDED))
            putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
        }
        return runCatching {
            context.contentResolver.query(collection, projection, query, null)?.use { c ->
                buildList {
                    while (c.moveToNext()) {
                        add(
                            Row(
                                id = c.getLong(0),
                                name = c.getString(1).orEmpty(),
                                takenMs = c.getLong(2) * 1000,
                                bucket = c.getString(3).orEmpty(),
                                path = c.getString(4).orEmpty(),
                                mime = c.getString(5) ?: if (video) "video/mp4" else "image/jpeg",
                                size = c.getLong(6),
                                durationMs = if (video) c.getLong(7) else 0,
                                video = video,
                            )
                        )
                    }
                }
            }
        }.onFailure {
            UptimeLog.record("photos: reading the library failed: ${it.javaClass.simpleName}")
        }.getOrNull().orEmpty()
    }

    private fun item(context: Context, row: Row): MediaItemData {
        val uri = ContentUris.withAppendedId(if (row.video) videos else images, row.id)
        val thumbnail = runCatching {
            val bitmap = context.contentResolver.loadThumbnail(uri, Size(THUMBNAIL_SIZE, THUMBNAIL_SIZE), null)
            ByteArrayOutputStream().use {
                bitmap.compress(Bitmap.CompressFormat.JPEG, THUMBNAIL_QUALITY, it)
                it.toByteArray()
            }
        }.getOrDefault(ByteArray(0))
        return MediaItemData(
            id = row.id.toString(),
            name = row.name,
            takenMs = row.takenMs,
            screenshot = row.path.contains("Screenshots", ignoreCase = true) ||
                row.bucket.equals("Screenshots", ignoreCase = true),
            mime = row.mime,
            thumbnailJpeg = thumbnail,
            sizeBytes = row.size.coerceAtLeast(0).toULong(),
            durationMs = row.durationMs.coerceIn(0, UInt.MAX_VALUE.toLong()).toUInt(),
            video = row.video,
        )
    }

    /** The gallery's folders with their counts, newest item first as the cover. */
    private fun albums(context: Context, includeVideos: Boolean): List<MediaAlbumData> {
        data class Bucket(var count: Int, val cover: String, val video: Boolean)
        val buckets = LinkedHashMap<String, Bucket>()
        fun scan(collection: Uri, video: Boolean) {
            val projection = arrayOf(
                MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
                MediaStore.MediaColumns._ID,
            )
            val query = Bundle().apply {
                putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.MediaColumns.DATE_ADDED))
                putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
                putInt(ContentResolver.QUERY_ARG_LIMIT, ALBUM_SCAN_LIMIT)
            }
            runCatching {
                context.contentResolver.query(collection, projection, query, null)?.use { c ->
                    while (c.moveToNext()) {
                        val name = c.getString(0).orEmpty().ifEmpty { if (video) "Videos" else "Photos" }
                        val id = c.getString(1).orEmpty()
                        val bucket = buckets[name]
                        if (bucket == null) buckets[name] = Bucket(1, id, video) else bucket.count++
                    }
                }
            }
        }
        scan(images, video = false)
        if (includeVideos) scan(videos, video = true)
        return buckets.entries
            .sortedByDescending { it.value.count }
            .map { (name, bucket) ->
                MediaAlbumData(id = name, name = name, count = bucket.count.toUInt(), coverId = bucket.cover)
            }
    }
}
