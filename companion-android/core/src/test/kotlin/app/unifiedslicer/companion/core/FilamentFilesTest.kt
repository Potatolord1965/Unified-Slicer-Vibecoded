package app.unifiedslicer.companion.core

import app.unifiedslicer.companion.core.model.LanKind
import app.unifiedslicer.companion.core.model.LanPrinter
import app.unifiedslicer.companion.core.model.PrinterState
import app.unifiedslicer.companion.core.net.defaultHttpClient
import app.unifiedslicer.companion.core.net.int
import app.unifiedslicer.companion.core.net.parseJson
import app.unifiedslicer.companion.core.net.str
import app.unifiedslicer.companion.core.source.PrinterCommand
import app.unifiedslicer.companion.core.source.SourceContext
import app.unifiedslicer.companion.core.source.bambu.BambuCloudSource
import app.unifiedslicer.companion.core.source.bambu.BambuCommands
import app.unifiedslicer.companion.core.source.bambu.BambuReport
import app.unifiedslicer.companion.core.source.elegoo.ElegooStatus
import app.unifiedslicer.companion.core.source.elegoo.elegooRequest
import app.unifiedslicer.companion.core.source.lan.MoonrakerSource
import app.unifiedslicer.companion.core.source.motionGcode
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FilamentFilesTest {
    private fun obj(json: String) = parseJson(json) as JsonObject

    @Test
    fun bambuAmsAndExternalSpool() {
        val print = obj(
            """{"ams":{"tray_now":"1","ams":[{"id":"0","tray":[
                {"id":"0","tray_type":"PLA","tray_color":"FF0000FF","remain":80},
                {"id":"1","tray_type":"PETG","tray_color":"00FF00FF","remain":-1},
                {"id":"2"}]}]},
               "vt_tray":{"id":"254","tray_type":"TPU","tray_color":"000000FF"}}"""
        )
        val slots = BambuReport.filament(print)
        assertEquals(listOf("A1", "A2", "A3", "Ext"), slots.map { it.label })
        assertEquals("#FF0000", slots[0].color)
        assertEquals(80, slots[0].remainPercent)
        assertNull(slots[1].remainPercent)
        assertTrue(slots[1].active)
        assertTrue(slots[2].empty)
        assertFalse(slots[3].active)
        assertNull(BambuReport.bambuColor("FFFFFF00"))
    }

    @Test
    fun elegooCanvas() {
        val ci = obj(
            """{"active_canvas_id":0,"active_tray_id":2,"canvas_list":[{"canvas_id":0,"connected":1,"tray_list":[
                {"tray_id":0,"filament_type":"PLA","filament_color":"#ffffff"},
                {"tray_id":2,"filament_type":"PETG","filament_color":"112233"}]}]}"""
        )
        val slots = ElegooStatus.canvas(ci)
        assertEquals(listOf("1", "3"), slots.map { it.label })
        assertEquals("#FFFFFF", slots[0].color)
        assertEquals("#112233", slots[1].color)
        assertTrue(slots[1].active)
    }

    @Test
    fun motion() {
        assertEquals("G28", motionGcode(PrinterCommand.Home))
        assertEquals("G91\nG1 Z-0.1 F600\nG90", motionGcode(PrinterCommand.Move('z', -0.1)))
        assertEquals("G91\nG1 X10 F3000\nG90", motionGcode(PrinterCommand.Move('x', 10.0)))
        val (method, params) = elegooRequest(PrinterCommand.Move('y', 1.0))
        assertEquals(1027, method)
        assertEquals("y", params.str("axes"))
        assertEquals(1, params.int("distance"))
        assertEquals("gcode_line", BambuCommands.payload(PrinterCommand.Home, "1")["print"].let { (it as JsonObject).str("command") })
    }

    @Test
    fun moonrakerHistory() {
        val src = MoonrakerSource(LanPrinter("1", "k", LanKind.MOONRAKER, "10.0.0.5"), SourceContext(defaultHttpClient()))
        val jobs = src.parseHistory(parseJson(
            """{"result":{"jobs":[{"filename":"a/b.gcode","status":"completed","start_time":1700000000.5,"print_duration":3600.2},
                {"filename":"c.gcode","status":"cancelled","start_time":1700000100}]}}"""
        )!!)
        assertEquals("b.gcode", jobs[0].name)
        assertEquals(PrinterState.FINISHED, jobs[0].state)
        assertEquals(1700000000500L, jobs[0].startedAt)
        assertEquals(3600L, jobs[0].durationSeconds)
        assertEquals("Cancelled", jobs[1].note)
    }

    @Test
    fun bambuTasks() {
        val list = BambuCloudSource.parseTasks(parseJson(
            """{"hits":[{"title":"Benchy","status":2,"startTime":"2026-11-01T10:00:00Z","costTime":1800,"deviceId":"S1"},
                {"title":"Other printer","status":2,"deviceId":"S2"}]}"""
        )!!, "S1")
        assertEquals(1, list.size)
        assertEquals(PrinterState.FINISHED, list[0].state)
        assertEquals(1800L, list[0].durationSeconds)
        assertEquals(java.time.Instant.parse("2026-11-01T10:00:00Z").toEpochMilli(), list[0].startedAt)
    }
}
