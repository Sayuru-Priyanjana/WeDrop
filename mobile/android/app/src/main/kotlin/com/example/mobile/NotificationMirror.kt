package com.example.mobile

import android.app.Notification
import android.content.Context
import android.service.notification.StatusBarNotification

/**
 * Forwards a notification posted on this phone to Dart for mirroring to the
 * rest of the ecosystem — the notifications feature's half of what
 * [WeDropNotificationListener] reads; [MediaSessionTracker]-equivalent logic
 * (still inline in WeDropNotificationListener until the media plugin split)
 * is the other half.
 *
 * Skips ongoing/status notifications (music controls, "USB charging") and
 * WeDrop's own, so a mirror does not become a source of noise or an echo
 * loop.
 */
object NotificationMirror {
    fun onPosted(context: Context, sbn: StatusBarNotification) {
        if (sbn.isOngoing) return
        if (sbn.packageName == context.packageName) return

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
                "app_label" to appLabel(context, sbn.packageName),
                "title" to title,
                "body" to text,
                "time" to sbn.postTime,
            ),
        )
    }

    /** Resolves a package's user-facing app name; also used by media-session
     * state reporting to label which app is playing. */
    fun appLabel(context: Context, pkg: String): String {
        return try {
            val info = context.packageManager.getApplicationInfo(pkg, 0)
            context.packageManager.getApplicationLabel(info).toString()
        } catch (e: Exception) {
            pkg
        }
    }
}
