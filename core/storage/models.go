package storage

import (
	"encoding/json"

	"wedrop/core/protocol"
)

// DeviceConfig is this device's identity. It is stored encrypted and never
// leaves the machine — only PublicKey is ever put on the wire.
type DeviceConfig struct {
	DeviceID   string              `json:"device_id"`
	Name       string              `json:"name"`
	Platform   string              `json:"platform"`
	FormFactor protocol.FormFactor `json:"form_factor"`
	PublicKey  string              `json:"public_key"`  // base64 Ed25519
	PrivateKey string              `json:"private_key"` // base64 Ed25519
}

// Settings holds every user-facing toggle. Each feature has separate send and
// receive switches, because "share my clipboard" and "let others change my
// clipboard" are genuinely different decisions.
//
// The zero value is not the intended default — use DefaultSettings.
type Settings struct {
	// Clipboard
	AutoSyncClipboard bool `json:"auto_sync_clipboard"` // send my clipboard automatically
	ReceiveClipboard  bool `json:"receive_clipboard"`   // apply clipboard from peers
	ClipboardMaxChars int  `json:"clipboard_max_chars"` // skip anything larger
	// Files
	AutoAcceptFiles bool   `json:"auto_accept_files"` // accept without prompting (trusted only)
	DownloadDir     string `json:"download_dir"`
	// Notifications
	ShareNotifications   bool `json:"share_notifications"`   // mirror mine to peers
	ReceiveNotifications bool `json:"receive_notifications"` // show peers' notifications
	// Media
	AllowMediaControl bool `json:"allow_media_control"` // let peers control my playback
	// Workspace — off by default, unlike every other feature here: this is
	// the one action a workspace button can request (running an arbitrary
	// shell command) that is materially riskier than what remote-input
	// already permits (keystroke injection), so it needs its own explicit,
	// visible opt-in rather than inheriting an existing toggle.
	AllowAutomation bool `json:"allow_automation"` // let peers run shell/script commands
	// Discovery & lifecycle
	Discoverable     bool `json:"discoverable"`       // announce over UDP
	AcceptNewPairing bool `json:"accept_new_pairing"` // consider pairing requests
	RunInBackground  bool `json:"run_in_background"`  // keep running when window closes
	StartOnLogin     bool `json:"start_on_login"`
	StartMinimized   bool `json:"start_minimized"`
	// ShowAdvancedFeatures gates network/CPU/memory detail on a peer's health
	// display; off by default so the common case only shows battery and sound.
	ShowAdvancedFeatures bool `json:"show_advanced_features"`
}

// DefaultSettings is the out-of-the-box configuration: syncing is on, because
// an ecosystem app that does nothing until configured is just a file picker.
func DefaultSettings() Settings {
	return Settings{
		AutoSyncClipboard:    true,
		ReceiveClipboard:     true,
		ClipboardMaxChars:    64 * 1024,
		AutoAcceptFiles:      true,
		ShareNotifications:   true,
		ReceiveNotifications: true,
		AllowMediaControl:    true,
		AllowAutomation:      false,
		Discoverable:         true,
		AcceptNewPairing:     true,
		RunInBackground:      true,
		StartOnLogin:         false,
		StartMinimized:       false,
		ShowAdvancedFeatures: false,
	}
}

// Normalise repairs values loaded from an older or hand-edited settings file so
// a missing field can never silently disable a feature or set a zero limit.
func (s *Settings) Normalise(defaultDownloadDir string) {
	if s.ClipboardMaxChars <= 0 {
		s.ClipboardMaxChars = 64 * 1024
	}
	if s.DownloadDir == "" {
		s.DownloadDir = defaultDownloadDir
	}
}

// Capabilities converts the receive-side settings into the capability list
// advertised to peers, so they can skip sending what this device would drop.
func (s *Settings) Capabilities() []string {
	caps := make([]string, 0, 5)
	if s.ReceiveClipboard {
		caps = append(caps, protocol.CapClipboard)
	}
	caps = append(caps, protocol.CapFiles) // files are always receivable (with a prompt)
	if s.ReceiveNotifications {
		caps = append(caps, protocol.CapNotifications)
	}
	if s.AllowMediaControl {
		caps = append(caps, protocol.CapMedia)
	}
	caps = append(caps, protocol.CapWorkspace)        // per-device AllowWorkspace gates this further; see TrustedDevice.Allows
	caps = append(caps, protocol.CapAdaptiveControls) // always receivable; running a control still goes through AllowWorkspace
	caps = append(caps, protocol.CapMinimizedApps)    // always receivable; restoring a window still goes through AllowWorkspace
	caps = append(caps, protocol.CapHealth)           // no toggle; always receivable
	return caps
}

// TrustedDevice is a paired member of the ecosystem, plus the per-device
// permissions that override the global settings for that one peer.
type TrustedDevice struct {
	DeviceID   string              `json:"device_id"`
	Name       string              `json:"name"`
	Platform   string              `json:"platform"`
	FormFactor protocol.FormFactor `json:"form_factor"`
	PublicKey  string              `json:"public_key"` // base64 Ed25519
	PairedAt   int64               `json:"paired_at"`  // unix millis
	LastSeen   int64               `json:"last_seen"`  // unix millis

	// Per-device switches. All default to true when a device is first paired
	// — including AllowWorkspace, which only gates whether this device can
	// send workspace actions at all. The actually-risky action (running a
	// shell command) has its own separate, off-by-default gate:
	// Settings.AllowAutomation, a global switch checked in addition to this
	// one, not instead of it.
	AllowClipboard     bool `json:"allow_clipboard"`
	AllowFiles         bool `json:"allow_files"`
	AllowNotifications bool `json:"allow_notifications"`
	AllowMedia         bool `json:"allow_media"`
	AllowWorkspace     bool `json:"allow_workspace"`
}

// UnmarshalJSON defaults AllowWorkspace to true when the on-disk record has
// no "allow_workspace" key at all — a device paired before this permission
// existed. Plain json.Unmarshal cannot distinguish "key absent" from
// "explicitly false" for a bool field, so without this, every
// already-paired device silently got AllowWorkspace=false (Go's zero value)
// the moment this field was added, even though every other capability here
// defaults to true for an existing device. The Dart side already handles
// this correctly via `json['allow_workspace'] as bool? ?? true`; this
// mirrors that.
func (d *TrustedDevice) UnmarshalJSON(data []byte) error {
	type alias TrustedDevice
	aux := struct {
		*alias
		AllowWorkspace *bool `json:"allow_workspace"`
	}{alias: (*alias)(d)}

	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}
	if aux.AllowWorkspace != nil {
		d.AllowWorkspace = *aux.AllowWorkspace
	} else {
		d.AllowWorkspace = true
	}
	return nil
}

// DefaultPermissions turns everything on for a newly paired device.
func (d *TrustedDevice) DefaultPermissions() {
	d.AllowClipboard = true
	d.AllowFiles = true
	d.AllowNotifications = true
	d.AllowMedia = true
	d.AllowWorkspace = true
}

// Allows reports whether a capability is permitted for this specific device.
func (d *TrustedDevice) Allows(capability string) bool {
	switch capability {
	case protocol.CapClipboard:
		return d.AllowClipboard
	case protocol.CapFiles:
		return d.AllowFiles
	case protocol.CapNotifications:
		return d.AllowNotifications
	case protocol.CapMedia:
		return d.AllowMedia
	case protocol.CapWorkspace:
		return d.AllowWorkspace
	}
	return false
}
