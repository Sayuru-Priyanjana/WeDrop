// Package files is the files/transfer plugin: it sends and receives files
// over a dedicated connection per transfer (see sender.go/receiver.go,
// relocated unchanged from the former core/transfer package — moved here
// because file transfer is feature logic, not core), and keeps the local
// transfer history the UI renders from.
//
// Unlike every other plugin, this one also implements plugin.TransferPlugin:
// transfers use their own connection (protocol.IntentTransfer) rather than
// the shared control session, so inbound offers are routed via
// HandleTransferOffer instead of HandleMessage.
package files

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sync"
	"time"

	"wedrop/core/plugin"
	"wedrop/core/protocol"
	"wedrop/core/transport"
)

// ID is this plugin's stable identifier and capability string.
const ID plugin.ID = protocol.CapFiles

// State is a transfer's lifecycle stage.
type State string

const (
	StatePending   State = "pending"
	StateActive    State = "active"
	StateCompleted State = "completed"
	StateFailed    State = "failed"
	StateDeclined  State = "declined"
)

// View describes a transfer for the UI. The host (desktop/api.go) converts
// this to its own TransferView (identical JSON shape, matching field names)
// so the Wails-bound AppState type and its generated TypeScript model never
// change.
type View struct {
	ID          string
	DeviceID    string
	DeviceName  string
	Filename    string
	Size        int64
	Transferred int64
	Incoming    bool
	State       State
	Error       string
	SavedPath   string
	StartedAt   int64
	UpdatedAt   int64
}

// Settings is this plugin's own settings, bridged for now from the shared
// storage.Settings by the host (see desktop/service.go
// pluginHost.LoadPluginSettings) until the settings/capability
// de-hardcoding migration gives every plugin real persisted settings.
type Settings struct {
	AutoAccept  bool   `json:"auto_accept"`
	DownloadDir string `json:"download_dir"`
}

// Plugin implements plugin.Plugin and plugin.TransferPlugin for file
// transfer.
type Plugin struct {
	api plugin.API
	// resolveName resolves a peer's display name — the trusted name if set,
	// else the session's advertised name (passed as fallback).
	resolveName func(deviceID, fallback string) string
	deviceName  func() string

	mu        sync.Mutex
	transfers map[string]*View
	pendingIn map[string]chan bool
}

// New creates the files plugin.
func New(resolveName func(deviceID, fallback string) string, deviceName func() string) *Plugin {
	return &Plugin{
		resolveName: resolveName,
		deviceName:  deviceName,
		transfers:   make(map[string]*View),
		pendingIn:   make(map[string]chan bool),
	}
}

func (p *Plugin) ID() plugin.ID { return ID }

// MessageTypes is empty: transfers run on their own dedicated connection
// (protocol.IntentTransfer), never the shared control session, so this
// plugin claims no control-session message type — it is routed instead via
// HandleTransferOffer (see plugin.TransferPlugin).
func (p *Plugin) MessageTypes() []protocol.MessageType { return nil }

func (p *Plugin) Init(api plugin.API) error {
	p.api = api
	return nil
}

func (p *Plugin) HandleMessage(from plugin.PeerRef, msgType protocol.MessageType, raw []byte) error {
	return nil
}

func (p *Plugin) OnPeerConnected(peer plugin.PeerRef) {}
func (p *Plugin) OnPeerDisconnected(deviceID string)  {}
func (p *Plugin) Start(ctx context.Context) error     { return nil }
func (p *Plugin) Stop()                               {}

// HandleTransferOffer implements plugin.TransferPlugin for an inbound
// transfer connection.
func (p *Plugin) HandleTransferOffer(conn plugin.TransferConn, peer protocol.DeviceInfo, offer protocol.TransferOffer) {
	sc, ok := conn.(*transport.SecureConn)
	if !ok {
		conn.Close()
		return
	}
	defer sc.Close()

	settings := p.settings()
	receiver := NewReceiver(sc, settings.DownloadDir)

	if !p.api.Allows(peer.DeviceID) {
		receiver.Decline(offer, "file transfers from this device are switched off")
		return
	}

	name := p.resolveName(peer.DeviceID, peer.Name)
	view := &View{
		ID:         offer.TransferID,
		DeviceID:   peer.DeviceID,
		DeviceName: name,
		Filename:   offer.Filename,
		Size:       offer.Size,
		Incoming:   true,
		State:      StatePending,
		StartedAt:  nowMillis(),
		UpdatedAt:  nowMillis(),
	}
	p.putTransfer(view)

	if !settings.AutoAccept {
		decision := make(chan bool, 1)

		p.mu.Lock()
		p.pendingIn[offer.TransferID] = decision
		p.mu.Unlock()

		p.api.Emit("incoming", *view)
		p.api.ShowWindow()

		var accepted bool
		select {
		case accepted = <-decision:
		case <-time.After(2 * time.Minute):
			accepted = false
		}

		p.mu.Lock()
		delete(p.pendingIn, offer.TransferID)
		p.mu.Unlock()

		if !accepted {
			receiver.Decline(offer, "declined")
			p.updateTransfer(offer.TransferID, func(t *View) { t.State = StateDeclined })
			return
		}
	}

	p.updateTransfer(offer.TransferID, func(t *View) { t.State = StateActive })

	throttle := newProgressThrottle()
	receiver.OnProgress = func(done, total int64) {
		if throttle.should(done, total) {
			p.updateTransfer(offer.TransferID, func(t *View) { t.Transferred = done })
		}
	}

	savedPath, err := receiver.Receive(offer)
	if err != nil {
		p.updateTransfer(offer.TransferID, func(t *View) {
			t.State = StateFailed
			t.Error = err.Error()
		})
		p.api.Toast("error", fmt.Sprintf("Could not receive %s: %v", offer.Filename, err))
		return
	}

	p.updateTransfer(offer.TransferID, func(t *View) {
		t.State = StateCompleted
		t.Transferred = offer.Size
		t.SavedPath = savedPath
	})
	p.api.Toast("success", fmt.Sprintf("Received %s from %s", offer.Filename, name))
}

// SendFile sends one file to a peer — used by the host (desktop/api.go) for
// the Wails-bound SendFiles, one goroutine per path.
func (p *Plugin) SendFile(deviceID, path string) {
	name := p.resolveName(deviceID, "")
	transferID := newTransferID()

	view := &View{
		ID:         transferID,
		DeviceID:   deviceID,
		DeviceName: name,
		Filename:   filepath.Base(path),
		Incoming:   false,
		State:      StateActive,
		StartedAt:  nowMillis(),
		UpdatedAt:  nowMillis(),
	}
	if info, err := statSize(path); err == nil {
		view.Size = info
	}
	p.putTransfer(view)

	fail := func(err error) {
		p.updateTransfer(transferID, func(t *View) {
			t.State = StateFailed
			t.Error = err.Error()
		})
		p.api.Toast("error", fmt.Sprintf("Could not send %s: %v", filepath.Base(path), err))
	}

	conn, _, err := p.api.DialTransfer(deviceID)
	if err != nil {
		fail(err)
		return
	}
	sc, ok := conn.(*transport.SecureConn)
	if !ok {
		fail(fmt.Errorf("internal error: unexpected connection type"))
		return
	}
	defer sc.Close()

	sender := NewSender(sc)
	throttle := newProgressThrottle()
	sender.OnProgress = func(done, total int64) {
		if throttle.should(done, total) {
			p.updateTransfer(transferID, func(t *View) {
				t.Transferred = done
				t.Size = total
			})
		}
	}

	if err := sender.SendFile(transferID, path); err != nil {
		fail(err)
		return
	}

	p.updateTransfer(transferID, func(t *View) {
		t.State = StateCompleted
		t.Transferred = t.Size
	})
	p.api.Toast("success", fmt.Sprintf("Sent %s to %s", filepath.Base(path), name))
}

// RespondToTransfer answers a pending incoming file prompt — used by the
// host for the Wails-bound RespondToTransfer.
func (p *Plugin) RespondToTransfer(transferID string, accept bool) error {
	p.mu.Lock()
	decision, ok := p.pendingIn[transferID]
	p.mu.Unlock()

	if !ok {
		return fmt.Errorf("that transfer is no longer waiting")
	}

	select {
	case decision <- accept:
		return nil
	default:
		return fmt.Errorf("that transfer has already been answered")
	}
}

func (p *Plugin) putTransfer(view *View) {
	p.mu.Lock()
	p.transfers[view.ID] = view
	p.mu.Unlock()
	p.api.Emit("changed", nil)
}

func (p *Plugin) updateTransfer(id string, fn func(*View)) {
	p.mu.Lock()
	view, ok := p.transfers[id]
	if !ok {
		p.mu.Unlock()
		return
	}
	fn(view)
	view.UpdatedAt = nowMillis()
	copyOfView := *view
	p.mu.Unlock()

	p.api.Emit("progress", copyOfView)
	if copyOfView.State != StateActive {
		p.api.Emit("changed", nil)
	}
}

// Snapshot returns every known transfer, newest first — used by the host to
// populate AppState.Transfers.
func (p *Plugin) Snapshot() []View {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]View, 0, len(p.transfers))
	for _, v := range p.transfers {
		out = append(out, *v)
	}
	return out
}

func (p *Plugin) settings() Settings {
	var s Settings
	_ = json.Unmarshal(p.api.Settings(), &s)
	return s
}
