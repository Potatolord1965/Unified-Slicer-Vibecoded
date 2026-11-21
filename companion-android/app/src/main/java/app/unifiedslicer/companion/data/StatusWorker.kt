package app.unifiedslicer.companion.data

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import app.unifiedslicer.companion.CompanionApp
import java.util.concurrent.TimeUnit

/** Checks every printer every 15 minutes while the app is closed, so finished prints still notify. */
class StatusWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val app = applicationContext as CompanionApp
        // While the app is open its live view already watches.
        if (app.inForeground || app.accounts.accounts.value.isEmpty()) return Result.success()
        app.printers.checkInBackground(timeoutMs = 20_000)
        return Result.success()
    }

    companion object {
        private const val NAME = "printer-status"

        fun schedule(context: Context, enabled: Boolean) {
            val wm = WorkManager.getInstance(context)
            if (!enabled) {
                wm.cancelUniqueWork(NAME)
                return
            }
            val request = PeriodicWorkRequestBuilder<StatusWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            wm.enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
