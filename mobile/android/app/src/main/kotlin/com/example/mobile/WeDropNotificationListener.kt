package com.example.mobile

import android.content.ComponentName
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Reads notifications posted on this phone so the Dart side can mirror them
 * to the other devices in the ecosystem ([NotificationMirror]), and
 * separately drives [MediaSessionTracker] so the ecosystem can see and
 * control what this phone is playing.
 *
 * Both capabilities ride on the same "notification access" grant — Android
 * requires a live [NotificationListenerService] component as the caller
 * identity for [android.media.session.MediaSessionManager.getActiveSessions]
 * too, so there is no extra permission to ask for beyond what notification
 * mirroring already needs. This class exists only to own that one Android
 * component and hand its lifecycle to the two collaborators above; it holds
 * no feature logic itself.
 *
 * This only runs after the user grants notification access in system
 * settings — there is no way to enable it programmatically, by design,
 * because it can read every notification (and every media session) on the
 * device.
 */
class WeDropNotificationListener : NotificationListenerService() {

    private var mediaTracker: MediaSessionTracker? = null

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        NotificationMirror.onPosted(this, sbn)
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        val tracker = MediaSessionTracker(
            this,
            ComponentName(this, WeDropNotificationListener::class.java),
        )
        mediaTracker = tracker
        tracker.start()
    }

    override fun onListenerDisconnected() {
        mediaTracker?.stop()
        mediaTracker = null
        super.onListenerDisconnected()
    }
}
