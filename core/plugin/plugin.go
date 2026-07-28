// Package plugin defines the boundary between WeDrop's core (transport,
// security, device/peer management, message routing) and every user-facing
// feature (clipboard, files, notifications, media, remote input, device
// health). Core never contains feature logic; every feature implements
// Plugin and talks to core only through the API it is handed, never
// directly to another plugin.
//
// Plugins are registered at compile time into the single application
// binary — Go's plugin package only works on Linux and Dart has no stable
// hot-load mechanism, so true dynamic loading is not realistic across
// Windows, Linux, Android and macOS from one codebase. What "loadable,
// unloadable, enableable, disableable" means here is a Registry
// (registry.go) that can enable or disable a registered plugin at runtime
// without restarting the app or any other plugin.
package plugin

import (
	"context"

	"wedrop/core/protocol"
)

// ID identifies a plugin. A plugin's ID doubles as the capability string it
// advertises to peers (see protocol.DeviceInfo.Capabilities) and as the key
// under which its settings and per-device permissions are stored.
type ID string

// PeerRef is the minimal peer handle a plugin receives — deliberately not
// the full *transport.Session, so a plugin cannot reach into transport
// internals or address a peer outside the API's capability checks.
type PeerRef struct {
	DeviceID string
	Info     protocol.DeviceInfo
}

// Event is a (plugin, name, payload) tuple a plugin raises through
// API.Emit. The host embedding core (the desktop Wails layer, the mobile
// AppService) maps these to its own UI-facing event mechanism; core/plugin
// itself knows nothing about Wails or Flutter.
type Event struct {
	Plugin  ID
	Name    string
	Payload interface{}
}

// API is everything core exposes to a plugin. It is issued once per plugin
// (see Registry.Register), so Send/Broadcast/ConnectedPeers implicitly
// scope to that plugin's own capability — a plugin cannot address a peer
// that has not granted it that capability, and never needs to check
// permissions itself.
type API interface {
	// Send delivers v (typically a protocol message struct) to one peer.
	Send(deviceID string, v interface{}) error
	// Broadcast delivers v to every connected peer that has granted this
	// plugin's capability.
	Broadcast(v interface{})
	// ConnectedPeers lists peers currently reachable and permitted for this
	// plugin's capability.
	ConnectedPeers() []PeerRef
	// Allows reports whether a specific peer has been granted this plugin's
	// capability (the per-device trust permission, distinct from whether
	// the peer merely advertised wanting it). A plugin whose feature has no
	// per-device permission gate can simply not call this.
	Allows(deviceID string) bool
	// AllowsCapability is Allows generalised to an arbitrary capability
	// string instead of this plugin's own ID. It exists for the rare case
	// of one feature deliberately reusing another's permission toggle by
	// product design (remote input reuses the media capability: "let this
	// device control my media" also covers the touchpad/keyboard) — not a
	// way for a plugin to guess at another plugin's internal state.
	AllowsCapability(deviceID string, capability string) bool
	// Emit raises a UI-facing event tagged with this plugin's ID.
	Emit(name string, payload interface{})
	// Settings returns this plugin's own settings, previously saved via
	// SaveSettings, as raw JSON (empty/null if never saved). Core stores
	// this opaquely — it does not know or care about a plugin's settings
	// shape.
	Settings() []byte
	// SaveSettings persists v (typically the plugin's own settings struct)
	// under this plugin's namespace.
	SaveSettings(v interface{}) error
	// Enabled reports whether this plugin is currently enabled. A disabled
	// plugin still exists in the registry (so it can be re-enabled) but
	// receives no messages and its Start has been stopped.
	Enabled() bool
	// Logf writes a diagnostic line tagged with this plugin's ID.
	Logf(format string, args ...interface{})
}

// Plugin is the contract every feature implements. A Plugin has no
// knowledge of Wails, Flutter, or any other plugin — only of the API it is
// handed by Init.
type Plugin interface {
	// ID is this plugin's stable identifier and capability string.
	ID() ID
	// MessageTypes lists the wire message types this plugin handles. The
	// registry rejects registering two plugins that claim the same type.
	MessageTypes() []protocol.MessageType
	// Init is called once, before Start, with the API this plugin must use
	// for everything it needs from core.
	Init(api API) error
	// HandleMessage is called for every inbound message whose type this
	// plugin claimed in MessageTypes. raw is the still-encoded JSON payload;
	// the plugin unmarshals it into its own message struct.
	HandleMessage(from PeerRef, msgType protocol.MessageType, raw []byte) error
	// OnPeerConnected/OnPeerDisconnected notify a plugin of session
	// lifecycle changes, so it can maintain any per-peer state it needs.
	OnPeerConnected(peer PeerRef)
	OnPeerDisconnected(deviceID string)
	// Start begins any background work (polling, broadcasting) the plugin
	// needs; it must return promptly and do its work on its own
	// goroutine(s), stopping when ctx is done or Stop is called.
	Start(ctx context.Context) error
	// Stop ends the plugin's background work. Called when the plugin is
	// disabled or the app shuts down.
	Stop()
}

// TransferPlugin is implemented additionally by a plugin that needs its own
// dedicated connection type (today, only the files plugin: transfers use a
// separate connection per protocol.IntentTransfer rather than the shared
// control session, so they cannot be routed through HandleMessage).
type TransferPlugin interface {
	Plugin
	// HandleTransferOffer is called for an inbound transfer connection. The
	// plugin owns conn from this point and must close it.
	HandleTransferOffer(conn TransferConn, peer protocol.DeviceInfo, offer protocol.TransferOffer)
}

// TransferConn is the minimal connection surface a TransferPlugin needs,
// matching transport.SecureConn's read/write/close behaviour without
// core/plugin importing core/transport (which would make transport depend
// on plugin depend on transport).
type TransferConn interface {
	ReadEncrypted() ([]byte, error)
	WriteEncrypted(data []byte) error
	WriteJSON(v interface{}) error
	Close() error
}
