package app.brege.capture

import android.Manifest
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import app.brege.BregeApplication
import app.brege.R
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.launch
import uniffi.brege_ffi.CaptureKind
import uniffi.brege_ffi.CaptureStatus

/**
 * Import from phone: the Mac asks for a photo or a document scan. Android does not let an app
 * open the camera from the background, so the request becomes a notification; tapping it opens
 * this activity, which runs the system camera or Google's document scanner and sends the result.
 */
class CaptureActivity : ComponentActivity() {
    private lateinit var mac: String
    private lateinit var requestId: String
    private var photo: File? = null

    /** Whether the camera, permission dialog or scanner was launched: its result then comes back here. */
    private var launched = false

    /** A scanner that became ready while this activity was not started, launched in onStart. */
    private var pendingScan: IntentSender? = null

    private val takePicture = registerForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        val file = photo
        if (saved && file != null && file.length() > 0) send(file) else cancel()
    }

    // Brêge declares the camera permission (for the live camera), and Android then refuses the
    // system camera intent until that permission is granted.
    private val cameraPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startCamera() else fail("Camera access was denied on the phone")
    }

    private val scanDocument = registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        // A scan is always one PDF, however many pages it has.
        val scan = GmsDocumentScanningResult.fromActivityResultIntent(result.data)
        val uri: Uri? = if (result.resultCode == RESULT_OK) scan?.pdf?.uri else null
        if (uri == null) {
            cancel()
            return@registerForActivityResult
        }
        val file = newFile("Scan", "pdf")
        runCatching { contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().use { input.copyTo(it) } } }
            .onSuccess { send(file) }
            .onFailure { fail("Could not read the scan") }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        mac = intent.getStringExtra(EXTRA_MAC) ?: return finish()
        requestId = intent.getStringExtra(EXTRA_REQUEST) ?: return finish()
        getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_TAG, notificationId(requestId))
        if (savedInstanceState != null) {
            photo = savedInstanceState.getString(STATE_PHOTO)?.let(::File)
            launched = savedInstanceState.getBoolean(STATE_LAUNCHED)
            if (launched) return // a result is on its way
        }
        when (intent.getStringExtra(EXTRA_KIND)) {
            KIND_DOCUMENT -> startScan()
            else ->
                if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                    startCamera()
                } else {
                    launched = true
                    cameraPermission.launch(Manifest.permission.CAMERA)
                }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        photo?.let { outState.putString(STATE_PHOTO, it.path) }
        outState.putBoolean(STATE_LAUNCHED, launched)
    }

    override fun onStart() {
        super.onStart()
        pendingScan?.let {
            pendingScan = null
            launchScan(it)
        }
    }

    private fun startCamera() {
        val file = newFile("Photo", "jpg")
        photo = file
        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
        launched = true
        runCatching { takePicture.launch(uri) }.onFailure { fail("No camera app available") }
    }

    private fun startScan() {
        val options = GmsDocumentScannerOptions.Builder()
            .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
            .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_PDF)
            .setGalleryImportAllowed(true)
            .build()
        GmsDocumentScanning.getClient(options).getStartScanIntent(this)
            .addOnSuccessListener { sender ->
                // Rotated meanwhile: the new activity (nothing launched in its saved state) starts its own scanner.
                if (isDestroyed || isFinishing) return@addOnSuccessListener
                // Not started (saved state may already be written): onStart launches it.
                pendingScan = sender
                if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
                    pendingScan = null
                    launchScan(sender)
                }
            }
            .addOnFailureListener { if (!isDestroyed) fail("The document scanner is not available: ${it.message}") }
    }

    private fun launchScan(sender: IntentSender) {
        if (isDestroyed || isFinishing) return
        launched = true
        runCatching { scanDocument.launch(IntentSenderRequest.Builder(sender).build()) }
            .onFailure { fail("The document scanner is not available: ${it.message}") }
    }

    private fun newFile(prefix: String, extension: String): File {
        val dir = File(cacheDir, "captures").apply { mkdirs() }
        dir.listFiles()?.filter { it.lastModified() < System.currentTimeMillis() - 86_400_000 }?.forEach { it.delete() }
        val stamp = SimpleDateFormat("yyyy-MM-dd 'at' HH.mm.ss", Locale.US).format(Date())
        return File(dir, "$prefix $stamp.$extension")
    }

    private fun send(file: File) {
        Core.scope.launch {
            val node = Core.ensureStarted()
            val result = runCatching { node!!.sendFile(mac, file.path) }
            result.onSuccess { transferId ->
                runCatching { node!!.sendCaptureResult(mac, requestId, CaptureStatus.SENDING, transferId, "") }
                UptimeLog.record("capture: sent ${file.extension} to the Mac")
            }.onFailure {
                runCatching { node?.sendCaptureResult(mac, requestId, CaptureStatus.FAILED, "", "The Mac is not connected") }
            }
        }
        finish()
    }

    private fun cancel() {
        runCatching { Core.node?.sendCaptureResult(mac, requestId, CaptureStatus.CANCELLED, "", "") }
        finish()
    }

    private fun fail(detail: String) {
        runCatching { Core.node?.sendCaptureResult(mac, requestId, CaptureStatus.FAILED, "", detail) }
        UptimeLog.record("capture: failed ($detail)")
        finish()
    }

    companion object {
        /** Each request has its own notification, so a newer request does not replace an older one. */
        private const val NOTIFICATION_TAG = "capture"
        private const val EXTRA_MAC = "mac"
        private const val EXTRA_REQUEST = "request"
        private const val EXTRA_KIND = "kind"
        private const val KIND_DOCUMENT = "document"
        private const val STATE_PHOTO = "photo"
        private const val STATE_LAUNCHED = "launched"

        private fun notificationId(requestId: String) = requestId.hashCode()

        /** A capture request from the Mac: ask the user with a notification. */
        fun request(context: Context, mac: String, requestId: String, kind: CaptureKind) {
            val document = kind == CaptureKind.DOCUMENT
            val macName = Core.connectedDevices.firstOrNull { it.id == mac }?.name ?: "your Mac"
            val intent = Intent(context, CaptureActivity::class.java)
                .putExtra(EXTRA_MAC, mac)
                .putExtra(EXTRA_REQUEST, requestId)
                .putExtra(EXTRA_KIND, if (document) KIND_DOCUMENT else "photo")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val tap = PendingIntent.getActivity(
                context, notificationId(requestId), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val notification = NotificationCompat.Builder(context, BregeApplication.CHANNEL_EVENTS)
                .setSmallIcon(R.drawable.ic_brege)
                .setContentTitle(if (document) "Scan a document for $macName" else "Take a photo for $macName")
                .setContentText("Tap to open the ${if (document) "scanner" else "camera"}")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setAutoCancel(true)
                .setContentIntent(tap)
                .setTimeoutAfter(180_000)
                .build()
            context.getSystemService(NotificationManager::class.java).notify(NOTIFICATION_TAG, notificationId(requestId), notification)
            UptimeLog.record("capture: ${if (document) "scan" else "photo"} requested by the Mac")
        }
    }
}
