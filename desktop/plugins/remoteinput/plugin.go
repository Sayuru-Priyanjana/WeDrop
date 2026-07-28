// Package remoteinput is the remote-input plugin: it injects mouse,
// keyboard, and presentation-control events a paired device sends, turning
// a phone into a touchpad/keyboard/presentation remote for this machine.
//
// It has no knowledge of Wails or the frontend — it only uses the
// core/plugin API it is handed by Init, per the plugin-architecture
// refactor plan. Platform backends (input_windows.go/input_other.go,
// relocated unchanged from desktop/input_*.go) live in this same package
// and are called directly, since they were never exported outside package
// main to begin with.
package remoteinput

import (
	"context"
	"encoding/json"

	"wedrop/core/plugin"
	"wedrop/core/protocol"
)

// ID is this plugin's stable identifier. Unlike every other plugin, this is
// not also its wire capability string: remote input is never broadcast
// (always a direct, targeted send), so it has no need to be advertised in
// DeviceInfo.Capabilities.
const ID plugin.ID = "remote-input"

// Settings is this plugin's own settings, bridged for now from the shared
// storage.Settings by the host (see desktop/service.go
// pluginHost.LoadPluginSettings) until the settings/capability
// de-hardcoding migration gives every plugin real persisted settings.
type Settings struct {
	AllowControl bool `json:"allow_control"`
}

// Plugin implements plugin.Plugin for remote input injection.
type Plugin struct {
	api plugin.API
}

// New creates the remote-input plugin.
func New() *Plugin { return &Plugin{} }

func (p *Plugin) ID() plugin.ID { return ID }

func (p *Plugin) MessageTypes() []protocol.MessageType {
	return []protocol.MessageType{protocol.TypeRemoteInput}
}

func (p *Plugin) Init(api plugin.API) error {
	p.api = api
	return nil
}

func (p *Plugin) HandleMessage(from plugin.PeerRef, msgType protocol.MessageType, raw []byte) error {
	if !p.settings().AllowControl {
		return nil
	}
	// Remote control is gated by the same per-device media permission as
	// the media keys — turning off "control my media" also disarms the
	// touchpad and keyboard, so one switch covers "let this device drive
	// me". This deliberately checks the media capability, not this
	// plugin's own ID.
	if !p.api.AllowsCapability(from.DeviceID, protocol.CapMedia) {
		return nil
	}

	var msg protocol.RemoteInput
	if err := json.Unmarshal(raw, &msg); err != nil {
		return err
	}
	applyRemoteInput(msg)
	return nil
}

func (p *Plugin) OnPeerConnected(peer plugin.PeerRef) {}
func (p *Plugin) OnPeerDisconnected(deviceID string)  {}
func (p *Plugin) Start(ctx context.Context) error     { return nil }
func (p *Plugin) Stop()                               {}

// SendInput delivers one remote-input event to a peer — used by the host
// (desktop/api.go) for the Wails-bound Send{MouseMove,MouseClick,Scroll,
// Text,Key,Presentation} methods.
func (p *Plugin) SendInput(deviceID string, input protocol.RemoteInput) error {
	return p.api.Send(deviceID, input)
}

func (p *Plugin) settings() Settings {
	var s Settings
	_ = json.Unmarshal(p.api.Settings(), &s)
	return s
}
