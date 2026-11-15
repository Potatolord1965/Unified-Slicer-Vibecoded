package app.unifiedslicer.companion.core.source.bambu

import app.unifiedslicer.companion.core.source.Controllable
import app.unifiedslicer.companion.core.source.PrinterCommand
import app.unifiedslicer.companion.core.camera.CameraCapable
import app.unifiedslicer.companion.core.camera.CameraFeed
import app.unifiedslicer.companion.core.net.str
import app.unifiedslicer.companion.core.model.Brand
import app.unifiedslicer.companion.core.model.LanPrinter
import app.unifiedslicer.companion.core.model.PrinterState
import app.unifiedslicer.companion.core.model.PrinterStatus
import app.unifiedslicer.companion.core.net.MqttLink
import app.unifiedslicer.companion.core.net.bareHost
import app.unifiedslicer.companion.core.net.mergeJson
import app.unifiedslicer.companion.core.net.obj
import app.unifiedslicer.companion.core.net.parseJson
import app.unifiedslicer.companion.core.source.PrinterSource
import app.unifiedslicer.companion.core.source.awaitCondition
import kotlinx.serialization.json.JsonObject

/**
 * A Bambu printer in LAN mode: MQTT over TLS on port 8883, user "bblp", password = the access
 * code from the printer's screen. The printer's certificate is self-signed, so it is not verified.
 */
class BambuLanSource(override val account: LanPrinter) : PrinterSource, Controllable, CameraCapable {
    private val serial = account.serial.trim()
    @Volatile private var report: JsonObject? = null
    @Volatile private var reportAt = 0L
    private val commands = BambuCommands()

    private val link = MqttLink(
        uri = "ssl://${bareHost(account.host)}:8883",
        username = "bblp",
        password = account.secret,
        topics = listOf("device/$serial/report"),
        insecureTls = true,
        onConnected = { it.publish("device/$serial/request", PUSH_ALL) },
    ) { _, payload ->
        val message = parseJson(payload)
        commands.onReport(message)
        message.obj("print")?.takeIf { it.str("command") != "gcode_line" }?.let { p ->
            report = report?.let { mergeJson(it, p) } ?: p
            reportAt = System.currentTimeMillis()
        }
    }

    override suspend fun refresh(): List<PrinterStatus> {
        try {
            if (!link.isConnected) {
                link.ensureConnected()
                awaitCondition(6_000) { report != null }
            }
        } catch (e: app.unifiedslicer.companion.core.net.AuthException) {
            throw e
        } catch (e: java.io.IOException) {
            return listOf(PrinterStatus(account.id, serial, account.label, "", Brand.BAMBU, VIA, PrinterState.OFFLINE))
        }
        val r = report ?: return listOf(PrinterStatus(account.id, serial, account.label, "", Brand.BAMBU, VIA, PrinterState.UNKNOWN))
        return listOf(BambuReport.toStatus(account.id, serial, account.label, "", VIA, r, reportAt))
    }

    override suspend fun control(deviceId: String, command: PrinterCommand) {
        link.ensureConnected()
        commands.send(link, serial, command)
    }

    /** X1 printers report an RTSP address (or "disable"); the others stream JPEG on port 6000. */
    override suspend fun camera(deviceId: String): CameraFeed {
        val host = bareHost(account.host)
        val rtsp = report.obj("ipcam").str("rtsp_url")
        return when {
            rtsp == null -> CameraFeed.BambuJpeg(host, account.secret)
            rtsp.startsWith("rtsp") -> CameraFeed.BambuRtsp(
                "rtsp://bblp:" + java.net.URLEncoder.encode(account.secret, "UTF-8") + "@$host:322/streaming/live/1"
            )
            else -> throw java.io.IOException("Turn on LAN Only Liveview on the printer's screen to watch the camera")
        }
    }

    override fun close() = link.close()

    private companion object {
        const val VIA = "LAN"
        const val PUSH_ALL = """{"pushing":{"sequence_id":"0","command":"pushall","version":1,"push_target":1}}"""
    }
}
