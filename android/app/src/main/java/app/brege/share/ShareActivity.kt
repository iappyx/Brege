package app.brege.share

import android.app.Activity
import android.app.AlertDialog
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.ContextThemeWrapper
import android.widget.Toast
import app.brege.core.Core
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.brege_ffi.BregeNode
import uniffi.brege_ffi.Device

/** Share-sheet target: links and text are opened on the Mac, files are transferred. */
class ShareActivity : Activity() {
    /** Set once sending began, so the activity recreated after a rotation does not send again. */
    private var sending = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState?.getBoolean(STATE_SENDING) == true) {
            finish()
            return
        }
        Core.scope.launch {
            val node = Core.ensureStarted()
            val macs = Core.connectedDevices
            withContext(Dispatchers.Main) {
                if (isFinishing || isDestroyed) return@withContext
                when {
                    node == null -> done("Brêge is not running")
                    macs.isEmpty() -> done("No Mac connected")
                    macs.size == 1 -> send(node, macs[0])
                    // Theme.Translucent has no dialog style of its own.
                    else -> AlertDialog.Builder(ContextThemeWrapper(this@ShareActivity, android.R.style.Theme_DeviceDefault_DayNight))
                        .setTitle("Send to")
                        .setItems(macs.map { it.name }.toTypedArray()) { _, which -> send(node, macs[which]) }
                        .setOnCancelListener { finish() }
                        .show()
                }
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_SENDING, sending)
    }

    private fun send(node: BregeNode, mac: Device) {
        sending = true
        val intent = intent
        Core.scope.launch {
            val message = runCatching { share(node, mac, intent) }.getOrElse { "Could not send: ${it.message}" }
            withContext(Dispatchers.Main) { done(message) }
        }
    }

    private fun done(message: String) {
        // The application context: after a rotation this instance is already gone.
        Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
        finish()
    }

    private suspend fun share(node: BregeNode, mac: Device, intent: Intent): String {
        val uris = streams(intent)
        if (uris.isNotEmpty()) {
            pruneOutgoing(this)
            val allowed = uris.filter(::isShareable)
            if (allowed.isEmpty()) return "Could not send: that file is not accessible"
            for (uri in allowed) {
                val file = copyToCache(uri)
                node.sendFile(mac.id, file.path)
            }
            return if (allowed.size == 1) "Sending to ${mac.name}" else "Sending ${allowed.size} files to ${mac.name}"
        }

        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        if (text.isEmpty()) return "Nothing to send"
        val url = Regex("""https?://\S+""").find(text)?.value
        if (url != null) {
            node.sendUrl(mac.id, url, intent.getStringExtra(Intent.EXTRA_SUBJECT).orEmpty())
        } else {
            node.sendText(mac.id, text)
        }
        return "Sent to ${mac.name}"
    }

    @Suppress("DEPRECATION")
    private fun streams(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(
            if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableExtra(Intent.EXTRA_STREAM),
        )
        Intent.ACTION_SEND_MULTIPLE ->
            (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)).orEmpty()
        else -> emptyList()
    }

    /**
     * Brêge reads shared URIs with its own identity, so another app could otherwise hand it a path
     * to Brêge's private files (or its own file provider) and have them sent to the Mac.
     */
    private fun isShareable(uri: Uri): Boolean = when (uri.scheme) {
        ContentResolver.SCHEME_CONTENT -> uri.authority != "$packageName.files"
        ContentResolver.SCHEME_FILE -> {
            val path = runCatching { File(uri.path ?: "").canonicalPath }.getOrNull()
            val privateDirs = listOfNotNull(
                dataDir.path, createDeviceProtectedStorageContext().dataDir.path, externalCacheDir?.parentFile?.path,
            ).mapNotNull { runCatching { File(it).canonicalPath }.getOrNull() }
            path != null && privateDirs.none { path == it || path.startsWith("$it/") }
        }
        else -> false
    }

    /**
     * The core reads files by path, so shared content URIs are copied to app cache first.
     * Kept until the transfer completes so an interrupted transfer can resume.
     */
    private suspend fun copyToCache(uri: Uri): File = withContext(Dispatchers.IO) {
        val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
            ?: uri.lastPathSegment ?: "shared"
        val dir = File(cacheDir, "$OUTGOING/${System.nanoTime()}").apply { mkdirs() }
        val file = File(dir, name.substringAfterLast('/'))
        contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().use { input.copyTo(it) } }
        file
    }

    companion object {
        private const val STATE_SENDING = "sending"
        private const val OUTGOING = "outgoing"
        private const val KEEP_MS = 24 * 60 * 60_000L

        /** A shared file reached the Mac: delete its copy. */
        fun sent(context: Context, file: File) {
            val dir = file.parentFile ?: return
            val outgoing = runCatching { File(context.cacheDir, OUTGOING).canonicalPath == dir.parentFile?.canonicalPath }
            if (outgoing.getOrDefault(false)) dir.deleteRecursively()
        }

        /** Copies of transfers that failed or never finished within a day are not resumed any more. */
        private fun pruneOutgoing(context: Context) {
            val now = System.currentTimeMillis()
            File(context.cacheDir, OUTGOING).listFiles()
                ?.filter { it.isDirectory && now - it.lastModified() > KEEP_MS }
                ?.forEach { it.deleteRecursively() }
        }
    }
}
