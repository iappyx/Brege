package app.brege.wear

import android.content.Context
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.expand
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.protolayout.material.Text
import androidx.wear.protolayout.material.Typography
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * The tile: the Mac's state and four taps. It draws whatever the phone last said and asks for a
 * fresh answer every time it is shown — Wear OS suspends everything in between, so there is no
 * point keeping anything alive.
 */
class MacTileService : TileService() {

    override fun onTileRequest(
        requestParams: RequestBuilders.TileRequest
    ): ListenableFuture<TileBuilders.Tile> {
        // A tap arrives as the id of the thing that was tapped, and then the tile is drawn again.
        requestParams.currentState.lastClickableId
            .takeIf { it.isNotEmpty() }
            ?.split(":")
            ?.let { parts ->
                when {
                    parts.size == 2 && parts[0] == "page" -> page = parts[1]
                    parts.size == 2 -> MacLink.act(this, parts[0], parts[1].toIntOrNull() ?: 0)
                }
            }
        MacLink.ask(this)
        val state = MacLink.state.value
        val layout = LayoutElementBuilders.Box.Builder()
            .setWidth(expand())
            .setHeight(expand())
            .addContent(column(this, state))
            .build()

        return Futures.immediateFuture(
            TileBuilders.Tile.Builder()
                .setResourcesVersion(RESOURCES)
                .setFreshnessIntervalMillis(0) // redrawn when shown, not on a timer
                .setTileTimeline(
                    TimelineBuilders.Timeline.Builder()
                        .addTimelineEntry(
                            TimelineBuilders.TimelineEntry.Builder()
                                .setLayout(
                                    LayoutElementBuilders.Layout.Builder().setRoot(layout).build()
                                )
                                .build()
                        )
                        .build()
                )
                .build()
        )
    }

    override fun onTileResourcesRequest(
        requestParams: RequestBuilders.ResourcesRequest
    ): ListenableFuture<ResourceBuilders.Resources> = Futures.immediateFuture(
        ResourceBuilders.Resources.Builder().setVersion(RESOURCES).build()
    )

    private fun column(context: Context, state: MacState): LayoutElementBuilders.LayoutElement =
        if (page == PAGE_PLAYBACK && state.keyControl) playbackPage(context, state)
        else macPage(context, state)

    /** Ring, lock and volume: everything that needs no permission on the Mac. */
    private fun macPage(context: Context, state: MacState): LayoutElementBuilders.LayoutElement {
        val column = LayoutElementBuilders.Column.Builder()
            .addContent(
                Text.Builder(context, if (state.connected) state.name.ifEmpty { "Mac" } else "No Mac")
                    .setTypography(Typography.TYPOGRAPHY_TITLE3)
                    .setColor(argb(0xFFFFFFFF.toInt()))
                    .build()
            )
            .addContent(
                Text.Builder(context, detail(state))
                    .setTypography(Typography.TYPOGRAPHY_CAPTION2)
                    .setColor(argb(0xFFB0B0B8.toInt()))
                    .build()
            )
            .addContent(
                row(
                    button(context, if (state.ringing) "Stop" else "Ring", "ring",
                          if (state.ringing) 0 else 1),
                    button(context, "Lock", "lock", 0),
                )
            )
            .addContent(gap())
            .addContent(
                row(
                    button(context, "−", "volume", (state.volume - 10).coerceAtLeast(0), 58f),
                    button(context, if (state.muted) "On" else "Off", "mute",
                           if (state.muted) 0 else 1, 58f),
                    button(context, "+", "volume", (state.volume + 10).coerceAtMost(100), 58f),
                )
            )
        // Only when the Mac says it may press keys: otherwise the page would do nothing.
        if (state.keyControl) {
            column.addContent(gap())
            column.addContent(button(context, "Playback ›", "page", 0, 124f, PAGE_PLAYBACK))
        }
        return column.build()
    }

    /** Playback and slides, which the Mac only accepts with accessibility access. */
    private fun playbackPage(
        context: Context,
        state: MacState,
    ): LayoutElementBuilders.LayoutElement =
        LayoutElementBuilders.Column.Builder()
            .addContent(
                Text.Builder(context, "Playback")
                    .setTypography(Typography.TYPOGRAPHY_TITLE3)
                    .setColor(argb(0xFFFFFFFF.toInt()))
                    .build()
            )
            .addContent(
                row(
                    button(context, "◀◀", "previous", 0, 58f),
                    button(context, "Play", "playpause", 0, 58f),
                    button(context, "▶▶", "next", 0, 58f),
                )
            )
            .addContent(gap())
            .addContent(
                row(
                    button(context, "Slide −", "slideprev", 0),
                    button(context, "Slide +", "slidenext", 0),
                )
            )
            .addContent(gap())
            .addContent(button(context, "‹ Back", "page", 0, 124f, PAGE_MAC))
            .build()

    private fun row(
        vararg items: LayoutElementBuilders.LayoutElement
    ): LayoutElementBuilders.LayoutElement {
        val row = LayoutElementBuilders.Row.Builder()
        items.forEachIndexed { index, item ->
            if (index > 0) row.addContent(gap())
            row.addContent(item)
        }
        return row.build()
    }

    private fun gap(): LayoutElementBuilders.LayoutElement =
        LayoutElementBuilders.Spacer.Builder()
            .setWidth(androidx.wear.protolayout.DimensionBuilders.dp(6f))
            .setHeight(androidx.wear.protolayout.DimensionBuilders.dp(6f))
            .build()

    /** A tap runs TapAction, which hands the action to the phone through MacLink. */
    private fun button(
        context: Context,
        label: String,
        kind: String,
        value: Int,
        width: Float = 88f,
        page: String? = null,
    ): LayoutElementBuilders.LayoutElement =
        LayoutElementBuilders.Box.Builder()
            .setWidth(androidx.wear.protolayout.DimensionBuilders.dp(width))
            .setHeight(androidx.wear.protolayout.DimensionBuilders.dp(46f))
            .setModifiers(
                ModifiersBuilders.Modifiers.Builder()
                    .setPadding(
                        ModifiersBuilders.Padding.Builder().setAll(
                            androidx.wear.protolayout.DimensionBuilders.dp(4f)
                        ).build()
                    )
                    .setBackground(
                        ModifiersBuilders.Background.Builder()
                            .setColor(argb(0xFF2C2C2F.toInt()))
                            .setCorner(
                                ModifiersBuilders.Corner.Builder().setRadius(
                                    androidx.wear.protolayout.DimensionBuilders.dp(23f)
                                ).build()
                            )
                            .build()
                    )
                    .setClickable(
                        ModifiersBuilders.Clickable.Builder()
                            .setId(if (page != null) "page:$page" else "$kind:$value")
                            .setOnClick(
                                ActionBuilders.LoadAction.Builder().build()
                            )
                            .build()
                    )
                    .build()
            )
            .addContent(
                Text.Builder(context, label)
                    .setTypography(Typography.TYPOGRAPHY_BUTTON)
                    .setColor(argb(0xFFFFFFFF.toInt()))
                    .build()
            )
            .build()

    override fun onTileEnterEvent(requestParams: androidx.wear.tiles.EventBuilders.TileEnterEvent) {
        page = PAGE_MAC
        MacLink.ask(this)
    }

    private fun detail(state: MacState): String {
        if (!state.connected) return "the phone cannot reach it"
        val parts = mutableListOf<String>()
        parts.add(if (state.muted) "muted" else "${state.volume}%")
        if (state.hasBattery) parts.add("${state.battery}%")
        if (state.ringing) parts.add("ringing")
        return parts.joinToString(" · ")
    }

    companion object {
        private const val RESOURCES = "1"
        private const val PAGE_MAC = "mac"
        private const val PAGE_PLAYBACK = "play"

        /** Which half of the tile is showing; it goes back to the Mac page when you leave it. */
        @Volatile
        private var page = PAGE_MAC

        /** Redraw the tile when the phone sends a new state. */
        fun refresh(context: Context) {
            runCatching { getUpdater(context).requestUpdate(MacTileService::class.java) }
        }
    }
}
