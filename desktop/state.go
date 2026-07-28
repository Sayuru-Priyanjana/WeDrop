package main

import (
	"wedrop/core/protocol"
	"wedrop/core/storage"
)

// DeviceView is one row in the UI's device list. It merges what we know from
// the trust store with live discovery and session state, so the frontend never
// has to correlate three separate lists itself.
type DeviceView struct {
	DeviceID   string              `json:"device_id"`
	Name       string              `json:"name"`
	Platform   string              `json:"platform"`
	FormFactor protocol.FormFactor `json:"form_factor"`
	IP         string              `json:"ip"`

	Paired    bool `json:"paired"`
	Online    bool `json:"online"`    // announcing itself over UDP
	Connected bool `json:"connected"` // encrypted session is up
	Battery   int  `json:"battery"`

	AllowClipboard     bool `json:"allow_clipboard"`
	AllowFiles         bool `json:"allow_files"`
	AllowNotifications bool `json:"allow_notifications"`
	AllowMedia         bool `json:"allow_media"`
	AllowWorkspace     bool `json:"allow_workspace"`

	PairedAt int64 `json:"paired_at"`
	LastSeen int64 `json:"last_seen"`

	// Live telemetry from the peer, present only while connected.
	Health *protocol.DeviceHealth `json:"health,omitempty"`
	Media  *protocol.MediaState   `json:"media,omitempty"`
}

// PairingPrompt is an inbound request awaiting the user's decision.
type PairingPrompt struct {
	DeviceID         string              `json:"device_id"`
	Name             string              `json:"name"`
	Platform         string              `json:"platform"`
	FormFactor       protocol.FormFactor `json:"form_factor"`
	VerificationCode string              `json:"verification_code"`
	Address          string              `json:"address"`
	ExpiresAt        int64               `json:"expires_at"`
}

// TransferState is the lifecycle of one file transfer.
type TransferState string

const (
	TransferPending   TransferState = "pending" // waiting for the user to accept
	TransferActive    TransferState = "active"
	TransferCompleted TransferState = "completed"
	TransferFailed    TransferState = "failed"
	TransferDeclined  TransferState = "declined"
)

// TransferView describes a transfer for the UI.
type TransferView struct {
	ID          string        `json:"id"`
	DeviceID    string        `json:"device_id"`
	DeviceName  string        `json:"device_name"`
	Filename    string        `json:"filename"`
	Size        int64         `json:"size"`
	Transferred int64         `json:"transferred"`
	Incoming    bool          `json:"incoming"`
	State       TransferState `json:"state"`
	Error       string        `json:"error,omitempty"`
	SavedPath   string        `json:"saved_path,omitempty"`
	StartedAt   int64         `json:"started_at"`
	UpdatedAt   int64         `json:"updated_at"`
}

// NotificationView is a mirrored notification held in the local feed.
type NotificationView struct {
	ID         string `json:"id"`
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"`
	App        string `json:"app"`
	Title      string `json:"title"`
	Body       string `json:"body"`
	Time       int64  `json:"time"`
	Read       bool   `json:"read"`
}

// ClipboardEntry is one item of clipboard history.
type ClipboardEntry struct {
	Text       string `json:"text"`
	Origin     string `json:"origin"`
	OriginName string `json:"origin_name"`
	Time       int64  `json:"time"`
	Incoming   bool   `json:"incoming"`
}

// AppState is the single snapshot the frontend renders from.
type AppState struct {
	Ready      bool               `json:"ready"`
	Error      string             `json:"error,omitempty"`
	Self       DeviceView         `json:"self"`
	PublicKey  string             `json:"public_key"`
	Settings   storage.Settings   `json:"settings"`
	Paired     []DeviceView       `json:"paired"`
	Discovered []DeviceView       `json:"discovered"`
	Transfers  []TransferView     `json:"transfers"`
	Clipboard  []ClipboardEntry   `json:"clipboard"`
	Notifs     []NotificationView `json:"notifications"`
	Pairing    *PairingPrompt     `json:"pairing"`
	ListenPort int                `json:"listen_port"`
}
