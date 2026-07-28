package plugin

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	"wedrop/core/protocol"
)

// Host is what the registry needs from whatever embeds core (the desktop
// Wails service today; a future Linux/macOS host later) to actually reach
// peers, persist settings, and surface events. The registry is otherwise
// self-contained and knows nothing about Wails, sockets, or storage
// formats.
type Host interface {
	Send(deviceID string, v interface{}) error
	Broadcast(capability string, v interface{})
	ConnectedPeers(capability string) []PeerRef
	Emit(event Event)
	LoadPluginSettings(id ID) []byte
	SavePluginSettings(id ID, data []byte) error
}

type registeredPlugin struct {
	plugin  Plugin
	enabled bool
}

// Registry holds every compiled-in plugin, routes inbound messages to the
// plugin that claimed each message type, and lets a plugin be enabled or
// disabled at runtime without touching any other plugin.
//
// This is the "loadable/unloadable" mechanism: plugins are linked into the
// binary at compile time (RegisterAll-style call sites own the flat list),
// but the registry's enable/disable is a genuine runtime toggle — a
// disabled plugin's messages are silently dropped and its background work
// is stopped, without restarting the process or any other plugin.
type Registry struct {
	host Host

	mu      sync.RWMutex
	plugins map[ID]*registeredPlugin
	byMsg   map[protocol.MessageType]ID
}

// NewRegistry creates an empty registry bound to host.
func NewRegistry(host Host) *Registry {
	return &Registry{
		host:    host,
		plugins: make(map[ID]*registeredPlugin),
		byMsg:   make(map[protocol.MessageType]ID),
	}
}

// Register adds a plugin, enabled by default unless enabledByDefault is
// false. It is an error for two plugins to claim the same message type.
func (r *Registry) Register(p Plugin, enabledByDefault bool) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	id := p.ID()
	if _, exists := r.plugins[id]; exists {
		return fmt.Errorf("plugin %q already registered", id)
	}
	for _, mt := range p.MessageTypes() {
		if owner, taken := r.byMsg[mt]; taken {
			return fmt.Errorf("message type %q already claimed by plugin %q", mt, owner)
		}
	}

	if err := p.Init(&pluginAPI{id: id, registry: r}); err != nil {
		return fmt.Errorf("init plugin %q: %w", id, err)
	}

	for _, mt := range p.MessageTypes() {
		r.byMsg[mt] = id
	}
	r.plugins[id] = &registeredPlugin{plugin: p, enabled: enabledByDefault}
	return nil
}

// Plugin returns a registered plugin by ID, if any.
func (r *Registry) Plugin(id ID) (Plugin, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	rp, ok := r.plugins[id]
	if !ok {
		return nil, false
	}
	return rp.plugin, true
}

// IDs lists every registered plugin ID.
func (r *Registry) IDs() []ID {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ids := make([]ID, 0, len(r.plugins))
	for id := range r.plugins {
		ids = append(ids, id)
	}
	return ids
}

// Enabled reports whether a plugin is currently enabled. An unknown ID
// reports false.
func (r *Registry) Enabled(id ID) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	rp, ok := r.plugins[id]
	return ok && rp.enabled
}

// SetEnabled toggles a plugin at runtime. Disabling stops its background
// work and starts silently dropping its messages; re-enabling restarts it.
func (r *Registry) SetEnabled(ctx context.Context, id ID, enabled bool) error {
	r.mu.Lock()
	rp, ok := r.plugins[id]
	if !ok {
		r.mu.Unlock()
		return fmt.Errorf("unknown plugin %q", id)
	}
	already := rp.enabled
	rp.enabled = enabled
	r.mu.Unlock()

	if already == enabled {
		return nil
	}
	if enabled {
		return rp.plugin.Start(ctx)
	}
	rp.plugin.Stop()
	return nil
}

// StartAll starts every enabled plugin's background work.
func (r *Registry) StartAll(ctx context.Context) error {
	r.mu.RLock()
	toStart := make([]Plugin, 0, len(r.plugins))
	for _, rp := range r.plugins {
		if rp.enabled {
			toStart = append(toStart, rp.plugin)
		}
	}
	r.mu.RUnlock()

	for _, p := range toStart {
		if err := p.Start(ctx); err != nil {
			return fmt.Errorf("start plugin %q: %w", p.ID(), err)
		}
	}
	return nil
}

// StopAll stops every plugin's background work, regardless of enabled state.
func (r *Registry) StopAll() {
	r.mu.RLock()
	all := make([]Plugin, 0, len(r.plugins))
	for _, rp := range r.plugins {
		all = append(all, rp.plugin)
	}
	r.mu.RUnlock()

	for _, p := range all {
		p.Stop()
	}
}

// --------------------------------------------- transport.SessionHandler

// OnMessage implements transport.SessionHandler (structurally — core/plugin
// does not import core/transport to avoid a dependency cycle; see
// desktop/service.go for the adapter that wires this in). It looks up which
// plugin claimed msgType and, if that plugin is enabled, hands it the raw
// payload; an unclaimed or disabled plugin's message is dropped silently.
func (r *Registry) OnMessage(peer PeerRef, msgType protocol.MessageType, raw []byte) {
	r.mu.RLock()
	id, claimed := r.byMsg[msgType]
	var rp *registeredPlugin
	if claimed {
		rp = r.plugins[id]
	}
	r.mu.RUnlock()

	if !claimed || rp == nil || !rp.enabled {
		return
	}
	_ = rp.plugin.HandleMessage(peer, msgType, raw)
}

// OnPeerConnected/OnPeerDisconnected fan out session lifecycle changes to
// every enabled plugin.
func (r *Registry) OnPeerConnected(peer PeerRef) {
	for _, p := range r.enabledPlugins() {
		p.OnPeerConnected(peer)
	}
}

func (r *Registry) OnPeerDisconnected(deviceID string) {
	for _, p := range r.enabledPlugins() {
		p.OnPeerDisconnected(deviceID)
	}
}

func (r *Registry) enabledPlugins() []Plugin {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Plugin, 0, len(r.plugins))
	for _, rp := range r.plugins {
		if rp.enabled {
			out = append(out, rp.plugin)
		}
	}
	return out
}

// HandleTransferOffer routes an inbound transfer connection to whichever
// registered plugin implements TransferPlugin (today, only files). If no
// such plugin is registered or it is disabled, the caller should close conn.
func (r *Registry) HandleTransferOffer(conn TransferConn, peer protocol.DeviceInfo, offer protocol.TransferOffer) {
	r.mu.RLock()
	var target *registeredPlugin
	for _, rp := range r.plugins {
		if _, ok := rp.plugin.(TransferPlugin); ok {
			target = rp
			break
		}
	}
	r.mu.RUnlock()

	if target == nil || !target.enabled {
		conn.Close()
		return
	}
	target.plugin.(TransferPlugin).HandleTransferOffer(conn, peer, offer)
}

// --------------------------------------------------------- per-plugin API

// pluginAPI is the API handed to exactly one plugin; every method is scoped
// to that plugin's ID acting as its capability string.
type pluginAPI struct {
	id       ID
	registry *Registry
}

func (a *pluginAPI) Send(deviceID string, v interface{}) error {
	return a.registry.host.Send(deviceID, v)
}

func (a *pluginAPI) Broadcast(v interface{}) {
	a.registry.host.Broadcast(string(a.id), v)
}

func (a *pluginAPI) ConnectedPeers() []PeerRef {
	return a.registry.host.ConnectedPeers(string(a.id))
}

func (a *pluginAPI) Emit(name string, payload interface{}) {
	a.registry.host.Emit(Event{Plugin: a.id, Name: name, Payload: payload})
}

func (a *pluginAPI) Settings() []byte {
	return a.registry.host.LoadPluginSettings(a.id)
}

func (a *pluginAPI) SaveSettings(v interface{}) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return a.registry.host.SavePluginSettings(a.id, data)
}

func (a *pluginAPI) Enabled() bool {
	return a.registry.Enabled(a.id)
}

func (a *pluginAPI) Logf(format string, args ...interface{}) {
	fmt.Printf("[%s] "+format+"\n", append([]interface{}{a.id}, args...)...)
}
