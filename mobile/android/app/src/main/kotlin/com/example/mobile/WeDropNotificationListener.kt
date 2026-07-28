package com.example.mobile

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import java.io.ByteArrayOutputStream

/**
 * Reads notifications posted on this phone so the Dart side can mirror them to
 * the other devices in the ecosystem, and separately tracks the active media
 * session so the ecosystem can see and control what this phone is playing.
 *
 * Both capabilities ride on the same "notification access" grant — Android
 * requires a live [NotificationListenerService] component as the caller
 * identity for [MediaSessionManager.getActiveSessions] too, so there is no
 * extra permission to ask for beyond what notification mirroring already needs.
 *
 * This only runs after the user grants that access in system settings — there
 * is no way to enable it programmatically, by design, because it can read
 * every notification (and every media session) on the device. We forward only
 * the app label, title and text for notifications, and skip WeDrop's own to
 * avoid an echo loop.
 */
class WeDropNotificationListener : NotificationListenerService() {

    private var sessionManager: MediaSessionManager? = null
    private var activeController: MediaController? = null
    private var activeCallback: MediaController.Callback? = null

    private val sessionsChangedListener =
        MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
            pickController(controllers ?: emptyList())
        }

    // ------------------------------------------------------------ notifications

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        NotificationMirror.onPosted(this, sbn)
    }

    // ------------------------------------------------------------ media session

    override fun onListenerConnected() {
        super.onListenerConnected()

        val manager = getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
        sessionManager = manager
        if (manager == null) return

        val component = ComponentName(this, WeDropNotificationListener::class.java)
        try {
            manager.addOnActiveSessionsChangedListener(sessionsChangedListener, component)
            pickController(manager.getActiveSessions(component))
        } catch (e: SecurityException) {
            // Access has not actually propagated to this call yet on some OEMs
            // right after the user grants it; nothing to watch until the next
            // onListenerConnected (e.g. after the app restarts).
        }
    }

    override fun onListenerDisconnected() {
        sessionManager?.removeOnActiveSessionsChangedListener(sessionsChangedListener)
        detachController()
        sessionManager = null
        super.onListenerDisconnected()
    }

    /** Picks the first session actually reporting playback state to track. */
    private fun pickController(controllers: List<MediaController>) {
        val next = controllers.firstOrNull { it.playbackState != null }
        if (next?.sessionToken == activeController?.sessionToken) return

        detachController()
        activeController = next
        MediaSessionHolder.current = next

        if (next != null) {
            val callback = object : MediaController.Callback() {
                override fun onPlaybackStateChanged(state: PlaybackState?) = emitMediaState()
                override fun onMetadataChanged(metadata: MediaMetadata?) = emitMediaState()
                override fun onSessionDestroyed() {
                    detachController()
                    emitMediaState()
                }
            }
            next.registerCallback(callback)
            activeCallback = callback
        }
        emitMediaState()
    }

    private fun detachController() {
        val controller = activeController
        val callback = activeCallback
        if (controller != null && callback != null) {
            try {
                controller.unregisterCallback(callback)
            } catch (e: Exception) {
                // The session may already be gone; nothing left to clean up.
            }
        }
        activeController = null
        activeCallback = null
        MediaSessionHolder.current = null
    }

    // Caches the last encoded artwork so it is only re-encoded when the track
    // actually changes, not on every playback-state tick (position updates
    // fire far more often than the track itself changes).
    private var cachedArtworkKey: String? = null
    private var cachedArtworkBase64: String = ""

    private fun emitMediaState() {
        val controller = activeController
        if (controller == null) {
            MainActivity.emit(mapOf("type" to "media_state_local", "has_media" to false))
            return
        }

        val metadata = controller.metadata
        val playback = controller.playbackState

        val title = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
        val artist = metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: ""
        val durationRaw = metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: -1L

        MainActivity.emit(
            mapOf(
                "type" to "media_state_local",
                "has_media" to (title.isNotEmpty() || artist.isNotEmpty()),
                "playing" to (playback?.state == PlaybackState.STATE_PLAYING),
                "title" to title,
                "artist" to artist,
                "app" to NotificationMirror.appLabel(this, controller.packageName),
                "position" to (playback?.position ?: -1L),
                "duration" to if (durationRaw > 0) durationRaw else -1L,
                "volume" to currentVolumePercent(),
                "artwork" to artworkBase64(metadata, title, artist),
            ),
        )
    }

    /**
     * Extracts the track's album art, downscaled and JPEG-compressed to a
     * small preview (max 200px, quality 70) so it stays comfortably inside a
     * single network frame and doesn't cost much to send on every track
     * change. Re-encoding is skipped when the title/artist haven't changed
     * since the last call, since [MediaController.Callback.onPlaybackStateChanged]
     * fires far more often than the artwork actually changes.
     */
    private fun artworkBase64(metadata: MediaMetadata?, title: String, artist: String): String {
        val key = "$title|$artist"
        if (key == cachedArtworkKey) return cachedArtworkBase64

        val bitmap: Bitmap? = metadata?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: metadata?.getBitmap(MediaMetadata.METADATA_KEY_ART)

        cachedArtworkKey = key
        cachedArtworkBase64 = if (bitmap == null) {
            ""
        } else {
            try {
                val maxDim = 200
                val scale = maxDim.toFloat() / maxOf(bitmap.width, bitmap.height, 1)
                val scaled = if (scale < 1f) {
                    Bitmap.createScaledBitmap(
                        bitmap,
                        (bitmap.width * scale).toInt().coerceAtLeast(1),
                        (bitmap.height * scale).toInt().coerceAtLeast(1),
                        true,
                    )
                } else {
                    bitmap
                }
                val out = ByteArrayOutputStream()
                scaled.compress(Bitmap.CompressFormat.JPEG, 70, out)
                Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            } catch (e: Exception) {
                ""
            }
        }
        return cachedArtworkBase64
    }

    private fun currentVolumePercent(): Int {
        val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return -1
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return -1
        return (am.getStreamVolume(AudioManager.STREAM_MUSIC) * 100) / max
    }
}
