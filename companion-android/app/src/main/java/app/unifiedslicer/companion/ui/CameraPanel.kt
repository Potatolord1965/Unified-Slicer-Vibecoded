package app.unifiedslicer.companion.ui

import android.graphics.BitmapFactory
import androidx.annotation.OptIn
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.rtsp.RtspMediaSource
import androidx.media3.ui.PlayerView
import app.unifiedslicer.companion.core.camera.CameraFeed
import app.unifiedslicer.companion.core.camera.frames
import app.unifiedslicer.companion.core.model.PrinterStatus
import app.unifiedslicer.companion.core.net.bambuPrinterSocketFactory
import app.unifiedslicer.companion.data.PrinterRepository
import app.unifiedslicer.companion.ui.theme.LocalStudio
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** The printer's camera. It connects only after a tap, so opening a printer costs no data. */
@Composable
fun CameraPanel(repo: PrinterRepository, p: PrinterStatus, accent: Color) {
    var watching by rememberSaveable(p.key) { mutableStateOf(false) }
    var attempt by remember { mutableIntStateOf(0) }
    var feed by remember(p.key) { mutableStateOf<CameraFeed?>(null) }
    var error by remember(p.key) { mutableStateOf<String?>(null) }

    LaunchedEffect(p.key, watching, attempt) {
        if (!watching) return@LaunchedEffect
        error = null
        feed = null
        try {
            feed = repo.camera(p) ?: throw java.io.IOException("This printer has no camera the app can show")
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message ?: e.javaClass.simpleName
        }
    }

    Panel(Modifier.fillMaxWidth()) {
        if (!watching) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Videocam, null, Modifier.size(20.dp), tint = LocalStudio.current.muted)
                Text("Camera", Modifier.weight(1f).padding(start = 10.dp), style = MaterialTheme.typography.bodyMedium)
                TextButton(onClick = { watching = true }) { Text("Watch", color = accent) }
            }
            return@Panel
        }
        Column {
            Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).background(Color.Black), contentAlignment = Alignment.Center) {
                val current = feed
                when {
                    error != null -> Text(
                        error.orEmpty(), Modifier.padding(16.dp),
                        style = MaterialTheme.typography.bodySmall, color = Color.White,
                    )
                    current == null -> CircularProgressIndicator(Modifier.size(28.dp), color = accent, strokeWidth = 3.dp)
                    current is CameraFeed.BambuRtsp -> RtspView(current.url, current.serial) { error = it }
                    else -> FrameView(repo, current, accent) { error = it }
                }
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (error != null) TextButton(onClick = { attempt++ }) { Text("Retry", color = accent) }
                Box(Modifier.weight(1f))
                TextButton(onClick = { watching = false }) { Text("Close") }
            }
        }
    }
}

/** Shows JPEG frames as they arrive. */
@Composable
private fun FrameView(repo: PrinterRepository, feed: CameraFeed, accent: Color, onError: (String) -> Unit) {
    var picture by remember(feed) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(feed) {
        try {
            frames(repo.http, feed).collect { bytes ->
                val bitmap = withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }
                if (bitmap != null) picture = bitmap.asImageBitmap()
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            onError("Could not reach the camera: " + (e.message ?: e.javaClass.simpleName))
        }
    }
    val shown = picture
    if (shown == null) CircularProgressIndicator(Modifier.size(28.dp), color = accent, strokeWidth = 3.dp)
    else Image(shown, "Printer camera", Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
}

/** Bambu X1 live view: RTSP over TLS with the printer's own certificate, on the local network only. */
@OptIn(UnstableApi::class)
@Composable
private fun RtspView(url: String, serial: String, onError: (String) -> Unit) {
    val context = LocalContext.current
    val player = remember(url) {
        ExoPlayer.Builder(context).build().apply {
            setMediaSource(
                RtspMediaSource.Factory()
                    .setForceUseRtpTcp(true)
                    .setSocketFactory(bambuPrinterSocketFactory(serial))
                    .createMediaSource(MediaItem.fromUri(url))
            )
            volume = 0f
            playWhenReady = true
            prepare()
        }
    }
    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlayerError(e: PlaybackException) {
                onError("Could not play the camera: " + (e.cause?.message ?: e.message ?: e.errorCodeName))
            }
        }
        player.addListener(listener)
        onDispose {
            player.removeListener(listener)
            player.release()
        }
    }
    AndroidView(
        factory = { PlayerView(it).apply { useController = false; this.player = player } },
        modifier = Modifier.fillMaxSize(),
    )
}
