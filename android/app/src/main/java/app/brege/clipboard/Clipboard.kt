package app.brege.clipboard

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.ClipboardManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.TileService
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import app.brege.core.Core
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.brege_ffi.ClipData

/**
 * Android 10+ only lets the focused app read the clipboard, so "send clipboard" briefly shows
 * this transparent activity, reads once it has window focus, and finishes.
 */
class ClipboardSendActivity : ComponentActivity() {
    private var sent = false
    private var coreReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Make sure the core is up when launched from the tile or notification. Never block the
        // main thread on it: the service may hold the start lock while it needs the main thread.
        lifecycleScope.launch {
            withContext(Dispatchers.Default) { Core.ensureStarted() }
            coreReady = true
            if (hasWindowFocus()) sendOnce()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && coreReady) sendOnce()
    }

    /** Reads the clipboard once the core is up and the window has focus. */
    private fun sendOnce() {
        if (sent || isFinishing) return
        sent = true
        val message = sendClipboard()
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun sendClipboard(): String {
        val node = Core.node ?: return "Brêge is not running"
        if (Core.connectedDevices.isEmpty()) return "No Mac connected"
        val cm = getSystemService(ClipboardManager::class.java)
        val clip = cm.primaryClip ?: return "Clipboard is empty"
        if (Build.VERSION.SDK_INT >= 33 &&
            clip.description.extras?.getBoolean(android.content.ClipDescription.EXTRA_IS_SENSITIVE) == true
        ) {
            return "Sensitive content is not sent"
        }
        val text = clip.getItemAt(0)?.coerceToText(this)?.toString().orEmpty()
        if (text.isEmpty()) return "Clipboard is empty"
        return if (node.localClipboardChanged(ClipData.Text(text), System.currentTimeMillis().toULong())) {
            "Sent to Mac"
        } else {
            "Already on your Mac"
        }
    }
}

class ClipboardTileService : TileService() {
    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        val intent = Intent(this, ClipboardSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
