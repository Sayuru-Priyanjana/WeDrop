//go:build windows

package media

import (
	"context"
	"log"
	"time"

	"wedrop/core/protocol"
)

// nowPlayingInterval is how often Windows' System Media Transport Controls are
// polled for a track/position change.
const nowPlayingInterval = 2 * time.Second

// nowPlayingTimeout bounds each poll. The async completion callback involved
// in acquiring the session manager has, rarely, been observed not to fire
// promptly; this turns that into "try again next cycle" rather than blocking
// the broadcaster goroutine.
const nowPlayingTimeout = 2 * time.Second

var nowPlayingPanicLogged bool
var nowPlayingHangLogged bool

// collectNowPlaying asks Windows what is currently loaded in any app's System
// Media Transport Controls session (Spotify, browser tabs playing video, VLC,
// etc.) — the same API Windows' own volume mixer and lock-screen media
// controls use. See media_smtc_windows.go for what is and is not implemented
// and why (in short: real title/artist/position/duration/playing state, but
// not seek).
func collectNowPlaying() protocol.MediaState {
	snapshot, ok := boundedReadSMTCSnapshot()
	if !ok || snapshot == nil || snapshot.Title == "" {
		return protocol.MediaState{Type: protocol.TypeMediaState, HasMedia: false}
	}

	return protocol.MediaState{
		Type:     protocol.TypeMediaState,
		HasMedia: true,
		Playing:  snapshot.Playing,
		Title:    snapshot.Title,
		Artist:   snapshot.Artist,
		App:      "Windows",
		Position: snapshot.PositionMs,
		Duration: snapshot.DurationMs,
		Volume:   getSystemVolumePercent(),
		Artwork:  localArtwork.Artwork(),
	}
}

// boundedReadSMTCSnapshot enforces nowPlayingTimeout on our own timer around a
// call that has, rarely, been observed not to return promptly. The call runs
// on its own goroutine so a slow cycle cannot block the caller; if it never
// completes, that one goroutine leaks for the life of the process rather than
// freezing every future now-playing update.
func boundedReadSMTCSnapshot() (*smtcSnapshot, bool) {
	type result struct {
		snapshot *smtcSnapshot
		ok       bool
	}
	done := make(chan result, 1)

	go func() {
		snapshot, ok := safeReadSMTCSnapshot()
		// A send here after the caller has already timed out and stopped
		// listening is harmless: the channel is buffered (capacity 1).
		done <- result{snapshot, ok}
	}()

	select {
	case r := <-done:
		return r.snapshot, r.ok
	case <-time.After(nowPlayingTimeout):
		if !nowPlayingHangLogged {
			nowPlayingHangLogged = true
			log.Printf("wedrop: now-playing lookup did not return within %s (logging this once); continuing without it", nowPlayingTimeout)
		}
		return nil, false
	}
}

// safeReadSMTCSnapshot recovers a panic from the underlying COM/WinRT calls.
// This recover must live in the same goroutine as the call it guards (see
// boundedReadSMTCSnapshot), since recover() only catches a panic on the
// goroutine where it is deferred.
func safeReadSMTCSnapshot() (snapshot *smtcSnapshot, ok bool) {
	defer func() {
		if r := recover(); r != nil {
			ok = false
			if !nowPlayingPanicLogged {
				nowPlayingPanicLogged = true
				log.Printf("wedrop: now-playing lookup panicked (recovered), disabling further logging for this: %v", r)
			}
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), nowPlayingTimeout)
	defer cancel()

	result, err := readSMTCSnapshot(ctx)
	if err != nil {
		return nil, false
	}
	return result, true
}
