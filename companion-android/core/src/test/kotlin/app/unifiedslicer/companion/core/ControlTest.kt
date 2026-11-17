package app.unifiedslicer.companion.core

import app.unifiedslicer.companion.core.camera.bambuAuthPacket
import app.unifiedslicer.companion.core.camera.readJpeg
import app.unifiedslicer.companion.core.model.LanKind
import app.unifiedslicer.companion.core.model.LanPrinter
import app.unifiedslicer.companion.core.model.MarkforgedAccount
import app.unifiedslicer.companion.core.net.int
import app.unifiedslicer.companion.core.net.obj
import app.unifiedslicer.companion.core.net.parseJson
import app.unifiedslicer.companion.core.net.str
import app.unifiedslicer.companion.core.source.Control
import app.unifiedslicer.companion.core.source.PrinterCommand
import app.unifiedslicer.companion.core.source.SpeedLevel
import app.unifiedslicer.companion.core.source.bambu.BambuCommands
import app.unifiedslicer.companion.core.source.bambu.BambuReport
import app.unifiedslicer.companion.core.source.controlsFor
import app.unifiedslicer.companion.core.source.creality.CrealityCloudSource
import app.unifiedslicer.companion.core.source.elegoo.ElegooPrinterChannel
import app.unifiedslicer.companion.core.source.elegoo.elegooRequest
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ControlTest {
    @Test
    fun bambuPayloads() {
        val pause = BambuCommands.payload(PrinterCommand.Pause, "7").obj("print")
        assertEquals("pause", pause.str("command"))
        assertEquals("7", pause.str("sequence_id"))
        assertEquals("M104 S215\n", BambuCommands.payload(PrinterCommand.SetNozzle(215), "1").obj("print").str("param"))
        assertEquals("3", BambuCommands.payload(PrinterCommand.Speed(SpeedLevel.SPORT), "1").obj("print").str("param"))
        val light = BambuCommands.payload(PrinterCommand.Light(false), "1").obj("system")
        assertEquals("ledctrl", light.str("command"))
        assertEquals("off", light.str("led_mode"))
    }

    @Test
    fun bambuRejections() {
        fun reply(json: String) = parseJson(json) as JsonObject
        assertNull(BambuCommands.rejection(reply("""{"command":"pause","result":"success","reason":""}""")))
        assertNull(BambuCommands.rejection(reply("""{"command":"pause"}""")))
        assertTrue(BambuCommands.rejection(reply("""{"command":"gcode_line","result":"failed","err_code":84033543,"reason":"mqtt message verify failed"}"""))!!.contains("Developer Mode"))
        assertTrue(BambuCommands.rejection(reply("""{"command":"stop","result":"fail","reason":"busy"}"""))!!.endsWith("busy"))
    }

    @Test
    fun bambuLightAndSpeed() {
        val report = parseJson("""{"gcode_state":"RUNNING","spd_lvl":2,"lights_report":[{"node":"chamber_light","mode":"on"}]}""") as JsonObject
        val status = BambuReport.toStatus("a", "d", "n", "X1C", "LAN", report, 0)
        assertEquals(true, status.light)
        assertEquals(SpeedLevel.STANDARD, SpeedLevel.of(status.speedLevel))
    }

    @Test
    fun elegooAndCrealityRequests() {
        assertEquals(ElegooPrinterChannel.M_RESUME_PRINT, elegooRequest(PrinterCommand.Resume).first)
        val (method, params) = elegooRequest(PrinterCommand.SetBed(60))
        assertEquals(1028, method)
        assertEquals(60, params.int("heater_bed"))
        assertEquals(0, CrealityCloudSource.controlParams(PrinterCommand.Resume).int("pause"))
        assertEquals(60, CrealityCloudSource.controlParams(PrinterCommand.SetBed(60)).obj("bedTempControl").int("val"))
    }

    @Test
    fun controlsPerPrinterKind() {
        assertTrue(Control.SPEED in controlsFor(LanPrinter("1", "x", LanKind.BAMBU, "10.0.0.2")))
        assertTrue(Control.NOZZLE_TEMP !in controlsFor(LanPrinter("1", "x", LanKind.PRUSALINK, "10.0.0.2")))
        assertTrue(controlsFor(MarkforgedAccount("1", "x", "a", "b")).isEmpty())
    }

    @Test
    fun cameraFraming() {
        val packet = bambuAuthPacket("12345678")
        assertEquals(80, packet.size)
        assertArrayEquals(byteArrayOf(0x40, 0, 0, 0, 0, 0x30, 0, 0), packet.copyOf(8))
        assertEquals("bblp", String(packet, 16, 4))
        assertEquals("12345678", String(packet, 48, 8))

        fun b(vararg v: Int) = v.map { it.toByte() }.toByteArray()
        val stream = (b(1, 2) + b(0xFF, 0xD8, 5, 6, 0xFF, 0xD9) + b(9) + b(0xFF, 0xD8, 7, 0xFF, 0xD9)).inputStream()
        assertArrayEquals(b(0xFF, 0xD8, 5, 6, 0xFF, 0xD9), readJpeg(stream))
        assertArrayEquals(b(0xFF, 0xD8, 7, 0xFF, 0xD9), readJpeg(stream))
        assertNull(readJpeg(stream))
    }
}
