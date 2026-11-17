package app.unifiedslicer.companion.core.source

import app.unifiedslicer.companion.core.model.Account
import app.unifiedslicer.companion.core.model.BambuAccount
import app.unifiedslicer.companion.core.model.CrealityAccount
import app.unifiedslicer.companion.core.model.ElegooAccount
import app.unifiedslicer.companion.core.model.LanKind
import app.unifiedslicer.companion.core.model.LanPrinter
import app.unifiedslicer.companion.core.model.MarkforgedAccount

/** What a printer can be told to do from the app. */
enum class Control { PAUSE, RESUME, STOP, NOZZLE_TEMP, BED_TEMP, LIGHT, SPEED }

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
}

/** A source whose printers take commands. */
interface Controllable {
    /** Sends [command] to the printer [deviceId]. Throws with a readable message when it is refused. */
    suspend fun control(deviceId: String, command: PrinterCommand)
}

private val JOB = setOf(Control.PAUSE, Control.RESUME, Control.STOP)
private val JOB_AND_TEMPS = JOB + Control.NOZZLE_TEMP + Control.BED_TEMP

/** The controls printers of [account] offer in this app. */
fun controlsFor(account: Account): Set<Control> = when (account) {
    is BambuAccount -> JOB_AND_TEMPS + Control.LIGHT + Control.SPEED
    is ElegooAccount -> JOB_AND_TEMPS
    is CrealityAccount -> JOB_AND_TEMPS + Control.LIGHT
    is MarkforgedAccount -> emptySet()
    is LanPrinter -> when (account.kind) {
        LanKind.BAMBU -> JOB_AND_TEMPS + Control.LIGHT + Control.SPEED
        LanKind.ELEGOO_CC2, LanKind.MOONRAKER, LanKind.OCTOPRINT -> JOB_AND_TEMPS
        LanKind.PRUSALINK -> JOB
    }
}
