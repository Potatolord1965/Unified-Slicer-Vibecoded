package app.unifiedslicer.companion.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.History
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.unifiedslicer.companion.core.model.FilamentSlot
import app.unifiedslicer.companion.core.model.PastPrint
import app.unifiedslicer.companion.core.model.PrinterFile
import app.unifiedslicer.companion.core.model.PrinterState
import app.unifiedslicer.companion.core.model.PrinterStatus
import app.unifiedslicer.companion.core.source.Control
import app.unifiedslicer.companion.core.source.PrinterCommand
import app.unifiedslicer.companion.ui.theme.LocalStudio
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** The loaded filament: one swatch per slot, the one feeding the nozzle outlined. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FilamentPanel(slots: List<FilamentSlot>, accent: Color) {
    if (slots.isEmpty()) return
    SectionLabel("Filament", Modifier.fillMaxWidth().padding(bottom = 6.dp))
    Panel(Modifier.fillMaxWidth()) {
        FlowRow(
            Modifier.fillMaxWidth().padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            slots.forEach { FilamentSwatch(it, accent) }
        }
    }
    Spacer(Modifier.height(10.dp))
}

@Composable
private fun FilamentSwatch(slot: FilamentSlot, accent: Color) {
    val muted = LocalStudio.current.muted
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier.width(64.dp).clip(shape)
            .border(if (slot.active) 2.dp else 1.dp, if (slot.active) accent else LocalStudio.current.hairline, shape)
            .padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        val fill = slot.color?.let(::parseHex)
        Box(
            Modifier.size(26.dp).clip(CircleShape)
                .background(if (slot.empty || fill == null) Color.Transparent else fill)
                .border(1.dp, muted.copy(alpha = 0.5f), CircleShape),
        )
        Spacer(Modifier.height(4.dp))
        Text(slot.label, style = MaterialTheme.typography.labelSmall, color = muted)
        Text(
            if (slot.empty) "–" else slot.type,
            style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        slot.remainPercent?.takeIf { !slot.empty }?.let { Text("$it%", style = MaterialTheme.typography.labelSmall, color = muted) }
    }
}

/** "#RRGGBB" → colour, or null when malformed. */
fun parseHex(hex: String): Color? {
    val v = hex.removePrefix("#").takeIf { it.length == 6 }?.toLongOrNull(16) ?: return null
    return Color(0xFF000000 or v)
}

/** Home and step moves, for an idle printer. Collapsed until opened, so a stray tap moves nothing. */
@Composable
fun MovePanel(p: PrinterStatus, controls: Set<Control>, accent: Color, commands: CommandRunner) {
    if (Control.MOVE !in controls || !p.state.ready) return
    var open by remember(p.key) { mutableStateOf(false) }
    var step by remember { mutableDoubleStateOf(10.0) }
    Panel(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Move", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                TextButton(onClick = { open = !open }) { Text(if (open) "Hide" else "Show", color = accent) }
            }
            if (!open) return@Column
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf(0.1, 1.0, 10.0).forEach { s ->
                    FilterChip(
                        selected = step == s, onClick = { step = s },
                        label = { Text("${if (s < 1) s else s.toInt()} mm") },
                        colors = FilterChipDefaults.filterChipColors(selectedContainerColor = accent, selectedLabelColor = Color.White),
                    )
                }
            }
            listOf('x', 'y', 'z').forEach { axis ->
                Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(axis.uppercase(), Modifier.width(28.dp), style = MaterialTheme.typography.titleMedium)
                    OutlinedButton(onClick = { commands.run(PrinterCommand.Move(axis, -step)) }, enabled = !commands.busy, modifier = Modifier.weight(1f)) { Text("−") }
                    Spacer(Modifier.width(8.dp))
                    OutlinedButton(onClick = { commands.run(PrinterCommand.Move(axis, step)) }, enabled = !commands.busy, modifier = Modifier.weight(1f)) { Text("+") }
                }
            }
            OutlinedButton(
                onClick = { commands.run(PrinterCommand.Home) }, enabled = !commands.busy,
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
            ) { Text("Home all axes") }
            Text(
                "Moves are relative. Home first after the printer was switched on.",
                style = MaterialTheme.typography.bodySmall, color = LocalStudio.current.muted,
                modifier = Modifier.padding(bottom = 6.dp),
            )
        }
    }
    Spacer(Modifier.height(10.dp))
}

/** Links to the printer's stored files and its history. */
@Composable
fun MoreLinks(onFiles: (() -> Unit)?, onHistory: (() -> Unit)?) {
    if (onFiles == null && onHistory == null) return
    Panel(Modifier.fillMaxWidth()) {
        Column {
            onFiles?.let { LinkRow(Icons.Outlined.Folder, "Files on the printer", it) }
            if (onFiles != null && onHistory != null) HorizontalDivider(color = LocalStudio.current.hairline)
            onHistory?.let { LinkRow(Icons.Outlined.History, "Print history", it) }
        }
    }
    Spacer(Modifier.height(10.dp))
}

@Composable
private fun LinkRow(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(20.dp), tint = LocalStudio.current.muted)
        Text(text, Modifier.padding(start = 12.dp), style = MaterialTheme.typography.bodyMedium)
    }
}

/** Loads a list once (and on Retry), with loading and error states. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> ListScreen(
    title: String,
    empty: String,
    load: suspend () -> List<T>,
    onBack: () -> Unit,
    row: @Composable (T) -> Unit,
) {
    var attempt by remember { mutableIntStateOf(0) }
    var items by remember { mutableStateOf<List<T>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(attempt) {
        error = null
        items = null
        try {
            items = load()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message ?: e.javaClass.simpleName
        }
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        val list = items
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                error != null -> Column(Modifier.align(Alignment.Center).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(error.orEmpty(), color = LocalStudio.current.bad, style = MaterialTheme.typography.bodyMedium)
                    TextButton(onClick = { attempt++ }) { Text("Retry") }
                }
                list == null -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                list.isEmpty() -> Text(empty, Modifier.align(Alignment.Center), color = LocalStudio.current.muted)
                else -> LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
                    items(list) { item ->
                        row(item)
                        HorizontalDivider(color = LocalStudio.current.hairline)
                    }
                }
            }
        }
    }
}

/** Why a printer in [state] takes no new print, or null when it takes one. */
fun notReadyReason(state: PrinterState): String? = when {
    state.ready -> null
    state.active -> "The printer is busy with another print."
    state == PrinterState.OFFLINE -> "The printer is offline."
    else -> "The printer's state isn't known yet, so it might be printing."
}

/** Files stored on the printer; tapping one asks before printing it. */
@Composable
fun PrinterFilesScreen(
    printerName: String,
    /** Why printing is blocked right now, or null; see [notReadyReason]. */
    notReady: String?,
    load: suspend () -> List<PrinterFile>,
    onPrint: suspend (PrinterFile) -> String?,
    onBack: () -> Unit,
) {
    var chosen by remember { mutableStateOf<PrinterFile?>(null) }
    var result by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    ListScreen("Files on $printerName", "No print files on the printer.", load, onBack) { f ->
        Column(Modifier.fillMaxWidth().clickable { chosen = f }.padding(vertical = 12.dp)) {
            Text(f.name, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val meta = listOfNotNull(f.sizeBytes?.let(::formatSize), f.modifiedAt?.let(::formatDate))
            if (meta.isNotEmpty()) Text(meta.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = LocalStudio.current.muted)
        }
    }
    chosen?.let { f ->
        AlertDialog(
            onDismissRequest = { chosen = null },
            title = { Text("Print this file?") },
            text = { Text(notReady ?: f.name) },
            confirmButton = {
                TextButton(enabled = notReady == null, onClick = {
                    chosen = null
                    scope.launch { result = onPrint(f) ?: "Print started" }
                }) { Text("Print") }
            },
            dismissButton = { TextButton(onClick = { chosen = null }) { Text("Cancel") } },
        )
    }
    result?.let {
        AlertDialog(
            onDismissRequest = { result = null },
            text = { Text(it) },
            confirmButton = {
                TextButton(onClick = { val started = it == "Print started"; result = null; if (started) onBack() }) { Text("OK") }
            },
        )
    }
}

/** Past prints, newest first. */
@Composable
fun PrintHistoryScreen(printerName: String, load: suspend () -> List<PastPrint>, onBack: () -> Unit) {
    ListScreen("History of $printerName", "No past prints yet.", load, onBack) { job ->
        Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(job.name, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                val meta = listOfNotNull(job.startedAt?.let(::formatDate), job.durationSeconds?.let(::formatDuration))
                if (meta.isNotEmpty()) Text(meta.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = LocalStudio.current.muted)
            }
            val label = job.note ?: when (job.state) {
                PrinterState.FINISHED -> "Done"
                PrinterState.FAILED -> "Failed"
                PrinterState.PRINTING -> "Printing"
                else -> ""
            }
            val color = when (job.state) {
                PrinterState.FINISHED -> LocalStudio.current.good
                PrinterState.FAILED -> LocalStudio.current.bad
                else -> LocalStudio.current.muted
            }
            if (label.isNotEmpty()) Text(label, style = MaterialTheme.typography.labelMedium, color = color)
        }
    }
}

fun formatSize(bytes: Long): String = when {
    bytes >= 1L shl 20 -> "%.1f MB".format(bytes / 1048576.0)
    bytes >= 1L shl 10 -> "${bytes shr 10} KB"
    else -> "$bytes B"
}

fun formatDate(at: Long): String = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(at))
