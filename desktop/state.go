package main

import (
	"sync"
	"time"

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

// ringBuffer keeps the most recent N items of a feed without growing forever.
// The clipboard and notification feeds are append-only from the user's point of
// view, and an app expected to run for weeks in the background cannot hold
// every item it ever saw.
type ringBuffer[T any] struct {
	mu    sync.Mutex
	items []T
	limit int
}

func newRingBuffer[T any](limit int) *ringBuffer[T] {
	return &ringBuffer[T]{limit: limit, items: make([]T, 0, limit)}
}

// Push adds an item to the front, dropping the oldest if the buffer is full.
func (r *ringBuffer[T]) Push(item T) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.items = append([]T{item}, r.items...)
	if len(r.items) > r.limit {
		r.items = r.items[:r.limit]
	}
}

// Snapshot returns a copy of the current contents, newest first.
func (r *ringBuffer[T]) Snapshot() []T {
	r.mu.Lock()
	defer r.mu.Unlock()

	out := make([]T, len(r.items))
	copy(out, r.items)
	return out
}

// Clear empties the buffer.
func (r *ringBuffer[T]) Clear() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.items = r.items[:0]
}

// Update applies fn to every item, keeping those fn returns true for.
func (r *ringBuffer[T]) Update(fn func(*T)) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := range r.items {
		fn(&r.items[i])
	}
}

func nowMillis() int64 { return time.Now().UnixMilli() }
