// Package protocol defines the WeDrop v2 wire format.
//
// Every TCP frame is length-prefixed (4-byte big-endian length). The handshake
// frames are plaintext JSON; everything after the handshake is an AES-256-GCM
// sealed frame whose plaintext is JSON (or, for transfer payloads, raw bytes).
package protocol

import "encoding/json"

// Version is the protocol revision. Peers on different revisions refuse to talk
// to each other rather than failing later with an opaque handshake error.
const Version = 2

// Ports used by every WeDrop device.
const (
	DiscoveryPort = 47820
	TransportPort = 47821
)

// MessageType identifies a message on the wire.
type MessageType string

const (
	// Discovery (UDP)
	TypeDiscovery      MessageType = "wedrop_discovery"
	TypeDiscoveryQuery MessageType = "wedrop_discovery_query"
	TypeDiscoveryBye   MessageType = "wedrop_discovery_bye"

	// Handshake (TCP, plaintext)
	TypeHandshakeInit    MessageType = "handshake_init"
	TypeHandshakeResp    MessageType = "handshake_resp"
	TypeHandshakeConfirm MessageType = "handshake_confirm"

	// Pairing (TCP, encrypted)
	TypePairingResp MessageType = "pairing_resp"
	TypeUnpair      MessageType = "unpair"

	// Session control (TCP, encrypted)
	TypePing       MessageType = "ping"
	TypePong       MessageType = "pong"
	TypeDeviceInfo MessageType = "device_info"

	// Features (TCP, encrypted)
	TypeClipboard        MessageType = "clipboard"
	TypeNotification     MessageType = "notification"
	TypeMedia            MessageType = "media"
	TypeMediaState       MessageType = "media_state"
	TypeHealth           MessageType = "health"
	TypeRemoteInput      MessageType = "remote_input"
	TypeWorkspaceAction  MessageType = "workspace_action"
	TypeAdaptiveControls MessageType = "adaptive_controls"
	TypeMinimizedApps    MessageType = "minimized_apps"

	// Transfer (TCP, encrypted, dedicated connection)
	TypeTransferOffer  MessageType = "transfer_offer"
	TypeTransferAccept MessageType = "transfer_accept"
	TypeTransferChunk  MessageType = "transfer_chunk"
	TypeTransferDone   MessageType = "transfer_done"

	TypeError MessageType = "error"
)

// Intent tells the listening side what a freshly dialled connection is for, so
// it can route the connection without guessing from the first message.
type Intent string

const (
	// IntentPair asks to join the peer's ecosystem. The peer does not require
	// the caller to be trusted yet, but does prompt its user for confirmation.
	IntentPair Intent = "pair"
	// IntentSession opens the long-lived control channel. Requires trust.
	IntentSession Intent = "session"
	// IntentTransfer opens a short-lived channel carrying one file. Requires trust.
	IntentTransfer Intent = "transfer"
)

// Error codes returned in ErrorMessage.Code. These are stable strings so both
// the Go and Dart implementations can branch on them.
const (
	ErrNotPaired       = "not_paired"
	ErrKeyMismatch     = "key_mismatch"
	ErrVersionMismatch = "version_mismatch"
	ErrRejected        = "rejected"
	ErrTimeout         = "timeout"
	ErrBadSignature    = "bad_signature"
	ErrNotPermitted    = "not_permitted"
	ErrInternal        = "internal"
	ErrBusy            = "busy"
)

// FormFactor is a coarse device class used for iconography and sorting.
type FormFactor string

const (
	FormDesktop FormFactor = "desktop"
	FormPhone   FormFactor = "phone"
	FormTablet  FormFactor = "tablet"
)

// BaseMessage carries the fields present on every JSON message.
type BaseMessage struct {
	Type MessageType `json:"type"`
}

// DiscoveryMessage is broadcast over UDP to announce presence.
//
// IP is advisory: receivers overwrite it with the real UDP source address,
// because a device behind a hotspot or with several interfaces frequently
// cannot tell which of its own addresses the peer can actually reach.
type DiscoveryMessage struct {
	Type       MessageType `json:"type"`
	Version    int         `json:"version"`
	DeviceID   string      `json:"device_id"`
	Name       string      `json:"name"`
	Platform   string      `json:"platform"`
	FormFactor FormFactor  `json:"form_factor"`
	IP         string      `json:"ip"`
	TCPPort    int         `json:"tcp_port"`
	PublicKey  string      `json:"public_key"`
}

// HandshakeInit is the first frame a dialler sends.
type HandshakeInit struct {
	Type         MessageType `json:"type"`
	Version      int         `json:"version"`
	Intent       Intent      `json:"intent"`
	DeviceID     string      `json:"device_id"`
	Name         string      `json:"name"`
	Platform     string      `json:"platform"`
	FormFactor   FormFactor  `json:"form_factor"`
	PublicKey    string      `json:"public_key"`    // base64 Ed25519 identity key
	EphemeralPub string      `json:"ephemeral_pub"` // base64 X25519 key
	Nonce        string      `json:"nonce"`         // base64, 16 random bytes
}

// HandshakeResp answers a HandshakeInit and proves possession of the identity
// key by signing the full transcript.
type HandshakeResp struct {
	Type         MessageType `json:"type"`
	Version      int         `json:"version"`
	DeviceID     string      `json:"device_id"`
	Name         string      `json:"name"`
	Platform     string      `json:"platform"`
	FormFactor   FormFactor  `json:"form_factor"`
	PublicKey    string      `json:"public_key"`
	EphemeralPub string      `json:"ephemeral_pub"`
	Nonce        string      `json:"nonce"`
	Signature    string      `json:"signature"` // base64 Ed25519 over the transcript
}

// HandshakeConfirm closes the handshake with the dialler's transcript signature.
type HandshakeConfirm struct {
	Type      MessageType `json:"type"`
	Signature string      `json:"signature"`
}

// PairingResp is sent (encrypted) by the accepting side once its user decides.
type PairingResp struct {
	Type     MessageType `json:"type"`
	DeviceID string      `json:"device_id"`
	Name     string      `json:"name"`
	Accepted bool        `json:"accepted"`
	Reason   string      `json:"reason,omitempty"`
}

// Unpair tells a peer we removed it, so it can drop us too.
type Unpair struct {
	Type     MessageType `json:"type"`
	DeviceID string      `json:"device_id"`
}

// Ping and Pong keep Wi-Fi power-save state alive and detect dead peers.
type Ping struct {
	Type MessageType `json:"type"`
	Seq  int64       `json:"seq"`
}

// Pong answers a Ping with the same sequence number.
type Pong struct {
	Type MessageType `json:"type"`
	Seq  int64       `json:"seq"`
}

// Capability names shared by both implementations.
const (
	CapClipboard     = "clipboard"
	CapFiles         = "files"
	CapNotifications = "notifications"
	CapMedia         = "media"
	CapWorkspace     = "workspace"
	// CapAdaptiveControls is its own capability (a plugin's ID must be
	// unique, so this cannot literally be CapWorkspace) purely so a peer can
	// advertise "I understand this message type" — always advertised
	// unconditionally by both sides (see Settings.Capabilities), same as
	// CapFiles/CapWorkspace. The actual authorization to run whatever
	// action a control carries still goes through the exact same
	// AllowWorkspace permission as any other workspace action; this
	// capability only gates whether the schema itself is even sent.
	CapAdaptiveControls = "adaptive_controls"
	// CapMinimizedApps is its own capability for the same reason as
	// CapAdaptiveControls above (plugin ID uniqueness) — the real
	// authorization is still AllowWorkspace.
	CapMinimizedApps = "minimized_apps"
	// CapHealth is always advertised — there is no user-facing toggle for
	// device-health reporting, unlike the other capabilities.
	CapHealth = "device-health"
)

// DeviceInfo is exchanged right after a session opens and whenever the user
// renames a device or toggles a capability.
type DeviceInfo struct {
	Type       MessageType `json:"type"`
	DeviceID   string      `json:"device_id"`
	Name       string      `json:"name"`
	Platform   string      `json:"platform"`
	FormFactor FormFactor  `json:"form_factor"`
	// Capabilities the peer is willing to serve. A missing capability means
	// "do not send me this", so senders can skip work instead of being refused.
	Capabilities []string `json:"capabilities"`
	Battery      int      `json:"battery"` // 0-100, -1 when unknown
}

// HasCapability reports whether the peer advertised the given capability.
func (d *DeviceInfo) HasCapability(cap string) bool {
	for _, c := range d.Capabilities {
		if c == cap {
			return true
		}
	}
	return false
}

// ClipboardMessage carries clipboard text. Origin and Hash let a device ignore
// an echo of its own content when several devices relay to each other.
type ClipboardMessage struct {
	Type     MessageType `json:"type"`
	Text     string      `json:"text"`
	Origin   string      `json:"origin"`   // device_id that first copied it
	Sequence int64       `json:"sequence"` // monotonic per origin
	Hash     string      `json:"hash"`     // sha256 of Text
}

// NotificationMessage mirrors a notification from one device to another.
type NotificationMessage struct {
	Type     MessageType `json:"type"`
	ID       string      `json:"id"`
	App      string      `json:"app"`
	Title    string      `json:"title"`
	Body     string      `json:"body"`
	Time     int64       `json:"time"` // unix millis
	Dismiss  bool        `json:"dismiss,omitempty"`
	Category string      `json:"category,omitempty"`
}

// Media commands understood by every platform.
const (
	MediaPlayPause = "play_pause"
	MediaNext      = "next"
	MediaPrev      = "prev"
	MediaStop      = "stop"
	MediaVolUp     = "vol_up"
	MediaVolDown   = "vol_down"
	MediaMute      = "mute"
	// MediaSeek jumps to an absolute position, carried in MediaMessage.Position.
	// Not every platform can honour it — a receiver with no active media session
	// API (today, Windows) silently ignores it rather than erroring, the same
	// as any other command it cannot service.
	MediaSeek = "seek"
	// MediaSetVolume sets an absolute system volume level, carried in
	// MediaMessage.Volume (0-100) — what a slider sends, as opposed to the
	// relative nudges MediaVolUp/MediaVolDown apply.
	MediaSetVolume = "set_volume"
	// MediaSelectPlayer picks which of the peer's active sessions
	// (MediaState.Players) future play/pause/next/prev/seek commands target,
	// carried in MediaMessage.PlayerID — "" (or an id that has since
	// disappeared) falls back to whatever the platform itself considers
	// current. Mirrors KDE Connect's own player-selection UI.
	MediaSelectPlayer = "select_player"
	// MediaSelectAudioDevice makes MediaMessage.DeviceID the peer's default
	// playback device (every role — console/multimedia/communications).
	MediaSelectAudioDevice = "select_audio_device"
	// MediaSetAppVolume sets one running app's own mixer volume (as opposed
	// to MediaSetVolume, which is the whole system), carried in
	// MediaMessage.AppID + Volume.
	MediaSetAppVolume = "set_app_volume"
	// MediaSetAppMute mutes/unmutes one running app's own mixer channel,
	// carried in MediaMessage.AppID + Muted.
	MediaSetAppMute = "set_app_mute"
)

// MediaMessage asks the peer to act on its currently playing media.
type MediaMessage struct {
	Type    MessageType `json:"type"`
	Command string      `json:"command"`
	// Position is only meaningful for MediaSeek: the target position in millis.
	Position int64 `json:"position,omitempty"`
	// Volume is only meaningful for MediaSetVolume: the target level, 0-100.
	Volume int `json:"volume,omitempty"`
	// PlayerID is only meaningful for MediaSelectPlayer — see its constant doc.
	PlayerID string `json:"player_id,omitempty"`
	// DeviceID is only meaningful for MediaSelectAudioDevice: the target
	// output device's id, from MediaState.AudioDevices.
	DeviceID string `json:"device_id,omitempty"`
	// AppID is only meaningful for MediaSetAppVolume/MediaSetAppMute: the
	// target app's id, from MediaState.AppVolumes.
	AppID string `json:"app_id,omitempty"`
	// Muted is only meaningful for MediaSetAppMute.
	Muted bool `json:"muted,omitempty"`
}

// PlayerSummary describes one of the peer's active media sessions, so a
// remote can list and pick which one to control — mirrors KDE Connect's own
// player list, rather than a remote only ever being able to guess at
// whatever the platform itself currently calls "current".
type PlayerSummary struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Artist  string `json:"artist"`
	Playing bool   `json:"playing"`
}

// AudioDeviceSummary describes one of the peer's playback (render) devices.
type AudioDeviceSummary struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Default bool   `json:"default"`
}

// AppVolumeSummary describes one running app's own mixer channel on the peer.
type AppVolumeSummary struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Volume int    `json:"volume"`
	Muted  bool   `json:"muted"`
}

// MediaState reports what the peer is playing, so remotes can render a UI.
type MediaState struct {
	Type     MessageType `json:"type"`
	Playing  bool        `json:"playing"`
	HasMedia bool        `json:"has_media"` // false means nothing is loaded
	Title    string      `json:"title"`
	Artist   string      `json:"artist"`
	App      string      `json:"app"`
	Volume   int         `json:"volume"`   // 0-100, -1 when unknown
	Position int64       `json:"position"` // current position, millis, -1 unknown
	Duration int64       `json:"duration"` // total length, millis, -1 unknown
	// Artwork is a small base64-encoded JPEG preview of the track/album art,
	// when the source provides one. Empty when there is none — never a
	// placeholder, so a UI can tell "no art" from "hasn't arrived yet".
	Artwork string `json:"artwork,omitempty"`
	// Players lists every active session on the peer, not just whatever this
	// state's own Title/Artist/etc. reflect — empty on platforms/builds with
	// no multi-player support. SelectedPlayer is the id (from Players) future
	// commands are scoped to, "" meaning "whatever the platform calls current".
	Players        []PlayerSummary `json:"players,omitempty"`
	SelectedPlayer string          `json:"selected_player,omitempty"`
	// AudioDevices lists the peer's playback devices — empty on
	// platforms/builds with no device enumeration support.
	AudioDevices []AudioDeviceSummary `json:"audio_devices,omitempty"`
	// AppVolumes lists the peer's active per-app mixer channels — empty on
	// platforms/builds with no per-app volume support.
	AppVolumes []AppVolumeSummary `json:"app_volumes,omitempty"`
}

// DeviceHealth is broadcast periodically so remotes can show a device's status.
type DeviceHealth struct {
	Type        MessageType `json:"type"`
	DeviceID    string      `json:"device_id"`
	Battery     int         `json:"battery"` // 0-100, -1 unknown (e.g. a desktop with no battery)
	Charging    bool        `json:"charging"`
	CPUPercent  int         `json:"cpu_percent"`  // 0-100, -1 unknown
	MemPercent  int         `json:"mem_percent"`  // 0-100, -1 unknown
	NetworkType string      `json:"network_type"` // "wifi", "ethernet", "cellular", "offline"
	NetworkName string      `json:"network_name"` // SSID or interface, best effort
}

// RemoteInput carries a mouse, keyboard or presentation event to be injected on
// the receiving device — the heart of using a phone as a remote for a desktop.
type RemoteInput struct {
	Type   MessageType `json:"type"`
	Action string      `json:"action"`

	// Mouse: DX/DY are relative movement; scroll uses DY. X/Y (0..1) are
	// absolute fractions of the screen for an absolute move.
	DX float64 `json:"dx,omitempty"`
	DY float64 `json:"dy,omitempty"`
	X  float64 `json:"x,omitempty"`
	Y  float64 `json:"y,omitempty"`

	// Keyboard: Text is literal characters to type; Key is a named special key.
	Text string `json:"text,omitempty"`
	Key  string `json:"key,omitempty"`
}

// Remote input actions.
const (
	InputMouseMove   = "mouse_move"   // relative move by DX/DY
	InputMouseLeft   = "mouse_left"   // left click
	InputMouseRight  = "mouse_right"  // right click
	InputMouseMiddle = "mouse_middle" // middle click
	InputMouseDown   = "mouse_down"   // press-and-hold left (for drags)
	InputMouseUp     = "mouse_up"     // release left
	InputScroll      = "scroll"       // scroll by DY
	InputType        = "type"         // type Text literally
	InputKey         = "key"          // press the named Key

	// Presentation keys, kept distinct so the desktop maps them to whatever the
	// active slideshow expects even if the generic key table changes.
	InputPresentNext  = "present_next"
	InputPresentPrev  = "present_prev"
	InputPresentStart = "present_start"
	InputPresentEnd   = "present_end"
	InputPresentBlank = "present_blank"
)

// Named special keys carried in RemoteInput.Key.
const (
	KeyBackspace = "backspace"
	KeyEnter     = "enter"
	KeyTab       = "tab"
	KeyEscape    = "escape"
	KeyUp        = "up"
	KeyDown      = "down"
	KeyLeft      = "left"
	KeyRight     = "right"
	KeySpace     = "space"
	KeyHome      = "home"
	KeyEnd       = "end"
	KeyDelete    = "delete"

	// Function keys — added for dynamic controls (e.g. VS Code's Run/Debug),
	// not previously needed by anything RemoteInput sent.
	KeyF1  = "f1"
	KeyF2  = "f2"
	KeyF3  = "f3"
	KeyF4  = "f4"
	KeyF5  = "f5"
	KeyF6  = "f6"
	KeyF7  = "f7"
	KeyF8  = "f8"
	KeyF9  = "f9"
	KeyF10 = "f10"
	KeyF11 = "f11"
	KeyF12 = "f12"
)

// WorkspaceAction asks the peer to run one of a user's own custom "My
// Workspace" buttons — a phone-triggers-local-action message with no
// broadcast state, the same shape as RemoteInput. Kept as its own message
// type (rather than folded into RemoteInput) since its actions have nothing
// to do with mouse/keyboard synthesis except the shortcut case, which reuses
// RemoteInput's own SendInput machinery under the hood.
type WorkspaceAction struct {
	Type   MessageType `json:"type"`
	Action string      `json:"action"` // Workspace* below

	// Shortcut: Modifiers held down while Key is pressed. Key is either a
	// single letter/digit or one of the RemoteInput SpecialKey names above —
	// this is a separate, dedicated surface for combos (Ctrl+Shift+P), not a
	// change to RemoteInput's own single-key path.
	Modifiers []string `json:"modifiers,omitempty"`
	Key       string   `json:"key,omitempty"`

	// OpenApp / OpenFolder: a local path on the peer.
	Path string `json:"path,omitempty"`
	// OpenURL: opened in the peer's default browser.
	URL string `json:"url,omitempty"`
	// ShellCommand: run verbatim through the peer's shell. Gated by the
	// peer's own AllowAutomation permission — a workspace button existing
	// does not by itself mean shell commands are allowed.
	Command string `json:"command,omitempty"`
	// RestoreWindow: the id (native window handle) of a window reported by
	// MinimizedAppsState to bring to the front.
	WindowID int64 `json:"window_id,omitempty"`
}

// Workspace button actions.
const (
	WorkspaceShortcut      = "shortcut"
	WorkspaceOpenApp       = "open_app"
	WorkspaceOpenFolder    = "open_folder"
	WorkspaceOpenURL       = "open_url"
	WorkspaceShellCommand  = "shell_command"
	WorkspaceRestoreWindow = "restore_window"
)

// Modifier names carried in WorkspaceAction.Modifiers.
const (
	ModifierCtrl  = "ctrl"
	ModifierShift = "shift"
	ModifierAlt   = "alt"
	// ModifierMeta is the Windows/Command/Super key — added for the desktop
	// switcher widget (Ctrl+Win+Left/Right is Windows' own native virtual
	// desktop shortcut), not previously needed by any shortcut button.
	ModifierMeta = "meta"
)

// AdaptiveControl is one dynamic, app-provided control the peer's currently
// focused application makes available — its Action reuses WorkspaceAction
// verbatim (in every built-in profile so far, a keyboard shortcut), so
// running one needs no execution path beyond what already handles a
// workspace button's own action.
type AdaptiveControl struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	// Icon uses the same curated icon-key vocabulary as WorkspaceButton.icon
	// (mobile/lib/ui/workspace_tab.dart's kWorkspaceIcons) — a string, not a
	// platform icon reference, so both clients render it consistently.
	Icon   string          `json:"icon"`
	Action WorkspaceAction `json:"action"`
}

// AdaptiveControlsState is broadcast whenever the peer's foreground app
// changes (and once when a peer connects, so it need not wait for the next
// switch to see the current one). Controls is empty when AppName is empty —
// no recognized app is currently focused.
type AdaptiveControlsState struct {
	Type     MessageType       `json:"type"`
	AppName  string            `json:"app_name"`
	Controls []AdaptiveControl `json:"controls"`
}

// MinimizedWindow is one currently-minimized top-level window on the peer.
// ID is the native window handle (an HWND on Windows), opaque to the
// receiver — it only ever gets echoed back verbatim in a WorkspaceAction's
// WindowID to restore that exact window, never interpreted on the phone.
type MinimizedWindow struct {
	ID      int64  `json:"id"`
	Title   string `json:"title"`
	AppName string `json:"app_name"`
}

// MinimizedAppsState is broadcast whenever the peer's set of minimized
// windows changes (and once when a peer connects). Deliberately scoped to
// "currently minimized", not "every open window on the currently selected
// virtual desktop" — the latter needs the same undocumented, version-fragile
// virtual-desktop COM interfaces the desktop-switcher widget avoids by using
// Windows' own native Ctrl+Win+Left/Right shortcut instead.
type MinimizedAppsState struct {
	Type    MessageType       `json:"type"`
	Windows []MinimizedWindow `json:"windows"`
}

// TransferOffer announces an incoming file on a dedicated transfer connection.
type TransferOffer struct {
	Type       MessageType `json:"type"`
	TransferID string      `json:"transfer_id"`
	Filename   string      `json:"filename"`
	Size       int64       `json:"size"`
	Checksum   string      `json:"checksum"` // hex SHA-256 of the whole file
	MimeType   string      `json:"mime_type,omitempty"`
	ChunkSize  int         `json:"chunk_size"`
	ChunkCount int         `json:"chunk_count"`
}

// TransferAccept is the receiver's verdict on a TransferOffer.
type TransferAccept struct {
	Type       MessageType `json:"type"`
	TransferID string      `json:"transfer_id"`
	Accepted   bool        `json:"accepted"`
	Reason     string      `json:"reason,omitempty"`
}

// TransferChunk is the header for one chunk. The chunk bytes follow as the very
// next encrypted frame, which keeps the JSON small and avoids base64 bloat.
type TransferChunk struct {
	Type       MessageType `json:"type"`
	TransferID string      `json:"transfer_id"`
	Index      int         `json:"index"`
	Size       int         `json:"size"`
}

// TransferDone ends a transfer and repeats the checksum for verification.
type TransferDone struct {
	Type       MessageType `json:"type"`
	TransferID string      `json:"transfer_id"`
	Checksum   string      `json:"checksum"`
}

// ErrorMessage is sent before closing a connection so the other end can show a
// useful reason instead of "connection reset by peer".
type ErrorMessage struct {
	Type    MessageType `json:"type"`
	Code    string      `json:"code"`
	Message string      `json:"message"`
}

// NewError builds an ErrorMessage.
func NewError(code, message string) ErrorMessage {
	return ErrorMessage{Type: TypeError, Code: code, Message: message}
}

// ParseMessageType decodes just the discriminator of a JSON message.
func ParseMessageType(data []byte) (MessageType, error) {
	var base BaseMessage
	if err := json.Unmarshal(data, &base); err != nil {
		return "", err
	}
	return base.Type, nil
}
