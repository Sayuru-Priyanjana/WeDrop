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
	cancel  context.CancelFunc
	lastApp string // last-broadcast app name; "" means "nothing recognized"
}

// New creates the adaptive-controls plugin.
func New() *Plugin { return &Plugin{} }

func (p *Plugin) ID() plugin.ID { return ID }

// MessageTypes is empty: this plugin only ever sends, never receives.
func (p *Plugin) MessageTypes() []protocol.MessageType { return nil }

func (p *Plugin) Init(api plugin.API) error {
	p.api = api
	return nil
}

func (p *Plugin) HandleMessage(from plugin.PeerRef, msgType protocol.MessageType, raw []byte) error {
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
	controls, appName := profileFor(currentForegroundProcess())
	return protocol.AdaptiveControlsState{
		Type:     protocol.TypeAdaptiveControls,
		AppName:  appName,
		Controls: controls,
	}
}
