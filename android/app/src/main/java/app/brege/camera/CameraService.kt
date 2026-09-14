package app.brege.camera

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Range
import android.util.Size
import android.view.OrientationEventListener
import android.view.Surface
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import app.brege.BregeApplication
import app.brege.R
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import app.brege.mic.MicService
import java.util.concurrent.Executor
import kotlinx.coroutines.launch
import uniffi.brege_ffi.CameraStateData

/**
 * Phone camera on the Mac: Camera2 frames go straight into a hardware encoder (H.265, else
 * H.264) whose packets travel on the Brêge video stream. Android only lets a camera service start
 * while the user interacts, so a request from the Mac goes through a notification tap.
 */
class CameraService : android.app.Service() {
    private var mac: String = ""
    private var front = false
    private var torch = false
    private var withAudio = false

    private val cameraThread = HandlerThread("brege-camera").apply { start() }
    private val cameraHandler = Handler(cameraThread.looper)
    // Once the thread has quit a late callback runs right away, so it can still close its camera.
    private val executor = Executor { if (!cameraHandler.post(it)) it.run() }

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var encoder: MediaCodec? = null
    private var encoderSurface: Surface? = null
    private var codec = "h265"
    private var size = Size(1920, 1080)
    private var sensorOrientation = 90
    private var torchAvailable = false
    private var deviceRotation = 0
    @Volatile private var running = false
    private var drainThread: Thread? = null
    private var audioThread: Thread? = null
    private var orientation: OrientationEventListener? = null
    /// The reason the camera stopped, so the final state does not replace it with an empty one.
    private var failure: String? = null
    /// Bumped whenever the camera is stopped: callbacks of an older open close what they opened.
    @Volatile private var generation = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val newMac = intent?.getStringExtra(EXTRA_MAC) ?: mac
        val newFront = intent?.getBooleanExtra(EXTRA_FRONT, front) ?: front
        val newTorch = intent?.getBooleanExtra(EXTRA_TORCH, torch) ?: torch
        val newAudio = intent?.getBooleanExtra(EXTRA_AUDIO, withAudio) ?: withAudio
        if (running) {
            if (newMac != mac) {
                // Another Mac cannot take over or change a camera in use.
                Core.node?.publishCameraState(inactiveState("The camera is in use by another Mac"), newMac)
                UptimeLog.record("camera: request from another Mac refused")
                return START_NOT_STICKY
            }
            // A change from the Mac while streaming: switch camera or torch.
            val switchCamera = newFront != front
            front = newFront; torch = newTorch; withAudio = newAudio
            cameraHandler.post { if (switchCamera) restartCamera() else applyRepeatingRequest() }
            return START_NOT_STICKY
        }
        mac = newMac
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            Core.node?.publishCameraState(inactive("Allow camera access for Brêge on your phone"), to())
            stopSelf()
            return START_NOT_STICKY
        }
        front = newFront; torch = newTorch
        owner = newMac
        withAudio = newAudio && checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        try {
            val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                (if (withAudio) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(), type)
        } catch (e: Exception) {
            UptimeLog.record("camera: foreground start refused: ${e.javaClass.simpleName}")
            Core.node?.publishCameraState(inactive("Tap the Brêge notification on your phone"), to())
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        getSystemService(NotificationManager::class.java).cancel(REQUEST_NOTIFICATION_ID)
        orientation = object : OrientationEventListener(this) {
            override fun onOrientationChanged(degrees: Int) {
                if (degrees == ORIENTATION_UNKNOWN) return
                val snapped = ((degrees + 45) / 90 * 90) % 360
                if (snapped != deviceRotation) {
                    deviceRotation = snapped
                    publishState()
                }
            }
        }.also { if (it.canDetectOrientation()) it.enable() }
        Core.scope.launch {
            val opened = runCatching { Core.ensureStarted()?.openVideoStream(mac) }.isSuccess
            if (!running) {
                // Stopped while the stream was opening: onDestroy already closed what existed.
                if (opened) Core.node?.closeVideoStream()
                return@launch
            }
            if (!opened) {
                Core.node?.publishCameraState(inactive("The Mac is not connected"), to())
                stopSelf()
                return@launch
            }
            cameraHandler.post { startCamera() }
            if (withAudio) startAudio()
        }
        UptimeLog.record("camera: started (${if (front) "front" else "back"})")
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        instance = null
        owner = null
        running = false
        orientation?.disable()
        audioThread?.join(500)
        cameraHandler.post { stopCamera() }
        cameraThread.quitSafely()
        cameraThread.join(1_000)
        Core.node?.closeVideoStream()
        Core.node?.publishCameraState(inactiveState(failure ?: ""), to())
        UptimeLog.record("camera: stopped")
        super.onDestroy()
    }

    // MARK: camera and encoder (camera thread)

    private fun startCamera() {
        if (!running) return
        try {
            openCamera()
        } catch (e: Exception) {
            // Disabled by policy, taken away, or disconnected while opening.
            UptimeLog.record("camera: start failed: ${e.javaClass.simpleName}")
            stopCamera()
            val detail = when {
                e is SecurityException -> "Allow camera access for Brêge on your phone"
                e is CameraAccessException && e.reason == CameraAccessException.CAMERA_DISABLED ->
                    "The camera is turned off on your phone (device policy or privacy setting)"
                e is CameraAccessException && (e.reason == CameraAccessException.CAMERA_IN_USE ||
                    e.reason == CameraAccessException.MAX_CAMERAS_IN_USE) -> "Another app is using the camera"
                else -> "The camera could not start"
            }
            Core.node?.publishCameraState(inactive(detail), to())
            stopSelf()
        }
    }

    @SuppressLint("MissingPermission") // checked in onStartCommand
    private fun openCamera() {
        val opening = generation
        /** False for callbacks that arrive after the service stopped or switched camera. */
        fun stillWanted() = running && opening == generation
        val manager = getSystemService(CameraManager::class.java)
        val wanted = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        val id = manager.cameraIdList.firstOrNull {
            manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == wanted
        } ?: manager.cameraIdList.firstOrNull()
        if (id == null) {
            Core.node?.publishCameraState(inactive("This phone has no usable camera"), to())
            stopSelf()
            return
        }
        val characteristics = manager.getCameraCharacteristics(id)
        sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        torchAvailable = characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        val sizes = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.getOutputSizes(MediaCodec::class.java).orEmpty()
        // The largest 16:9 size up to 1080p; 1080p is what video calls use.
        size = sizes.filter { it.width * 9 == it.height * 16 && it.height <= 1080 }.maxByOrNull { it.width }
            ?: sizes.filter { it.height <= 1080 }.maxByOrNull { it.width * it.height }
            ?: Size(1280, 720)

        val surface = startEncoder() ?: run {
            Core.node?.publishCameraState(inactive("The video encoder is not available"), to())
            stopSelf()
            return
        }
        manager.openCamera(id, executor, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                if (!stillWanted()) {
                    camera.close()
                    return
                }
                device = camera
                val config = SessionConfiguration(
                    SessionConfiguration.SESSION_REGULAR, listOf(OutputConfiguration(surface)), executor,
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(s: CameraCaptureSession) {
                            if (!stillWanted()) {
                                s.close()
                                return
                            }
                            session = s
                            applyRepeatingRequest()
                            publishState()
                        }

                        override fun onConfigureFailed(s: CameraCaptureSession) {
                            if (!stillWanted()) return
                            Core.node?.publishCameraState(inactive("The camera could not start"), to())
                            stopSelf()
                        }
                    },
                )
                try {
                    camera.createCaptureSession(config)
                } catch (e: Exception) {
                    UptimeLog.record("camera: session failed: ${e.javaClass.simpleName}")
                    stopCamera()
                    Core.node?.publishCameraState(inactive("The camera could not start"), to())
                    stopSelf()
                }
            }

            override fun onDisconnected(camera: CameraDevice) {
                camera.close()
                if (!stillWanted()) return
                Core.node?.publishCameraState(inactive("Another app is using the camera"), to())
                stopSelf()
            }

            override fun onError(camera: CameraDevice, error: Int) {
                camera.close()
                if (!stillWanted()) return
                Core.node?.publishCameraState(inactive("Camera error $error"), to())
                stopSelf()
            }
        })
    }

    private fun applyRepeatingRequest() {
        val camera = device ?: return
        val s = session ?: return
        val surface = encoderSurface ?: return
        runCatching {
            val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                addTarget(surface)
                set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(30, 30))
                set(CaptureRequest.FLASH_MODE, if (torch && torchAvailable) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF)
            }.build()
            s.setRepeatingRequest(request, null, cameraHandler)
        }
        publishState()
    }

    private fun startEncoder(): Surface? {
        val codecs = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { it.isEncoder }
        for ((name, mime) in listOf("h265" to MediaFormat.MIMETYPE_VIDEO_HEVC, "h264" to MediaFormat.MIMETYPE_VIDEO_AVC)) {
            // Every encoder for this format by name, hardware first: the default pick can be one
            // that does not accept a camera surface.
            val candidates = codecs.filter { info -> info.supportedTypes.any { it.equals(mime, ignoreCase = true) } }
                .sortedBy { if (it.isHardwareAccelerated) 0 else 1 }
            for (info in candidates) {
                val capabilities = info.getCapabilitiesForType(mime)
                val video = capabilities.videoCapabilities
                val encodeSize = if (video?.isSizeSupported(size.width, size.height) != false) size else Size(1280, 720)
                // Low-latency keys are optional: some encoders reject them, so step down to the basics.
                for (variant in 0..1) {
                    val codecInstance = runCatching { MediaCodec.createByCodecName(info.name) }.getOrNull() ?: break
                    val format = MediaFormat.createVideoFormat(mime, encodeSize.width, encodeSize.height).apply {
                        setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                        val bitrate = if (name == "h265") 6_000_000 else 8_000_000
                        setInteger(MediaFormat.KEY_BIT_RATE, video?.bitrateRange?.clamp(bitrate) ?: bitrate)
                        setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                        setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                        if (variant == 0) setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
                    }
                    // Android 17 refuses to configure an encoder without CONFIGURE_FLAG_ENCODE.
                    val configured = runCatching { codecInstance.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE) }
                    if (configured.isFailure) {
                        UptimeLog.record("camera: ${info.name} ${encodeSize.width}x${encodeSize.height} variant $variant refused")
                        codecInstance.release()
                        continue
                    }
                    val surface = runCatching { codecInstance.createInputSurface() }.getOrNull()
                    if (surface == null || runCatching { codecInstance.start() }.isFailure) {
                        UptimeLog.record("camera: ${info.name} variant $variant did not start")
                        surface?.release()
                        codecInstance.release()
                        continue
                    }
                    size = encodeSize
                    encoder = codecInstance
                    encoderSurface = surface
                    codec = name
                    drainThread = Thread({ drain(codecInstance) }, "brege-camera-encoder").apply { start() }
                    UptimeLog.record("camera: using ${info.name} ${encodeSize.width}x${encodeSize.height} (variant $variant)")
                    return surface
                }
            }
        }
        return null
    }

    private fun drain(codecInstance: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (running && encoder === codecInstance) {
            val index = runCatching { codecInstance.dequeueOutputBuffer(info, 100_000) }.getOrDefault(-1)
            if (index < 0) continue
            val buffer = codecInstance.getOutputBuffer(index)
            if (buffer != null && info.size > 0) {
                val data = ByteArray(info.size)
                buffer.position(info.offset)
                buffer.get(data, 0, info.size)
                var flags = 0
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) flags = flags or 1
                if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) flags = flags or 2
                val sent = Core.node?.sendVideoPacket(flags.toUByte(), info.presentationTimeUs.toULong(), data) == true
                if (!sent) running = false
            }
            runCatching { codecInstance.releaseOutputBuffer(index, false) }
        }
        if (!running) stopSelf()
    }

    private fun stopCamera() {
        generation++
        runCatching { session?.close() }
        runCatching { device?.close() }
        session = null
        device = null
        val old = encoder
        encoder = null
        drainThread?.join(500)
        runCatching { old?.stop() }
        runCatching { old?.release() }
        runCatching { encoderSurface?.release() }
        encoderSurface = null
    }

    private fun restartCamera() {
        stopCamera()
        startCamera()
    }

    // MARK: audio for recordings (sent like the phone microphone)

    @SuppressLint("MissingPermission") // checked before starting
    @Synchronized
    private fun startAudio() {
        if (MicService.active) return // already sending the microphone; see onMicStopped
        if (audioThread?.isAlive == true) return
        audioThread = Thread({
            val frameBytes = 960 // 10 ms, 48 kHz mono 16-bit
            val record = runCatching {
                AudioRecord(MediaRecorder.AudioSource.CAMCORDER, 48_000, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, frameBytes * 8)
            }.getOrNull()
            // Another app holding the microphone leaves it uninitialized: keep the video without sound.
            if (record == null || record.state != AudioRecord.STATE_INITIALIZED) {
                record?.release()
                UptimeLog.record("camera: microphone not available, video without sound")
                return@Thread
            }
            val buffer = ByteArray(frameBytes)
            try {
                record.startRecording()
                // The phone microphone takes over while it runs; see onMicStarted.
                while (running && !MicService.active) {
                    var filled = 0
                    while (filled < frameBytes && running && !MicService.active) {
                        val n = record.read(buffer, filled, frameBytes - filled)
                        if (n < 0) throw IllegalStateException("read error $n")
                        filled += n
                    }
                    if (filled == frameBytes && !MicService.active) Core.node?.sendMicFrame(buffer, to())
                }
            } catch (e: Exception) {
                UptimeLog.record("camera: audio stopped: ${e.javaClass.simpleName}")
            } finally {
                runCatching { record.stop() }
                record.release()
            }
        }, "brege-camera-audio").apply { start() }
    }

    /** The phone microphone stopped: a recording that asked for sound captures it itself. */
    private fun micStopped() {
        if (running && withAudio) startAudio()
    }

    /** The phone microphone started: end this recording's own capture so it releases the microphone. */
    @Synchronized
    private fun micStarted() {
        audioThread?.join(500)
    }

    /** Camera state and sound go only to the Mac that uses the camera. */
    private fun to(): String? = mac.ifEmpty { null }

    // MARK: state

    private fun publishState() {
        // Degrees clockwise the Mac turns the picture to show it upright.
        // Camera2's orientation recipe: the back camera adds the device rotation, the front camera
        // (which faces the other way) subtracts it.
        val rotation = if (front) (sensorOrientation - deviceRotation + 360) % 360 else (sensorOrientation + deviceRotation) % 360
        Core.node?.publishCameraState(
            CameraStateData(
                active = running, codec = codec, width = size.width.toUInt(), height = size.height.toUInt(),
                rotation = rotation.toUInt(), front = front, torch = torch && torchAvailable,
                torchAvailable = torchAvailable, detail = "",
            ),
            to(),
        )
    }

    private fun inactive(detail: String): CameraStateData {
        if (detail.isNotEmpty()) failure = detail
        return inactiveState(detail)
    }

    private fun inactiveState(detail: String) = CameraStateData(
        active = false, codec = "", width = 0u, height = 0u, rotation = 0u, front = front,
        torch = false, torchAvailable = false, detail = detail,
    )

    private fun notification() = NotificationCompat.Builder(this, BregeApplication.CHANNEL_SERVICE)
        .setSmallIcon(R.drawable.ic_brege)
        .setContentTitle("Camera in use by your Mac")
        .setContentText("Brêge is sending this phone's camera to your Mac")
        .setOngoing(true)
        .setSilent(true)
        .addAction(
            R.drawable.ic_brege, "Stop",
            PendingIntent.getService(
                this, 5, Intent(this, CameraService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ),
        )
        .build()

    companion object {
        private const val NOTIFICATION_ID = 13
        private const val REQUEST_NOTIFICATION_ID = 14
        const val ACTION_STOP = "app.brege.CAMERA_STOP"
        const val EXTRA_MAC = "mac"
        const val EXTRA_FRONT = "front"
        const val EXTRA_TORCH = "torch"
        const val EXTRA_AUDIO = "audio"

        /** Set while the service exists, so a request from the Mac changes it instead of prompting. */
        @Volatile var isRunning = false
            private set

        @Volatile private var instance: CameraService? = null

        /** The Mac that started the running camera; requests from other Macs do not change it. */
        @Volatile private var owner: String? = null

        /** Called by [MicService] once its capture ended and released the microphone. */
        fun onMicStopped() {
            instance?.micStopped()
        }

        /** Called by [MicService] before it opens the microphone. */
        fun onMicStarted() {
            instance?.micStarted()
        }

        /** A request from the Mac: apply it when streaming, else ask the user with a notification. */
        fun request(context: Context, mac: String, start: Boolean, front: Boolean, torch: Boolean, audio: Boolean) {
            val service = Intent(context, CameraService::class.java)
                .putExtra(EXTRA_MAC, mac).putExtra(EXTRA_FRONT, front).putExtra(EXTRA_TORCH, torch).putExtra(EXTRA_AUDIO, audio)
            if (!start) {
                val current = owner
                if (isRunning && current != null && current != mac) {
                    UptimeLog.record("camera: stop from another Mac ignored")
                    return
                }
                context.getSystemService(NotificationManager::class.java).cancel(REQUEST_NOTIFICATION_ID)
                context.stopService(service)
                return
            }
            if (isRunning) {
                context.startService(service)
                return
            }
            val start = Intent(context, CameraStartActivity::class.java).putExtras(service).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val tap = PendingIntent.getActivity(context, 6, start, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val macName = Core.connectedDevices.firstOrNull { it.id == mac }?.name ?: "your Mac"
            val notification = NotificationCompat.Builder(context, BregeApplication.CHANNEL_EVENTS)
                .setSmallIcon(R.drawable.ic_brege)
                .setContentTitle("Use this phone as $macName's camera?")
                .setContentText("Tap to start the camera")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setAutoCancel(true)
                .setContentIntent(tap)
                .setTimeoutAfter(5 * 60_000L)
                .build()
            context.getSystemService(NotificationManager::class.java).notify(REQUEST_NOTIFICATION_ID, notification)
            Core.node?.publishCameraState(
                CameraStateData(false, "", 0u, 0u, 0u, front, false, false, "Tap the Brêge notification on your phone to start the camera"),
                mac,
            )
            UptimeLog.record("camera: requested by the Mac, waiting for tap")
        }
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        instance = this
    }
}

/** Opened from the notification: the tap allows starting the camera and asking for permissions. */
class CameraStartActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val needed = buildList {
            if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) add(Manifest.permission.CAMERA)
            if (intent.getBooleanExtra(CameraService.EXTRA_AUDIO, false) &&
                checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
            ) add(Manifest.permission.RECORD_AUDIO)
        }
        when {
            needed.isEmpty() -> start()
            // Recreated (e.g. rotated) while the dialog shows: its result arrives to this instance.
            savedInstanceState == null -> requestPermissions(needed.toTypedArray(), 1)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // Empty results mean the request was interrupted, not denied; a new one follows.
        if (grantResults.isEmpty()) return
        // Without the camera the service could not go to the foreground, and a service started
        // with startForegroundService that never does crashes the app.
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            Core.node?.publishCameraState(
                CameraStateData(
                    active = false, codec = "", width = 0u, height = 0u, rotation = 0u,
                    front = intent.getBooleanExtra(CameraService.EXTRA_FRONT, true),
                    torch = false, torchAvailable = false, detail = "Camera access was denied on the phone",
                ),
                intent.getStringExtra(CameraService.EXTRA_MAC),
            )
            finish()
            return
        }
        start()
    }

    private fun start() {
        startForegroundService(Intent(this, CameraService::class.java).putExtras(intent))
        finish()
    }
}
