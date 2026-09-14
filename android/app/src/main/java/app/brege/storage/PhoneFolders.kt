package app.brege.storage

import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.util.LruCache
import android.webkit.MimeTypeMap
import app.brege.diagnostics.UptimeLog
import java.io.FileNotFoundException
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import uniffi.brege_ffi.FsBackendException
import uniffi.brege_ffi.FsEntryData
import uniffi.brege_ffi.PhoneStorage

/**
 * Folders the user shared with the Mac, granted through the Storage Access
 * Framework. Android 11+ does not allow the whole internal storage or Download/ as a tree, so
 * users pick folders such as DCIM, Pictures or Documents.
 */
object PhoneFolders {
    data class Share(val name: String, val uri: Uri)

    private const val PREFS = "phone_folders"
    private const val KEY = "shares"

    fun shares(context: Context): List<Share> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "[]")
        val array = JSONArray(raw)
        return (0 until array.length()).map {
            val o = array.getJSONObject(it)
            Share(o.getString("name"), Uri.parse(o.getString("uri")))
        }
    }

    private fun save(context: Context, shares: List<Share>) {
        val array = JSONArray()
        shares.forEach { array.put(JSONObject().put("name", it.name).put("uri", it.uri.toString())) }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, array.toString()).apply()
    }

    fun add(context: Context, treeUri: Uri): Share {
        context.contentResolver.takePersistableUriPermission(
            treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
        val existing = shares(context)
        existing.firstOrNull { it.uri == treeUri }?.let { return it }
        val base = displayName(context, treeUri).ifBlank { "Folder" }.replace('/', '_')
        var name = base
        var n = 2
        while (existing.any { it.name.equals(name, ignoreCase = true) }) name = "$base ${n++}"
        val share = Share(name, treeUri)
        save(context, existing + share)
        UptimeLog.record("folders: shared a folder with the Mac (${existing.size + 1} total)")
        return share
    }

    fun remove(context: Context, share: Share) {
        runCatching {
            context.contentResolver.releasePersistableUriPermission(
                share.uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
        save(context, shares(context).filterNot { it.uri == share.uri })
    }

    private fun displayName(context: Context, treeUri: Uri): String {
        val doc = DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))
        return context.contentResolver.query(doc, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
            ?: DocumentsContract.getTreeDocumentId(treeUri).substringAfterLast(':').substringAfterLast('/')
    }
}

/** [PhoneStorage] over the shared folders. Paths look like `/<share name>/sub/file.jpg`. */
class SafStorage(context: Context) : PhoneStorage {
    private val app = context.applicationContext
    private val resolver = app.contentResolver
    /** path → document id, to avoid walking the tree for every request. */
    private val ids = LruCache<String, String>(4096)

    private data class Resolved(val share: PhoneFolders.Share, val docId: String) {
        val uri: Uri get() = DocumentsContract.buildDocumentUriUsingTree(share.uri, docId)
    }

    private fun parts(path: String) = path.split('/').filter { it.isNotEmpty() }

    private fun share(name: String): PhoneFolders.Share =
        PhoneFolders.shares(app).firstOrNull { it.name == name }
            ?: throw FsBackendException.NotFound("no shared folder $name")

    private fun resolve(path: String): Resolved {
        val p = parts(path)
        if (p.isEmpty()) throw FsBackendException.Forbidden("root is not a document")
        val share = share(p[0])
        var docId = DocumentsContract.getTreeDocumentId(share.uri)
        var current = "/${p[0]}"
        for (name in p.drop(1)) {
            current += "/$name"
            val cached = ids.get(current)
            docId = cached ?: findChild(share, docId, name)?.also { ids.put(current, it) }
                ?: throw FsBackendException.NotFound(current)
        }
        return Resolved(share, docId)
    }

    private fun findChild(share: PhoneFolders.Share, parentId: String, name: String): String? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(share.uri, parentId)
        return query(children, arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME)) { c ->
            var found: String? = null
            while (c.moveToNext()) {
                if (c.getString(1) == name) { found = c.getString(0); break }
            }
            found
        }
    }

    private fun <T> query(uri: Uri, projection: Array<String>, block: (Cursor) -> T): T = try {
        resolver.query(uri, projection, null, null, null)?.use(block)
            ?: throw FsBackendException.Unavailable("storage query failed")
    } catch (e: FsBackendException) {
        throw e
    } catch (e: SecurityException) {
        throw FsBackendException.Forbidden(e.message ?: "permission revoked")
    } catch (e: FileNotFoundException) {
        throw FsBackendException.NotFound(e.message ?: "not found")
    } catch (e: Exception) {
        throw FsBackendException.Io(e.message ?: e.javaClass.simpleName)
    }

    private val entryProjection = arrayOf(
        Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
        Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED,
    )

    private fun entry(c: Cursor, nameOverride: String? = null) = FsEntryData(
        name = nameOverride ?: c.getString(1).orEmpty(),
        dir = c.getString(2) == Document.MIME_TYPE_DIR,
        size = if (c.isNull(3)) 0u else c.getLong(3).toULong(),
        modifiedMs = if (c.isNull(4)) 0 else c.getLong(4),
        mime = c.getString(2).orEmpty(),
    )

    /** Cached document ids go stale when files change on the phone; retry once with a fresh walk. */
    private inline fun <T> fresh(path: String, block: () -> T): T = try {
        block()
    } catch (e: FsBackendException) {
        if (e is FsBackendException.Forbidden || e is FsBackendException.Exists) throw e
        forget(path)
        block()
    }

    override fun list(path: String): List<FsEntryData> = fresh(path) { listOnce(path) }

    private fun listOnce(path: String): List<FsEntryData> {
        if (parts(path).isEmpty()) {
            return PhoneFolders.shares(app).map { FsEntryData(it.name, true, 0u, 0, Document.MIME_TYPE_DIR) }
        }
        val dir = resolve(path)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(dir.share.uri, dir.docId)
        return query(children, entryProjection) { c ->
            val out = ArrayList<FsEntryData>(c.count)
            while (c.moveToNext()) {
                val e = entry(c)
                ids.put("${path.trimEnd('/')}/${e.name}", c.getString(0))
                out += e
            }
            out
        }
    }

    override fun stat(path: String): FsEntryData = fresh(path) { statOnce(path) }

    private fun statOnce(path: String): FsEntryData {
        val p = parts(path)
        if (p.isEmpty()) return FsEntryData("", true, 0u, 0, Document.MIME_TYPE_DIR)
        val r = resolve(path)
        return query(r.uri, entryProjection) { c ->
            if (!c.moveToFirst()) throw FsBackendException.NotFound(path)
            entry(c, nameOverride = p.last())
        }
    }

    override fun openRead(path: String): Int = fresh(path) { open(resolve(path).uri, "r") }

    override fun openWrite(path: String, truncate: Boolean): Int {
        val p = parts(path)
        if (p.size < 2) throw FsBackendException.Forbidden("files can only be written inside a shared folder")
        val existing = runCatching { resolve(path) }.getOrNull()
        if (existing != null) return open(existing.uri, if (truncate) "rwt" else "rw")
        val parent = resolve("/" + p.dropLast(1).joinToString("/"))
        val name = p.last()
        val extension = name.substringAfterLast('.', "").lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
        val created = createDocument(parent, mime, name)
        return open(created, "rw")
    }

    override fun mkdir(path: String): FsEntryData {
        val p = parts(path)
        if (p.size < 2) throw FsBackendException.Forbidden("folders can only be created inside a shared folder")
        if (runCatching { resolve(path) }.isSuccess) throw FsBackendException.Exists(path)
        val parent = resolve("/" + p.dropLast(1).joinToString("/"))
        createDocument(parent, Document.MIME_TYPE_DIR, p.last())
        return stat(path)
    }

    override fun delete(path: String) {
        if (parts(path).size < 2) throw FsBackendException.Forbidden("remove shared folders in the Brêge app")
        val r = resolve(path)
        guard { if (!DocumentsContract.deleteDocument(resolver, r.uri)) throw FsBackendException.Io("delete failed") }
        forget(path)
    }

    override fun rename(from: String, to: String) {
        val a = parts(from)
        val b = parts(to)
        if (a.size < 2 || b.size < 2) throw FsBackendException.Forbidden("shared folders cannot be renamed from the Mac")
        if (a[0] != b[0]) throw FsBackendException.Forbidden("moving between shared folders is not supported")
        val fromPath = "/" + a.joinToString("/")
        val toPath = "/" + b.joinToString("/")
        val parentPath = "/" + b.dropLast(1).joinToString("/")
        var backupPath: String? = null
        try {
            // The source first: a missing source must not touch the target.
            val source = fresh(fromPath) { resolve(fromPath) }
            if (a == b) return
            val target = try {
                fresh(toPath) { resolve(toPath) }
            } catch (e: FsBackendException.NotFound) {
                null
            }
            // WebDAV MOVE with overwrite: set the target aside, move the source, then delete the old
            // target, so a failed move leaves both files in place.
            var backup: Uri? = null
            if (target != null && target.docId != source.docId) {
                if (isDirectory(target.uri)) throw FsBackendException.Forbidden("$toPath is a folder and is not replaced")
                val backupName = ".brege-old-" + UUID.randomUUID().toString().replace("-", "").take(16)
                backupPath = "$parentPath/$backupName"
                backup = guard {
                    DocumentsContract.renameDocument(resolver, target.uri, backupName)
                        ?: throw FsBackendException.Io("could not set $toPath aside")
                }
            }
            try {
                moveAndRename(source, a, b)
            } catch (e: Exception) {
                if (backup != null) {
                    runCatching { DocumentsContract.renameDocument(resolver, backup, b.last()) }
                        .onFailure { UptimeLog.record("folders: could not restore a replaced file: ${it.javaClass.simpleName}") }
                }
                throw e
            }
            if (backup != null) {
                val deleted = runCatching { DocumentsContract.deleteDocument(resolver, backup) }.getOrDefault(false)
                if (!deleted) UptimeLog.record("folders: could not delete a replaced file")
            }
        } finally {
            forget(fromPath)
            forget(toPath)
            backupPath?.let(::forget)
        }
    }

    /** Moves [source] to the folder of [b] (if different) and gives it the name of [b]. */
    private fun moveAndRename(source: Resolved, a: List<String>, b: List<String>) = guard {
        var uri = source.uri
        if (a.dropLast(1) != b.dropLast(1)) {
            val oldParent = resolve("/" + a.dropLast(1).joinToString("/"))
            val newParent = resolve("/" + b.dropLast(1).joinToString("/"))
            uri = DocumentsContract.moveDocument(resolver, uri, oldParent.uri, newParent.uri)
                ?: throw FsBackendException.Io("move failed")
            if (a.last() != b.last()) {
                try {
                    // The provider may sanitize the name; the returned Uri is the document now.
                    DocumentsContract.renameDocument(resolver, uri, b.last()) ?: throw FsBackendException.Io("rename failed")
                } catch (e: Exception) {
                    // Put the source back where it was.
                    runCatching { DocumentsContract.moveDocument(resolver, uri, newParent.uri, oldParent.uri) }
                    throw e
                }
            }
        } else if (a.last() != b.last()) {
            DocumentsContract.renameDocument(resolver, uri, b.last()) ?: throw FsBackendException.Io("rename failed")
        }
    }

    private fun isDirectory(uri: Uri): Boolean =
        query(uri, arrayOf(Document.COLUMN_MIME_TYPE)) { c -> c.moveToFirst() && c.getString(0) == Document.MIME_TYPE_DIR }

    private fun createDocument(parent: Resolved, mime: String, name: String): Uri = guard {
        val uri = DocumentsContract.createDocument(resolver, parent.uri, mime, name)
            ?: throw FsBackendException.Io("could not create $name")
        uri
    }

    private fun open(uri: Uri, mode: String): Int = guard {
        val pfd = resolver.openFileDescriptor(uri, mode) ?: throw FsBackendException.Io("could not open file")
        pfd.detachFd()
    }

    private fun forget(path: String) {
        val prefix = path.trimEnd('/')
        ids.snapshot().keys.filter { it == prefix || it.startsWith("$prefix/") }.forEach { ids.remove(it) }
    }

    private inline fun <T> guard(block: () -> T): T = try {
        block()
    } catch (e: FsBackendException) {
        throw e
    } catch (e: SecurityException) {
        throw FsBackendException.Forbidden(e.message ?: "permission revoked")
    } catch (e: FileNotFoundException) {
        throw FsBackendException.NotFound(e.message ?: "not found")
    } catch (e: Exception) {
        throw FsBackendException.Io(e.message ?: e.javaClass.simpleName)
    }
}
