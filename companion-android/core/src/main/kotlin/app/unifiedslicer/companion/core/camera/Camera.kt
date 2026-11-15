package app.unifiedslicer.companion.core.camera

import app.unifiedslicer.companion.core.model.Account
import app.unifiedslicer.companion.core.model.LanKind
import app.unifiedslicer.companion.core.model.LanPrinter
import app.unifiedslicer.companion.core.net.insecureSocketFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.job
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.TimeUnit

/** Where a printer's camera picture comes from. Only printers reachable on the local network have one. */
sealed interface CameraFeed {
    /** A snapshot URL (polled) or an MJPEG stream. */
    data class Http(val url: String, val headers: Map<String, String> = emptyMap()) : CameraFeed

    /** Bambu A1 / P1 series: JPEG frames over TLS on port 6000. */
    data class BambuJpeg(val host: String, val accessCode: String) : CameraFeed

    /** Bambu X1 series: RTSP over TLS (H.264); [url] carries the credentials. Played by the app. */
    data class BambuRtsp(val url: String) : CameraFeed
}

/** A source whose printers have a camera this app can show. */
interface CameraCapable {
    /** The feed of [deviceId]; throws with a readable message when the camera is off or missing. */
    suspend fun camera(deviceId: String): CameraFeed
}

/** Whether printers of [account] have a camera this app can show. Cloud video uses the makers' own closed services. */
fun hasCamera(account: Account): Boolean =
    account is LanPrinter && account.kind in setOf(LanKind.BAMBU, LanKind.MOONRAKER, LanKind.OCTOPRINT, LanKind.PRUSALINK)

/** Pictures (JPEG or PNG bytes) from [feed], until the collector stops. Throws when the camera cannot be reached. */
fun frames(http: OkHttpClient, feed: CameraFeed): Flow<ByteArray> = when (feed) {
    is CameraFeed.Http -> httpFrames(http, feed)
    is CameraFeed.BambuJpeg -> bambuFrames(feed)
    is CameraFeed.BambuRtsp -> throw IllegalArgumentException("RTSP feeds are played as video")
}

private fun httpFrames(http: OkHttpClient, feed: CameraFeed.Http): Flow<ByteArray> = flow {
    // A stream stays open for as long as it is watched.
    val client = http.newBuilder().readTimeout(20, TimeUnit.SECONDS).callTimeout(0, TimeUnit.SECONDS).build()
    val request = Request.Builder().url(feed.url).apply { feed.headers.forEach { (k, v) -> header(k, v) } }.build()
    while (true) {
        val call = client.newCall(request)
        val watcher = currentCoroutineContext().job.invokeOnCompletion { call.cancel() }
        try {
            call.execute().use { reply ->
                if (!reply.isSuccessful) throw IOException("The camera answered HTTP ${reply.code}")
                val body = reply.body ?: throw IOException("The camera sent no picture")
                if (reply.header("Content-Type").orEmpty().startsWith("multipart", ignoreCase = true)) {
                    val input = body.byteStream().buffered(64 * 1024)
                    while (true) emit(readJpeg(input) ?: break)
                } else {
                    emit(body.bytes())
                }
            }
        } finally {
            watcher.dispose()
        }
        delay(1000)
    }
}.flowOn(Dispatchers.IO)

/** The next JPEG (FF D8 … FF D9) in [input], or null at the end of the stream. */
fun readJpeg(input: InputStream, maxBytes: Int = 8 shl 20): ByteArray? {
    val stream = input
    var prev = -1
    while (true) { // find the start marker
        val b = stream.read()
        if (b < 0) return null
        if (prev == 0xFF && b == 0xD8) break
        prev = b
    }
    val out = ByteArrayOutputStream(64 * 1024)
    out.write(0xFF); out.write(0xD8)
    prev = -1
    while (out.size() < maxBytes) {
        val b = stream.read()
        if (b < 0) return null
        out.write(b)
        if (prev == 0xFF && b == 0xD9) return out.toByteArray()
        prev = b
    }
    throw IOException("The camera sent an oversized picture")
}

private fun bambuFrames(feed: CameraFeed.BambuJpeg): Flow<ByteArray> = flow {
    val plain = Socket()
    val watcher = currentCoroutineContext().job.invokeOnCompletion { runCatching { plain.close() } }
    try {
        plain.connect(InetSocketAddress(feed.host, 6000), 8000)
        plain.soTimeout = 20_000
        insecureSocketFactory().createSocket(plain, feed.host, 6000, true).use { socket ->
            socket.getOutputStream().apply { write(bambuAuthPacket(feed.accessCode)); flush() }
            val input = DataInputStream(socket.getInputStream().buffered(64 * 1024))
            val header = ByteArray(16)
            while (true) {
                input.readFully(header)
                val size = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN).int
                if (size <= 0 || size > (8 shl 20)) throw IOException("The printer rejected the camera connection. Check the access code.")
                emit(ByteArray(size).also { input.readFully(it) })
            }
        }
    } catch (e: java.io.EOFException) {
        throw IOException("The printer closed the camera connection. Check the access code.", e)
    } finally {
        watcher.dispose()
        runCatching { plain.close() }
    }
}.flowOn(Dispatchers.IO)

/** 80 bytes: 0x40, 0x3000, 0, 0 (little endian), then user "bblp" and the access code, each padded to 32 bytes. */
fun bambuAuthPacket(accessCode: String): ByteArray {
    val buf = ByteBuffer.allocate(80).order(ByteOrder.LITTLE_ENDIAN)
    buf.putInt(0x40).putInt(0x3000).putInt(0).putInt(0)
    buf.put("bblp".toByteArray(Charsets.US_ASCII).copyOf(32))
    buf.put(accessCode.toByteArray(Charsets.US_ASCII).copyOf(32))
    return buf.array()
}
