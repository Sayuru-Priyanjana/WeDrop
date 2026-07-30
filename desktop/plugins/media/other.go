//go:build darwin

package media

import (
	"fmt"
	"os/exec"

	"wedrop/core/protocol"
)

// applyMediaCommand drives playback on macOS.
//
// macOS has no scriptable MPRIS-style equivalent that works across every
// player, so this falls back to controlling the system-wide media keys via
// osascript.
func applyMediaCommand(command string) error {
	return darwinMedia(command)
}

// setVolumePlatform is not implemented on this platform yet.
func setVolumePlatform(percent int) error {
	return fmt.Errorf("setting an absolute volume is not supported on darwin yet")
}

// listPlayers, applyCommandToPlayer and seekPlayer are Linux-only additions
// (real multi-player/session support via MPRIS, see mpris_linux.go) with no
// implementation here yet; honest "not supported"/empty results rather than
// guessed behaviour.
func listPlayers() ([]PlayerInfo, error) {
	return nil, fmt.Errorf("listing players is not supported on darwin yet")
}

func applyCommandToPlayer(playerID, command string) error {
	return fmt.Errorf("per-player control is not supported on darwin yet")
}

func seekPlayer(playerID string, positionMs int64) error {
	return fmt.Errorf("per-player seek is not supported on darwin yet")
}

// macOS key codes for the media keys, used with the Accessibility API.
func darwinMedia(command string) error {
	var script string

	switch command {
	case protocol.MediaPlayPause:
		script = `tell application "System Events" to key code 16 using {function down}`
	case protocol.MediaNext:
		script = `tell application "System Events" to key code 17 using {function down}`
	case protocol.MediaPrev:
		script = `tell application "System Events" to key code 18 using {function down}`
	case protocol.MediaVolUp:
		script = `set volume output volume ((output volume of (get volume settings)) + 6)`
	case protocol.MediaVolDown:
		script = `set volume output volume ((output volume of (get volume settings)) - 6)`
	case protocol.MediaMute:
		script = `set volume with output muted`
	case protocol.MediaStop:
		script = `tell application "System Events" to key code 16 using {function down}`
	default:
		return fmt.Errorf("unknown media command %q", command)
	}

	return exec.Command("osascript", "-e", script).Run()
}
