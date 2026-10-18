package app.brege.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.CompactChip
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text

/**
 * Brêge on the wrist: what you want when you stand up and walk away from the Mac.
 * The phone does the talking; this is only the remote.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MacRemote() }
    }

    override fun onResume() {
        super.onResume()
        MacLink.ask(this)
    }
}

@Composable
private fun MacRemote() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val state by MacLink.state.collectAsState()
    val waiting by MacLink.waiting.collectAsState()

    MaterialTheme {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 14.dp, vertical = 26.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Text(
                text = when {
                    state.connected -> state.name.ifEmpty { "Mac" }
                    waiting -> "Asking the phone…"
                    else -> "No Mac connected"
                },
                style = MaterialTheme.typography.title3,
                textAlign = TextAlign.Center,
            )
            Text(
                text = detail(state, waiting),
                style = MaterialTheme.typography.caption2,
                textAlign = TextAlign.Center,
            )

            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                CompactChip(
                    onClick = { MacLink.act(context, "ring", if (state.ringing) 0 else 1) },
                    colors = if (state.ringing) ChipDefaults.primaryChipColors()
                        else ChipDefaults.secondaryChipColors(),
                    label = { Text(if (state.ringing) "Stop" else "Ring") },
                )
                CompactChip(
                    onClick = { MacLink.act(context, "lock") },
                    colors = ChipDefaults.secondaryChipColors(),
                    label = { Text("Lock") },
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                CompactChip(
                    onClick = { MacLink.act(context, "volume", (state.volume - 10).coerceAtLeast(0)) },
                    colors = ChipDefaults.secondaryChipColors(),
                    label = { Text("Vol −") },
                )
                CompactChip(
                    onClick = { MacLink.act(context, "mute", if (state.muted) 0 else 1) },
                    colors = ChipDefaults.secondaryChipColors(),
                    label = { Text(if (state.muted) "Sound" else "Mute") },
                )
                CompactChip(
                    onClick = { MacLink.act(context, "volume", (state.volume + 10).coerceAtMost(100)) },
                    colors = ChipDefaults.secondaryChipColors(),
                    label = { Text("Vol +") },
                )
            }

            if (state.connected && state.keyControl) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    CompactChip(
                        onClick = { MacLink.act(context, "previous") },
                        colors = ChipDefaults.secondaryChipColors(),
                        label = { Text("◀◀") },
                    )
                    CompactChip(
                        onClick = { MacLink.act(context, "playpause") },
                        colors = ChipDefaults.primaryChipColors(),
                        label = { Text("Play") },
                    )
                    CompactChip(
                        onClick = { MacLink.act(context, "next") },
                        colors = ChipDefaults.secondaryChipColors(),
                        label = { Text("▶▶") },
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    CompactChip(
                        onClick = { MacLink.act(context, "slideprev") },
                        colors = ChipDefaults.secondaryChipColors(),
                        label = { Text("Slide −") },
                    )
                    CompactChip(
                        onClick = { MacLink.act(context, "slidenext") },
                        colors = ChipDefaults.secondaryChipColors(),
                        label = { Text("Slide +") },
                    )
                }
            }

            Chip(
                onClick = { MacLink.ask(context) },
                colors = ChipDefaults.secondaryChipColors(),
                label = { Text("Refresh", style = MaterialTheme.typography.caption2) },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

private fun detail(state: MacState, waiting: Boolean): String {
    if (!state.connected) {
        return if (waiting) "" else "The phone will reach it when it is back"
    }
    val parts = mutableListOf<String>()
    parts.add(if (state.muted) "muted" else "volume ${state.volume}%")
    if (state.hasBattery) parts.add("${state.battery}%${if (state.charging) " charging" else ""}")
    if (state.ringing) parts.add("ringing")
    return parts.joinToString(" · ")
}
