//go:build windows

package workspace

import (
	"fmt"
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows"

	"desktop/plugins/remoteinput"
	"wedrop/core/protocol"
)

// runAction executes one workspace button's action on this machine.
func runAction(msg protocol.WorkspaceAction) error {
	switch msg.Action {
	case protocol.WorkspaceShortcut:
		return remoteinput.PressShortcut(msg.Modifiers, msg.Key)

	case protocol.WorkspaceOpenApp:
		return shellOpen(msg.Path)
	case protocol.WorkspaceOpenFolder:
		return shellOpen(msg.Path)
	case protocol.WorkspaceOpenURL:
		return shellOpen(msg.URL)

	case protocol.WorkspaceShellCommand:
		return exec.Command("cmd", "/C", msg.Command).Start()

	case protocol.WorkspaceRestoreWindow:
		return restoreWindow(msg.WindowID)
	}
	return fmt.Errorf("unknown workspace action %q", msg.Action)
}

// user32 ShowWindow/SetForegroundWindow are not wrapped by x/sys/windows
// (only a handful of user32 functions are), so this declares them directly —
// same pattern as remoteinput's own user32 procs.
var (
	user32Workspace         = windows.NewLazySystemDLL("user32.dll")
	procShowWindow          = user32Workspace.NewProc("ShowWindow")
	procSetForegroundWindow = user32Workspace.NewProc("SetForegroundWindow")
)

// restoreWindow un-minimizes and focuses the window with the given native
// handle (reported earlier by the minimizedapps plugin) — SW_RESTORE first
// (a no-op if it's not actually minimized), then SetForegroundWindow, the
// same two-call sequence any normal taskbar click performs.
func restoreWindow(id int64) error {
	if id == 0 {
		return fmt.Errorf("no window id")
	}
	hwnd := uintptr(id)
	procShowWindow.Call(hwnd, uintptr(windows.SW_RESTORE))
	ret, _, _ := procSetForegroundWindow.Call(hwnd)
	if ret == 0 {
		return fmt.Errorf("could not focus window")
	}
	return nil
}

// shellOpen hands target (a file/app path, a folder path, or a URL) to
// ShellExecuteW with the "open" verb — the single Win32 API that already
// knows how to launch an executable, open a folder in Explorer, or open a
// URL in the default browser, all through its associated default handler.
// This is deliberately not `cmd /c start <target>`: cmd.exe would first
// parse target itself (quoting/escaping `&`, `^`, spaces, etc. becomes the
// caller's problem), where ShellExecuteW takes the string as a single opaque
// argument with no shell interpretation at all.
func shellOpen(target string) error {
	if target == "" {
		return fmt.Errorf("nothing to open")
	}
	verb, err := syscall.UTF16PtrFromString("open")
	if err != nil {
		return err
	}
	file, err := syscall.UTF16PtrFromString(target)
	if err != nil {
		return err
	}
	return windows.ShellExecute(0, verb, file, nil, nil, windows.SW_SHOWNORMAL)
}
