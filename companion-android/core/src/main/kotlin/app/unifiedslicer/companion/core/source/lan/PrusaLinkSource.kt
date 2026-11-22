package app.unifiedslicer.companion.core.source.lan

import app.unifiedslicer.companion.core.source.FileBrowsable
import app.unifiedslicer.companion.core.model.PrinterFile
import app.unifiedslicer.companion.core.source.Controllable
import app.unifiedslicer.companion.core.source.PrinterCommand
import app.unifiedslicer.companion.core.camera.CameraCapable
import app.unifiedslicer.companion.core.camera.CameraFeed
import app.unifiedslicer.companion.core.net.jsonBody
import app.unifiedslicer.companion.core.net.int
import app.unifiedslicer.companion.core.model.LanPrinter
import app.unifiedslicer.companion.core.model.PrinterState
import app.unifiedslicer.companion.core.model.PrinterStatus
import app.unifiedslicer.companion.core.model.Temperature
import app.unifiedslicer.companion.core.net.long
import app.unifiedslicer.companion.core.net.num
import app.unifiedslicer.companion.core.net.obj
import app.unifiedslicer.companion.core.net.str
import app.unifiedslicer.companion.core.net.arr
import app.unifiedslicer.companion.core.net.bool
import app.unifiedslicer.companion.core.net.fetchText
import app.unifiedslicer.companion.core.net.fileBody
import app.unifiedslicer.companion.core.net.forUploads
import app.unifiedslicer.companion.core.source.PrintCapable
import app.unifiedslicer.companion.core.source.PrintJob
import app.unifiedslicer.companion.core.source.SendProgress
import app.unifiedslicer.companion.core.source.SourceContext
import kotlinx.serialization.json.JsonElement

/** Prusa printers through PrusaLink's v1 API. */
class PrusaLinkSource(account: LanPrinter, ctx: SourceContext) : HttpPrinterSource(account, ctx), PrintCapable, Controllable, CameraCapable, FileBrowsable {
    override val via = "LAN · PrusaLink"

    override suspend fun read(): PrinterStatus {
        val status = get("/api/v1/status")
        val file = if (status.obj("job") != null) runCatching { get("/api/v1/job").obj("file") }.getOrNull() else null
        return parse(status, file)
    }

    override suspend fun print(deviceId: String, job: PrintJob, progress: SendProgress) {
        progress.update(0, "Uploading to the printer…")
        val size = job.file.length().coerceAtLeast(1)
        val storage = storage()
        val path = "/api/v1/files/$storage/" + java.net.URLEncoder.encode(job.name, "UTF-8").replace("+", "%20")
        val req = request(path)
            .header("Print-After-Upload", "?1")
            .header("Overwrite", "?1")
            .put(fileBody(job.file) { progress.update((it * 100 / size).toInt(), null) })
            .build()
        ctx.http.forUploads().fetchText(req)
        progress.update(100, "Print started")
    }

    override suspend fun control(deviceId: String, command: PrinterCommand) {
        val id = get("/api/v1/status").obj("job").int("id") ?: throw java.io.IOException("The printer has no print job")
        val req = when (command) {
            PrinterCommand.Pause -> request("/api/v1/job/$id/pause").put(jsonBody(""))
            PrinterCommand.Resume -> request("/api/v1/job/$id/resume").put(jsonBody(""))
            PrinterCommand.Stop -> request("/api/v1/job/$id").delete()
            else -> throw java.io.IOException("Not available on PrusaLink from this app")
        }
        ctx.http.fetchText(req.build())
    }

    override suspend fun camera(deviceId: String): CameraFeed =
        CameraFeed.Http(resolve("/api/v1/cameras/snap"), if (account.secret.isBlank()) emptyMap() else mapOf("X-Api-Key" to account.secret.trim()))

    /** The printer's own storage: "usb" on MK4/XL/MINI, "local" on PrusaLink for the MK3. */
    private suspend fun storage(): String = runCatching {
        get("/api/v1/storage").arr("storage_list").orEmpty()
            .firstOrNull { it.bool("available") != false && it.bool("read_only") != true }?.str("path")?.trim('/')
    }.getOrNull() ?: "usb"

    override suspend fun files(deviceId: String): List<PrinterFile> {
        val storage = storage()
        return get("/api/v1/files/$storage").arr("children").orEmpty()
            .filter { it.str("type") == "PRINT_FILE" }
            .mapNotNull { f ->
                val name = f.str("name") ?: return@mapNotNull null
                PrinterFile("$storage/$name", f.str("display_name") ?: name, f.long("size"), f.long("m_timestamp")?.times(1000))
            }.sortedByDescending { it.modifiedAt ?: 0 }
    }

    override suspend fun printFile(deviceId: String, file: PrinterFile) {
        ctx.http.fetchText(request("/api/v1/files/" + encodePath(file.path)).post(jsonBody("")).build())
    }

    fun parse(s: JsonElement, file: JsonElement?): PrinterStatus {
        val p = s.obj("printer")
        val state = when (p.str("state")?.uppercase()) {
            "IDLE", "READY" -> PrinterState.IDLE
            "BUSY" -> PrinterState.PREPARING
            "PRINTING" -> PrinterState.PRINTING
            "PAUSED" -> PrinterState.PAUSED
            "FINISHED" -> PrinterState.FINISHED
            "STOPPED", "ERROR" -> PrinterState.FAILED
            "ATTENTION" -> PrinterState.PAUSED
            else -> PrinterState.UNKNOWN
        }
        val job = s.obj("job")
        val printing = state.active || state == PrinterState.FINISHED
        return status(state).copy(
            stage = "Needs attention".takeIf { p.str("state").equals("ATTENTION", true) },
            progress = job.num("progress")?.toInt()?.takeIf { printing },
            remainingSeconds = job.long("time_remaining")?.takeIf { state.active && it > 0 },
            file = (file.str("display_name") ?: file.str("name"))?.takeIf { printing },
            nozzle = p.num("temp_nozzle")?.let { Temperature(it, p.num("target_nozzle")?.takeIf { t -> t > 0 }) },
            bed = p.num("temp_bed")?.let { Temperature(it, p.num("target_bed")?.takeIf { t -> t > 0 }) },
        )
    }
}
