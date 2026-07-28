// Package workspace is the workspace plugin: it runs a user's own custom
// "My Workspace" buttons (keyboard shortcuts, opening an app/folder/URL, or
// running a shell command) that a phone sends. Like remote-input, this is a
// one-way, phone-triggers-local-action plugin with no broadcast state.
//
// It has no knowledge of Wails or the frontend — it only uses the
// core/plugin API it is handed by Init, per the plugin architecture (see
// desktop/plugins/remoteinput, media, etc. for the same shape).
package workspace

import (
	"context"
	"encoding/json"
	"fmt"

	"wedrop/core/plugin"
	"wedrop/core/protocol"
)

// ID is this plugin's stable identifier and capability string.
const ID plugin.ID = protocol.CapWorkspace

// Settings is this plugin's own settings, bridged for now from the shared
// storage.Settings by the host (see desktop/service.go
// pluginHost.LoadPluginSettings), the same way media/remoteinput already are.
type Settings struct {
	// AllowAutomation gates only WorkspaceShellCommand — a device having
	// been granted the "workspace" capability at all (checked separately,
	// per-device, via p.api.Allows) does not by itself permit shell
	// commands; see protocol.WorkspaceAction's own doc comment.
	AllowAutomation bool `json:"allow_automation"`
}

// Plugin implements plugin.Plugin for running workspace button actions.
type Plugin struct {
	api plugin.API
}

// New creates the workspace plugin.
func New() *Plugin { return &Plugin{} }

func (p *Plugin) ID() plugin.ID { return ID }

func (p *Plugin) MessageTypes() []protocol.MessageType {
	return []protocol.MessageType{protocol.TypeWorkspaceAction}
}

func (p *Plugin) Init(api plugin.API) error {
	p.api = api
	return nil
}

func (p *Plugin) HandleMessage(from plugin.PeerRef, msgType protocol.MessageType, raw []byte) error {
	if !p.api.Allows(from.DeviceID) {
		return nil
	}

	var msg protocol.WorkspaceAction
	if err := json.Unmarshal(raw, &msg); err != nil {
		return err
	}

	if msg.Action == protocol.WorkspaceShellCommand && !p.settings().AllowAutomation {
		return fmt.Errorf("shell/script commands are not allowed from this device")
	}

	if err := runAction(msg); err != nil {
		return err
	}
	p.api.Emit("applied", msg.Action)
	return nil
}

func (p *Plugin) OnPeerConnected(peer plugin.PeerRef) {}
func (p *Plugin) OnPeerDisconnected(deviceID string)  {}
func (p *Plugin) Start(ctx context.Context) error     { return nil }
func (p *Plugin) Stop()                               {}

func (p *Plugin) settings() Settings {
	var s Settings
	_ = json.Unmarshal(p.api.Settings(), &s)
	return s
}
