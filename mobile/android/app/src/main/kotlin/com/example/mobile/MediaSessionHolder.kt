package com.example.mobile

import android.media.session.MediaController
import android.media.session.PlaybackState

/**
 * Holds a reference to whichever media session [WeDropNotificationListener] is
 * currently tracking, so an incoming remote command (including seek) can be
 * routed straight to that session's real transport controls instead of only
 * being able to send blunt, app-agnostic media key presses.
 */
object MediaSessionHolder {
    @Volatile
    var current: MediaController? = null

    /** Applies a play/pause/next/prev/stop command via the tracked session.
     * Returns false if there is nothing to route to, or the command is one
     * (volume, mute) that this session API does not cover. */
    fun applyCommand(command: String): Boolean {
        val controller = current ?: return false
        val controls = controller.transportControls

        when (command) {
            "play_pause" -> {
                val playing = controller.playbackState?.state == PlaybackState.STATE_PLAYING
                if (playing) controls.pause() else controls.play()
            }
            "next" -> controls.skipToNext()
            "prev" -> controls.skipToPrevious()
            "stop" -> controls.stop()
            else -> return false
        }
        return true
    }

    fun seek(position: Long) {
        if (position < 0) return
        current?.transportControls?.seekTo(position)
    }
}
