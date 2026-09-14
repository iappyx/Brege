package app.brege.ui

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import app.brege.companion.CompanionSetup
import app.brege.core.Core
import app.brege.diagnostics.UptimeLog
import app.brege.media.RecentMedia
import app.brege.mic.MicService
import app.brege.screen.WirelessDebugging
import app.brege.notifications.BregeNotificationListener
import app.brege.service.BregeService
import app.brege.storage.PhoneFolders
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import uniffi.brege_ffi.BregeEvent
import uniffi.brege_ffi.BregeException
import uniffi.brege_ffi.Device

class MainActivity : ComponentActivity() {
    private var pendingInvite by mutableStateOf<String?>(null)

    private val folderLauncher = registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            runCatching { PhoneFolders.add(this, uri) }
            resumeTick++
        }
    }

    private val associationLauncher = registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) {
        if (it.resultCode == RESULT_OK) CompanionSetup.onAssociated(this)
    }

    /** Bumped on resume and after permission results so the setup card re-reads system state. */
    private var resumeTick by mutableStateOf(0)

    /** When the Wi‑Fi names request was sent (elapsed realtime), to notice the system ignoring it. */
    private var wifiNamesRequestedAt = 0L

    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        resumeTick++
        // Lets the service start modules that just got their permissions (messages, calls).
        BregeService.start(this, "permissions changed")
        val requestedAt = wifiNamesRequestedAt
        wifiNamesRequestedAt = 0L
        // An answer faster than anyone can tap means Android showed no dialog (for example after
        // precise location was denied twice): send the user to the app's settings instead.
        if (requestedAt != 0L && SystemClock.elapsedRealtime() - requestedAt < NO_DIALOG_MS) {
            val missing = missingPermissions(PermissionGroup.WIFI_NAMES)
            if (missing.isNotEmpty()) openAppSettings(missing)
        }
    }

    override fun onResume() {
        super.onResume()
        if (permissionExists(LOCAL_NETWORK)) {
            val granted = ContextCompat.checkSelfPermission(this, LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED
            UptimeLog.record("local network permission: ${if (granted) "granted" else "NOT granted"} (API ${Build.VERSION.SDK_INT})")
        }
        resumeTick++
        Core.refreshDevices()
        // Location access may just have been granted: read the Wi‑Fi name again.
        app.brege.discovery.NetworkPaths.report(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        BregeService.start(this, "app opened")
        ScreenshotMode.apply(this, intent)
        // After a rotation or theme change the link was already handled.
        if (savedInstanceState == null && !ScreenshotMode.active) handleIntent(intent)
        // A pairing link still waiting for the user's go-ahead survives a rotation.
        if (savedInstanceState != null) pendingInvite = savedInstanceState.getString(STATE_INVITE)
        setContent {
            val dark = androidx.compose.foundation.isSystemInDarkTheme()
            MaterialTheme(colorScheme = if (dark) darkColorScheme() else lightColorScheme()) {
                BregeScreen(
                    resumeTick = resumeTick,
                    permissionsGranted = { group -> missingPermissions(group).isEmpty() },
                    pendingInvite = pendingInvite,
                    onInviteHandled = { pendingInvite = null },
                    onAssociate = ::associate,
                    onRequestPermissions = { group -> requestPermissions(group, openSettings = true) },
                    onRequestPermissionDialogs = { group -> requestPermissions(group, openSettings = false) },
                    onAddFolder = { folderLauncher.launch(null) },
                )
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        pendingInvite?.let { outState.putString(STATE_INVITE, it) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val data = intent?.data?.toString() ?: return
        if (data.startsWith("brege://pair")) pendingInvite = data
    }

    private fun associate(onError: (String) -> Unit) {
        CompanionSetup.associate(
            this, ContextCompat.getMainExecutor(this),
            launch = { associationLauncher.launch(IntentSenderRequest.Builder(it).build()) },
            onError = onError,
        )
    }

    private fun missingPermissions(group: PermissionGroup): List<String> {
        // Optional: lets Brêge show and check Wi‑Fi names (network privacy plan). Android 12+ ignores
        // a request for precise location on its own, so approximate location is asked for with it
        // until precise location is granted (that is also how Approximate becomes Precise).
        if (group == PermissionGroup.WIFI_NAMES) {
            val fine = Manifest.permission.ACCESS_FINE_LOCATION
            return if (isGranted(fine)) emptyList() else listOf(fine, Manifest.permission.ACCESS_COARSE_LOCATION)
        }
        return requiredPermissions(group).filter { !isGranted(it) }
    }

    private fun isGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    private fun requiredPermissions(group: PermissionGroup): List<String> = when (group) {
        PermissionGroup.CORE -> buildList {
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
            if (Build.VERSION.SDK_INT >= 31) {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
                // Lets a Mac tell the phone is nearby before it asks about a network.
                add(Manifest.permission.BLUETOOTH_ADVERTISE)
            }
            // Android 17+ blocks traffic to devices on the local network without this permission
            // (VPN traffic is not affected, which is why connections only worked through WireGuard).
            if (permissionExists(LOCAL_NETWORK)) add(LOCAL_NETWORK)
        }
        PermissionGroup.MESSAGES -> listOf(
            Manifest.permission.READ_SMS,
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.SEND_SMS,
            Manifest.permission.READ_CONTACTS,
        )
        // "Select photos" grants only READ_MEDIA_VISUAL_USER_SELECTED, which is enough for Brêge.
        PermissionGroup.PHOTOS -> if (RecentMedia.hasPermission(this)) emptyList() else listOf(
            if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE,
        )
        // Handled in missingPermissions: approximate location alone is not enough.
        PermissionGroup.WIFI_NAMES -> listOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
        PermissionGroup.CALLS -> listOf(
            Manifest.permission.READ_PHONE_STATE,
            Manifest.permission.READ_CALL_LOG,
            Manifest.permission.ANSWER_PHONE_CALLS,
            Manifest.permission.CALL_PHONE,
            Manifest.permission.READ_CONTACTS,
        )
    }

    private fun permissionExists(name: String): Boolean =
        runCatching { packageManager.getPermissionInfo(name, 0) }.isSuccess

    private companion object {
        const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
        const val STATE_INVITE = "pending_invite"
        /** A permission result sooner than this after the request means no dialog was shown. */
        const val NO_DIALOG_MS = 500L
    }

    /**
     * Android shows a permission dialog at most twice; after that the request returns immediately.
     * With [openSettings] (the setup buttons) the user is then sent to the app's settings page instead
     * of nothing happening; without it (pairing) only permissions that can still show a dialog are asked.
     */
    private fun requestPermissions(group: PermissionGroup, openSettings: Boolean) {
        // A late callback (a scanned code after a rotation) must not launch on a destroyed activity.
        if (isDestroyed) return
        val missing = missingPermissions(group)
        if (missing.isEmpty()) return
        val prefs = getSharedPreferences("setup", MODE_PRIVATE)
        val asked = prefs.getStringSet("requested_permissions", emptySet()).orEmpty()
        // The system shows its dialog for permissions never asked before, or once more after a denial.
        val askable = missing.filter { it !in asked || shouldShowRequestPermissionRationale(it) }
        // Whether Android offers Approximate → Precise cannot be told beforehand: always ask, and open
        // the settings when the answer comes back without a dialog (see permissionLauncher).
        val wifiNames = group == PermissionGroup.WIFI_NAMES && openSettings
        // Location must be requested as a pair; otherwise ask only what can still show a dialog.
        val request = if (openSettings || group == PermissionGroup.WIFI_NAMES) missing else askable
        if (askable.isNotEmpty() || wifiNames) {
            prefs.edit().putStringSet("requested_permissions", asked + request).apply()
            UptimeLog.record("permissions: requesting ${request.joinToString { it.substringAfterLast('.') }}")
            wifiNamesRequestedAt = if (wifiNames) SystemClock.elapsedRealtime() else 0L
            permissionLauncher.launch(request.toTypedArray())
        } else if (openSettings) {
            openAppSettings(missing)
        } else {
            UptimeLog.record("permissions: not asking again for ${missing.joinToString { it.substringAfterLast('.') }}")
        }
    }

    private fun openAppSettings(missing: List<String>) {
        UptimeLog.record("permissions: opening app settings for ${missing.joinToString { it.substringAfterLast('.') }}")
        startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.fromParts("package", packageName, null)),
        )
    }
}

/**
 * Pairing runs in the core's scope and keeps its progress here, so rotating the phone neither
 * cancels it nor resets the screen while the core keeps pairing.
 */
private object Pairing {
    data class State(
        val active: Boolean = false,
        val status: String = "",
        val error: String? = null,
        /** Pairing succeeded and the screen has not yet asked for the permissions Brêge needs. */
        val succeeded: Boolean = false,
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    /** Called on the main thread. */
    fun start(uri: String) {
        if (_state.value.active) return
        _state.value = State(active = true, status = "Connecting to your Mac…")
        // Log only the addresses from the code, never the one-time token.
        val addresses = runCatching { android.net.Uri.parse(uri.trim()).getQueryParameter("addr") }.getOrNull()
        UptimeLog.record("pairing: started, Mac addresses: $addresses")
        Core.scope.launch {
            val node = Core.ensureStarted()
            if (node == null) {
                _state.value = State(error = "Brêge could not start: ${Core.error.value}")
                return@launch
            }
            // Undispatched, so it listens before pairing starts.
            val waiting = launch(start = CoroutineStart.UNDISPATCHED) {
                Core.events.collect { event ->
                    if (event is BregeEvent.PairingWaitingForConfirmation) {
                        _state.update { it.copy(status = "Confirm on ${event.name}…") }
                        UptimeLog.record("pairing: reached ${event.name}, waiting for confirmation")
                    }
                }
            }
            val result = runCatching { node.pairWithInvite(uri.trim()) }
            waiting.cancel()
            result.onFailure {
                val message = when (it) {
                    is BregeException.PairingFailed -> it.reason
                    else -> it.message ?: it.toString()
                }
                _state.value = State(error = message)
                UptimeLog.record("pairing: failed: $message")
            }
            result.onSuccess {
                _state.value = State(succeeded = true)
                Core.refreshDevices()
            }
        }
    }

    fun fail(message: String?) = _state.update { it.copy(error = message) }

    fun successHandled() = _state.update { it.copy(succeeded = false) }
}

enum class PermissionGroup { CORE, MESSAGES, CALLS, PHOTOS, WIFI_NAMES }

@Composable
private fun BregeScreen(
    resumeTick: Int,
    permissionsGranted: (PermissionGroup) -> Boolean,
    pendingInvite: String?,
    onInviteHandled: () -> Unit,
    onAssociate: ((String) -> Unit) -> Unit,
    onRequestPermissions: (PermissionGroup) -> Unit,
    onRequestPermissionDialogs: (PermissionGroup) -> Unit,
    onAddFolder: () -> Unit,
) {
    val context = LocalContext.current
    val realDevices by Core.devices.collectAsState()
    val devices = if (ScreenshotMode.active) ScreenshotMode.devices else realDevices
    val statuses by Core.statuses.collectAsState()
    val coreError by Core.error.collectAsState()
    val pairingState by Pairing.state.collectAsState()
    val pairing = pairingState.active
    val pairingStatus = pairingState.status
    val pairingError = pairingState.error
    var manualUri by rememberSaveable { mutableStateOf("") }
    var showLog by remember { mutableStateOf(false) }
    var showAbout by remember { mutableStateOf(false) }
    var associationError by remember { mutableStateOf<String?>(null) }
    var clickTick by remember { mutableStateOf(0) }
    val refreshTick = resumeTick + clickTick

    // During pairing only ask for permissions that can still show a dialog: the setup card's
    // buttons are the place to open the app's settings.
    fun pair(uri: String) {
        onRequestPermissionDialogs(PermissionGroup.CORE)
        Pairing.start(uri)
    }

    LaunchedEffect(pairingState.succeeded) {
        if (pairingState.succeeded) {
            Pairing.successHandled()
            onRequestPermissionDialogs(PermissionGroup.CORE)
        }
    }

    // A pairing link can come from any web page or app, so it needs the user's go-ahead: the
    // only other confirmation happens on the computer that made the link. Scanned and pasted
    // codes are the user's own action.
    pendingInvite?.let { invite ->
        val name = runCatching { android.net.Uri.parse(invite).getQueryParameter("name") }.getOrNull()
            ?.takeIf { it.isNotBlank() }?.take(60) ?: "a computer"
        AlertDialog(
            onDismissRequest = onInviteHandled,
            title = { Text("Pair with “$name”?") },
            text = {
                Text(
                    "A pairing link opened Brêge. Only continue if you just chose “Pair phone” in Brêge on your own Mac. " +
                        "A paired computer can see your notifications and messages.",
                )
            },
            confirmButton = {
                TextButton(onClick = { onInviteHandled(); pair(invite) }) { Text("Pair") }
            },
            dismissButton = {
                TextButton(onClick = onInviteHandled) { Text("Cancel") }
            },
        )
    }

    Scaffold { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(20.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Brêge", style = MaterialTheme.typography.headlineMedium)
            coreError?.let { Text("Core failed to start: $it", color = MaterialTheme.colorScheme.error) }

            if (devices.isEmpty()) {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("Pair with your Mac", style = MaterialTheme.typography.titleMedium)
                        Text("On your Mac, open Brêge in the menu bar and choose “Pair phone”. Then scan the code.")
                        Button(
                            enabled = !pairing,
                            onClick = {
                                val options = GmsBarcodeScannerOptions.Builder()
                                    .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                                    .build()
                                GmsBarcodeScanning.getClient(context, options).startScan()
                                    .addOnSuccessListener { code -> code.rawValue?.let(::pair) }
                                    .addOnFailureListener { Pairing.fail(it.message) }
                            },
                        ) {
                            Icon(Icons.Default.QrCodeScanner, null)
                            Spacer(Modifier.width(8.dp))
                            Text(if (pairing) pairingStatus else "Scan pairing code")
                        }
                        OutlinedTextField(
                            value = manualUri, onValueChange = { manualUri = it },
                            label = { Text("Or paste the pairing link") }, singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        OutlinedButton(enabled = manualUri.startsWith("brege://pair") && !pairing, onClick = { pair(manualUri) }) {
                            Text("Pair")
                        }
                        pairingError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    }
                }
            }

            if (devices.any { !it.connected }) {
                NetworkQuestionCard(refreshTick = refreshTick, onChanged = { clickTick++ })
            }

            devices.forEach { device -> DeviceCard(device, statuses[device.id]?.batteryPct) }

            if (devices.isNotEmpty()) {
                SetupCard(
                    refreshTick = refreshTick,
                    onAssociate = { onAssociate { associationError = it }; clickTick++ },
                    associationError = associationError,
                    permissionsGranted = permissionsGranted,
                    onRequestPermissions = { group -> onRequestPermissions(group); clickTick++ },
                )
            }

            if (devices.any { it.connected }) {
                MicCard(refreshTick = refreshTick, onChanged = { clickTick++ })
            }

            if (devices.isNotEmpty()) {
                ScreenCard(refreshTick = refreshTick)
            }

            if (devices.isNotEmpty()) {
                FoldersCard(refreshTick = refreshTick, onAdd = onAddFolder, onChanged = { clickTick++ })
            }

            if (devices.isNotEmpty()) {
                NetworksCard(
                    refreshTick = refreshTick,
                    onRequestNames = { onRequestPermissions(PermissionGroup.WIFI_NAMES); clickTick++ },
                    onChanged = { clickTick++ },
                )
            }

            Row {
                TextButton(onClick = { showAbout = true }) { Text("About Brêge") }
                TextButton(onClick = { showLog = true }) { Text("Connection log (diagnostics)") }
            }
        }
    }

    if (showAbout) {
        AboutScreen(onClose = { showAbout = false })
    }

    if (showLog) {
        AlertDialog(
            onDismissRequest = { showLog = false },
            confirmButton = {
                TextButton(onClick = {
                    UptimeLog.file()?.let { file ->
                        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", copyForShare(context, file))
                        val share = Intent(Intent.ACTION_SEND).setType("text/plain")
                            .putExtra(Intent.EXTRA_STREAM, uri)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        context.startActivity(Intent.createChooser(share, "Export log"))
                    }
                }) { Text("Export") }
            },
            dismissButton = { TextButton(onClick = { showLog = false }) { Text("Close") } },
            title = { Text("Connection log") },
            text = {
                SelectionContainer {
                    Text(
                        UptimeLog.read().lines().takeLast(200).joinToString("\n"),
                        fontFamily = FontFamily.Monospace, fontSize = 11.sp,
                        modifier = Modifier.verticalScroll(rememberScrollState()),
                    )
                }
            },
        )
    }
}

private fun copyForShare(context: android.content.Context, file: java.io.File): java.io.File {
    val dir = java.io.File(context.cacheDir, "outgoing").apply { mkdirs() }
    return java.io.File(dir, "brege-uptime.log").also { file.copyTo(it, overwrite = true) }
}

@Composable
private fun DeviceCard(device: Device, battery: UInt?) {
    val scope = rememberCoroutineScope()
    Card(Modifier.fillMaxWidth()) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Laptop, null)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(device.name, style = MaterialTheme.typography.titleMedium)
                Text(if (device.connected) "Connected" else "Not connected — same Wi‑Fi?", style = MaterialTheme.typography.bodySmall)
            }
            TextButton(onClick = { if (!ScreenshotMode.active) scope.launch { runCatching { Core.node?.forgetDevice(device.id) } } }) {
                Text("Forget")
            }
        }
    }
}

@Composable
private fun SetupCard(
    refreshTick: Int,
    permissionsGranted: (PermissionGroup) -> Boolean,
    onAssociate: () -> Unit,
    associationError: String?,
    onRequestPermissions: (PermissionGroup) -> Unit,
) {
    val context = LocalContext.current
    val listenerEnabled = remember(refreshTick) {
        Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
            ?.contains(ComponentName(context, BregeNotificationListener::class.java).flattenToString()) == true
    }
    val associated = remember(refreshTick) { CompanionSetup.isAssociated(context) }
    val granted = remember(refreshTick) { PermissionGroup.entries.associateWith(permissionsGranted) }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Setup", style = MaterialTheme.typography.titleMedium)
            SetupStep(
                done = associated,
                title = "Stay connected in the background",
                body = "Links Brêge to your Mac so Android lets it reconnect on its own.",
                action = "Link Mac", onClick = onAssociate,
            )
            associationError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            SetupStep(
                done = listenerEnabled,
                title = "Show notifications on your Mac",
                body = "Brêge needs notification access. Message contents stay between your devices.",
                action = "Allow",
                onClick = { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) },
            )
            SetupStep(
                done = granted.getValue(PermissionGroup.CORE),
                title = "Notifications, nearby devices and local network",
                body = "Lets Brêge show received files, find your Mac nearby and connect to it over Wi‑Fi.",
                action = "Allow", onClick = { onRequestPermissions(PermissionGroup.CORE) },
            )
            SetupStep(
                done = granted.getValue(PermissionGroup.MESSAGES),
                title = "Text messages on your Mac",
                body = "Read and send SMS from your Mac. Messages are only stored on your devices.",
                action = "Allow", onClick = { onRequestPermissions(PermissionGroup.MESSAGES) },
            )
            SetupStep(
                done = granted.getValue(PermissionGroup.CALLS),
                title = "Calls on your Mac",
                body = "See who is calling, answer, decline and dial from your Mac. You talk on the phone.",
                action = "Allow", onClick = { onRequestPermissions(PermissionGroup.CALLS) },
            )
            SetupStep(
                done = granted.getValue(PermissionGroup.PHOTOS),
                title = "Recent photos on your Mac",
                body = "Drag your latest photos and screenshots into Mac apps. Photos are only sent when you use them.",
                action = "Allow", onClick = { onRequestPermissions(PermissionGroup.PHOTOS) },
            )
        }
    }
}

@Composable
private fun MicCard(refreshTick: Int, onChanged: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var micTick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        Core.events.collect { if (it is BregeEvent.MicStateChanged) micTick++ }
    }
    val active = remember(refreshTick, micTick) { MicService.active }
    fun changed() {
        onChanged()
        // The microphone service starts and stops asynchronously: look again once it has.
        scope.launch {
            delay(500)
            micTick++
            delay(1500)
            micTick++
        }
    }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Microphone for your Mac", style = MaterialTheme.typography.titleMedium)
            Text(
                if (active) "Your Mac is using this phone's microphone. Choose “Brêge Microphone” as the input on the Mac."
                else "Use this phone as a microphone on your Mac. On the Mac, choose “Brêge Microphone” as the input.",
                style = MaterialTheme.typography.bodySmall,
            )
            if (active) {
                OutlinedButton(onClick = { MicService.stop(context); changed() }) { Text("Stop microphone") }
            } else {
                Button(onClick = { MicService.startFromApp(context); changed() }) { Text("Start microphone") }
            }
        }
    }
}

@Composable
private fun ScreenCard(refreshTick: Int) {
    val context = LocalContext.current
    val developer = remember(refreshTick) { WirelessDebugging.developerOptionsEnabled(context) }
    val wireless = remember(refreshTick) { WirelessDebugging.isOn(context) }
    val automatic = remember(refreshTick) { WirelessDebugging.canSwitchOn(context) }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Phone screen on your Mac", style = MaterialTheme.typography.titleMedium)
            Text(
                when {
                    !developer -> "To use this phone's screen and apps on your Mac, turn on Developer options: " +
                        "open About phone and tap Build number seven times."
                    !wireless -> "Turn on Wireless debugging in Developer options, then click Screen in Brêge on your Mac. " +
                        "Tip: add the Wireless debugging tile to Quick Settings."
                    automatic -> "Ready. Your Mac switches wireless debugging back on when needed."
                    else -> "Wireless debugging is on. Click Screen in Brêge on your Mac."
                },
                style = MaterialTheme.typography.bodySmall,
            )
            if (!developer || !wireless) {
                OutlinedButton(onClick = { WirelessDebugging.openSettings(context) }) {
                    Text(if (developer) "Open Developer options" else "Open About phone")
                }
            }
        }
    }
}

@Composable
private fun FoldersCard(refreshTick: Int, onAdd: () -> Unit, onChanged: () -> Unit) {
    val context = LocalContext.current
    val shares = remember(refreshTick) { PhoneFolders.shares(context) }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Phone folders on your Mac", style = MaterialTheme.typography.titleMedium)
            Text(
                "Folders you add here appear in Finder on your Mac. Tip: add DCIM for camera photos, " +
                    "and Pictures, Documents or a folder inside Download.",
                style = MaterialTheme.typography.bodySmall,
            )
            if (ScreenshotMode.active) {
                ScreenshotMode.folders.forEach { name ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Folder, null)
                        Spacer(Modifier.width(8.dp))
                        Text(name, Modifier.weight(1f))
                        TextButton(onClick = {}) { Text("Remove") }
                    }
                }
            }
            if (!ScreenshotMode.active) shares.forEach { share ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Folder, null)
                    Spacer(Modifier.width(8.dp))
                    Text(share.name, Modifier.weight(1f))
                    TextButton(onClick = { PhoneFolders.remove(context, share); onChanged() }) { Text("Remove") }
                }
            }
            OutlinedButton(onClick = onAdd) { Text("Add folder") }
        }
    }
}

/** Changes whenever the core reports changed networks, to re-read them. */
@Composable
private fun rememberNetworksTick(): Int {
    var tick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        Core.events.collect { if (it is BregeEvent.NetworkPathsChanged) tick++ }
    }
    return tick
}

/**
 * The phone's question about a network or VPN Brêge does not know yet (network privacy plan). The
 * phone asks only here, never with a notification.
 */
@Composable
private fun NetworkQuestionCard(refreshTick: Int, onChanged: () -> Unit) {
    val networksTick = rememberNetworksTick()
    var decided by remember { mutableStateOf(0) }
    val node = Core.node
    val undecided = remember(refreshTick, networksTick, decided) {
        if (ScreenshotMode.active) return@remember ScreenshotMode.undecided
        runCatching { node?.networkPaths() }.getOrNull().orEmpty()
            .filter { !it.trusted && !it.declined && (!it.isVpn || it.blockedDeviceIds.isNotEmpty()) }
    }
    if (undecided.isEmpty()) return
    fun done() {
        decided++
        onChanged()
    }
    undecided.forEach { path ->
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    if (path.isVpn) "Use this VPN to reach your Mac?" else "Use Brêge on this network?",
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(path.label, style = MaterialTheme.typography.bodyMedium)
                Text(
                    if (path.isVpn) {
                        "Brêge only connects through VPNs you allow."
                    } else {
                        "Brêge stays silent on networks you have not chosen. Choose Use here only for networks you trust."
                    },
                    style = MaterialTheme.typography.bodySmall,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { runCatching { node?.declineNetwork(path.fingerprint) }; done() }) {
                        Text(if (path.isVpn) "Never" else "Not here")
                    }
                    if (path.isVpn) {
                        OutlinedButton(onClick = { node?.allowNetworkOnce(path.fingerprint); done() }) { Text("Only now") }
                    }
                    Button(onClick = { runCatching { node?.trustNetwork(path.fingerprint) }; done() }) {
                        Text(if (path.isVpn) "Always" else "Use here")
                    }
                }
            }
        }
    }
}

/** Networks and VPNs Brêge uses (network privacy plan), with Forget. */
@Composable
private fun NetworksCard(refreshTick: Int, onRequestNames: () -> Unit, onChanged: () -> Unit) {
    val context = LocalContext.current
    val networksTick = rememberNetworksTick()
    var forgotten by remember { mutableStateOf(0) }
    val node = Core.node
    val known = remember(refreshTick, networksTick, forgotten) {
        if (ScreenshotMode.active) ScreenshotMode.known else runCatching { node?.knownNetworks() }.getOrNull().orEmpty()
    }
    val hasNames = remember(refreshTick) { ScreenshotMode.active || app.brege.discovery.NetworkPaths.hasLocation(context) }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Networks", style = MaterialTheme.typography.titleMedium)
            Text(
                "Brêge only connects and answers on the networks and VPNs you use it on. Elsewhere it stays silent.",
                style = MaterialTheme.typography.bodySmall,
            )
            known.forEach { network ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(network.label)
                        if (!network.trusted) Text("Not used", style = MaterialTheme.typography.bodySmall)
                    }
                    TextButton(onClick = {
                        runCatching { node?.forgetNetwork(network.fingerprint) }
                        forgotten++
                        onChanged()
                    }) { Text("Forget") }
                }
            }
            if (!hasNames) {
                Text(
                    "Optional: with Location access Brêge shows Wi‑Fi names and can tell your network apart from another " +
                        "network with the same addresses.",
                    style = MaterialTheme.typography.bodySmall,
                )
                OutlinedButton(onClick = onRequestNames) { Text("Show Wi‑Fi names") }
            }
        }
    }
}

@Composable
private fun SetupStep(done: Boolean, title: String, body: String, action: String, onClick: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(body, style = MaterialTheme.typography.bodySmall)
        }
        if (done) {
            Icon(Icons.Default.CheckCircle, "Done", tint = MaterialTheme.colorScheme.primary)
        } else {
            OutlinedButton(onClick = onClick) { Text(action) }
        }
    }
}
