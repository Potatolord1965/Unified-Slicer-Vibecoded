package app.unifiedslicer.companion.core.model

import kotlinx.serialization.Serializable

@Serializable
enum class PrinterState(val label: String, val active: Boolean) {
    OFFLINE("Offline", false),
    IDLE("Idle", false),
    PREPARING("Preparing", true),
    PRINTING("Printing", true),
    PAUSED("Paused", true),
    FINISHED("Finished", false),
    FAILED("Failed", false),
    UNKNOWN("Unknown", false),
}

data class Temperature(val current: Double, val target: Double? = null)

/** One printer's last known state, as shown in the app. */
data class PrinterStatus(
    val accountId: String,
    val deviceId: String,
    val name: String,
    val model: String = "",
    val brand: Brand,
    /** Where the data comes from, e.g. "Bambu Cloud" or "LAN". */
    val via: String,
    val state: PrinterState,
    /** Finer stage reported by the printer, e.g. "Heating bed". */
    val stage: String? = null,
    val progress: Int? = null,
    val remainingSeconds: Long? = null,
    val layer: Int? = null,
    val totalLayers: Int? = null,
    val file: String? = null,
    val nozzle: Temperature? = null,
    val bed: Temperature? = null,
    val chamber: Temperature? = null,
    /** Printer-side alert, e.g. an error code. */
    val alert: String? = null,
    /** Chamber light, where the printer reports it. */
    val light: Boolean? = null,
    /** Bambu speed level 1..4. */
    val speedLevel: Int? = null,
    /** Loaded filament: AMS / Canvas slots and the external spool, where the printer reports them. */
    val filament: List<FilamentSlot> = emptyList(),
    val updatedAt: Long = System.currentTimeMillis(),
) {
    val key: String get() = "$accountId/$deviceId"
}

/**
 * One filament slot. [label] is what the maker's app shows ("A1", "Ext"), [color] is "#RRGGBB"
 * or null when unknown, [remainPercent] is null when the printer does not measure it.
 */
data class FilamentSlot(
    val label: String,
    val type: String,
    val color: String? = null,
    val remainPercent: Int? = null,
    val active: Boolean = false,
    /** Empty slot: no spool loaded. */
    val empty: Boolean = false,
)

/** A file stored on the printer (or its host), which can be printed again. */
data class PrinterFile(
    /** What the printer needs to print it, e.g. "folder/part.gcode". */
    val path: String,
    val name: String = path.substringAfterLast('/'),
    val sizeBytes: Long? = null,
    /** Epoch milliseconds. */
    val modifiedAt: Long? = null,
)

/** One finished, failed or cancelled print from the printer's history. */
data class PastPrint(
    val name: String,
    val state: PrinterState,
    /** Epoch milliseconds. */
    val startedAt: Long? = null,
    val durationSeconds: Long? = null,
    /** Shown instead of the state when the service has its own word for it. */
    val note: String? = null,
)
