package app.unifiedslicer.companion.core.source.lan

import app.unifiedslicer.companion.core.source.FileBrowsable
import app.unifiedslicer.companion.core.model.PrinterFile
import app.unifiedslicer.companion.core.net.arr
import app.unifiedslicer.companion.core.source.Controllable
import app.unifiedslicer.companion.core.source.PrinterCommand
import app.unifiedslicer.companion.core.camera.CameraCapable
import app.unifiedslicer.companion.core.camera.CameraFeed
import app.unifiedslicer.companion.core.model.LanPrinter
import app.unifiedslicer.companion.core.model.PrinterState
import app.unifiedslicer.companion.core.model.PrinterStatus
import app.unifiedslicer.companion.core.net.HttpException
import app.unifiedslicer.companion.core.net.bool
import app.unifiedslicer.companion.core.net.long
import app.unifiedslicer.companion.core.net.num
import app.unifiedslicer.companion.core.net.obj
import app.unifiedslicer.companion.core.net.str
import app.unifiedslicer.companion.core.net.fetchText
import app.unifiedslicer.companion.core.net.fileBody
import app.unifiedslicer.companion.core.net.forUploads
import app.unifiedslicer.companion.core.source.PrintCapable
import app.unifiedslicer.companion.core.source.PrintJob
import app.unifiedslicer.companion.core.source.SendProgress
import app.unifiedslicer.companion.core.source.SourceContext
import okhttp3.MultipartBody
import kotlinx.serialization.json.JsonElement

class OctoPrintSource(account: LanPrinter, ctx: SourceContext) : HttpPrinterSource(account, ctx), PrintCapable, Controllable, CameraCapable, FileBrowsable {
    override val via = "LAN · OctoPrint"

    override suspend fun read(): PrinterStatus {
        val printer = try {
            get("/api/printer")
        } catch (e: HttpException) {
            // 409: OctoPrint is running but not connected to the printer.
            if (e.code == 409) return status(PrinterState.OFFLINE).copy(alert = "OctoPrint is not connected to the printer")
            throw e
        }
        return parse(printer, get("/api/job"))
    }

    override suspend fun print(deviceId: String, job: PrintJob, progress: SendProgress) {
        progress.update(0, "Uploading to OctoPrint…")
        val size = job.file.length().coerceAtLeast(1)
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("select", "true")
            .addFormDataPart("print", "true")
            .addFormDataPart("file", job.name, fileBody(job.file) { progress.update((it * 100 / size).toInt(), null) })
            .build()
        ctx.http.forUploads().fetchText(request("/api/files/local").post(body).build())
        progress.update(100, "Print started")
    }

    override suspend fun control(deviceId: String, command: PrinterCommand) = when (command) {
        PrinterCommand.Pause -> post("/api/job", """{"command":"pause","action":"pause"}""")
        PrinterCommand.Resume -> post("/api/job", """{"command":"pause","action":"resume"}""")
        PrinterCommand.Stop -> post("/api/job", """{"command":"cancel"}""")
        is PrinterCommand.SetNozzle -> post("/api/printer/tool", """{"command":"target","targets":{"tool0":${command.celsius}}}""")
        is PrinterCommand.SetBed -> post("/api/printer/bed", """{"command":"target","target":${command.celsius}}""")
        PrinterCommand.Home -> post("/api/printer/printhead", """{"command":"home","axes":["x","y","z"]}""")
        is PrinterCommand.Move -> post("/api/printer/printhead", """{"command":"jog","${command.axis}":${command.mm}}""")
        is PrinterCommand.Light, is PrinterCommand.Speed -> throw java.io.IOException("Not available on OctoPrint from this app")
    }

    override suspend fun camera(deviceId: String): CameraFeed = CameraFeed.Http(resolve("/webcam/?action=snapshot"))

    override suspend fun files(deviceId: String): List<PrinterFile> {
        val out = mutableListOf<PrinterFile>()
        fun walk(list: List<JsonElement>) {
            for (f in list) when (f.str("type")) {
                "folder" -> walk(f.arr("children").orEmpty())
                "machinecode" -> f.str("path")?.let { out += PrinterFile(it, f.str("name") ?: it, f.long("size"), f.long("date")?.times(1000)) }
            }
        }
        walk(get("/api/files/local?recursive=true").arr("files").orEmpty())
        return out.sortedByDescending { it.modifiedAt ?: 0 }
    }

    override suspend fun printFile(deviceId: String, file: PrinterFile) =
        post("/api/files/local/" + encodePath(file.path), """{"command":"select","print":true}""")

    fun parse(printer: JsonElement, job: JsonElement): PrinterStatus {
        val flags = printer.obj("state").obj("flags")
        val state = when {
            flags.bool("error") == true || flags.bool("closedOrError") == true -> PrinterState.FAILED
            flags.bool("paused") == true || flags.bool("pausing") == true -> PrinterState.PAUSED
            flags.bool("printing") == true || flags.bool("cancelling") == true -> PrinterState.PRINTING
            flags.bool("ready") == true || flags.bool("operational") == true -> PrinterState.IDLE
            else -> PrinterState.UNKNOWN
        }
        val progress = job.obj("progress")
        val temps = printer.obj("temperature")
        return status(state).copy(
            progress = progress.num("completion")?.toInt()?.takeIf { state.active },
            remainingSeconds = progress.long("printTimeLeft")?.takeIf { state.active && it > 0 },
            file = job.obj("job").obj("file").str("name")?.takeIf { state.active },
            nozzle = temps.temp("tool0", "actual", "target"),
            bed = temps.temp("bed", "actual", "target"),
            alert = printer.obj("state").str("error"),
        )
    }
}
