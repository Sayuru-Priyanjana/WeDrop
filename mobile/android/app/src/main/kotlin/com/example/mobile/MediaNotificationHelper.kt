package com.example.mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.SystemClock
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Base64
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Builds the "now playing" notification for whichever peer is currently
 * reporting media, backed by a real [MediaSessionCompat] so seeking is a true
 * draggable scrubber (on the lock screen, quick-settings player, and inline in
 * the notification on Android 13+) rather than a static progress readout.
 *
 * This works whenever the app's process is alive (open or minimized, not
 * task-swiped-and-killed): both the notification's action buttons and the
 * session's callbacks route back into Dart via [MainActivity.emit], which
 * buffers the event if nothing is listening yet rather than dropping it.
 */
object MediaNotificationHelper {
    const val CHANNEL_ID = "wedrop_media"
    const val NOTIFICATION_ID = 1002

    // One session, reused across updates and repointed at whichever peer's
    // media is currently shown — its callbacks always target currentDeviceId.
    private var session: MediaSessionCompat? = null
    private var currentDeviceId: String = ""

    // show() is called roughly once a second (whenever the peer's playback
    // position ticks), but the artwork bytes only actually change when the
    // track does. Without this cache, decodeArtwork() re-decoded the same
    // JPEG on every single tick, which is what was behind the repeated HWUI
    // "Image decoding logging dropped!" spam.
    private var cachedArtworkBase64: String? = null
    private var cachedArtworkBitmap: Bitmap? = null

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Now playing",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Playback controls for whatever a paired device is playing"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun ensureSession(context: Context): MediaSessionCompat {
        session?.let { return it }

        val created = MediaSessionCompat(context.applicationContext, "WeDropRemoteSession")
        created.setCallback(object : MediaSessionCompat.Callback() {
            override fun onPlay() = sendMediaAction("play_pause")
            override fun onPause() = sendMediaAction("play_pause")
            override fun onSkipToNext() = sendMediaAction("next")
            override fun onSkipToPrevious() = sendMediaAction("prev")
            override fun onSeekTo(pos: Long) = sendMediaAction("seek", pos)
        })
        created.isActive = true
        session = created
        return created
    }

    private fun sendMediaAction(command: String, position: Long? = null) {
        MainActivity.emit(
            mapOf(
                "type" to "notification_action",
                "kind" to "media",
                "device_id" to currentDeviceId,
                "command" to command,
                "position" to position,
            ),
        )
    }

    fun show(
        context: Context,
        deviceId: String,
        deviceName: String,
        appName: String,
        title: String,
        artist: String,
        playing: Boolean,
        position: Long,
        duration: Long,
        volume: Int,
        artworkBase64: String = "",
    ) {
        if (!NotificationHelper.canPostNotifications(context)) return
        ensureChannel(context)

        currentDeviceId = deviceId
        val mediaSession = ensureSession(context)
        val artwork = decodeArtwork(artworkBase64)

        val hasDuration = duration > 0
        val metadata = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title.ifEmpty { "Now playing" })
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
            .apply {
                if (hasDuration) putLong(MediaMetadataCompat.METADATA_KEY_DURATION, duration)
                if (artwork != null) putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, artwork)
            }
            .build()
        mediaSession.setMetadata(metadata)

        // ACTION_SEEK_TO is only advertised when we actually know the track's
        // length — without it there is nothing sensible to drag a scrubber
        // across, so the system correctly omits the seek bar (e.g. for a
        // Windows source, which cannot currently report position/duration).
        var actions = PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
        if (hasDuration) actions = actions or PlaybackStateCompat.ACTION_SEEK_TO

        mediaSession.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(actions)
                .setState(
                    if (playing) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    if (position >= 0) position else PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN,
                    1.0f,
                    SystemClock.elapsedRealtime(),
                )
                .build(),
        )

        val subtitleParts = mutableListOf<String>()
        if (artist.isNotEmpty()) subtitleParts.add(artist)
        if (volume in 0..100) subtitleParts.add("Vol $volume%")

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title.ifEmpty { "Now playing" })
            .setContentText(subtitleParts.joinToString(" · "))
            .setSubText(if (deviceName.isNotEmpty()) deviceName else appName)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .apply { if (artwork != null) setLargeIcon(artwork) }
            .setOngoing(playing)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2),
            )
            .addAction(actionFor(context, "prev", deviceId, android.R.drawable.ic_media_previous, "Previous"))
            .addAction(
                if (playing)
                    actionFor(context, "play_pause", deviceId, android.R.drawable.ic_media_pause, "Pause")
                else
                    actionFor(context, "play_pause", deviceId, android.R.drawable.ic_media_play, "Play"),
            )
            .addAction(actionFor(context, "next", deviceId, android.R.drawable.ic_media_next, "Next"))

        // A fallback static progress readout for surfaces that render the
        // notification without the session-driven inline scrubber.
        if (position >= 0 && hasDuration) {
            val percent = ((position * 100) / duration).toInt().coerceIn(0, 100)
            builder.setProgress(100, percent, false)
        }

        NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, builder.build())
    }

    private fun decodeArtwork(base64: String): Bitmap? {
        if (base64.isEmpty()) return null
        if (base64 == cachedArtworkBase64) return cachedArtworkBitmap
        val decoded = try {
            val bytes = Base64.decode(base64, Base64.NO_WRAP)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        } catch (e: Exception) {
            null
        }
        cachedArtworkBase64 = base64
        cachedArtworkBitmap = decoded
        return decoded
    }

    fun clear(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
        session?.apply {
            isActive = false
            release()
        }
        session = null
        currentDeviceId = ""
    }

    private fun actionFor(
        context: Context,
        command: String,
        deviceId: String,
        icon: Int,
        label: String,
    ): NotificationCompat.Action {
        val intent = Intent(context, NotificationActionReceiver::class.java).apply {
            action = NotificationActionReceiver.ACTION_MEDIA
            putExtra(NotificationActionReceiver.EXTRA_DEVICE_ID, deviceId)
            putExtra(NotificationActionReceiver.EXTRA_COMMAND, command)
        }
        // A distinct request code per (device, command) keeps each PendingIntent's
        // extras from colliding with another action's.
        val requestCode = (deviceId + command).hashCode()
        val pending = PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Action.Builder(icon, label, pending).build()
    }
}
