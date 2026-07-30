//go:build linux

package media

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/godbus/dbus/v5"

	"wedrop/core/protocol"
)

// nowPlayingInterval is how often the active MPRIS session is polled for a
// track/position change — same cadence as Windows' SMTC polling.
const nowPlayingInterval = 2 * time.Second

const (
	mprisObjectPath      = "/org/mpris/MediaPlayer2"
	mprisRootInterface   = "org.mpris.MediaPlayer2"
	mprisPlayerInterface = "org.mpris.MediaPlayer2.Player"
	dbusPropsInterface   = "org.freedesktop.DBus.Properties"
)

// dbusCallTimeout bounds every session-bus round trip, so a hung or
// misbehaving player can't stall the broadcaster/command goroutine.
const dbusCallTimeout = 2 * time.Second

// mprisPlayer is one discovered MPRIS session on the session bus.
type mprisPlayer struct {
	busName  string
	name     string // Identity, or busName trimmed if empty
	playing  bool
	title    string
	artist   string
	artURL   string
	lengthMs int64
	posMs    int64
	volume   float64 // 0.0-1.0, -1 unknown
}

// mprisPlayers enumerates every active MPRIS session on the session bus,
// excluding playerctld — a proxy service that mirrors whatever real player
// is active, which would otherwise double-report the same session.
func mprisPlayers(ctx context.Context) ([]mprisPlayer, error) {
	conn, err := dbus.ConnectSessionBus(dbus.WithContext(ctx))
	if err != nil {
		return nil, fmt.Errorf("connecting to session bus: %w", err)
	}
	defer conn.Close()

	var names []string
	if err := conn.BusObject().CallWithContext(ctx, "org.freedesktop.DBus.ListNames", 0).Store(&names); err != nil {
		return nil, fmt.Errorf("listing dbus names: %w", err)
	}

	var players []mprisPlayer
	for _, name := range names {
		if !strings.HasPrefix(name, "org.mpris.MediaPlayer2.") {
			continue
		}
		if name == "org.mpris.MediaPlayer2.playerctld" {
			continue
		}
		if p, ok := readMprisPlayer(ctx, conn, name); ok {
			players = append(players, p)
		}
	}
	return players, nil
}

// readMprisPlayer reads one session's identity, playback status, metadata,
// volume and position. A player that doesn't answer PlaybackStatus, or
// reports anything other than Playing/Paused (e.g. Stopped, or a transient
// service with no real session behind it), is skipped entirely.
func readMprisPlayer(ctx context.Context, conn *dbus.Conn, busName string) (mprisPlayer, bool) {
	obj := conn.Object(busName, dbus.ObjectPath(mprisObjectPath))

	var status string
	if err := obj.CallWithContext(ctx, dbusPropsInterface+".Get", 0, mprisPlayerInterface, "PlaybackStatus").Store(&status); err != nil {
		return mprisPlayer{}, false
	}
	if status != "Playing" && status != "Paused" {
		return mprisPlayer{}, false
	}

	p := mprisPlayer{busName: busName, playing: status == "Playing", volume: -1, lengthMs: -1, posMs: -1}

	var identity string
	if err := obj.CallWithContext(ctx, dbusPropsInterface+".Get", 0, mprisRootInterface, "Identity").Store(&identity); err == nil && identity != "" {
		p.name = identity
	} else {
		p.name = strings.TrimPrefix(busName, "org.mpris.MediaPlayer2.")
	}

	var metadata map[string]dbus.Variant
	if err := obj.CallWithContext(ctx, dbusPropsInterface+".Get", 0, mprisPlayerInterface, "Metadata").Store(&metadata); err == nil {
		if v, ok := metadata["xesam:title"].Value().(string); ok {
			p.title = v
		}
		if v, ok := metadata["xesam:artist"].Value().([]string); ok && len(v) > 0 {
			p.artist = strings.Join(v, ", ")
		}
		// mpris:length is in microseconds; WeDrop's protocol wants milliseconds.
		if v, ok := metadata["mpris:length"].Value().(int64); ok {
			p.lengthMs = v / 1000
		}
		if v, ok := metadata["mpris:artUrl"].Value().(string); ok {
			p.artURL = v
		}
	}

	var volume float64
	if err := obj.CallWithContext(ctx, dbusPropsInterface+".Get", 0, mprisPlayerInterface, "Volume").Store(&volume); err == nil {
		p.volume = volume
	}

	// Position, like Length, is microseconds on the wire.
	var position int64
	if err := obj.CallWithContext(ctx, dbusPropsInterface+".Get", 0, mprisPlayerInterface, "Position").Store(&position); err == nil {
		p.posMs = position / 1000
	}

	return p, true
}

// pickPlayer resolves "the" player a caller means: an explicit playerID if
// given, otherwise the first one actually playing, otherwise just the first
// one found (e.g. paused).
func pickPlayer(players []mprisPlayer, playerID string) (mprisPlayer, bool) {
	if playerID != "" {
		for _, p := range players {
			if p.busName == playerID {
				return p, true
			}
		}
		return mprisPlayer{}, false
	}
	for _, p := range players {
		if p.playing {
			return p, true
		}
	}
	if len(players) > 0 {
		return players[0], true
	}
	return mprisPlayer{}, false
}

// collectNowPlaying asks the session's MPRIS players what is currently
// loaded — the same D-Bus interface every Linux media player (VLC, Spotify,
// browser tabs, mpv-with-plugin, etc.) implements, mirroring what KDE
// Connect's own mpriscontrol plugin does.
func collectNowPlaying(playerID string) protocol.MediaState {
	ctx, cancel := context.WithTimeout(context.Background(), dbusCallTimeout)
	defer cancel()

	players, err := mprisPlayers(ctx)
	if err != nil {
		return protocol.MediaState{Type: protocol.TypeMediaState, HasMedia: false}
	}
	p, ok := pickPlayer(players, playerID)
	if !ok || p.title == "" {
		return protocol.MediaState{Type: protocol.TypeMediaState, HasMedia: false}
	}

	volume := -1
	if p.volume >= 0 {
		volume = int(p.volume * 100)
	}

	return protocol.MediaState{
		Type:     protocol.TypeMediaState,
		HasMedia: true,
		Playing:  p.playing,
		Title:    p.title,
		Artist:   p.artist,
		App:      p.name,
		Position: p.posMs,
		Duration: p.lengthMs,
		Volume:   volume,
		Artwork:  loadLocalArtwork(p.artURL),
	}
}

// loadLocalArtwork reads a local file:// artUrl and returns it as base64.
// Only local files are handled — like KDE Connect's own choice — since a
// streaming service's http(s) artUrl would need a network fetch, a
// materially different (and slower) operation than reading a filesystem
// cache thumbnail; left for later rather than done speculatively here.
func loadLocalArtwork(artURL string) string {
	if artURL == "" {
		return ""
	}
	u, err := url.Parse(artURL)
	if err != nil || u.Scheme != "file" {
		return ""
	}
	data, err := os.ReadFile(u.Path)
	if err != nil {
		return ""
	}
	return base64.StdEncoding.EncodeToString(data)
}

// listPlayers reports every active MPRIS session, for the multi-player
// picker on the remote.
func listPlayers() ([]PlayerInfo, error) {
	ctx, cancel := context.WithTimeout(context.Background(), dbusCallTimeout)
	defer cancel()

	players, err := mprisPlayers(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]PlayerInfo, 0, len(players))
	for _, p := range players {
		out = append(out, PlayerInfo{ID: p.busName, Title: p.title, Artist: p.artist, Playing: p.playing})
	}
	return out, nil
}

// withPlayer opens a short-lived session-bus connection scoped to one call —
// simple and safe at the polling/command cadence this plugin runs at, with
// no persistent subscription to manage.
func withPlayer(ctx context.Context, busName string, fn func(obj dbus.BusObject) error) error {
	conn, err := dbus.ConnectSessionBus(dbus.WithContext(ctx))
	if err != nil {
		return fmt.Errorf("connecting to session bus: %w", err)
	}
	defer conn.Close()
	return fn(conn.Object(busName, dbus.ObjectPath(mprisObjectPath)))
}

func mprisMethodFor(command string) (string, error) {
	switch command {
	case protocol.MediaPlayPause:
		return "PlayPause", nil
	case protocol.MediaNext:
		return "Next", nil
	case protocol.MediaPrev:
		return "Previous", nil
	case protocol.MediaStop:
		return "Stop", nil
	}
	return "", fmt.Errorf("unknown media command %q", command)
}

// applyCommandToPlayer sends a transport command to one specific MPRIS
// session, via that session's own D-Bus object — precise per-player control
// rather than a simulated key press that only ever reaches whichever
// session the desktop environment itself treats as active.
func applyCommandToPlayer(playerID, command string) error {
	method, err := mprisMethodFor(command)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), dbusCallTimeout)
	defer cancel()
	return withPlayer(ctx, playerID, func(obj dbus.BusObject) error {
		return obj.CallWithContext(ctx, mprisPlayerInterface+"."+method, 0).Err
	})
}

// seekPlayer jumps to an absolute position by computing the offset from the
// player's own current position and calling Seek (a relative jump) —
// deliberately not SetPosition, which requires matching the exact current
// TrackId object path and is fragile in practice; this mirrors KDE
// Connect's own mpriscontrol plugin.
func seekPlayer(playerID string, positionMs int64) error {
	ctx, cancel := context.WithTimeout(context.Background(), dbusCallTimeout)
	defer cancel()
	return withPlayer(ctx, playerID, func(obj dbus.BusObject) error {
		var currentUs int64
		if err := obj.CallWithContext(ctx, dbusPropsInterface+".Get", 0, mprisPlayerInterface, "Position").Store(&currentUs); err != nil {
			return fmt.Errorf("reading current position: %w", err)
		}
		offsetUs := positionMs*1000 - currentUs
		return obj.CallWithContext(ctx, mprisPlayerInterface+".Seek", 0, offsetUs).Err
	})
}

func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

func setPlayerVolume(ctx context.Context, busName string, volume float64) error {
	volume = clamp01(volume)
	return withPlayer(ctx, busName, func(obj dbus.BusObject) error {
		return obj.CallWithContext(ctx, dbusPropsInterface+".Set", 0, mprisPlayerInterface, "Volume", dbus.MakeVariant(volume)).Err
	})
}

func adjustPlayerVolume(ctx context.Context, busName string, delta float64) error {
	return withPlayer(ctx, busName, func(obj dbus.BusObject) error {
		var current float64
		if err := obj.CallWithContext(ctx, dbusPropsInterface+".Get", 0, mprisPlayerInterface, "Volume").Store(&current); err != nil {
			return fmt.Errorf("reading current volume: %w", err)
		}
		return obj.CallWithContext(ctx, dbusPropsInterface+".Set", 0, mprisPlayerInterface, "Volume", dbus.MakeVariant(clamp01(current+delta))).Err
	})
}

// applyMediaCommand drives whichever MPRIS session is "active" (the first
// one playing, else the first one found) when the caller hasn't selected a
// specific player — used both as plugin.go's no-selection fallback and for
// local media-key handling on this machine.
func applyMediaCommand(command string) error {
	ctx, cancel := context.WithTimeout(context.Background(), dbusCallTimeout)
	defer cancel()

	players, err := mprisPlayers(ctx)
	if err != nil {
		return err
	}
	p, ok := pickPlayer(players, "")
	if !ok {
		return fmt.Errorf("no active media player found")
	}

	switch command {
	case protocol.MediaPlayPause, protocol.MediaNext, protocol.MediaPrev, protocol.MediaStop:
		return applyCommandToPlayer(p.busName, command)
	case protocol.MediaVolUp:
		return adjustPlayerVolume(ctx, p.busName, 0.05)
	case protocol.MediaVolDown:
		return adjustPlayerVolume(ctx, p.busName, -0.05)
	case protocol.MediaMute:
		return setPlayerVolume(ctx, p.busName, 0)
	}
	return fmt.Errorf("unknown media command %q", command)
}

// setVolumePlatform sets an absolute volume (0-100) on the active MPRIS
// player's own volume control. This is deliberately the player's MPRIS
// Volume, not the Linux system/output volume — a real PulseAudio/PipeWire
// integration for system-wide and per-app mixer control (matching Windows'
// Core Audio-backed listAudioDevices/listAppVolumes in common_other.go) is a
// separate, larger effort left for later.
func setVolumePlatform(percent int) error {
	ctx, cancel := context.WithTimeout(context.Background(), dbusCallTimeout)
	defer cancel()

	players, err := mprisPlayers(ctx)
	if err != nil {
		return err
	}
	p, ok := pickPlayer(players, "")
	if !ok {
		return fmt.Errorf("no active media player found")
	}
	return setPlayerVolume(ctx, p.busName, float64(percent)/100)
}
