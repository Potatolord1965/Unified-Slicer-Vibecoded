package app.unifiedslicer.companion.ui.add

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import app.unifiedslicer.companion.core.handoff.HandedOver
import app.unifiedslicer.companion.core.handoff.SignInCode
import app.unifiedslicer.companion.core.handoff.SignInHandoff
import app.unifiedslicer.companion.core.handoff.sameLogin
import app.unifiedslicer.companion.core.model.Account
import app.unifiedslicer.companion.ui.Panel
import app.unifiedslicer.companion.ui.theme.LocalStudio
import app.unifiedslicer.companion.ui.theme.color
import okhttp3.OkHttpClient

/**
 * Signs in with the accounts Unified Slicer on a computer hands over (Accounts > Sign in on phone).
 * [codeText] is the scanned QR code. Nothing is saved until the person confirms the list.
 */
@Composable
fun ComputerSignInScreen(
    codeText: String,
    http: OkHttpClient,
    saved: List<Account>,
    onBack: () -> Unit,
    onScanAgain: () -> Unit,
    onImport: (List<Account>) -> Unit,
) {
    var result by remember { mutableStateOf<HandedOver?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(codeText) {
        val code = SignInCode.parse(codeText)
        if (code == null) {
            error = "That isn't a Unified Slicer sign-in code. On the computer, open Accounts and click Sign in on phone."
            return@LaunchedEffect
        }
        try {
            result = SignInHandoff(http).fetch(code)
        } catch (e: Exception) {
            error = e.message ?: "Couldn't sign in from the computer."
        }
    }

    FormScaffold("Sign in from computer", onBack) {
        val r = result
        when {
            error != null -> {
                ErrorText(error)
                OutlinedButton(onClick = onScanAgain, modifier = Modifier.fillMaxWidth()) { Text("Scan again") }
            }
            r == null -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(12.dp))
                Hint("Getting your sign-ins from the computer…")
            }
            r.accounts.isEmpty() -> {
                Hint("${r.computer} isn't signed in to any printer service this app supports.")
                OutlinedButton(onClick = onBack, modifier = Modifier.fillMaxWidth()) { Text("Close") }
            }
            else -> {
                Hint("From ${r.computer}. They're stored encrypted on this phone only.")
                r.accounts.forEach { a ->
                    val replaces = saved.any { it.sameLogin(a) }
                    Panel(Modifier.fillMaxWidth()) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(10.dp).clip(CircleShape).background(a.brand.color()))
                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f)) {
                                Text(a.label, style = MaterialTheme.typography.bodyLarge)
                                Text(
                                    a.kindLabel + if (replaces) " · replaces the saved sign-in" else "",
                                    style = MaterialTheme.typography.bodySmall, color = LocalStudio.current.muted,
                                )
                            }
                        }
                    }
                }
                val n = r.accounts.size
                PrimaryButton(if (n == 1) "Sign in to 1 account" else "Sign in to $n accounts", busy = false) { onImport(r.accounts) }
            }
        }
    }
}
