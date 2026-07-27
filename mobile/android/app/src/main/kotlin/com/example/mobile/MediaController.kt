package com.example.mobile

import android.content.Context
import android.media.AudioManager
import android.os.SystemClock
import android.view.KeyEvent

/**
 * Applies a media command from another device to this phone's playback.
 *
 * Playback keys are dispatched through AudioManager, which routes them to
 * whichever app currently holds the media session — the same path the physical
 * volume and headset buttons take. That means WeDrop does not need to know or
 * care which player is in front (Spotify, YouTube, a podcast app); the OS
 * delivers the key to the active session for us.
 */
object MediaController {

    fun apply(context: Context, command: String) {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        when (command) {
            "play_pause" -> sendKey(audio, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            "next" -> sendKey(audio, KeyEvent.KEYCODE_MEDIA_NEXT)
            "prev" -> sendKey(audio, KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            "stop" -> sendKey(audio, KeyEvent.KEYCODE_MEDIA_STOP)
            "vol_up" -> audio.adjustStreamVolume(
                AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI,
            )
            "vol_down" -> audio.adjustStreamVolume(
                AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI,
            )
            "mute" -> audio.adjustStreamVolume(
                AudioManager.STREAM_MUSIC, AudioManager.ADJUST_TOGGLE_MUTE, AudioManager.FLAG_SHOW_UI,
            )
        }
    }

    /**
     * A media key press is only delivered once both the down and up events are
     * dispatched; sending just the down leaves the key logically held.
     */
    private fun sendKey(audio: AudioManager, keyCode: Int) {
        val now = SystemClock.uptimeMillis()
        audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, keyCode, 0))
        audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, keyCode, 0))
    }
}
