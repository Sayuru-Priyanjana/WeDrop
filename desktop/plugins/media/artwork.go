package media

// ArtworkProvider supplies base64-encoded JPEG album art for whatever is
// currently playing locally, if the platform can safely provide it.
//
// Kept as its own small abstraction, separate from metadata/seek/volume, so
// a future or safer per-platform implementation can be swapped in without
// touching the rest of the media plugin — mirroring how the mobile side
// keeps its own artwork extraction (Android's MediaSessionTracker) behind
// nothing more than "give me base64 JPEG bytes or an empty string."
type ArtworkProvider interface {
	// Artwork returns base64-encoded JPEG album art for the current track,
	// or "" if none is available.
	Artwork() string
}

// localArtwork is this device's platform-specific artwork source, consulted
// by collectNowPlaying (now_playing_windows.go / now_playing_other.go) when
// attaching album art to the locally-playing track it reports.
var localArtwork = newArtworkProvider()
