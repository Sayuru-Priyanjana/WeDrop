package storage

import "wedrop/core/protocol"

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
	AutoSyncClipboard    bool `json:"auto_sync_clipboard"`    // send my clipboard automatically
	ReceiveClipboard     bool `json:"receive_clipboard"`      // apply clipboard from peers
	ClipboardMaxChars    int  `json:"clipboard_max_chars"`    // skip anything larger
	// Files
	AutoAcceptFiles bool   `json:"auto_accept_files"` // accept without prompting (trusted only)
	DownloadDir     string `json:"download_dir"`
	// Notifications
	ShareNotifications   bool `json:"share_notifications"`   // mirror mine to peers
	ReceiveNotifications bool `json:"receive_notifications"` // show peers' notifications
	// Media
	AllowMediaControl bool `json:"allow_media_control"` // let peers control my playback
	// Discovery & lifecycle
	Discoverable    bool `json:"discoverable"`      // announce over UDP
	AcceptNewPairing bool `json:"accept_new_pairing"` // consider pairing requests
	RunInBackground bool `json:"run_in_background"`  // keep running when window closes
	StartOnLogin    bool `json:"start_on_login"`
	StartMinimized  bool `json:"start_minimized"`
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
	caps := make([]string, 0, 4)
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

	// Per-device switches. All default to true when a device is first paired.
	AllowClipboard     bool `json:"allow_clipboard"`
	AllowFiles         bool `json:"allow_files"`
	AllowNotifications bool `json:"allow_notifications"`
	AllowMedia         bool `json:"allow_media"`
}

// DefaultPermissions turns everything on for a newly paired device.
func (d *TrustedDevice) DefaultPermissions() {
	d.AllowClipboard = true
	d.AllowFiles = true
	d.AllowNotifications = true
	d.AllowMedia = true
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
	}
	return false
}
