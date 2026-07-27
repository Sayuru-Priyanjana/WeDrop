package com.example.mobile

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Reads notifications posted on this phone so the Dart side can mirror them to
 * the other devices in the ecosystem.
 *
 * This only runs after the user grants notification-listener access in system
 * settings — there is no way to enable it programmatically, by design, because
 * it can read every notification on the device. We forward only the app label,
 * title and text, and skip WeDrop's own notifications to avoid an echo loop.
 */
class WeDropNotificationListener : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        // Ongoing notifications (music controls, "USB charging") are noise for a
        // mirror; the user wants messages and alerts, not persistent status.
        if (sbn.isOngoing) return
        if (sbn.packageName == packageName) return

        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""

        // Nothing worth forwarding if both the title and body are empty.
        if (title.isEmpty() && text.isEmpty()) return

        MainActivity.emit(
            mapOf(
                "type" to "notification_posted",
                "id" to sbn.key,
                "app" to sbn.packageName,
                "app_label" to appLabel(sbn.packageName),
                "title" to title,
                "body" to text,
                "time" to sbn.postTime,
            ),
        )
    }

    private fun appLabel(pkg: String): String {
        return try {
            val info = packageManager.getApplicationInfo(pkg, 0)
            packageManager.getApplicationLabel(info).toString()
        } catch (e: Exception) {
            pkg
        }
    }
}
