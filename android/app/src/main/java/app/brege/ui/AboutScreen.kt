package app.brege.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.graphics.drawable.toBitmap
import org.json.JSONObject

/** About Brêge: version, author, the MIT license and the open-source components in the app. */
@Composable
fun AboutScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    var licenseText by remember { mutableStateOf<Pair<String, String>?>(null) }
    var showComponents by remember { mutableStateOf(false) }
    val info = remember { context.packageManager.getPackageInfo(context.packageName, 0) }
    val icon = remember { context.packageManager.getApplicationIcon(context.packageName).toBitmap(256, 256).asImageBitmap() }

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            if (showComponents) {
                ComponentList(onBack = { showComponents = false }, onOpen = { licenseText = it })
            } else {
                Column(
                    Modifier.fillMaxSize().padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically),
                ) {
                    Image(icon, contentDescription = null, modifier = Modifier.size(96.dp))
                    Text("Brêge", style = MaterialTheme.typography.headlineMedium)
                    Text("Version ${info.versionName} (${info.longVersionCode})", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(4.dp))
                    Text("Your Android phone and your Mac, together.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(12.dp))
                    Text("© 2026 iappyx")
                    TextButton(onClick = { open(context, "https://iappyx.github.io/") }) { Text("iappyx.github.io") }
                    Text("Released under the MIT License.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedButton(onClick = { licenseText = "MIT License" to asset(context, "LICENSE.txt") }) { Text("License") }
                        OutlinedButton(onClick = { showComponents = true }) { Text("Open-source licenses") }
                    }
                    Spacer(Modifier.height(24.dp))
                    TextButton(onClick = onClose) { Text("Close") }
                }
            }
        }
    }

    licenseText?.let { (title, text) ->
        AlertDialog(
            onDismissRequest = { licenseText = null },
            confirmButton = { TextButton(onClick = { licenseText = null }) { Text("Close") } },
            title = { Text(title) },
            text = {
                SelectionContainer {
                    Text(reflowLicense(text), style = MaterialTheme.typography.bodySmall, modifier = Modifier.verticalScroll(rememberScrollState()))
                }
            },
        )
    }
}

private data class Component(val name: String, val version: String, val license: String, val homepage: String, val text: String)

@Composable
private fun ComponentList(onBack: () -> Unit, onOpen: (Pair<String, String>) -> Unit) {
    val context = LocalContext.current
    val components = remember { loadComponents(context) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("Back") }
            Text("Open-source licenses", style = MaterialTheme.typography.titleLarge)
        }
        Text(
            "Brêge is built with ${components.size} open-source components.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
        )
        LazyColumn(Modifier.fillMaxSize()) {
            items(components, key = { it.name + it.version }) { c ->
                Column(
                    Modifier.fillMaxWidth()
                        .clickable { onOpen("${c.name} ${c.version}" to listOf(c.license, c.homepage, c.text).filter { it.isNotBlank() }.joinToString("\n\n")) }
                        .padding(horizontal = 20.dp, vertical = 10.dp),
                ) {
                    Text(c.name, fontWeight = FontWeight.Medium)
                    Text("${c.version} · ${c.license}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                HorizontalDivider()
            }
        }
    }
}

private fun loadComponents(context: Context): List<Component> = runCatching {
    val root = JSONObject(asset(context, "licenses.json"))
    val texts = root.getJSONObject("texts")
    val array = root.getJSONArray("components")
    (0 until array.length()).map { i ->
        val c = array.getJSONObject(i)
        val textId = c.optString("text", "")
        Component(
            name = c.getString("name"), version = c.getString("version"), license = c.getString("license"),
            homepage = c.optString("homepage", ""), text = if (textId.isEmpty() || textId == "null") "" else texts.optString(textId, ""),
        )
    }
}.getOrDefault(emptyList())

/**
 * License files are wrapped at about 80 columns; in a phone-width dialog those breaks land
 * mid-sentence. Joins the lines of each paragraph so the text wraps to the dialog. Blank lines,
 * list items, copyright lines, separator lines and lines after a short line (headings, addresses)
 * keep their own line.
 */
internal fun reflowLicense(text: String): String {
    val listItem = Regex("""^([-*•·]|\(?[0-9A-Za-z]{1,3}[.)])\s""")
    fun isSeparator(line: String) = line.length >= 3 && line.all { it in "=-_*#~" }
    val paragraphs = mutableListOf<String>()
    val current = StringBuilder()
    var previous = ""
    for (raw in text.replace("\r\n", "\n").split("\n")) {
        val line = raw.trim()
        when {
            line.isEmpty() -> {
                if (current.isNotEmpty()) paragraphs += current.toString()
                current.clear()
            }
            current.isEmpty() -> current.append(line)
            previous.length < 40 || listItem.containsMatchIn(line) || line.startsWith("Copyright") || line.startsWith("©") ||
                isSeparator(line) || isSeparator(previous) -> current.append('\n').append(line)
            previous.endsWith("-") && previous.dropLast(1).lastOrNull()?.isLetter() == true -> current.append(line)
            else -> current.append(' ').append(line)
        }
        if (line.isNotEmpty()) previous = line
    }
    if (current.isNotEmpty()) paragraphs += current.toString()
    return paragraphs.joinToString("\n\n")
}

private fun asset(context: Context, name: String): String =
    runCatching { context.assets.open(name).bufferedReader().use { it.readText() } }.getOrDefault("")

private fun open(context: Context, url: String) {
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}
