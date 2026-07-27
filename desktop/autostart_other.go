//go:build !windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

// setStartOnLogin writes a freedesktop autostart entry on Linux. macOS would
// need a LaunchAgent plist and a signed bundle to be reliable, so it reports an
// honest "not supported" rather than writing something that silently fails.
func setStartOnLogin(enabled bool) error {
	if runtime.GOOS != "linux" {
		return fmt.Errorf("start on login is not supported on %s yet", runtime.GOOS)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(home, ".config", "autostart")
	path := filepath.Join(dir, "wedrop.desktop")

	if !enabled {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	exe, err := os.Executable()
	if err != nil {
		return err
	}

	entry := fmt.Sprintf(`[Desktop Entry]
Type=Application
Name=WeDrop
Comment=Keep your devices in sync
Exec=%s --background
Terminal=false
X-GNOME-Autostart-enabled=true
`, exe)

	return os.WriteFile(path, []byte(entry), 0o644)
}

func startOnLoginEnabled() bool {
	home, err := os.UserHomeDir()
	if err != nil {
		return false
	}
	_, err = os.Stat(filepath.Join(home, ".config", "autostart", "wedrop.desktop"))
	return err == nil
}
