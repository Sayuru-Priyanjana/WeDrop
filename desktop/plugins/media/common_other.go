//go:build !windows

package media

import (
	"fmt"
	"runtime"
)

// PlayerInfo, AudioDevice and AppVolume are declared per-family (Windows
// declares its own matching shapes in smtc_windows.go/audio_windows.go)
// since their fields depend on what each platform can actually report;
// these are the shapes every non-Windows platform shares.
type PlayerInfo struct {
	ID      string
	Title   string
	Artist  string
	Playing bool
}

type AudioDevice struct {
	ID      string
	Name    string
	Default bool
}

type AppVolume struct {
	ID     string
	Name   string
	Volume int
	Muted  bool
}

// listAudioDevices, setDefaultAudioDevice, listAppVolumes,
// setAppVolumePercent and setAppMute are Windows-only additions (Core Audio
// output-device switching and per-app session volume) with no
// implementation on Linux or macOS yet — honest "not supported" rather than
// guessed behaviour. Linux's per-app/per-device audio mixer would need a
// PulseAudio/PipeWire integration, a separate, larger effort from the MPRIS
// now-playing/control support in mpris_linux.go.
func listAudioDevices() ([]AudioDevice, error) {
	return nil, fmt.Errorf("listing audio devices is not supported on %s yet", runtime.GOOS)
}

func setDefaultAudioDevice(deviceID string) error {
	return fmt.Errorf("switching the audio device is not supported on %s yet", runtime.GOOS)
}

func listAppVolumes() ([]AppVolume, error) {
	return nil, fmt.Errorf("per-app volume is not supported on %s yet", runtime.GOOS)
}

func setAppVolumePercent(id string, percent int) error {
	return fmt.Errorf("per-app volume is not supported on %s yet", runtime.GOOS)
}

func setAppMute(id string, muted bool) error {
	return fmt.Errorf("per-app volume is not supported on %s yet", runtime.GOOS)
}
