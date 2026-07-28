//go:build windows

package media

import (
	"fmt"

	"golang.org/x/sys/windows"

	"wedrop/core/protocol"
)

// Windows virtual key codes for the multimedia keys. Sending these is how a
// remote play/pause reaches whichever app currently owns media playback —
// Windows routes them to the foreground media session for us, so WeDrop does
// not need to know or care whether the user is in Spotify or a browser tab.
const (
	vkVolumeMute      = 0xAD
	vkVolumeDown      = 0xAE
	vkVolumeUp        = 0xAF
	vkMediaNextTrack  = 0xB0
	vkMediaPrevTrack  = 0xB1
	vkMediaStop       = 0xB2
	vkMediaPlayPause  = 0xB3
	keyEventKeyUp     = 0x0002
	keyEventExtendedK = 0x0001
)

var (
	user32      = windows.NewLazySystemDLL("user32.dll")
	procKeybdEv = user32.NewProc("keybd_event")
)

// applyMediaCommand presses the matching media key on this machine.
func applyMediaCommand(command string) error {
	var vk uintptr

	switch command {
	case protocol.MediaPlayPause:
		vk = vkMediaPlayPause
	case protocol.MediaNext:
		vk = vkMediaNextTrack
	case protocol.MediaPrev:
		vk = vkMediaPrevTrack
	case protocol.MediaStop:
		vk = vkMediaStop
	case protocol.MediaVolUp:
		vk = vkVolumeUp
	case protocol.MediaVolDown:
		vk = vkVolumeDown
	case protocol.MediaMute:
		vk = vkVolumeMute
	default:
		return fmt.Errorf("unknown media command %q", command)
	}

	if err := procKeybdEv.Find(); err != nil {
		return fmt.Errorf("media keys are unavailable: %w", err)
	}

	// A key press is only delivered once both the down and the up event are
	// sent; omitting the release leaves the key logically stuck down.
	procKeybdEv.Call(vk, 0, keyEventExtendedK, 0)
	procKeybdEv.Call(vk, 0, keyEventExtendedK|keyEventKeyUp, 0)
	return nil
}
