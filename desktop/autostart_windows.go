//go:build windows

package main

import (
	"fmt"
	"os"

	"golang.org/x/sys/windows/registry"
)

const runKeyPath = `Software\Microsoft\Windows\CurrentVersion\Run`
const runValueName = "WeDrop"

// setStartOnLogin registers or removes the current executable in the per-user
// Run key. HKCU is deliberate: writing the machine-wide key would need
// administrator rights the app does not have and should not ask for.
func setStartOnLogin(enabled bool) error {
	key, err := registry.OpenKey(registry.CURRENT_USER, runKeyPath, registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("could not open the startup registry key: %w", err)
	}
	defer key.Close()

	if !enabled {
		err := key.DeleteValue(runValueName)
		if err != nil && err != registry.ErrNotExist {
			return err
		}
		return nil
	}

	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("could not determine the application path: %w", err)
	}

	// --background asks the app to start hidden, so a machine that boots with
	// WeDrop enabled does not throw a window at the user on every login.
	return key.SetStringValue(runValueName, fmt.Sprintf("\"%s\" --background", exe))
}

// startOnLoginEnabled reports whether the registry entry is present.
func startOnLoginEnabled() bool {
	key, err := registry.OpenKey(registry.CURRENT_USER, runKeyPath, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer key.Close()

	_, _, err = key.GetStringValue(runValueName)
	return err == nil
}
