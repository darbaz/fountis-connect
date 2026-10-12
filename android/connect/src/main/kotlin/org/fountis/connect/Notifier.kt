package org.fountis.connect

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/** Periodic background check (WorkManager). Android's minimum period is 15 minutes; the SDK asks for the server's interval, 4 h by default. */
internal class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        try {
            Core.checkAndNotify()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (t: Throwable) {
            logd("background check failed: $t")
        }
        return Result.success()
    }
}

internal object Notifier {
    const val WORK_NAME = "org.fountis.connect.refresh"
    const val CHANNEL_ID = "org.fountis.connect.studies"
    const val CHANNEL_NAME = "FOUNTIS studies"
    const val NOTIFICATION_ID = 0x464F
    /** Intent extra on the notification's launch intent: the offer id. */
    const val EXTRA_OFFER = "fountis"

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        try {
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT))
            }
        } catch (t: Throwable) {
            logd("channel not created: $t")
        }
    }

    fun schedule(context: Context, minutes: Int?) {
        try {
            val interval = maxOf(minutes ?: 240, 15).toLong()
            val req = PeriodicWorkRequestBuilder<RefreshWorker>(interval, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, req)
        } catch (t: Throwable) {
            logd("could not schedule refresh: $t")
        }
    }

    fun permissionGranted(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return false
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    fun cancel(context: Context) {
        try {
            NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
        } catch (_: Throwable) {
        }
    }

    /** Posts the one local notification. Tapping it opens the host app with the offer id as an intent extra. */
    @SuppressLint("MissingPermission")
    fun post(context: Context, title: String, body: String, offerId: String): Boolean {
        return try {
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                putExtra(EXTRA_OFFER, offerId)
            }
            val pi = launch?.let {
                PendingIntent.getActivity(context, offerId.hashCode(), it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            }
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.fountis_ic_notification)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .setContentIntent(pi)
                .build()
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, n)
            true
        } catch (t: Throwable) {
            logd("notification failed: $t")
            false
        }
    }
}
