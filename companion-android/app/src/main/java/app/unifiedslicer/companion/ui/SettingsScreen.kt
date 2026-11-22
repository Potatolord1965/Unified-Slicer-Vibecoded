package app.unifiedslicer.companion.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.unifiedslicer.companion.data.Settings
import app.unifiedslicer.companion.data.ThemeMode
import app.unifiedslicer.companion.ui.theme.LocalStudio

@Composable
fun SettingsScreen(settings: Settings, version: String, onBackgroundChanged: (Boolean) -> Unit) {
    val theme by settings.theme.collectAsStateWithLifecycle()
    val notifications by settings.notifications.collectAsStateWithLifecycle()
    val background by settings.backgroundChecks.collectAsStateWithLifecycle()
    val refresh by settings.refreshSeconds.collectAsStateWithLifecycle()
    val uriHandler = LocalUriHandler.current
    var showLicenses by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
        Text("Settings", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(top = 8.dp))

        SectionLabel("Appearance")
        Row {
            listOf(ThemeMode.DARK to "Dark", ThemeMode.LIGHT to "Light", ThemeMode.SYSTEM to "System").forEach { (m, l) ->
                FilterChip(selected = theme == m, onClick = { settings.setTheme(m) }, label = { Text(l) })
                Spacer(Modifier.width(8.dp))
            }
        }

        SectionLabel("Live view")
        Text("Refresh every", style = MaterialTheme.typography.bodyMedium)
        Row(Modifier.padding(top = 6.dp)) {
            listOf(5, 10, 30, 60).forEach { s ->
                FilterChip(selected = refresh == s, onClick = { settings.setRefreshSeconds(s) }, label = { Text("${s}s") })
                Spacer(Modifier.width(8.dp))
            }
        }

        SectionLabel("Notifications")
        ToggleRow("Print finished, failed or paused", "Posts a notification when a print changes state.", notifications) { settings.setNotifications(it) }
        ToggleRow(
            "Check while the app is closed",
            "Every 15 minutes (Android's minimum). Turn off to save battery; you then only hear about prints while the app is open.",
            background,
        ) { settings.setBackgroundChecks(it); onBackgroundChanged(it) }

        SectionLabel("About")
        Text("Unified Monitor $version", style = MaterialTheme.typography.bodyMedium)
        Text(
            "Companion to Unified Slicer. Watches Bambu Lab, Elegoo, Creality and Markforged printers plus Klipper, OctoPrint and PrusaLink on your network, and sends sliced files to Elegoo, Creality and network printers.",
            style = MaterialTheme.typography.bodySmall, color = LocalStudio.current.muted,
        )
        Text(
            "Unofficial free software, provided as is, with no warranty. Not affiliated with or endorsed by Bambu Lab, Elegoo, Creality, Markforged or Snapmaker; their names and trademarks belong to their owners. Cloud features are unofficial and used at your own risk. Never leave a printer unattended.",
            style = MaterialTheme.typography.bodySmall, color = LocalStudio.current.muted,
            modifier = Modifier.padding(top = 8.dp),
        )
        Row(Modifier.padding(top = 4.dp)) {
            TextButton(onClick = { uriHandler.openUri(SOURCE_URL) }) { Text("Source code") }
            TextButton(onClick = { uriHandler.openUri(PRIVACY_URL) }) { Text("Privacy") }
            TextButton(onClick = { showLicenses = true }) { Text("Licenses") }
        }
    }

    if (showLicenses) {
        val context = LocalContext.current
        val text = remember { context.assets.open("open_source_licenses.txt").bufferedReader().use { it.readText() } }
        AlertDialog(
            onDismissRequest = { showLicenses = false },
            confirmButton = { TextButton(onClick = { showLicenses = false }) { Text("Close") } },
            title = { Text("Open-source licenses") },
            text = {
                Text(text, style = MaterialTheme.typography.bodySmall, modifier = Modifier.verticalScroll(rememberScrollState()))
            },
        )
    }
}

private const val SOURCE_URL = "https://github.com/Potatolord1965/Unified-Slicer-Vibecoded/tree/main/companion-android"
private const val PRIVACY_URL = "https://github.com/Potatolord1965/Unified-Slicer-Vibecoded/blob/main/PRIVACY.md"

@Composable
private fun ToggleRow(title: String, subtitle: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = LocalStudio.current.muted)
        }
        Spacer(Modifier.width(12.dp))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}
