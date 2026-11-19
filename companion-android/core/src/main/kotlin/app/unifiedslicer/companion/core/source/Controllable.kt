package app.unifiedslicer.companion.core.source

import app.unifiedslicer.companion.core.model.Account
import app.unifiedslicer.companion.core.model.BambuAccount
import app.unifiedslicer.companion.core.model.CrealityAccount
import app.unifiedslicer.companion.core.model.ElegooAccount
import app.unifiedslicer.companion.core.model.LanKind
import app.unifiedslicer.companion.core.model.LanPrinter
import app.unifiedslicer.companion.core.model.MarkforgedAccount

/** What a printer can be told to do from the app. */
enum class Control { PAUSE, RESUME, STOP, NOZZLE_TEMP, BED_TEMP, LIGHT, SPEED, MOVE }

/** Bambu's print speed levels; [level] is the value the printer reports and accepts. */
enum class SpeedLevel(val level: Int, val label: String) {
    SILENT(1, "Silent"), STANDARD(2, "Standard"), SPORT(3, "Sport"), LUDICROUS(4, "Ludicrous");

    companion object {
        fun of(level: Int?) = entries.firstOrNull { it.level == level }
    }
}

sealed interface PrinterCommand {
    val control: Control

    data object Pause : PrinterCommand { override val control get() = Control.PAUSE }
    data object Resume : PrinterCommand { override val control get() = Control.RESUME }
    data object Stop : PrinterCommand { override val control get() = Control.STOP }
    /** 0 turns the heater off. */
    data class SetNozzle(val celsius: Int) : PrinterCommand { override val control get() = Control.NOZZLE_TEMP }
    data class SetBed(val celsius: Int) : PrinterCommand { override val control get() = Control.BED_TEMP }
    data class Light(val on: Boolean) : PrinterCommand { override val control get() = Control.LIGHT }
    data class Speed(val level: SpeedLevel) : PrinterCommand { override val control get() = Control.SPEED }
    /** Homes all axes. */
    data object Home : PrinterCommand { override val control get() = Control.MOVE }
    /** Moves one axis ('x', 'y' or 'z') by [mm], relative to where it is. */
    data class Move(val axis: Char, val mm: Double) : PrinterCommand {
        init { require(axis in "xyz") { "axis must be x, y or z" } }
        override val control get() = Control.MOVE
    }
}

/** A source whose printers take commands. */
interface Controllable {
    /** Sends [command] to the printer [deviceId]. Throws with a readable message when it is refused. */
    suspend fun control(deviceId: String, command: PrinterCommand)
}

private val JOB = setOf(Control.PAUSE, Control.RESUME, Control.STOP)
private val JOB_AND_TEMPS = JOB + Control.NOZZLE_TEMP + Control.BED_TEMP
private val FULL = JOB_AND_TEMPS + Control.MOVE

/** The controls printers of [account] offer in this app. */
fun controlsFor(account: Account): Set<Control> = when (account) {
    is BambuAccount -> FULL + Control.LIGHT + Control.SPEED
    is ElegooAccount -> FULL
    is CrealityAccount -> FULL + Control.LIGHT
    is MarkforgedAccount -> emptySet()
    is LanPrinter -> when (account.kind) {
        LanKind.BAMBU -> FULL + Control.LIGHT + Control.SPEED
        LanKind.ELEGOO_CC2, LanKind.MOONRAKER, LanKind.OCTOPRINT -> FULL
        LanKind.PRUSALINK -> JOB
    }
}

/** G-code for a move or home, for printers that take raw G-code. Null for other commands. */
fun motionGcode(command: PrinterCommand): String? = when (command) {
    PrinterCommand.Home -> "G28"
    // Relative move at a modest feed rate, then back to absolute; Z moves slower.
    is PrinterCommand.Move -> {
        val feed = if (command.axis == 'z') 600 else 3000
        "G91\nG1 ${command.axis.uppercaseChar()}${fmt(command.mm)} F$feed\nG90"
    }
    else -> null
}

private fun fmt(mm: Double) = if (mm == mm.toLong().toDouble()) mm.toLong().toString() else mm.toString()

/** A source whose printers keep files that can be listed and printed again. */
interface FileBrowsable {
    suspend fun files(deviceId: String): List<app.unifiedslicer.companion.core.model.PrinterFile>
    /** Starts printing [file], already on the printer. */
    suspend fun printFile(deviceId: String, file: app.unifiedslicer.companion.core.model.PrinterFile)
}

/** A source that keeps a history of past prints. */
interface HistoryCapable {
    /** Newest first. */
    suspend fun history(deviceId: String): List<app.unifiedslicer.companion.core.model.PastPrint>
}

/** Whether printers of [account] can list their stored files in this app. */
fun canBrowseFiles(account: Account): Boolean =
    account is LanPrinter && account.kind in setOf(LanKind.MOONRAKER, LanKind.OCTOPRINT, LanKind.PRUSALINK)

/** Whether this app can read [account]'s print history. */
fun hasHistory(account: Account): Boolean =
    account is BambuAccount || account is LanPrinter && account.kind == LanKind.MOONRAKER
