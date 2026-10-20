package app.brege.display

import android.app.Activity
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.core.app.NotificationCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import app.brege.BregeApplication
import app.brege.R
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import java.nio.ByteBuffer
import uniffi.brege_ffi.DisplayPacketListener
import uniffi.brege_ffi.DisplayTouchPhase

/**
 * The Mac's own screen, shown on this tablet (docs/brege-second-display-plan.md).
 *
 * The Mac creates a display macOS believes in, captures it and sends it here; this side only
 * decodes. Frames arrive on a core thread, so nothing here may block: a packet that cannot be
 * handed to the decoder straight away is dropped, because a queue of stale frames is worse than a
 * gap.
 */
object MacDisplay : DisplayPacketListener {
    private const val TAG = "MacDisplay"
    private const val FLAG_CONFIG = 1
    private const val FLAG_KEY_FRAME = 2
    private const val NOTIFICATION_ID = 4120

    data class Offer(
        val from: String,
        val codec: String,
        val width: Int,
        val height: Int,
        val refreshHz: Int,
        val scale: Int,
    ) {
        val mime: String get() = if (codec == "h265") MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
    }

    @Volatile
    private var offer: Offer? = null

    @Volatile
    private var decoder: DisplayDecoder? = null

    /** Set by the screen while it is open, so an offer that arrives later still reaches it. */
    @Volatile
    var onOffer: ((Offer) -> Unit)? = null

    /** Set by the screen while it is open, so it can close itself when the Mac stops. */
    @Volatile
    var onStop: (() -> Unit)? = null

    /**
     * Whether to read touch as a trackpad rather than as a touchscreen.
     *
     * The Mac decides, from its own settings: that is where its owner is when they choose, and this
     * screen is a full-screen picture with nothing on it to tap.
     */
    @Volatile
    var trackpad = false
        private set

    /** Set by the screen while it is open, so a change mid-touch can let go of what it held. */
    @Volatile
    var onModeChanged: (() -> Unit)? = null

    fun setInputMode(trackpad: Boolean) {
        if (this.trackpad == trackpad) return
        this.trackpad = trackpad
        UptimeLog.record("display: reading touch as a ${if (trackpad) "trackpad" else "touchscreen"}")
        onModeChanged?.invoke()
    }

    val currentOffer: Offer? get() = offer

    /**
     * The Mac is about to send its display. Android does not let an app open a screen from the
     * background, so this asks — the same way the camera does — and the tap opens it.
     */
    fun offered(context: Context, offer: Offer) {
        // One Mac at a time, as the camera and the microphone already work: whichever is showing
        // keeps the screen, and the other is told why instead of quietly taking it over.
        val showing = this.offer
        if (showing != null && showing.from != offer.from && decoder != null) {
            runCatching { Core.node?.stopDisplay(offer.from, "The tablet is showing another Mac") }
            UptimeLog.record("display: refused a second Mac while showing ${showing.from}")
            return
        }
        this.offer = offer
        UptimeLog.record("display: ${offer.width}x${offer.height} offered by the Mac")
        val waiting = onOffer
        if (waiting != null) return waiting(offer)

        val intent = Intent(context, MacDisplayActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        // An app the user is looking at may open a screen itself; one in the background may not,
        // and has to ask. Brêge's foreground service does not count as being in front — hence the
        // importance test rather than a plain "is the process alive".
        if (isInFront(context)) {
            runCatching { context.startActivity(intent) }.onSuccess { return }
        }
        val tap = PendingIntent.getActivity(
            context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, BregeApplication.CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_brege)
            .setContentTitle(context.getString(R.string.display_offer_title))
            .setContentText(context.getString(R.string.display_offer_text))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build()
        context.getSystemService(NotificationManager::class.java)
            ?.notify(NOTIFICATION_ID, notification)
    }

    /**
     * The display session is over.
     *
     * `from` names the Mac that said so, and a stop from any other one is not about this session:
     * a second Mac being refused gets its own stop back, and acting on that would tear down the
     * display the first Mac is still showing — leaving its user's windows stranded on a screen
     * that no longer exists, which is the thing this feature works hardest to avoid. `null` means
     * the screen is closing itself and no check is needed.
     */
    fun stopped(context: Context?, from: String? = null) {
        if (from != null && offer?.from != from) {
            UptimeLog.record("display: ignored a stop from a Mac that is not the one showing")
            return
        }
        offer = null
        decoder?.release()
        decoder = null
        context?.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
        onStop?.invoke()
    }

    /// Whether Brêge has a screen in front of the user, as opposed to only its service running.
    private fun isInFront(context: Context): Boolean {
        val manager = context.getSystemService(android.app.ActivityManager::class.java) ?: return false
        val mine = android.os.Process.myPid()
        return manager.runningAppProcesses?.any {
            it.pid == mine &&
                it.importance <= android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        } == true
    }

    /**
     * Tells a Mac what this screen is, so an offer can be the right size and shape.
     *
     * Reported on connect rather than when the display opens: the Mac has to create the display
     * before it can offer it, and a display created at the wrong size would have to be torn down
     * and rebuilt — which moves the user's windows twice.
     */
    fun reportCapabilities(context: Context, macId: String, portrait: Boolean = false) {
        val node = Core.node ?: return
        val display = context.getSystemService(android.hardware.display.DisplayManager::class.java)
            ?.getDisplay(android.view.Display.DEFAULT_DISPLAY) ?: return
        val mode = display.mode
        // The mode's own numbers do not turn with the tablet, so the caller says which way up this
        // is: the screen that is open knows, and a report made before one is open assumes the
        // landscape a display is usually wanted in.
        val long = maxOf(mode.physicalWidth, mode.physicalHeight)
        val short = minOf(mode.physicalWidth, mode.physicalHeight)
        val width = if (portrait) short else long
        val height = if (portrait) long else short
        val h265 = runCatching {
            MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC).also { it.release() }
        }.isSuccess
        runCatching {
            node.reportDisplayCapabilities(
                deviceId = macId,
                width = width.toUInt(),
                height = height.toUInt(),
                densityDpi = context.resources.displayMetrics.densityDpi.toUInt(),
                h265 = h265,
                maxRefreshHz = display.refreshRate.toInt().coerceIn(30, 120).toUInt(),
            )
        }.onSuccess {
            UptimeLog.record("display: told the Mac this screen is ${width}x$height")
        }
    }

    fun attach(decoder: DisplayDecoder) {
        this.decoder = decoder
    }

    fun detach(decoder: DisplayDecoder) {
        if (this.decoder === decoder) this.decoder = null
    }

    override fun onDisplayPacket(from: String, flags: UByte, ptsUs: ULong, data: ByteArray) {
        val decoder = this.decoder ?: return
        val bits = flags.toInt()
        if (bits and FLAG_CONFIG != 0) {
            decoder.configure(data)
        } else {
            decoder.queue(data, ptsUs.toLong(), bits and FLAG_KEY_FRAME != 0)
        }
    }

    /**
     * The stream closed — which is a transport event, not a decision.
     *
     * It happens when the Mac makes its display again at another size, and the screen here has to
     * stay open through that: closing it would leave the user to open it a second time for what
     * they experienced as turning the tablet. The session ends when the Mac says so, or when it
     * goes away ([macGone]).
     */
    override fun onDisplayEnd(from: String) {
        Log.i(TAG, "the Mac's display stream ended; waiting for what comes next")
        decoder?.release()
        decoder = null
    }

    /** The Mac that was showing has gone, so there is nothing to wait for. */
    fun macGone(context: Context, deviceId: String) {
        if (offer?.from != deviceId) return
        UptimeLog.record("display: the Mac disconnected")
        stopped(context)
    }
}

/**
 * Decodes the Mac's display into a surface.
 *
 * The decoder is built on the config packet rather than on the offer, because the parameter sets
 * are what it actually needs: a decoder configured from a size alone fails on the first frame
 * whose real geometry differs by a crop or a profile.
 */
class DisplayDecoder(
    private val surface: android.view.Surface,
    private val mime: String,
    private val width: Int,
    private val height: Int,
) {
    private val lock = Any()
    private var codec: MediaCodec? = null
    private val info = MediaCodec.BufferInfo()

    fun configure(parameterSets: ByteArray) {
        synchronized(lock) {
            if (codec != null) return
            try {
                val format = MediaFormat.createVideoFormat(mime, width, height)
                if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC) {
                    // H.265 wants its VPS, SPS and PPS together in csd-0. Split into csd-0 and
                    // csd-1 the way H.264's are, the decoder refuses the configuration.
                    format.setByteBuffer("csd-0", ByteBuffer.wrap(parameterSets))
                } else {
                    val sets = splitNalUnits(parameterSets)
                    format.setByteBuffer("csd-0", ByteBuffer.wrap(sets.firstOrNull() ?: parameterSets))
                    sets.getOrNull(1)?.let { format.setByteBuffer("csd-1", ByteBuffer.wrap(it)) }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                codec = MediaCodec.createDecoderByType(mime).apply {
                    configure(format, surface, null, 0)
                    start()
                }
                UptimeLog.record("display: decoder started, $width x $height $mime")
            } catch (e: Exception) {
                Log.e("MacDisplay", "decoder could not start", e)
                UptimeLog.record("display: decoder failed, ${e.javaClass.simpleName}")
            }
        }
    }

    fun queue(data: ByteArray, ptsUs: Long, keyframe: Boolean) {
        // Held for the whole frame rather than just to read the field. [release] frees the codec
        // natively, and a codec freed between being read here and being written to does not throw
        // — it takes the process down. Rotation and a change of input mode both release while the
        // core thread is still feeding frames, so this is a window the app opens in normal use.
        synchronized(lock) {
            val codec = codec ?: return
            try {
                // A short wait, then give up: no input buffer free means the decoder is behind, and
                // holding the core thread to wait for one would make that worse.
                val index = codec.dequeueInputBuffer(2_000)
                if (index < 0) return
                val buffer = codec.getInputBuffer(index) ?: return
                buffer.clear()
                buffer.put(data)
                codec.queueInputBuffer(
                    index, 0, data.size, ptsUs,
                    if (keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
                )
                render(codec)
            } catch (e: IllegalStateException) {
                Log.w("MacDisplay", "decoder rejected a frame", e)
            }
        }
    }

    /** Everything ready goes to the surface at once; a frame held back is a frame late. */
    private fun render(codec: MediaCodec) {
        while (true) {
            val index = codec.dequeueOutputBuffer(info, 0)
            if (index < 0) return
            codec.releaseOutputBuffer(index, true)
        }
    }

    fun release() {
        synchronized(lock) {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            codec = null
        }
    }

    /** Annex-B in, each NAL unit out, without its start code. */
    private fun splitNalUnits(data: ByteArray): List<ByteArray> {
        val starts = mutableListOf<Int>()
        var i = 0
        while (i + 3 < data.size) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte() &&
                data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()
            ) {
                starts.add(i)
                i += 4
            } else {
                i++
            }
        }
        return starts.mapIndexed { index, start ->
            val from = start
            val until = starts.getOrNull(index + 1) ?: data.size
            data.copyOfRange(from, until)
        }
    }
}

/** Full screen, nothing else: the Mac's display and the tablet's own backlight. */
class MacDisplayActivity : Activity() {
    private companion object {
        /// Long enough not to fire while aiming, short enough that picking something up feels
        /// deliberate rather than slow.
        const val HOLD_TO_DRAG_MS = 450L
        const val TAP_MS = 250L
    }

    private var decoder: DisplayDecoder? = null

    private lateinit var frame: FrameLayout
    private lateinit var view: SurfaceView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Edge to edge, with the bars hidden: the window has to be the whole panel. The Mac was
        // told this screen's full size, so a window that stopped short of the status and
        // navigation bars would squeeze that picture into less than it was made for.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        frame = FrameLayout(this)
        view = SurfaceView(this)
        frame.addView(
            view,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
        )
        frame.setBackgroundColor(android.graphics.Color.BLACK)
        setContentView(frame)
        WindowInsetsControllerCompat(window, view).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        view.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) = startDecoding(holder)
            override fun surfaceChanged(holder: SurfaceHolder, f: Int, w: Int, h: Int) = Unit
            override fun surfaceDestroyed(holder: SurfaceHolder) = stopDecoding()
        })
        // The window's size is not known in onCreate, and changes when the bars go.
        frame.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            MacDisplay.currentOffer?.let(::fit)
        }
        MacDisplay.onStop = { runOnUiThread { finish() } }
        view.setOnTouchListener { touched, event -> onTouch(touched, event) }
        // A mode change in the middle of a touch must not leave a button down on the Mac.
        MacDisplay.onModeChanged = { runOnUiThread { releaseEverything() } }
        reportCapabilities()
    }

    /**
     * Gives the picture the shape the Mac is sending, fitted inside the window and centred.
     *
     * A `SurfaceView` left to fill the window stretches whatever it is given to those bounds, so a
     * display even slightly off the window's proportions arrives distorted. Fitting it instead
     * means black edges in that case and a true picture in every case.
     */
    private fun fit(offer: MacDisplay.Offer) {
        if (offer.width <= 0 || offer.height <= 0) return
        val availableWidth = frame.width
        val availableHeight = frame.height
        if (availableWidth == 0 || availableHeight == 0) return
        val scale = minOf(
            availableWidth.toFloat() / offer.width,
            availableHeight.toFloat() / offer.height,
        )
        val width = (offer.width * scale).toInt()
        val height = (offer.height * scale).toInt()
        if (view.width == width && view.height == height) return
        view.layoutParams = FrameLayout.LayoutParams(width, height, android.view.Gravity.CENTER)
        view.requestLayout()
        UptimeLog.record("display: showing ${offer.width}x${offer.height} as ${width}x$height")
    }

    private var scrolling = false
    private var lastCentre: Pair<Float, Float>? = null
    private val trackpad: Boolean get() = MacDisplay.trackpad
    private var touchStart = 0L
    private var touchFrom: Pair<Float, Float>? = null
    private var lastPoint: Pair<Float, Float>? = null
    private var dragging = false
    private val holdToDrag = Runnable { beginDrag() }

    /**
     * Touch, as a pointer on the Mac.
     *
     * Touchscreen mode: one finger points and clicks where you touch, because that is what a screen
     * in front of you invites. Trackpad mode: one finger moves the cursor from where it already is,
     * a tap clicks there, and holding still for a moment picks up whatever is under it so windows
     * can still be dragged. Two fingers scroll in both. Everything leaves here as a fraction of
     * this view, which is why nothing on this side needs to know the Mac's geometry.
     */
    private fun onTouch(view: android.view.View, event: android.view.MotionEvent): Boolean {
        val mac = MacDisplay.currentOffer?.from ?: return false
        val node = Core.node ?: return false
        val width = view.width.toFloat().coerceAtLeast(1f)
        val height = view.height.toFloat().coerceAtLeast(1f)
        val x = (event.x / width).coerceIn(0f, 1f)
        val y = (event.y / height).coerceIn(0f, 1f)

        when (event.actionMasked) {
            android.view.MotionEvent.ACTION_DOWN -> {
                touchStart = android.os.SystemClock.uptimeMillis()
                touchFrom = Pair(event.x, event.y)
                lastPoint = Pair(event.x, event.y)
                dragging = false
                if (trackpad) {
                    view.postDelayed(holdToDrag, HOLD_TO_DRAG_MS)
                } else {
                    send(node, mac, DisplayTouchPhase.DOWN, x, y)
                }
            }

            android.view.MotionEvent.ACTION_POINTER_DOWN -> {
                // A second finger means a scroll rather than a drag, so let go of what was pressed.
                view.removeCallbacks(holdToDrag)
                if (!scrolling) releaseIfHeld(node, mac, x, y)
                scrolling = true
                lastCentre = centre(event)
            }

            android.view.MotionEvent.ACTION_MOVE -> if (scrolling) {
                val now = centre(event)
                lastCentre?.let { last ->
                    // The position goes with it: a scroll acts on whatever is under the fingers,
                    // and a delta on its own would be applied wherever the Mac's cursor happened
                    // to be — which is the corner of the display before anything has been touched.
                    scroll(
                        node, mac,
                        x = (now.first / width).coerceIn(0f, 1f),
                        y = (now.second / height).coerceIn(0f, 1f),
                        dx = (now.first - last.first) / width,
                        dy = (now.second - last.second) / height,
                    )
                }
                lastCentre = now
            } else if (trackpad) {
                val last = lastPoint
                lastPoint = Pair(event.x, event.y)
                if (last != null) {
                    // A finger that has travelled is steering, not holding, so it no longer counts
                    // as a press-and-hold.
                    if (!dragging && travelled(event)) view.removeCallbacks(holdToDrag)
                    move(node, mac, (event.x - last.first) / width, (event.y - last.second) / height)
                }
            } else {
                send(node, mac, DisplayTouchPhase.MOVE, x, y)
            }

            android.view.MotionEvent.ACTION_POINTER_UP -> lastCentre = null

            android.view.MotionEvent.ACTION_UP, android.view.MotionEvent.ACTION_CANCEL -> {
                view.removeCallbacks(holdToDrag)
                if (!scrolling) {
                    if (trackpad) {
                        val quick = android.os.SystemClock.uptimeMillis() - touchStart < TAP_MS
                        when {
                            dragging -> sendHere(node, mac, DisplayTouchPhase.UP)
                            // A tap clicks where the cursor is, not where the finger was.
                            quick && !travelled(event) -> {
                                sendHere(node, mac, DisplayTouchPhase.DOWN)
                                sendHere(node, mac, DisplayTouchPhase.UP)
                            }
                        }
                    } else {
                        send(node, mac, DisplayTouchPhase.UP, x, y)
                    }
                }
                dragging = false
                scrolling = false
                lastCentre = null
                lastPoint = null
            }
        }
        return true
    }

    /** Held still long enough to mean "pick this up": presses, so the next moves drag. */
    private fun beginDrag() {
        val mac = MacDisplay.currentOffer?.from ?: return
        val node = Core.node ?: return
        dragging = true
        sendHere(node, mac, DisplayTouchPhase.DOWN)
        view.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
    }

    /** Whether the finger has moved far enough to be a drag rather than a tap. */
    private fun travelled(event: android.view.MotionEvent): Boolean {
        val from = touchFrom ?: return false
        val slop = android.view.ViewConfiguration.get(this).scaledTouchSlop
        return Math.hypot((event.x - from.first).toDouble(), (event.y - from.second).toDouble()) > slop
    }

    private fun releaseIfHeld(node: uniffi.brege_ffi.BregeNode, mac: String, x: Float, y: Float) {
        if (trackpad) {
            if (dragging) sendHere(node, mac, DisplayTouchPhase.UP)
        } else {
            send(node, mac, DisplayTouchPhase.UP, x, y)
        }
        dragging = false
    }

    /** Lets go of everything, for a mode change in the middle of a touch. */
    private fun releaseEverything() {
        val mac = MacDisplay.currentOffer?.from ?: return
        val node = Core.node ?: return
        if (dragging) sendHere(node, mac, DisplayTouchPhase.UP)
        dragging = false
        scrolling = false
        lastCentre = null
        lastPoint = null
        view.removeCallbacks(holdToDrag)
    }

    /** Where the fingers are together, which is what a two-finger scroll follows. */
    private fun centre(event: android.view.MotionEvent): Pair<Float, Float> {
        var x = 0f
        var y = 0f
        for (index in 0 until event.pointerCount) {
            x += event.getX(index)
            y += event.getY(index)
        }
        return Pair(x / event.pointerCount, y / event.pointerCount)
    }

    private fun send(node: uniffi.brege_ffi.BregeNode, mac: String, phase: DisplayTouchPhase, x: Float, y: Float) {
        runCatching { node.sendDisplayPointer(mac, phase, x, y, 0f, 0f, false) }
    }

    /** Acts where the Mac's cursor already is, which is all trackpad mode can know about. */
    private fun sendHere(node: uniffi.brege_ffi.BregeNode, mac: String, phase: DisplayTouchPhase) {
        runCatching { node.sendDisplayPointer(mac, phase, 0f, 0f, 0f, 0f, true) }
    }

    private fun move(node: uniffi.brege_ffi.BregeNode, mac: String, dx: Float, dy: Float) {
        if (dx == 0f && dy == 0f) return
        runCatching { node.sendDisplayPointer(mac, DisplayTouchPhase.MOVE, 0f, 0f, dx, dy, true) }
    }

    private fun scroll(
        node: uniffi.brege_ffi.BregeNode,
        mac: String,
        x: Float,
        y: Float,
        dx: Float,
        dy: Float,
    ) {
        if (dx == 0f && dy == 0f) return
        runCatching { node.sendDisplayPointer(mac, DisplayTouchPhase.SCROLL, x, y, dx, dy, trackpad) }
    }

    private fun startDecoding(holder: SurfaceHolder) {
        val begin = { offer: MacDisplay.Offer ->
            stopDecoding()
            fit(offer)
            // The buffer is the size of the video, so the compositor scales once, to the view.
            holder.setFixedSize(offer.width, offer.height)
            val made = DisplayDecoder(holder.surface, offer.mime, offer.width, offer.height)
            decoder = made
            MacDisplay.attach(made)
            // The Mac cannot know when this screen became ready, and nothing here can decode
            // anything until a key frame arrives — so ask for one instead of waiting out the
            // interval with a blank screen.
            runCatching { Core.node?.requestDisplayKeyframe(offer.from) }
        }
        // An offer already in hand starts at once; one still on its way arrives here.
        MacDisplay.onOffer = { offer -> runOnUiThread { begin(offer) } }
        MacDisplay.currentOffer?.let(begin)
    }

    private fun stopDecoding() {
        decoder?.let {
            MacDisplay.detach(it)
            it.release()
        }
        decoder = null
    }

    /** Reported again here, in case this screen was opened before any Mac connected. */
    private fun reportCapabilities() {
        val mac = MacDisplay.currentOffer?.from ?: Core.connectedDevices.firstOrNull()?.id ?: return
        MacDisplay.reportCapabilities(this, mac, portrait = isPortrait())
    }

    private fun isPortrait(): Boolean =
        resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_PORTRAIT

    /**
     * The tablet has been turned.
     *
     * Reporting the new shape is what asks the Mac to make its display again: it cannot turn one
     * that already exists. The picture keeps its old shape, fitted and centred, until the new offer
     * arrives — a second of black edges rather than a second of distortion.
     */
    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        MacDisplay.currentOffer?.let(::fit)
        val mac = MacDisplay.currentOffer?.from ?: Core.connectedDevices.firstOrNull()?.id ?: return
        MacDisplay.reportCapabilities(this, mac, portrait = isPortrait())
    }

    override fun onDestroy() {
        super.onDestroy()
        val mac = MacDisplay.currentOffer?.from
        MacDisplay.onOffer = null
        MacDisplay.onStop = null
        MacDisplay.onModeChanged = null
        stopDecoding()
        MacDisplay.stopped(this)
        // The Mac cannot see that this screen closed. Without this it would keep a display nobody
        // can look at, with the user's windows stranded on it.
        if (mac != null) runCatching { Core.node?.stopDisplay(mac, "") }
    }
}
