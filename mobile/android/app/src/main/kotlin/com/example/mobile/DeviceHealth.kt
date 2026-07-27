package com.example.mobile

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager

/**
 * Reads this phone's vitals for the remote's health panel.
 *
 * Battery and network are cheap and always available. CPU load is deliberately
 * left unknown: since Android 8 an app can no longer read other processes' CPU
 * stats, and reporting only our own would be misleading — better an honest
 * "unknown" than a wrong number.
 */
object DeviceHealth {

    fun collect(context: Context): Map<String, Any?> {
        val (battery, charging) = battery(context)
        val (netType, netName) = network(context)

        return mapOf(
            "battery" to battery,
            "charging" to charging,
            "cpu_percent" to -1,
            "mem_percent" to memoryPercent(context),
            "network_type" to netType,
            "network_name" to netName,
        )
    }

    private fun battery(context: Context): Pair<Int, Boolean> {
        val manager = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val level = manager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1

        val status = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val plugged = status?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val charging = plugged != 0

        return Pair(if (level in 0..100) level else -1, charging)
    }

    private fun network(context: Context): Pair<String, String> {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return Pair("offline", "")

        val network = cm.activeNetwork ?: return Pair("offline", "")
        val caps = cm.getNetworkCapabilities(network) ?: return Pair("offline", "")

        val type = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> "offline"
        }
        return Pair(type, "")
    }

    private fun memoryPercent(context: Context): Int {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE)
            as? android.app.ActivityManager ?: return -1
        val info = android.app.ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        if (info.totalMem <= 0) return -1
        val used = info.totalMem - info.availMem
        return ((used * 100) / info.totalMem).toInt().coerceIn(0, 100)
    }
}
