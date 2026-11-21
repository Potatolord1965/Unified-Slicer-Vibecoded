package app.unifiedslicer.companion.data

import app.unifiedslicer.companion.core.HubSnapshot
import app.unifiedslicer.companion.core.PrinterHub
import app.unifiedslicer.companion.core.source.SourceContext
import app.unifiedslicer.companion.core.model.PrinterStatus
import app.unifiedslicer.companion.core.camera.CameraFeed
import app.unifiedslicer.companion.core.model.PastPrint
import app.unifiedslicer.companion.core.model.PrinterFile
import app.unifiedslicer.companion.core.source.PrintJob
import app.unifiedslicer.companion.core.source.PrinterCommand
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.OkHttpClient

/**
 * Live printer status for the UI. The activity drives [refresh] on a timer while it is visible, and
 * the background check uses [checkInBackground], so each account only ever has one client.
 */
class PrinterRepository(
    val http: OkHttpClient,
    private val store: AccountStore,
    private val notifier: TransitionNotifier,
    /** True while a screen is open: connections are only kept open then. */
    private val inForeground: () -> Boolean,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val hub = PrinterHub(SourceContext(http, { store.update(it) }, AgoraRtm))
    private val running = Mutex()

    private val _snapshot = MutableStateFlow<HubSnapshot?>(null)
    val snapshot: StateFlow<HubSnapshot?> = _snapshot.asStateFlow()

    private val _refreshing = MutableStateFlow(false)
    val refreshing: StateFlow<Boolean> = _refreshing.asStateFlow()

    init {
        scope.launch {
            store.accounts.collect {
                hub.setAccounts(it)
                // Started by the background check, the app has no screen to connect for; the
                // activity refreshes as soon as one opens.
                if (inForeground()) refresh()
            }
        }
    }

    /** Refreshes every account; a call while one is running is dropped. */
    suspend fun refresh() {
        if (!running.tryLock()) return
        try {
            _refreshing.value = true
            val snap = hub.refresh()
            _snapshot.value = snap
            notifier.process(snap)
        } finally {
            _refreshing.value = false
            running.unlock()
        }
    }

    /**
     * One check while the app is closed. Uses the live view's hub rather than a second one: two
     * clients renewing one Elegoo session at once would sign it out. The connections are dropped
     * again afterwards, unless a screen opened meanwhile.
     */
    suspend fun checkInBackground(timeoutMs: Long) {
        hub.setAccounts(store.accounts.value)
        running.withLock {
            val snap = hub.refresh(timeoutMs)
            _snapshot.value = snap
            notifier.process(snap)
        }
        if (!inForeground()) hub.disconnect()
    }

    private val _pendingFile = MutableStateFlow<PrintJob?>(null)
    /** A printer-ready file waiting for the user to pick a printer. */
    val pendingFile: StateFlow<PrintJob?> = _pendingFile.asStateFlow()

    private val _send = MutableStateFlow<SendState?>(null)
    /** The send in progress or just finished; null when there is none. */
    val send: StateFlow<SendState?> = _send.asStateFlow()
    private var sendJob: Job? = null

    fun offerFile(job: PrintJob?) {
        _pendingFile.value = job
        if (job != null && _send.value?.running != true) _send.value = null
    }

    /** Sends in the app's scope, so leaving the screen does not abort an upload. */
    fun startSend(printer: PrinterStatus, job: PrintJob) {
        if (_send.value?.running == true) return
        _send.value = SendState(printer.name, job.name, 0, "Starting…")
        sendJob = scope.launch {
            try {
                hub.print(printer.accountId, printer.deviceId, job) { pct, status ->
                    _send.update { s -> s?.copy(percent = pct ?: s.percent, status = status ?: s.status) }
                }
                _send.update { it?.copy(percent = 100, status = "Print started", running = false, done = true) }
                refresh()
            } catch (e: CancellationException) {
                _send.update { it?.copy(running = false, error = "Cancelled") }
            } catch (e: Exception) {
                _send.update { it?.copy(running = false, error = e.message ?: e.javaClass.simpleName) }
            }
        }
    }

    fun cancelSend() { sendJob?.cancel() }

    fun clearSend() { if (_send.value?.running != true) _send.value = null }

    /** Sends [command]; returns why it failed, or null when the printer took it. */
    suspend fun control(printer: PrinterStatus, command: PrinterCommand): String? = withContext(Dispatchers.Default) {
        try {
            hub.control(printer.accountId, printer.deviceId, command)
            scope.launch { delay(1500); refresh() }
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            e.message ?: e.javaClass.simpleName
        }
    }

    /** The camera of [printer], or null when the app cannot show one for it. Throws when it is switched off. */
    suspend fun camera(printer: PrinterStatus): CameraFeed? = hub.camera(printer.accountId, printer.deviceId)

    suspend fun files(printer: PrinterStatus): List<PrinterFile> = withContext(Dispatchers.Default) { hub.files(printer.accountId, printer.deviceId) }

    /** Starts [file] on [printer]; returns why it failed, or null. */
    suspend fun printFile(printer: PrinterStatus, file: PrinterFile): String? = withContext(Dispatchers.Default) {
        try {
            hub.printFile(printer.accountId, printer.deviceId, file)
            scope.launch { delay(1500); refresh() }
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            e.message ?: e.javaClass.simpleName
        }
    }

    suspend fun history(printer: PrinterStatus): List<PastPrint> = withContext(Dispatchers.Default) { hub.history(printer.accountId, printer.deviceId) }

    fun refreshAsync() { scope.launch { refresh() } }

    fun disconnect() { scope.launch { hub.disconnect() } }
}

data class SendState(
    val printer: String,
    val file: String,
    val percent: Int,
    val status: String,
    val running: Boolean = true,
    val done: Boolean = false,
    val error: String? = null,
)
