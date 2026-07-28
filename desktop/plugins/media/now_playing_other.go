//go:build !windows

package media

import "wedrop/core/protocol"

// nowPlayingInterval is unused on this stub path but kept so callers compile
// identically across platforms.
const nowPlayingInterval = 0

// collectNowPlaying has no implementation on this platform yet; reporting "no
// media" is the honest answer rather than fabricating one.
func collectNowPlaying() protocol.MediaState {
	return protocol.MediaState{Type: protocol.TypeMediaState, HasMedia: false}
}
