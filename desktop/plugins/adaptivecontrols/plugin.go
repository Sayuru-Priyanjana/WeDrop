// Package adaptivecontrols is the dynamic-controls plugin: it detects which
// desktop app is currently focused and pushes an adaptive set of controls
// for that app, so a paired phone can render them generically with no
// per-app layout hardcoded on the mobile side.
//
// It is broadcast-only — no message type flows the other way. Every
// control's Action reuses protocol.WorkspaceAction verbatim (a keyboard
// shortcut, in every built-in profile), so tapping one on the phone is
// literally a workspace-action send the existing workspace plugin already
// executes; this plugin adds detection and schema broadcast only, no new
// execution path.
package adaptivecontrols

import (
	"context"
	"encoding/json"
	"time"

	"wedrop/core/plugin"
	"wedrop/core/protocol"
)

// ID is this plugin's stable identifier and the capability it advertises —
// necessarily distinct from protocol.CapWorkspace (a plugin ID must be
// unique per Registry.Register), but the real authorization for what a
// control's action actually does still goes through the workspace plugin's
// own AllowWorkspace check; see the AllowsCapability call in checkPeers.
const ID plugin.ID = protocol.CapAdaptiveControls

// pollInterval trades responsiveness for cost: cheap enough to poll this
// often (two syscalls plus a process-name lookup), frequent enough that
// switching focus feels immediate.
const pollInterval = 1500 * time.Millisecond

// Plugin implements plugin.Plugin for adaptive per-app controls.
type Plugin struct {
	api     plugin.API
	store   *Store
	cancel  context.CancelFunc
	lastApp string // last-broadcast app name; "" means "nothing recognized"
}

// New creates the adaptive-controls plugin. path is where its editable
// per-app action profiles are persisted (see store.go) — plain JSON, no
// encryption needed since none of this is sensitive, unlike settings.json.
func New(path string) *Plugin {
	return &Plugin{store: newStore(path)}
}

// Store exposes the plugin's app-action profile store to desktop/api.go's
// Wails-bound methods, so the frontend's App Actions editor can read and
// edit it directly.
func (p *Plugin) Store() *Store { return p.store }

func (p *Plugin) ID() plugin.ID { return ID }

// MessageTypes: broadcast-only for the controls themselves, but this plugin
// also receives one thing from the phone — a request to open the desktop's
// App Actions editor for the app currently on screen (see HandleMessage).
func (p *Plugin) MessageTypes() []protocol.MessageType {
	return []protocol.MessageType{protocol.TypeConfigureApp}
}

func (p *Plugin) Init(api plugin.API) error {
	p.api = api
	return nil
}

func (p *Plugin) HandleMessage(from plugin.PeerRef, msgType protocol.MessageType, raw []byte) error {
	// This plugin's own capability (CapAdaptiveControls) has no case in
	// TrustedDevice.Allows — it exists only so a peer can advertise "I
	// understand this message type" (see the ID doc comment above). The
	// real authorization is the same AllowWorkspace permission every other
	// workspace action already goes through.
	if !p.api.AllowsCapability(from.DeviceID, protocol.CapWorkspace) {
		return nil
	}

	var msg protocol.ConfigureAppRequest
	if err := json.Unmarshal(raw, &msg); err != nil {
		return err
	}
	if msg.AppName == "" {
		return nil
	}

	// Bring the desktop window to front and tell its frontend which app to
	// preselect in the App Actions editor — see pluginHost.Emit's
	// adaptivecontrols.ID case in desktop/service.go for the event bridge.
	p.api.ShowWindow()
	p.api.Emit("configure", msg.AppName)
	return nil
}

// OnPeerConnected sends the current state to just this peer, so it does not
// have to wait for the next app switch to see what is already focused.
func (p *Plugin) OnPeerConnected(peer plugin.PeerRef) {
	p.sendTo(peer.DeviceID, p.currentState())
}

func (p *Plugin) OnPeerDisconnected(deviceID string) {}

func (p *Plugin) Start(ctx context.Context) error {
	runCtx, cancel := context.WithCancel(ctx)
	p.cancel = cancel
	go p.loop(runCtx)
	return nil
}

func (p *Plugin) Stop() {
	if p.cancel != nil {
		p.cancel()
	}
}

func (p *Plugin) loop(ctx context.Context) {
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			p.checkForegroundApp()
		}
	}
}

func (p *Plugin) checkForegroundApp() {
	peers := p.api.ConnectedPeers()
	if len(peers) == 0 {
		return
	}

	state := p.currentState()
	if state.AppName == p.lastApp {
		return
	}
	p.lastApp = state.AppName

	for _, peer := range peers {
		p.sendTo(peer.DeviceID, state)
	}
}

// sendTo delivers state to one peer, but only if that peer has actually
// been granted AllowWorkspace — this plugin's own capability
// (CapAdaptiveControls) only gates whether the peer understands the
// message type at all; the real authorization to act on a control (or, for
// that matter, to be told what's running) reuses the exact same permission
// as any other workspace action.
func (p *Plugin) sendTo(deviceID string, state protocol.AdaptiveControlsState) {
	if !p.api.AllowsCapability(deviceID, protocol.CapWorkspace) {
		return
	}
	_ = p.api.Send(deviceID, state)
}

func (p *Plugin) currentState() protocol.AdaptiveControlsState {
	exe := currentForegroundProcess()
	if exe == "" || selfExeNames[exe] {
		return protocol.AdaptiveControlsState{Type: protocol.TypeAdaptiveControls}
	}

	if profile, ok := p.store.Get(exe); ok {
		return protocol.AdaptiveControlsState{
			Type:     protocol.TypeAdaptiveControls,
			AppName:  profile.DisplayName,
			Exe:      exe,
			Controls: toProtocolControls(profile.Actions),
		}
	}

	// No profile for this app — report its name and exe (so the phone can
	// offer "Configure this app") but zero predefined controls. Deliberately
	// no generic fallback: an app with nothing configured shows nothing
	// until the user configures it, rather than the same nine buttons every
	// app used to get.
	return protocol.AdaptiveControlsState{
		Type:    protocol.TypeAdaptiveControls,
		AppName: friendlyName(exe),
		Exe:     exe,
	}
}

func toProtocolControls(actions []AppAction) []protocol.AdaptiveControl {
	out := make([]protocol.AdaptiveControl, len(actions))
	for i, a := range actions {
		out[i] = protocol.AdaptiveControl{
			ID:     a.ID,
			Label:  a.Label,
			Icon:   a.Icon,
			Color:  a.ColorValue,
			Action: a.Action,
		}
	}
	return out
}
