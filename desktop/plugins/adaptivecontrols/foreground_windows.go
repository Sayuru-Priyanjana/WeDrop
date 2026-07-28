//go:build windows

package adaptivecontrols

import (
	"strings"
	"syscall"

	"golang.org/x/sys/windows"
)

// currentForegroundProcess returns the lowercased executable name (e.g.
// "code.exe") owning the currently focused window, or "" if it cannot be
// resolved (no foreground window, access denied, etc.) — the same
// resolve-a-pid-to-its-exe-name approach already verified working this
// session in desktop/plugins/media/audio_windows.go's processName, just
// starting from the foreground window instead of an audio session's
// process id.
func currentForegroundProcess() string {
	hwnd := windows.GetForegroundWindow()
	if hwnd == 0 {
		return ""
	}

	var pid uint32
	if _, err := windows.GetWindowThreadProcessId(hwnd, &pid); err != nil || pid == 0 {
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
