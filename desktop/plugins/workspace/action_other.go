//go:build !windows

package workspace

import (
	"fmt"
	"os/exec"
	"runtime"

	"desktop/plugins/remoteinput"
	"wedrop/core/protocol"
)

// runAction executes one workspace button's action on this machine.
func runAction(msg protocol.WorkspaceAction) error {
	switch msg.Action {
	case protocol.WorkspaceShortcut:
		return remoteinput.PressShortcut(msg.Modifiers, msg.Key)

	case protocol.WorkspaceOpenApp:
		return open(msg.Path)
	case protocol.WorkspaceOpenFolder:
		return open(msg.Path)
	case protocol.WorkspaceOpenURL:
		return open(msg.URL)

	case protocol.WorkspaceShellCommand:
		shell := "bash"
		if runtime.GOOS == "darwin" {
			shell = "/bin/bash"
		}
		return exec.Command(shell, "-c", msg.Command).Start()

	case protocol.WorkspaceRestoreWindow:
		return fmt.Errorf("restoring windows is not supported on %s yet", runtime.GOOS)
	}
	return fmt.Errorf("unknown workspace action %q", msg.Action)
}

// open hands target (a file/app path, a folder path, or a URL) to the
// platform's own "open with default handler" command — xdg-open on Linux,
// `open` on macOS — the equivalent of Windows' ShellExecuteW for this
// purpose, taking target as a single argument with no shell interpretation.
func open(target string) error {
	if target == "" {
		return fmt.Errorf("nothing to open")
	}
	cmd := "xdg-open"
	if runtime.GOOS == "darwin" {
		cmd = "open"
	}
	return exec.Command(cmd, target).Start()
}
