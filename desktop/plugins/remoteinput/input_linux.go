//go:build linux

package remoteinput

import (
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"time"

	"wedrop/core/protocol"
)

var (
	xdoMu    sync.Mutex
	xdoStdin io.WriteCloser
	xdoCmd   *exec.Cmd
)

// ensureXdotool starts a persistent xdotool process reading from stdin.
// This is critical for performance because spawning a new xdotool process
// 60 times a second for mouse movements causes severe lag or drops events.
func ensureXdotool() (io.WriteCloser, error) {
	if xdoStdin != nil {
		return xdoStdin, nil
	}

	cmd := exec.Command("xdotool", "-")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}

	if err := cmd.Start(); err != nil {
		return nil, err
	}

	xdoCmd = cmd
	xdoStdin = stdin

	// Restart it if it dies
	go func() {
		cmd.Wait()
		xdoMu.Lock()
		xdoStdin = nil
		xdoCmd = nil
		xdoMu.Unlock()
	}()

	return stdin, nil
}

func sendXdotoolCommand(cmd string) {
	xdoMu.Lock()
	defer xdoMu.Unlock()

	stdin, err := ensureXdotool()
	if err != nil {
		// Fallback to one-off if daemon fails (should rarely happen)
		exec.Command("sh", "-c", fmt.Sprintf("xdotool %s", cmd)).Run()
		return
	}

	// Write the command with a newline
	_, err = io.WriteString(stdin, cmd+"\n")
	if err != nil {
		xdoStdin.Close()
		xdoStdin = nil
	}
}

// applyRemoteInput injects one event onto this machine using xdotool.
func applyRemoteInput(in protocol.RemoteInput) {
	switch in.Action {
	case protocol.InputMouseMove:
		// A speed multiplier makes the touchpad feel responsive
		dx := int(in.DX * 1.6)
		dy := int(in.DY * 1.6)
		// xdotool mousemove_relative takes -- for negative coordinates, but when
		// reading from stdin, it does not use getopt, so we can just pass the numbers.
		// However, it's safer to keep -- if the stdin parser uses it. Wait, xdotool stdin
		// parser is simple: `mousemove_relative -10 10` is supported without --.
		sendXdotoolCommand(fmt.Sprintf("mousemove_relative %d %d", dx, dy))

	case protocol.InputMouseLeft:
		sendXdotoolCommand("click 1")
	case protocol.InputMouseRight:
		sendXdotoolCommand("click 3")
	case protocol.InputMouseMiddle:
		sendXdotoolCommand("click 2")
	case protocol.InputMouseDown:
		sendXdotoolCommand("mousedown 1")
	case protocol.InputMouseUp:
		sendXdotoolCommand("mouseup 1")

	case protocol.InputScroll:
		if in.DY > 0 {
			sendXdotoolCommand("click 5") // Scroll down
		} else if in.DY < 0 {
			sendXdotoolCommand("click 4") // Scroll up
		}

	case protocol.InputType:
		// Escape single quotes for type command
		text := strings.ReplaceAll(in.Text, "'", "'\\''")
		sendXdotoolCommand(fmt.Sprintf("type '%s'", text))
	case protocol.InputKey:
		pressNamedKey(in.Key)

	case protocol.InputPresentNext:
		sendXdotoolCommand("key Right")
	case protocol.InputPresentPrev:
		sendXdotoolCommand("key Left")
	case protocol.InputPresentStart:
		sendXdotoolCommand("key F5")
	case protocol.InputPresentEnd:
		sendXdotoolCommand("key Escape")
	case protocol.InputPresentBlank:
		sendXdotoolCommand("key b")
	}
}

func pressNamedKey(key string) {
	if xkey, ok := resolveKeyX11(key); ok {
		sendXdotoolCommand(fmt.Sprintf("key %s", xkey))
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
	sendXdotoolCommand(fmt.Sprintf("key %s", combo))
	return nil
}
