// Package media is the media plugin: it applies remote play/pause/seek/
// volume commands to whatever is playing locally, and periodically shares
// what this device is playing so a paired remote can render and control it.
//
// It has no knowledge of Wails or the frontend — it only uses the
// core/plugin API it is handed by Init, per the plugin-architecture
// refactor plan. Platform backends (media_smtc_windows.go-derived
// smtc_windows.go, volume_windows.go, etc., relocated unchanged from
// desktop/media_*.go) live in this same package and are called directly,
// since they were never exported outside package main to begin with.
package media

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"wedrop/core/plugin"
	"wedrop/core/protocol"
)

// ID is this plugin's stable identifier and capability string.
const ID plugin.ID = protocol.CapMedia

// Settings is this plugin's own settings, bridged for now from the shared
// storage.Settings by the host (see desktop/service.go
// pluginHost.LoadPluginSettings) until the settings/capability
// de-hardcoding migration gives every plugin real persisted settings.
type Settings struct {
	AllowControl bool `json:"allow_control"`
}

// Plugin implements plugin.Plugin for media control and now-playing sharing.
type Plugin struct {
	api plugin.API

	mu    sync.RWMutex
	peers map[string]protocol.MediaState

	cancel context.CancelFunc
}

// New creates the media plugin.
func New() *Plugin {
	return &Plugin{peers: make(map[string]protocol.MediaState)}
}

func (p *Plugin) ID() plugin.ID { return ID }

func (p *Plugin) MessageTypes() []protocol.MessageType {
	return []protocol.MessageType{protocol.TypeMedia, protocol.TypeMediaState}
}

func (p *Plugin) Init(api plugin.API) error {
	p.api = api
	return nil
}

func (p *Plugin) HandleMessage(from plugin.PeerRef, msgType protocol.MessageType, raw []byte) error {
	switch msgType {
	case protocol.TypeMedia:
		return p.handleCommand(from, raw)
	case protocol.TypeMediaState:
		return p.handleState(from, raw)
	}
	return nil
}

// handleCommand applies a command a peer sent us — the receiving end of
// "let this device control my media."
func (p *Plugin) handleCommand(from plugin.PeerRef, raw []byte) error {
	if !p.settings().AllowControl {
		return nil
	}
	if !p.api.Allows(from.DeviceID) {
		return nil
	}

	var msg protocol.MediaMessage
	if err := json.Unmarshal(raw, &msg); err != nil {
		return err
	}

	if msg.Command == protocol.MediaSeek {
		if err := trySeekPlatform(msg.Position); err != nil {
			return err
		}
		p.api.Emit("applied", msg.Command)
		p.broadcastNowPlaying()
		return nil
	}
	if msg.Command == protocol.MediaSetVolume {
		if err := setVolumePlatform(msg.Volume); err != nil {
			return err
		}
		p.api.Emit("applied", msg.Command)
		p.broadcastNowPlaying()
		return nil
	}

	if err := applyMediaCommand(msg.Command); err != nil {
		return err
	}
	p.api.Emit("applied", msg.Command)
	// The command was just applied (e.g. simulated media keys for
	// play/pause/next/prev), so the sender's UI would otherwise sit on stale
	// data until the next periodic tick (nowPlayingInterval) — push a fresh
	// snapshot right away instead of making them wait.
	p.broadcastNowPlaying()
	return nil
}

// handleState records what a peer reports it is playing — never gated by a
// permission, same as the pre-plugin code: reporting playback state is not
// a control action.
func (p *Plugin) handleState(from plugin.PeerRef, raw []byte) error {
	var msg protocol.MediaState
	if err := json.Unmarshal(raw, &msg); err != nil {
		return err
	}
	p.mu.Lock()
	p.peers[from.DeviceID] = msg
	p.mu.Unlock()
	p.api.Emit("state_changed", nil)
	return nil
}

func (p *Plugin) OnPeerConnected(peer plugin.PeerRef) {}

// OnPeerDisconnected drops a peer's last-known state — GetState only ever
// reads it while the peer shows connected, so this is housekeeping rather
// than a visible behaviour change.
func (p *Plugin) OnPeerDisconnected(deviceID string) {
	p.mu.Lock()
	delete(p.peers, deviceID)
	p.mu.Unlock()
}

// Start begins periodically sharing this device's now-playing state.
// nowPlayingInterval is zero on platforms with no now-playing
// implementation (see now_playing_other.go), in which case this exits
// immediately rather than spinning on a zero-duration ticker.
func (p *Plugin) Start(ctx context.Context) error {
	if nowPlayingInterval <= 0 {
		return nil
	}
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

func (p *Plugin) broadcastLoop(ctx context.Context) {
	ticker := time.NewTicker(nowPlayingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			p.broadcastNowPlaying()
		}
	}
}

func (p *Plugin) broadcastNowPlaying() {
	if !p.settings().AllowControl {
		return
	}
	if len(p.api.ConnectedPeers()) == 0 {
		return
	}
	p.api.Broadcast(collectNowPlaying())
}

// SendCommand asks a peer to act on its playback — used by the host
// (desktop/api.go) for the Wails-bound SendMediaCommand.
func (p *Plugin) SendCommand(deviceID, command string) error {
	switch command {
	case protocol.MediaPlayPause, protocol.MediaNext, protocol.MediaPrev,
		protocol.MediaStop, protocol.MediaVolUp, protocol.MediaVolDown, protocol.MediaMute:
	default:
		return fmt.Errorf("unknown media command %q", command)
	}
	return p.api.Send(deviceID, protocol.MediaMessage{
		Type:    protocol.TypeMedia,
		Command: command,
	})
}

// ControlLocal applies a media command to this machine directly — used by
// the host for the Wails-bound ControlLocalMedia.
func (p *Plugin) ControlLocal(command string) error {
	return applyMediaCommand(command)
}

// SendSeek asks a peer to jump to an absolute position in its current
// track — used by the host (desktop/api.go) for the Wails-bound
// SendMediaSeek, which backs the desktop Now Playing card's seek bar.
func (p *Plugin) SendSeek(deviceID string, positionMs int64) error {
	return p.api.Send(deviceID, protocol.MediaMessage{
		Type:     protocol.TypeMedia,
		Command:  protocol.MediaSeek,
		Position: positionMs,
	})
}

// StateOf returns the last known media state a peer reported, if it has
// media actually loaded — used by the host (desktop/api.go) to populate
// DeviceView.Media.
func (p *Plugin) StateOf(deviceID string) (protocol.MediaState, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	s, ok := p.peers[deviceID]
	if !ok || !s.HasMedia {
		return protocol.MediaState{}, false
	}
	return s, true
}

func (p *Plugin) settings() Settings {
	var s Settings
	_ = json.Unmarshal(p.api.Settings(), &s)
	return s
}
