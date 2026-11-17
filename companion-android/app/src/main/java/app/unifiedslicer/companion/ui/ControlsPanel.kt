package app.unifiedslicer.companion.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import app.unifiedslicer.companion.core.model.PrinterState
import app.unifiedslicer.companion.core.model.PrinterStatus
import app.unifiedslicer.companion.core.source.Control
import app.unifiedslicer.companion.core.source.PrinterCommand
import app.unifiedslicer.companion.core.source.SpeedLevel
import app.unifiedslicer.companion.ui.theme.LocalStudio
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** Runs one command at a time and keeps the last failure for the screen to show. */
@Stable
class CommandRunner(private val scope: CoroutineScope, private val send: suspend (PrinterCommand) -> String?) {
    var busy by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    fun run(command: PrinterCommand) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try {
                error = send(command)
            } finally {
                busy = false
            }
        }
    }
}

@Composable
fun rememberCommandRunner(key: String, send: suspend (PrinterCommand) -> String?): CommandRunner {
    val scope = rememberCoroutineScope()
    return remember(key) { CommandRunner(scope, send) }
}

/** Pause / Resume / Stop for the running job, and the last command's failure. */
@Composable
fun JobControls(p: PrinterStatus, controls: Set<Control>, accent: Color, commands: CommandRunner) {
    var confirmStop by remember { mutableStateOf(false) }
    val paused = p.state == PrinterState.PAUSED
    val canToggle = if (paused) Control.RESUME in controls else Control.PAUSE in controls && p.state == PrinterState.PRINTING
    val canStop = Control.STOP in controls && p.state.active
    if (canToggle || canStop) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (canToggle) Button(
                onClick = { commands.run(if (paused) PrinterCommand.Resume else PrinterCommand.Pause) },
                enabled = !commands.busy,
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(containerColor = accent, contentColor = Color.White),
            ) { Text(if (paused) "Resume" else "Pause") }
            if (canStop) OutlinedButton(
                onClick = { confirmStop = true },
                enabled = !commands.busy,
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = LocalStudio.current.bad),
            ) { Text("Stop") }
        }
        Spacer(Modifier.height(10.dp))
    }
    commands.error?.let {
        Text(it, Modifier.fillMaxWidth().padding(bottom = 10.dp), style = MaterialTheme.typography.bodySmall, color = LocalStudio.current.bad)
    }
    if (confirmStop) AlertDialog(
        onDismissRequest = { confirmStop = false },
        title = { Text("Stop this print?") },
        text = { Text("A stopped print cannot be resumed.") },
        confirmButton = {
            TextButton(onClick = { confirmStop = false; commands.run(PrinterCommand.Stop) }) { Text("Stop", color = LocalStudio.current.bad) }
        },
        dismissButton = { TextButton(onClick = { confirmStop = false }) { Text("Keep printing") } },
    )
}

/** Chamber light and print speed, for printers that have them. */
@Composable
fun DeviceControls(p: PrinterStatus, controls: Set<Control>, accent: Color, commands: CommandRunner) {
    val online = p.state != PrinterState.OFFLINE
    val light = Control.LIGHT in controls && online
    val speed = Control.SPEED in controls && p.state.active
    if (!light && !speed) return
    Panel(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            if (light) Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Light", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                Switch(
                    checked = p.light == true,
                    onCheckedChange = { commands.run(PrinterCommand.Light(it)) },
                    enabled = !commands.busy,
                    colors = SwitchDefaults.colors(checkedTrackColor = accent),
                )
            }
            if (speed) {
                Text("Speed", Modifier.padding(top = 6.dp), style = MaterialTheme.typography.bodyMedium)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    SpeedLevel.entries.forEach { level ->
                        FilterChip(
                            selected = p.speedLevel == level.level,
                            onClick = { commands.run(PrinterCommand.Speed(level)) },
                            enabled = !commands.busy,
                            label = { Text(level.label, maxLines = 1, style = MaterialTheme.typography.labelMedium) },
                            colors = FilterChipDefaults.filterChipColors(selectedContainerColor = accent, selectedLabelColor = Color.White),
                        )
                    }
                }
            }
        }
    }
    Spacer(Modifier.height(10.dp))
}

/** Asks for a target temperature; "Off" sends 0. */
@Composable
fun TemperatureDialog(title: String, current: Int?, max: Int, onDismiss: () -> Unit, onSet: (Int) -> Unit) {
    var text by remember { mutableStateOf(current?.toString().orEmpty()) }
    val value = text.toIntOrNull()?.takeIf { it in 0..max }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { new -> text = new.filter { it.isDigit() }.take(3) },
                label = { Text("Target in °C (up to $max)") },
                singleLine = true,
                isError = text.isNotEmpty() && value == null,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            )
        },
        confirmButton = { TextButton(onClick = { value?.let(onSet) }, enabled = value != null) { Text("Set") } },
        dismissButton = {
            Row {
                TextButton(onClick = { onSet(0) }) { Text("Heater off") }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}
