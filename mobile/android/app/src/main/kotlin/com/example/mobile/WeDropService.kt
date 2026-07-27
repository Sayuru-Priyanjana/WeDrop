package com.example.mobile

import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * The foreground service that keeps WeDrop alive when the app is off-screen.
 *
 * Android suspends normal background processes within seconds, which would tear
 * down every socket and stop clipboard sync, file receipt and notification
 * mirroring the moment the user switched apps. A foreground service with an
 * ongoing notification is the platform's sanctioned way to keep running.
 *
 * The service does not itself run the networking — that lives in the Flutter
 * engine, which the OS keeps warm as long as this service is foreground. The
 * service's real job is to hold that promise, plus a multicast lock so
 * discovery packets are delivered and a partial wake lock so the CPU is not
 * fully parked mid-transfer.
 */
class WeDropService : Service() {

    private var multicastLock: WifiManager.MulticastLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        private const val ACTION_START = "com.example.mobile.START"
        private const val ACTION_STOP = "com.example.mobile.STOP"
        private const val ACTION_UPDATE = "com.example.mobile.UPDATE"
        private const val EXTRA_STATUS = "status"

        fun start(context: Context, status: String) {
            val intent = Intent(context, WeDropService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_STATUS, status)
            }
            ContextCompatStartForeground(context, intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, WeDropService::class.java).apply { action = ACTION_STOP }
            context.startService(intent)
        }

        fun updateStatus(context: Context, status: String) {
            val intent = Intent(context, WeDropService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_STATUS, status)
            }
            context.startService(intent)
        }

        /** Uses the foreground-safe start on the versions that require it. */
        private fun ContextCompatStartForeground(context: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseLocks()
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                val status = intent.getStringExtra(EXTRA_STATUS) ?: "Syncing"
                val notification = NotificationHelper.buildServiceNotification(this, status)
                val manager = getSystemService(Context.NOTIFICATION_SERVICE)
                    as android.app.NotificationManager
                manager.notify(NotificationHelper.SERVICE_NOTIFICATION_ID, notification)
                return START_STICKY
            }
            else -> {
                val status = intent?.getStringExtra(EXTRA_STATUS) ?: "Keeping your devices in sync"
                startForegroundCompat(status)
                acquireLocks()
                return START_STICKY
            }
        }
    }

    private fun startForegroundCompat(status: String) {
        val notification = NotificationHelper.buildServiceNotification(this, status)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NotificationHelper.SERVICE_NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NotificationHelper.SERVICE_NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    /**
     * Android drops multicast delivery to save power unless a lock is held, so
     * without this the phone would simply never see desktops' announcements.
     */
    private fun acquireLocks() {
        if (multicastLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("wedrop-discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "wedrop:sync",
            ).apply {
                setReferenceCounted(false)
                // A generous timeout, refreshed on each start command, so a bug
                // cannot pin the CPU on indefinitely.
                acquire(30 * 60 * 1000L)
            }
        }
    }

    private fun releaseLocks() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    // Deliberately empty: some OEM launchers stop a foreground service's host
    // process when its task is swiped from Recents even though stock Android
    // does not. Overriding this and doing nothing (rather than not overriding
    // it, which is the same as calling stopSelf() on those OEMs) is the
    // standard defensive measure; combined with the engine now living in
    // WeDropApplication rather than the Activity, this is what lets sync
    // survive the app being swiped away rather than only minimized.
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
