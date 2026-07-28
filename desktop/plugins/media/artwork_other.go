//go:build !windows

package media

// noArtworkProvider is the fallback for platforms with no artwork source
// implemented yet (Linux/macOS now-playing itself is also unimplemented —
// see now_playing_other.go).
type noArtworkProvider struct{}

func newArtworkProvider() ArtworkProvider { return noArtworkProvider{} }

func (noArtworkProvider) Artwork() string { return "" }
