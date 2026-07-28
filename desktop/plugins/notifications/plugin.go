// Package notifications is the notifications plugin: it keeps a local feed
// of notifications mirrored from paired devices.
//
// It has no knowledge of Wails or the frontend — it only uses the
// core/plugin API it is handed by Init, per the plugin-architecture
// refactor plan.
package notifications

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"wedrop/core/plugin"
	"wedrop/core/protocol"
)

// ID is this plugin's stable identifier and capability string.
const ID plugin.ID = "notifications"

// feedLimit caps the local feed so an app running for weeks in the
// background does not hold every notification it ever mirrored.
const feedLimit = 100

// View is a mirrored notification held in the local feed.
type View struct {
	ID         string `json:"id"`
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"`
	App        string `json:"app"`
	Title      string `json:"title"`
	Body       string `json:"body"`
	Time       int64  `json:"time"`
	Read       bool   `json:"read"`
}

// Settings is this plugin's own settings, bridged for now from
// storage.Settings.ReceiveNotifications by the host (see desktop/service.go
// pluginHost.LoadPluginSettings) until the settings/capability
// de-hardcoding migration gives every plugin real persisted settings.
type Settings struct {
	Receive bool `json:"receive"`
}

// Plugin implements plugin.Plugin for notification mirroring.
type Plugin struct {
	api plugin.API
	// deviceName resolves a peer's display name — the trusted name if set,
	// else the session's advertised name, else a short form of the ID.
	deviceName func(deviceID, fallback string) string

	mu    sync.Mutex
	items []View
}

// New creates the notifications plugin.
func New(deviceName func(deviceID, fallback string) string) *Plugin {
	return &Plugin{deviceName: deviceName, items: make([]View, 0, feedLimit)}
}

func (p *Plugin) ID() plugin.ID { return ID }

func (p *Plugin) MessageTypes() []protocol.MessageType {
	return []protocol.MessageType{protocol.TypeNotification}
}

func (p *Plugin) Init(api plugin.API) error {
	p.api = api
	return nil
}

func (p *Plugin) HandleMessage(from plugin.PeerRef, msgType protocol.MessageType, raw []byte) error {
	var settings Settings
	_ = json.Unmarshal(p.api.Settings(), &settings)
	if !settings.Receive {
		return nil
	}
	if !p.api.Allows(from.DeviceID) {
		return nil
	}

	var msg protocol.NotificationMessage
	if err := json.Unmarshal(raw, &msg); err != nil {
		return err
	}

	view := View{
		ID:         msg.ID,
		DeviceID:   from.DeviceID,
		DeviceName: p.deviceName(from.DeviceID, from.Info.Name),
		App:        msg.App,
		Title:      msg.Title,
		Body:       msg.Body,
		Time:       msg.Time,
	}
	if view.Time == 0 {
		view.Time = time.Now().UnixMilli()
	}

	p.push(view)
	p.api.Emit("received", view)
	return nil
}

func (p *Plugin) push(item View) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.items = append([]View{item}, p.items...)
	if len(p.items) > feedLimit {
		p.items = p.items[:feedLimit]
	}
}

func (p *Plugin) OnPeerConnected(peer plugin.PeerRef) {}
func (p *Plugin) OnPeerDisconnected(deviceID string)  {}
func (p *Plugin) Start(ctx context.Context) error     { return nil }
func (p *Plugin) Stop()                               {}

// Snapshot returns a copy of the feed, newest first — used by the host
// (desktop/api.go) to populate AppState.Notifs.
func (p *Plugin) Snapshot() []View {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]View, len(p.items))
	copy(out, p.items)
	return out
}

// MarkAllRead marks every item in the feed read.
func (p *Plugin) MarkAllRead() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for i := range p.items {
		p.items[i].Read = true
	}
}

// Clear empties the feed.
func (p *Plugin) Clear() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.items = p.items[:0]
}
