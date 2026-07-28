// Package health is the device-health plugin: it periodically broadcasts
// this device's battery/CPU/memory/network vitals and remembers the last
// reading each peer sent, so the UI can render a status panel per device.
//
// It has no knowledge of Wails or the frontend — it only uses the
// core/plugin API it is handed by Init, per the plugin-architecture
// refactor plan.
package health

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"wedrop/core/plugin"
	"wedrop/core/protocol"
)

// ID is this plugin's stable identifier and capability string.
const ID plugin.ID = "device-health"

// broadcastInterval is how often vitals are refreshed and broadcast.
const broadcastInterval = 8 * time.Second

// Plugin implements plugin.Plugin for device health.
type Plugin struct {
	deviceID string
	api      plugin.API

	mu    sync.RWMutex
	peers map[string]protocol.DeviceHealth

	cancel context.CancelFunc
}

// New creates the health plugin for this device's own identity.
func New(deviceID string) *Plugin {
	return &Plugin{
		deviceID: deviceID,
		peers:    make(map[string]protocol.DeviceHealth),
	}
}

func (p *Plugin) ID() plugin.ID { return ID }

func (p *Plugin) MessageTypes() []protocol.MessageType {
	return []protocol.MessageType{protocol.TypeHealth}
}

func (p *Plugin) Init(api plugin.API) error {
	p.api = api
	return nil
}

func (p *Plugin) HandleMessage(from plugin.PeerRef, msgType protocol.MessageType, raw []byte) error {
	var msg protocol.DeviceHealth
	if err := json.Unmarshal(raw, &msg); err != nil {
		return err
	}
	p.mu.Lock()
	p.peers[from.DeviceID] = msg
	p.mu.Unlock()
	p.api.Emit("changed", nil)
	return nil
}

func (p *Plugin) OnPeerConnected(peer plugin.PeerRef) {}

// OnPeerDisconnected drops a peer's last-known reading — GetState only ever
// reads it while the peer shows connected, so this is housekeeping rather
// than a visible behaviour change.
func (p *Plugin) OnPeerDisconnected(deviceID string) {
	p.mu.Lock()
	delete(p.peers, deviceID)
	p.mu.Unlock()
}

func (p *Plugin) Start(ctx context.Context) error {
	runCtx, cancel := context.WithCancel(ctx)
	p.cancel = cancel
	go p.broadcastLoop(runCtx)
	return nil
}

func (p *Plugin) Stop() {
	if p.cancel != nil {
		p.cancel()
	}
}

// broadcastLoop periodically sends this device's vitals to the ecosystem so
// remotes can render a live status panel.
func (p *Plugin) broadcastLoop(ctx context.Context) {
	// Prime the CPU sampler and send an initial reading shortly after start,
	// rather than making the remote wait a full interval for anything to show.
	collectHealth(p.deviceID)

	ticker := time.NewTicker(broadcastInterval)
	defer ticker.Stop()

	first := time.NewTimer(2 * time.Second)
	defer first.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-first.C:
			p.broadcast()
		case <-ticker.C:
			p.broadcast()
		}
	}
}

func (p *Plugin) broadcast() {
	if len(p.api.ConnectedPeers()) == 0 {
		return
	}
	p.api.Broadcast(collectHealth(p.deviceID))
}

// HealthOf returns the last known health reading for a peer, if any — used
// by the host (desktop/api.go) to populate DeviceView.Health.
func (p *Plugin) HealthOf(deviceID string) (protocol.DeviceHealth, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	h, ok := p.peers[deviceID]
	return h, ok
}
