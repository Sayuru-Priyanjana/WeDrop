// Package clipboard is the clipboard plugin: it watches the local clipboard
// and syncs it to paired devices, and applies clipboard text received from
// them.
//
// It has no knowledge of Wails or the frontend — it only uses the
// core/plugin API it is handed by Init, per the plugin-architecture
// refactor plan.
package clipboard

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/atotto/clipboard"

	"wedrop/core/crypto"
	"wedrop/core/plugin"
	"wedrop/core/protocol"
)

// ID is this plugin's stable identifier and capability string.
const ID plugin.ID = protocol.CapClipboard

// pollInterval is how often the local clipboard is read. Windows offers no
// cheap change notification without a message loop, so this polls — but it
// only compares a hash and does nothing else when unchanged, which is the
// overwhelmingly common case.
const pollInterval = 700 * time.Millisecond

// feedLimit caps the local history feed.
const feedLimit = 50

// Entry is one item of clipboard history.
type Entry struct {
	Text       string `json:"text"`
	Origin     string `json:"origin"`
	OriginName string `json:"origin_name"`
	Time       int64  `json:"time"`
	Incoming   bool   `json:"incoming"`
}

// Settings is this plugin's own settings, bridged for now from the shared
// storage.Settings by the host (see desktop/service.go
// pluginHost.LoadPluginSettings) until the settings/capability
// de-hardcoding migration gives every plugin real persisted settings.
type Settings struct {
	AutoSync bool `json:"auto_sync"`
	Receive  bool `json:"receive"`
	MaxChars int  `json:"max_chars"`
}

// Plugin implements plugin.Plugin for clipboard sync.
type Plugin struct {
	api      plugin.API
	deviceID string
	// deviceName returns this device's own current display name.
	deviceName func() string
	// resolveName resolves a peer's display name — the trusted name if set,
	// else the session's advertised name (passed as fallback).
	resolveName func(deviceID, fallback string) string

	mu       sync.Mutex
	items    []Entry
	lastHash string
	seq      int64

	cancel context.CancelFunc
}

// New creates the clipboard plugin for this device's own identity.
func New(deviceID string, deviceName func() string, resolveName func(deviceID, fallback string) string) *Plugin {
	return &Plugin{
		deviceID:    deviceID,
		deviceName:  deviceName,
		resolveName: resolveName,
		items:       make([]Entry, 0, feedLimit),
	}
}

func (p *Plugin) ID() plugin.ID { return ID }

func (p *Plugin) MessageTypes() []protocol.MessageType {
	return []protocol.MessageType{protocol.TypeClipboard}
}

func (p *Plugin) Init(api plugin.API) error {
	p.api = api
	return nil
}

func (p *Plugin) HandleMessage(from plugin.PeerRef, msgType protocol.MessageType, raw []byte) error {
	settings := p.settings()
	if !settings.Receive {
		return nil
	}
	if !p.api.Allows(from.DeviceID) {
		return nil
	}

	var msg protocol.ClipboardMessage
	if err := json.Unmarshal(raw, &msg); err != nil {
		return err
	}
	if msg.Text == "" || len(msg.Text) > settings.MaxChars {
		return nil
	}

	hash := msg.Hash
	if hash == "" {
		hash = crypto.HashBytes([]byte(msg.Text))
	}

	// Record the hash before writing, so our own watcher does not see the
	// text we just pasted in as a fresh local copy and bounce it back
	// around the ecosystem forever.
	p.mu.Lock()
	if hash == p.lastHash {
		p.mu.Unlock()
		return nil
	}
	p.lastHash = hash
	p.mu.Unlock()

	if err := clipboard.WriteAll(msg.Text); err != nil {
		return err
	}

	name := p.resolveName(from.DeviceID, from.Info.Name)
	p.push(Entry{
		Text:       msg.Text,
		Origin:     from.DeviceID,
		OriginName: name,
		Time:       time.Now().UnixMilli(),
		Incoming:   true,
	})
	p.api.Emit("received", name)
	return nil
}

func (p *Plugin) OnPeerConnected(peer plugin.PeerRef) {}
func (p *Plugin) OnPeerDisconnected(deviceID string)  {}

func (p *Plugin) Start(ctx context.Context) error {
	runCtx, cancel := context.WithCancel(ctx)
	p.cancel = cancel
	go p.pollLoop(runCtx)
	return nil
}

func (p *Plugin) Stop() {
	if p.cancel != nil {
		p.cancel()
	}
}

func (p *Plugin) pollLoop(ctx context.Context) {
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			p.checkClipboard()
		}
	}
}

func (p *Plugin) checkClipboard() {
	settings := p.settings()
	if !settings.AutoSync {
		return
	}
	// Nothing to broadcast to, so do not even touch the clipboard.
	if len(p.api.ConnectedPeers()) == 0 {
		return
	}

	text, err := clipboard.ReadAll()
	if err != nil || text == "" {
		return
	}
	if len(text) > settings.MaxChars {
		return
	}

	hash := crypto.HashBytes([]byte(text))

	p.mu.Lock()
	if hash == p.lastHash {
		p.mu.Unlock()
		return
	}
	p.lastHash = hash
	p.seq++
	seq := p.seq
	p.mu.Unlock()

	p.push(Entry{
		Text:       text,
		Origin:     p.deviceID,
		OriginName: p.deviceName(),
		Time:       time.Now().UnixMilli(),
	})

	p.api.Broadcast(protocol.ClipboardMessage{
		Type:     protocol.TypeClipboard,
		Text:     text,
		Origin:   p.deviceID,
		Sequence: seq,
		Hash:     hash,
	})
	p.api.Emit("changed", nil)
}

// PushNow sends the current clipboard to the ecosystem immediately,
// regardless of the auto-sync setting — what the "Send clipboard now"
// button does when auto-sync is off.
func (p *Plugin) PushNow() error {
	text, err := clipboard.ReadAll()
	if err != nil {
		return fmt.Errorf("could not read the clipboard: %w", err)
	}
	if text == "" {
		return fmt.Errorf("the clipboard is empty")
	}
	if len(p.api.ConnectedPeers()) == 0 {
		return fmt.Errorf("no devices are connected right now")
	}

	hash := crypto.HashBytes([]byte(text))
	p.mu.Lock()
	p.seq++
	seq := p.seq
	p.lastHash = hash
	p.mu.Unlock()

	p.push(Entry{
		Text:       text,
		Origin:     p.deviceID,
		OriginName: p.deviceName(),
		Time:       time.Now().UnixMilli(),
	})

	p.api.Broadcast(protocol.ClipboardMessage{
		Type:     protocol.TypeClipboard,
		Text:     text,
		Origin:   p.deviceID,
		Sequence: seq,
		Hash:     hash,
	})
	p.api.Emit("changed", nil)
	return nil
}

// SetClipboard puts a history entry back on the local clipboard (what
// tapping a history item does), recording its hash so the watcher does not
// immediately re-broadcast it as if it were new.
func (p *Plugin) SetClipboard(text string) error {
	if text == "" {
		return nil
	}
	p.mu.Lock()
	p.lastHash = crypto.HashBytes([]byte(text))
	p.mu.Unlock()
	return clipboard.WriteAll(text)
}

func (p *Plugin) push(item Entry) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.items = append([]Entry{item}, p.items...)
	if len(p.items) > feedLimit {
		p.items = p.items[:feedLimit]
	}
}

// Snapshot returns a copy of the feed, newest first — used by the host
// (desktop/api.go) to populate AppState.Clipboard.
func (p *Plugin) Snapshot() []Entry {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]Entry, len(p.items))
	copy(out, p.items)
	return out
}

// Clear empties the history feed.
func (p *Plugin) Clear() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.items = p.items[:0]
}

func (p *Plugin) settings() Settings {
	var s Settings
	_ = json.Unmarshal(p.api.Settings(), &s)
	return s
}
