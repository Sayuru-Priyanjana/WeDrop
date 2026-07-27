package com.example.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/** Central place for WeDrop's own notifications and their channels. */
object NotificationHelper {

    const val SERVICE_CHANNEL = "wedrop_service"
    const val MIRROR_CHANNEL = "wedrop_mirror"
    const val SERVICE_NOTIFICATION_ID = 1001

    private var channelsReady = false

    fun ensureChannels(context: Context) {
        if (channelsReady) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(NotificationManager::class.java)

            // The ongoing service channel is intentionally silent and low
            // importance: it is a status indicator, not something to interrupt.
            val service = NotificationChannel(
                SERVICE_CHANNEL,
                "WeDrop running",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shows while WeDrop is keeping your devices in sync"
                setShowBadge(false)
            }

            // Mirrored notifications from other devices deserve to be seen.
            val mirror = NotificationChannel(
                MIRROR_CHANNEL,
                "Mirrored notifications",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Notifications forwarded from your other devices"
            }

            manager.createNotificationChannel(service)
            manager.createNotificationChannel(mirror)
        }
        channelsReady = true
    }

    /** Builds the persistent notification the foreground service must show. */
    fun buildServiceNotification(context: Context, status: String): Notification {
        ensureChannels(context)

        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pending = launch?.let {
            PendingIntent.getActivity(
                context, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        return NotificationCompat.Builder(context, SERVICE_CHANNEL)
            .setContentTitle("WeDrop")
            .setContentText(status)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setContentIntent(pending)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    /** Shows a notification mirrored from another device. */
    fun showMirrored(context: Context, title: String, body: String, tag: String) {
        if (!canPostNotifications(context)) return
        ensureChannels(context)

        val notification = NotificationCompat.Builder(context, MIRROR_CHANNEL)
            .setContentTitle(title.ifEmpty { "WeDrop" })
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        // A stable id per tag lets an update replace the earlier copy instead of
        // stacking duplicates as a chat thread grows.
        val id = if (tag.isNotEmpty()) tag.hashCode() else System.currentTimeMillis().toInt()
        NotificationManagerCompat.from(context).notify(id, notification)
    }

    fun canPostNotifications(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context, android.Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }
}
