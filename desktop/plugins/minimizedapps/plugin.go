// Package minimizedapps is the minimized-apps widget's plugin: it detects the
// peer's currently-minimized top-level windows and pushes them to a paired
// phone, so tapping one can restore and focus it. Broadcast-only, shaped
// exactly like desktop/plugins/adaptivecontrols (poll on a ticker, broadcast
// only on change, gated by the workspace capability) — restoring a window is
// itself just a protocol.WorkspaceAction (WorkspaceRestoreWindow), executed
// by the existing workspace plugin, so this package adds detection and
// schema broadcast only, no new execution path.
package minimizedapps

import (
	"context"
	"fmt"
	"strings"
	"time"

	"wedrop/core/plugin"
	"wedrop/core/protocol"
)

// ID is this plugin's stable identifier and the capability it advertises —
// necessarily distinct from protocol.CapWorkspace (a plugin ID must be
// unique per Registry.Register), but the real authorization for restoring a
// window still goes through the workspace plugin's own AllowWorkspace check;
// see the AllowsCapability call in sendTo.
const ID plugin.ID = protocol.CapMinimizedApps

// pollInterval: cheap enough (one EnumWindows pass plus a handful of
// per-window syscalls) to poll this often without meaningfully taxing the
// desktop, frequent enough that minimizing/restoring something elsewhere
// shows up promptly.
const pollInterval = 2 * time.Second

// Plugin implements plugin.Plugin for the minimized-apps widget.
type Plugin struct {
	api    plugin.API
	cancel context.CancelFunc
	last   string // fingerprint of the last-broadcast window list
}

// New creates the minimized-apps plugin.
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

// OnPeerConnected sends the current list to just this peer, so it does not
// have to wait for the next change to see what's already minimized.
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
			p.checkMinimizedWindows()
		}
	}
}

func (p *Plugin) checkMinimizedWindows() {
	peers := p.api.ConnectedPeers()
	if len(peers) == 0 {
		return
	}

	state := p.currentState()
	fp := fingerprint(state)
	if fp == p.last {
		return
	}
	p.last = fp

	for _, peer := range peers {
		p.sendTo(peer.DeviceID, state)
	}
}

// sendTo delivers state to one peer, but only if that peer has actually been
// granted AllowWorkspace — this plugin's own capability (CapMinimizedApps)
// only gates whether the peer understands the message type at all; the real
// authorization to restore a window (or be told what's minimized) reuses the
// exact same permission as any other workspace action.
func (p *Plugin) sendTo(deviceID string, state protocol.MinimizedAppsState) {
	if !p.api.AllowsCapability(deviceID, protocol.CapWorkspace) {
		return
	}
	_ = p.api.Send(deviceID, state)
}

func (p *Plugin) currentState() protocol.MinimizedAppsState {
	return protocol.MinimizedAppsState{
		Type:    protocol.TypeMinimizedApps,
		Windows: currentMinimizedWindows(),
	}
}

// fingerprint gives a cheap, order-sensitive way to detect "nothing changed"
// without keeping a full previous slice around.
func fingerprint(state protocol.MinimizedAppsState) string {
	var b strings.Builder
	for _, w := range state.Windows {
		fmt.Fprintf(&b, "%d:%s|", w.ID, w.Title)
	}
	return b.String()
}
