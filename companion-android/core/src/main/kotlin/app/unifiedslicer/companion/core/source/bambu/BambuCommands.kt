package app.unifiedslicer.companion.core.source.bambu

import app.unifiedslicer.companion.core.source.motionGcode
import app.unifiedslicer.companion.core.net.MqttLink
import app.unifiedslicer.companion.core.net.long
import app.unifiedslicer.companion.core.net.obj
import app.unifiedslicer.companion.core.net.str
import app.unifiedslicer.companion.core.source.PrinterCommand
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Commands on a Bambu printer's MQTT request topic, shared by cloud and LAN mode. Printers answer
 * on the report topic with the same sequence_id; firmware with "authorization control" refuses
 * unsigned commands there unless Developer Mode is on.
 */
class BambuCommands {
    private val nextSeq = AtomicInteger(20000)
    private val pending = ConcurrentHashMap<String, CompletableDeferred<JsonObject>>()

    /** Feed every report message here; completes the matching [send]. */
    fun onReport(message: JsonElement?) {
        for (group in GROUPS) {
            val body = message.obj(group) ?: continue
            body.str("sequence_id")?.let { pending[it]?.complete(body) }
        }
    }

    suspend fun send(link: MqttLink, serial: String, command: PrinterCommand) {
        if (!link.isConnected) throw IOException("Not connected to the printer")
        val seq = nextSeq.incrementAndGet().toString()
        val waiter = CompletableDeferred<JsonObject>()
        pending[seq] = waiter
        try {
            link.publish("device/$serial/request", payload(command, seq).toString())
            // Older firmware does not answer every command; silence counts as sent.
            val reply = withTimeoutOrNull(4_000) { waiter.await() } ?: return
            rejection(reply)?.let { throw IOException(it) }
        } finally {
            pending.remove(seq)
        }
    }

    companion object {
        private val GROUPS = listOf("print", "system")

        fun payload(command: PrinterCommand, seq: String): JsonObject {
            fun print(name: String, param: String) = buildJsonObject {
                putJsonObject("print") { put("sequence_id", seq); put("command", name); put("param", param) }
            }
            return when (command) {
                PrinterCommand.Pause -> print("pause", "")
                PrinterCommand.Resume -> print("resume", "")
                PrinterCommand.Stop -> print("stop", "")
                is PrinterCommand.SetNozzle -> print("gcode_line", "M104 S${command.celsius}\n")
                is PrinterCommand.SetBed -> print("gcode_line", "M140 S${command.celsius}\n")
                is PrinterCommand.Speed -> print("print_speed", command.level.level.toString())
                PrinterCommand.Home, is PrinterCommand.Move -> print("gcode_line", motionGcode(command) + "\n")
                is PrinterCommand.Light -> buildJsonObject {
                    putJsonObject("system") {
                        put("sequence_id", seq); put("command", "ledctrl"); put("led_node", "chamber_light")
                        put("led_mode", if (command.on) "on" else "off")
                        put("led_on_time", 500); put("led_off_time", 500); put("loop_times", 0); put("interval_time", 0)
                    }
                }
            }
        }

        /** Why the printer refused, or null when [reply] reports success. */
        fun rejection(reply: JsonObject): String? {
            val result = reply.str("result")?.lowercase()
            val code = reply.long("err_code") ?: 0L
            if (code == 0L && (result == null || result == "success" || result == "ok")) return null
            val reason = reply.str("reason")?.takeIf { it.isNotBlank() }
            // 84033543 (0x05024007): the command was not signed by a Bambu app.
            return if (code == 84033543L || reason?.contains("verif", ignoreCase = true) == true)
                "The printer only accepts this from Bambu's own apps. Turn on Developer Mode on the printer (LAN only) to allow it."
            else "The printer refused the command" + (reason?.let { ": $it" } ?: if (code != 0L) " (error $code)" else "")
        }
    }
}
