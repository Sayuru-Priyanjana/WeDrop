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
                // Reading the clipboard requires this app to actually hold
                // window focus (Android only grants clipboard reads to the
                // focused app or the default IME, since API 29) — a
                // BroadcastReceiver firing on its own never brings the app's
                // window forward, so without this the read on the Dart side
                // silently comes back empty. Bring the launcher activity to
                // the foreground first, the same way tapping the
                // notification's body already does via its content intent.
                context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    context.startActivity(this)
                }
                MainActivity.emit(mapOf("type" to "notification_action", "kind" to "clipboard"))
            }
        }
    }
}
