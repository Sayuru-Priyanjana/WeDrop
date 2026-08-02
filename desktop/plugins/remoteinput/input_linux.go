//go:build linux

package remoteinput

import (
	"fmt"
	"os/exec"
	"strings"

	"wedrop/core/protocol"
)

func runXdotool(args ...string) error {
	return exec.Command("xdotool", args...).Run()
}

// applyRemoteInput injects one event onto this machine using xdotool.
func applyRemoteInput(in protocol.RemoteInput) {
	switch in.Action {
	case protocol.InputMouseMove:
		// A speed multiplier makes the touchpad feel responsive
		dx := int(in.DX * 1.6)
		dy := int(in.DY * 1.6)
		runXdotool("mousemove_relative", "--", fmt.Sprintf("%d", dx), fmt.Sprintf("%d", dy))

	case protocol.InputMouseLeft:
		runXdotool("click", "1")
	case protocol.InputMouseRight:
		runXdotool("click", "3")
	case protocol.InputMouseMiddle:
		runXdotool("click", "2")
	case protocol.InputMouseDown:
		runXdotool("mousedown", "1")
	case protocol.InputMouseUp:
		runXdotool("mouseup", "1")

	case protocol.InputScroll:
		if in.DY > 0 {
			// Scroll down
			runXdotool("click", "5")
		} else if in.DY < 0 {
			// Scroll up
			runXdotool("click", "4")
		}

	case protocol.InputType:
		// We use type to simulate typing
		runXdotool("type", in.Text)
	case protocol.InputKey:
		pressNamedKey(in.Key)

	case protocol.InputPresentNext:
		runXdotool("key", "Right")
	case protocol.InputPresentPrev:
		runXdotool("key", "Left")
	case protocol.InputPresentStart:
		runXdotool("key", "F5")
	case protocol.InputPresentEnd:
		runXdotool("key", "Escape")
	case protocol.InputPresentBlank:
		runXdotool("key", "b")
	}
}

func pressNamedKey(key string) {
	if xkey, ok := resolveKeyX11(key); ok {
		runXdotool("key", xkey)
	}
}

// resolveKeyX11 maps a RemoteInput/WorkspaceAction key name to its xdotool key name.
func resolveKeyX11(key string) (string, bool) {
	switch strings.ToLower(key) {
	case protocol.KeyBackspace:
		return "BackSpace", true
	case protocol.KeyEnter:
		return "Return", true
	case protocol.KeyTab:
		return "Tab", true
	case protocol.KeyEscape:
		return "Escape", true
	case protocol.KeySpace:
		return "space", true
	case protocol.KeyUp:
		return "Up", true
	case protocol.KeyDown:
		return "Down", true
	case protocol.KeyLeft:
		return "Left", true
	case protocol.KeyRight:
		return "Right", true
	case protocol.KeyHome:
		return "Home", true
	case protocol.KeyEnd:
		return "End", true
	case protocol.KeyDelete:
		return "Delete", true
	}

	lower := strings.ToLower(key)
	if strings.HasPrefix(lower, "f") && len(lower) >= 2 {
		return strings.ToUpper(lower), true // F1..F12
	}

	if key == "`" {
		return "grave", true
	}

	if len(key) == 1 {
		return key, true
	}
	return "", false
}

func modifierX11(name string) (string, bool) {
	switch strings.ToLower(name) {
	case protocol.ModifierCtrl:
		return "ctrl", true
	case protocol.ModifierShift:
		return "shift", true
	case protocol.ModifierAlt:
		return "alt", true
	case protocol.ModifierMeta:
		return "super", true // commonly super in X11
	}
	return "", false
}

// PressShortcut holds down each modifier (in order), taps key, then releases.
func PressShortcut(modifiers []string, key string) error {
	xkey, ok := resolveKeyX11(key)
	if !ok {
		return fmt.Errorf("unknown key %q", key)
	}

	var parts []string
	for _, m := range modifiers {
		if xmod, ok := modifierX11(m); ok {
			parts = append(parts, xmod)
		}
	}
	parts = append(parts, xkey)

	combo := strings.Join(parts, "+")
	return runXdotool("key", combo)
}
