//go:build windows

package minimizedapps

import (
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"

	"wedrop/core/protocol"
)

// A handful of user32 functions x/sys/windows does not wrap (only a subset
// of user32 is covered there) — declared directly, same pattern already used
// by desktop/plugins/remoteinput's own user32 procs.
var (
	user32                = windows.NewLazySystemDLL("user32.dll")
	procIsIconic          = user32.NewProc("IsIconic")
	procGetWindow         = user32.NewProc("GetWindow")
	procGetWindowTextW    = user32.NewProc("GetWindowTextW")
	procGetWindowTextLenW = user32.NewProc("GetWindowTextLengthW")
)

const gwOwner = 4 // GW_OWNER

// selfExeNames are this app's own possible executable names — matches
// desktop/plugins/adaptivecontrols/profiles.go's own list; duplicated here
// rather than imported, consistent with this codebase's per-plugin
// isolation convention. WeDrop's own window is never useful to "restore".
var selfExeNames = map[string]bool{
	"desktop.exe":     true,
	"desktop-dev.exe": true,
}

// currentMinimizedWindows enumerates every top-level, currently-minimized
// window with a non-empty title and no owner (owned windows are dialogs/
// tool windows belonging to another top-level window, not something a user
// thinks of as "an app on the taskbar").
func currentMinimizedWindows() []protocol.MinimizedWindow {
	var windowsFound []protocol.MinimizedWindow

	cb := syscall.NewCallback(func(hwnd syscall.Handle, lparam uintptr) uintptr {
		if !isMinimizedTopLevel(hwnd) {
			return 1 // continue enumeration
		}

		title := windowTitle(hwnd)
		if title == "" {
			return 1
		}

		appName := processNameForWindow(hwnd)
		if appName == "" || selfExeNames[appName] {
			// An unresolvable owning process means this is almost always a
			// system/shell surface (e.g. DWM's own notification window),
			// not something a user thinks of as "an app" to restore.
			return 1
		}

		windowsFound = append(windowsFound, protocol.MinimizedWindow{
			ID:      int64(hwnd),
			Title:   title,
			AppName: appName,
		})
		return 1
	})

	_ = windows.EnumWindows(cb, nil)
	return windowsFound
}

func isMinimizedTopLevel(hwnd syscall.Handle) bool {
	iconic, _, _ := procIsIconic.Call(uintptr(hwnd))
	if iconic == 0 {
		return false
	}
	owner, _, _ := procGetWindow.Call(uintptr(hwnd), uintptr(gwOwner))
	return owner == 0
}

func windowTitle(hwnd syscall.Handle) string {
	length, _, _ := procGetWindowTextLenW.Call(uintptr(hwnd))
	if length == 0 {
		return ""
	}
	buf := make([]uint16, length+1)
	procGetWindowTextW.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	return syscall.UTF16ToString(buf)
}

// processNameForWindow resolves the lowercased executable name owning hwnd —
// the same resolve-a-pid-to-its-exe-name approach as
// desktop/plugins/adaptivecontrols/foreground_windows.go, duplicated here per
// this codebase's established per-plugin isolation convention.
func processNameForWindow(hwnd syscall.Handle) string {
	var pid uint32
	if _, err := windows.GetWindowThreadProcessId(windows.HWND(hwnd), &pid); err != nil || pid == 0 {
		return ""
	}

	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(handle)

	buf := make([]uint16, windows.MAX_PATH)
	size := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(handle, 0, &buf[0], &size); err != nil {
		return ""
	}

	full := syscall.UTF16ToString(buf[:size])
	base := full
	for i := len(full) - 1; i >= 0; i-- {
		if full[i] == '\\' || full[i] == '/' {
			base = full[i+1:]
			break
		}
	}
	return strings.ToLower(base)
}
