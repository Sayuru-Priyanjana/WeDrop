package com.example.mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives taps on the action buttons of the media and service notifications
 * and forwards them into Dart via [MainActivity.emit].
 *
 * If the app's process is alive (open or minimized — see [WeDropApplication]
 * for why that now covers far more cases than before), the event reaches
 * [AppService] immediately. If the process was fully killed, [MainActivity.emit]
 * simply buffers the event and it fires the next time the app is opened,
 * rather than crashing or silently vanishing.
 */
class NotificationActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_MEDIA = "com.example.mobile.action.MEDIA"
        const val ACTION_SEND_CLIPBOARD = "com.example.mobile.action.SEND_CLIPBOARD"
        const val EXTRA_DEVICE_ID = "device_id"
        const val EXTRA_COMMAND = "command"
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_MEDIA -> {
                MainActivity.emit(
                    mapOf(
                        "type" to "notification_action",
                        "kind" to "media",
                        "device_id" to intent.getStringExtra(EXTRA_DEVICE_ID),
                        "command" to intent.getStringExtra(EXTRA_COMMAND),
                    ),
                )
            }
            ACTION_SEND_CLIPBOARD -> {
                MainActivity.emit(mapOf("type" to "notification_action", "kind" to "clipboard"))
            }
        }
    }
}
