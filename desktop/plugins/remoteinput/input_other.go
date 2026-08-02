//go:build !windows && !linux

package remoteinput

import (
	"fmt"
	"runtime"

	"wedrop/core/protocol"
)

// applyRemoteInput is a no-op on platforms without an input backend yet.
// Remote control from a phone simply does nothing here rather than failing;
// a Linux/macOS implementation can inject via XTest / CGEvent later.
func applyRemoteInput(in protocol.RemoteInput) {}

// PressShortcut is not implemented on this platform yet; see input_windows.go.
func PressShortcut(modifiers []string, key string) error {
	return fmt.Errorf("keyboard shortcuts are not supported on %s yet", runtime.GOOS)
}
