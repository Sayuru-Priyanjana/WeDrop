//go:build !windows

package media

import (
	"fmt"
	"os/exec"
	"runtime"

	"wedrop/core/protocol"
)

// applyMediaCommand drives playback on Linux and macOS.
//
// Linux goes through playerctl, the standard MPRIS client. macOS has no
// scriptable equivalent that works across every player, so it falls back to
// controlling the system-wide media keys via osascript.
func applyMediaCommand(command string) error {
	switch runtime.GOOS {
	case "linux":
		return linuxMedia(command)
	case "darwin":
		return darwinMedia(command)
	}
	return fmt.Errorf("media control is not supported on %s", runtime.GOOS)
}

// trySeekPlatform is not implemented on this platform yet. playerctl does
// support an absolute "position" command on Linux, but its exact semantics
// were not verified against a running instance the way the Windows path was,
// so this reports an honest "not supported" rather than shipping a guess.
func trySeekPlatform(positionMs int64) error {
	return fmt.Errorf("seeking is not supported on %s yet", runtime.GOOS)
}

// setVolumePlatform is not implemented on this platform yet.
func setVolumePlatform(percent int) error {
	return fmt.Errorf("setting an absolute volume is not supported on %s yet", runtime.GOOS)
}

func linuxMedia(command string) error {
	var args []string

	switch command {
	case protocol.MediaPlayPause:
		args = []string{"play-pause"}
	case protocol.MediaNext:
		args = []string{"next"}
	case protocol.MediaPrev:
		args = []string{"previous"}
	case protocol.MediaStop:
		args = []string{"stop"}
	case protocol.MediaVolUp:
		args = []string{"volume", "0.05+"}
	case protocol.MediaVolDown:
		args = []string{"volume", "0.05-"}
	case protocol.MediaMute:
		args = []string{"volume", "0"}
	default:
		return fmt.Errorf("unknown media command %q", command)
	}

	if _, err := exec.LookPath("playerctl"); err != nil {
		return fmt.Errorf("install playerctl to control media from other devices")
	}
	return exec.Command("playerctl", args...).Run()
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
