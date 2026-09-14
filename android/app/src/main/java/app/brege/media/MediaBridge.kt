package app.brege.media

import android.content.ComponentName
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import app.brege.core.Core
import app.brege.notifications.BregeNotificationListener
import uniffi.brege_ffi.CommandKind
import uniffi.brege_ffi.MediaData

/** Publishes the active media session to the Mac and applies its commands. */
object MediaBridge {
    private var manager: MediaSessionManager? = null
    private var controller: MediaController? = null
    private val handler = Handler(Looper.getMainLooper())

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        select(controllers?.firstOrNull())
    }

    private val callback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) = publish()
        override fun onMetadataChanged(metadata: MediaMetadata?) = publish()
    }

    fun attach(service: BregeNotificationListener) {
        val m = service.getSystemService(MediaSessionManager::class.java)
        val component = ComponentName(service, BregeNotificationListener::class.java)
        runCatching {
            m.addOnActiveSessionsChangedListener(sessionsListener, component, handler)
            select(m.getActiveSessions(component).firstOrNull())
            manager = m
        }
    }

    fun detach() {
        runCatching { manager?.removeOnActiveSessionsChangedListener(sessionsListener) }
        controller?.unregisterCallback(callback)
        controller = null
        manager = null
    }

    fun command(kind: CommandKind) {
        val controls = controller?.transportControls ?: return
        when (kind) {
            CommandKind.MEDIA_PLAY_PAUSE ->
                if (controller?.playbackState?.state == PlaybackState.STATE_PLAYING) controls.pause() else controls.play()
            CommandKind.MEDIA_NEXT -> controls.skipToNext()
            CommandKind.MEDIA_PREVIOUS -> controls.skipToPrevious()
            else -> Unit
        }
    }

    private fun select(next: MediaController?) {
        if (next?.sessionToken == controller?.sessionToken) return
        controller?.unregisterCallback(callback)
        controller = next
        next?.registerCallback(callback, handler)
        publish()
    }

    private fun publish() {
        val c = controller
        val metadata = c?.metadata
        val state = c?.playbackState
        Core.node?.sendMedia(
            MediaData(
                appLabel = c?.packageName.orEmpty(),
                title = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE).orEmpty(),
                artist = metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST).orEmpty(),
                playing = state?.state == PlaybackState.STATE_PLAYING,
                positionMs = state?.position ?: 0,
                durationMs = metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0,
            ),
        )
    }
}
