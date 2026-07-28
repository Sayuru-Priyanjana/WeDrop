package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"

	"wedrop/core/crypto"
	"wedrop/core/discovery"
	"wedrop/core/pairing"
	"wedrop/core/plugin"
	"wedrop/core/protocol"
	"wedrop/core/storage"
	"wedrop/core/transport"

	"desktop/plugins/adaptivecontrols"
	"desktop/plugins/clipboard"
	"desktop/plugins/files"
	"desktop/plugins/health"
	"desktop/plugins/media"
	"desktop/plugins/notifications"
	"desktop/plugins/remoteinput"
	"desktop/plugins/workspace"
)

const (
	settingsFile = "settings.json"
	deviceFile   = "device.json"
	masterKey    = "master.key"

	// pairingTimeout is how long an inbound request waits for the user.
	pairingTimeout = 90 * time.Second
)

// WeDropService is the whole desktop application behind the Wails bridge.
type WeDropService struct {
	ctx context.Context

	store    *storage.Store
	trust    *pairing.TrustStore
	disc     *discovery.Service
	manager  *transport.Manager
	identity *crypto.Identity

	mu       sync.RWMutex
	device   storage.DeviceConfig
	settings storage.Settings
	ready    bool
	initErr  string

	// Pending pairing prompt, at most one at a time — a second request while
	// the user is deciding is refused rather than queued, so nobody can bury a
	// malicious request under a legitimate one.
	pairingMu     sync.Mutex
	pairingPrompt *PairingPrompt
	pairingReply  chan bool

	// Health, notifications, clipboard, media, remote input, and files each
	// moved to their own plugin (desktop/plugins/*) — see s.registry.
	registry        *plugin.Registry
	healthPlugin    *health.Plugin
	notifsPlugin    *notifications.Plugin
	clipPlugin      *clipboard.Plugin
	mediaPlugin     *media.Plugin
	remoteinPlugin  *remoteinput.Plugin
	filesPlugin     *files.Plugin
	workspacePlugin *workspace.Plugin
	adaptivePlugin  *adaptivecontrols.Plugin

	stopChan chan struct{}
	stopOnce sync.Once

	emitMu      sync.Mutex
	emitPending bool
	lastEmitted time.Time
}

// NewWeDropService constructs the service; no I/O happens until startup.
func NewWeDropService() *WeDropService {
	return &WeDropService{
		stopChan: make(chan struct{}),
		settings: storage.DefaultSettings(),
	}
}

func (s *WeDropService) startup(ctx context.Context) {
	s.ctx = ctx

	if err := s.initCore(); err != nil {
		log.Printf("wedrop: startup failed: %v", err)
		s.mu.Lock()
		s.initErr = err.Error()
		s.mu.Unlock()
		s.pushState()
		return
	}

	s.mu.Lock()
	s.ready = true
	s.mu.Unlock()
	s.pushState()
}

// ---------------------------------------------------------------- bootstrap

func dataDir() string {
	if runtime.GOOS == "windows" {
		if appdata := os.Getenv("APPDATA"); appdata != "" {
			return filepath.Join(appdata, "WeDrop")
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".wedrop"
	}
	return filepath.Join(home, ".wedrop")
}

func defaultDownloadDir() string {
	if home, err := os.UserHomeDir(); err == nil {
		downloads := filepath.Join(home, "Downloads")
		if info, err := os.Stat(downloads); err == nil && info.IsDir() {
			return filepath.Join(downloads, "WeDrop")
		}
	}
	return filepath.Join(dataDir(), "Downloads")
}

func defaultDeviceName() string {
	if host, err := os.Hostname(); err == nil && host != "" {
		return host
	}
	return "My PC"
}

// loadOrCreateMasterKey returns the key protecting everything else at rest.
func loadOrCreateMasterKey(dir string) ([]byte, error) {
	path := filepath.Join(dir, masterKey)

	if data, err := os.ReadFile(path); err == nil && len(data) == 32 {
		return data, nil
	}

	key := make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, key); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, key, 0o600); err != nil {
		return nil, fmt.Errorf("could not save the encryption key: %w", err)
	}
	return key, nil
}

func (s *WeDropService) initCore() error {
	dir := dataDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("could not create %s: %w", dir, err)
	}

	key, err := loadOrCreateMasterKey(dir)
	if err != nil {
		return err
	}

	store, err := storage.NewStore(key)
	if err != nil {
		return err
	}
	s.store = store

	trust, err := pairing.NewTrustStore(store)
	if err != nil {
		// A damaged trust file is worth reporting but not worth refusing to
		// start over — the user can pair again.
		log.Printf("wedrop: %v", err)
	}
	s.trust = trust
	s.trust.OnChange = func() { s.pushState() }

	if err := s.loadIdentity(); err != nil {
		return err
	}
	s.loadSettings()

	local := transport.LocalInfo{
		Identity:   s.identity,
		Name:       s.deviceName(),
		Platform:   runtime.GOOS,
		FormFactor: protocol.FormDesktop,
	}

	s.disc = discovery.NewService(protocol.DiscoveryMessage{
		DeviceID:   s.identity.DeviceID,
		Name:       local.Name,
		Platform:   local.Platform,
		FormFactor: protocol.FormDesktop,
		TCPPort:    protocol.TransportPort,
		PublicKey:  base64.StdEncoding.EncodeToString(s.identity.PublicKey),
	})
	s.disc.OnPeer = func(peer discovery.Peer) { s.pushState() }
	s.disc.OnPeerLost = func(deviceID string) { s.pushState() }

	s.manager = transport.NewManager(local, s.disc, authorizer{s})
	s.manager.Handler = sessionHandler{s}
	s.manager.Logf = func(format string, args ...interface{}) {
		log.Printf("wedrop: "+format, args...)
	}
	s.manager.LocalDeviceInfo = s.localDeviceInfo
	s.manager.OnPairingRequest = s.handlePairingRequest

	s.registry = plugin.NewRegistry(pluginHost{s})
	s.healthPlugin = health.New(s.identity.DeviceID)
	if err := s.registry.Register(s.healthPlugin, true); err != nil {
		return fmt.Errorf("register health plugin: %w", err)
	}
	s.notifsPlugin = notifications.New(s.peerName)
	if err := s.registry.Register(s.notifsPlugin, true); err != nil {
		return fmt.Errorf("register notifications plugin: %w", err)
	}
	s.clipPlugin = clipboard.New(s.identity.DeviceID, s.deviceName, s.peerName)
	if err := s.registry.Register(s.clipPlugin, true); err != nil {
		return fmt.Errorf("register clipboard plugin: %w", err)
	}
	s.mediaPlugin = media.New()
	if err := s.registry.Register(s.mediaPlugin, true); err != nil {
		return fmt.Errorf("register media plugin: %w", err)
	}
	s.remoteinPlugin = remoteinput.New()
	if err := s.registry.Register(s.remoteinPlugin, true); err != nil {
		return fmt.Errorf("register remote-input plugin: %w", err)
	}
	s.filesPlugin = files.New(s.peerName, s.deviceName)
	if err := s.registry.Register(s.filesPlugin, true); err != nil {
		return fmt.Errorf("register files plugin: %w", err)
	}
	s.workspacePlugin = workspace.New()
	if err := s.registry.Register(s.workspacePlugin, true); err != nil {
		return fmt.Errorf("register workspace plugin: %w", err)
	}
	s.adaptivePlugin = adaptivecontrols.New()
	if err := s.registry.Register(s.adaptivePlugin, true); err != nil {
		return fmt.Errorf("register adaptive-controls plugin: %w", err)
	}
	s.manager.OnTransferOffer = func(conn *transport.SecureConn, peer protocol.DeviceInfo, offer protocol.TransferOffer) {
		s.registry.HandleTransferOffer(conn, peer, offer)
	}

	s.manager.OnSessionChange = func(deviceID string, connected bool) {
		if connected {
			s.trust.TouchLastSeen(deviceID)
			if sess, ok := s.manager.Session(deviceID); ok {
				s.registry.OnPeerConnected(plugin.PeerRef{DeviceID: deviceID, Info: sess.PeerInfo()})
			}
		} else {
			s.registry.OnPeerDisconnected(deviceID)
		}
		s.pushState()
	}

	port, err := s.manager.Start()
	if err != nil {
		return err
	}

	// Announce the port we actually bound. Advertising a fixed port that the
	// listener failed to claim is what made peers report endless connection
	// failures with no visible cause.
	s.updateAnnouncement(port)

	if s.currentSettings().Discoverable {
		if err := s.disc.Start(); err != nil {
			log.Printf("wedrop: discovery unavailable: %v", err)
		}
	}

	if err := s.registry.StartAll(s.ctx); err != nil {
		return fmt.Errorf("start plugins: %w", err)
	}
	return nil
}

func (s *WeDropService) loadIdentity() error {
	var cfg storage.DeviceConfig

	if s.store.FileExists(deviceFile) {
		if err := s.store.LoadEncryptedJSON(deviceFile, &cfg); err == nil && cfg.DeviceID != "" {
			pub, err1 := base64.StdEncoding.DecodeString(cfg.PublicKey)
			priv, err2 := base64.StdEncoding.DecodeString(cfg.PrivateKey)
			if err1 == nil && err2 == nil &&
				len(pub) == ed25519.PublicKeySize && len(priv) == ed25519.PrivateKeySize {
				s.identity = &crypto.Identity{
					DeviceID:   cfg.DeviceID,
					PublicKey:  ed25519.PublicKey(pub),
					PrivateKey: ed25519.PrivateKey(priv),
				}
				s.mu.Lock()
				s.device = cfg
				s.mu.Unlock()
				return nil
			}
			// Keys that will not decode are worse than none: every handshake
			// would fail with an obscure signature error. Start fresh instead.
			log.Printf("wedrop: stored identity was unreadable, generating a new one")
		}
	}

	id, err := crypto.GenerateIdentity()
	if err != nil {
		return fmt.Errorf("could not create a device identity: %w", err)
	}
	s.identity = id

	cfg = storage.DeviceConfig{
		DeviceID:   id.DeviceID,
		Name:       defaultDeviceName(),
		Platform:   runtime.GOOS,
		FormFactor: protocol.FormDesktop,
		PublicKey:  base64.StdEncoding.EncodeToString(id.PublicKey),
		PrivateKey: base64.StdEncoding.EncodeToString(id.PrivateKey),
	}
	if err := s.store.SaveEncryptedJSON(deviceFile, &cfg); err != nil {
		return fmt.Errorf("could not save the device identity: %w", err)
	}

	s.mu.Lock()
	s.device = cfg
	s.mu.Unlock()
	return nil
}

func (s *WeDropService) loadSettings() {
	settings := storage.DefaultSettings()
	if s.store.FileExists(settingsFile) {
		if err := s.store.LoadEncryptedJSON(settingsFile, &settings); err != nil {
			log.Printf("wedrop: settings unreadable, using defaults: %v", err)
			settings = storage.DefaultSettings()
		}
	}
	settings.Normalise(defaultDownloadDir())

	s.mu.Lock()
	s.settings = settings
	s.mu.Unlock()
}

func (s *WeDropService) saveSettings(settings storage.Settings) error {
	settings.Normalise(defaultDownloadDir())

	s.mu.Lock()
	s.settings = settings
	s.mu.Unlock()

	return s.store.SaveEncryptedJSON(settingsFile, &settings)
}

func (s *WeDropService) currentSettings() storage.Settings {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.settings
}

func (s *WeDropService) deviceName() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.device.Name == "" {
		return defaultDeviceName()
	}
	return s.device.Name
}

func (s *WeDropService) updateAnnouncement(port int) {
	s.disc.UpdateConfig(protocol.DiscoveryMessage{
		DeviceID:   s.identity.DeviceID,
		Name:       s.deviceName(),
		Platform:   runtime.GOOS,
		FormFactor: protocol.FormDesktop,
		TCPPort:    port,
		PublicKey:  base64.StdEncoding.EncodeToString(s.identity.PublicKey),
	})
}

func (s *WeDropService) localDeviceInfo() protocol.DeviceInfo {
	settings := s.currentSettings()
	return protocol.DeviceInfo{
		Type:         protocol.TypeDeviceInfo,
		DeviceID:     s.identity.DeviceID,
		Name:         s.deviceName(),
		Platform:     runtime.GOOS,
		FormFactor:   protocol.FormDesktop,
		Capabilities: settings.Capabilities(),
		Battery:      -1,
	}
}

// authorizer answers the handshake's authorisation questions. Membership comes
// from the trust store, but whether pairing is open at all is a live setting,
// so the two are combined here rather than baked into the trust store.
type authorizer struct{ s *WeDropService }

func (a authorizer) TrustedKey(deviceID string) (string, bool) {
	return a.s.trust.TrustedKey(deviceID)
}

func (a authorizer) PairingAllowed() bool {
	return a.s.currentSettings().AcceptNewPairing
}

// ---------------------------------------------------------------- pairing

func (s *WeDropService) handlePairingRequest(req transport.PairingRequest) transport.PairingDecision {
	if !s.currentSettings().AcceptNewPairing {
		return transport.PairingDecision{Accepted: false, Reason: "this device is not accepting new pairings"}
	}

	reply := make(chan bool, 1)

	s.pairingMu.Lock()
	if s.pairingPrompt != nil {
		s.pairingMu.Unlock()
		return transport.PairingDecision{Accepted: false, Reason: "another pairing request is already open"}
	}
	prompt := &PairingPrompt{
		DeviceID:         req.DeviceID,
		Name:             req.Name,
		Platform:         req.Platform,
		FormFactor:       req.FormFactor,
		VerificationCode: req.VerificationCode,
		Address:          req.Address,
		ExpiresAt:        time.Now().Add(pairingTimeout).UnixMilli(),
	}
	s.pairingPrompt = prompt
	s.pairingReply = reply
	s.pairingMu.Unlock()

	s.emit("pairing:request", prompt)
	s.pushState()
	s.showWindow()

	clear := func() {
		s.pairingMu.Lock()
		s.pairingPrompt = nil
		s.pairingReply = nil
		s.pairingMu.Unlock()
		s.pushState()
	}

	var accepted bool
	select {
	case accepted = <-reply:
	case <-time.After(pairingTimeout):
		// Timing out rather than blocking forever matters: the old code parked
		// a goroutine on an unbuffered channel with no deadline, so a request
		// the user never saw held the connection open indefinitely.
		clear()
		s.toast("info", fmt.Sprintf("Pairing request from %s timed out", req.Name))
		return transport.PairingDecision{Accepted: false, Reason: "the other device did not respond in time"}
	case <-s.stopChan:
		clear()
		return transport.PairingDecision{Accepted: false, Reason: "the other device is shutting down"}
	}
	clear()

	if !accepted {
		return transport.PairingDecision{Accepted: false, Reason: "declined"}
	}

	// Store the key proved during the handshake, never one read from a UDP
	// announcement — the announcement is unauthenticated and anyone on the
	// network can forge it.
	device := storage.TrustedDevice{
		DeviceID:   req.DeviceID,
		Name:       req.Name,
		Platform:   req.Platform,
		FormFactor: req.FormFactor,
		PublicKey:  req.PublicKey,
	}
	if err := s.trust.Add(device); err != nil {
		return transport.PairingDecision{Accepted: false, Reason: "could not save the device"}
	}

	s.toast("success", fmt.Sprintf("%s joined your ecosystem", req.Name))
	return transport.PairingDecision{Accepted: true}
}

// ---------------------------------------------- transport.SessionHandler

// sessionHandler keeps the session callbacks off WeDropService itself. Wails
// binds every exported method of a bound struct, so implementing the interface
// directly on the service would publish these internal handlers to JavaScript
// and drag the whole transport package into the generated TypeScript models.
type sessionHandler struct{ s *WeDropService }

// OnMessage routes every feature message to whichever plugin claimed its
// type (device-health, notifications, clipboard, media, remote input — see
// s.registry) — every feature has now been extracted into its own plugin
// package, so nothing is left to handle directly here.
func (h sessionHandler) OnMessage(session *transport.Session, msgType protocol.MessageType, raw []byte) {
	h.s.registry.OnMessage(plugin.PeerRef{DeviceID: session.DeviceID(), Info: session.PeerInfo()}, msgType, raw)
}

func (h sessionHandler) OnDeviceInfo(session *transport.Session, info protocol.DeviceInfo) {
	h.s.onDeviceInfo(session, info)
}

func (h sessionHandler) OnUnpair(session *transport.Session, msg protocol.Unpair) {
	h.s.onUnpair(session, msg)
}

func (h sessionHandler) OnClosed(session *transport.Session, err error) {
	h.s.onClosed(session, err)
}

// -------------------------------------------------------- plugin.Host

// pluginHost gives every registered plugin's API a way to reach real peers,
// persist settings, and surface events, without any plugin importing Wails
// or transport directly. Kept as a separate unexported type for the same
// reason as sessionHandler: WeDropService itself must only expose methods
// meant for the frontend.
type pluginHost struct{ s *WeDropService }

func (h pluginHost) Send(deviceID string, v interface{}) error {
	return h.s.manager.SendTo(deviceID, v)
}

func (h pluginHost) Broadcast(capability string, v interface{}) {
	h.s.manager.Broadcast(capability, v)
}

func (h pluginHost) ConnectedPeers(capability string) []plugin.PeerRef {
	ids := h.s.manager.ConnectedDevices()
	out := make([]plugin.PeerRef, 0, len(ids))
	for _, id := range ids {
		sess, ok := h.s.manager.Session(id)
		if !ok {
			continue
		}
		if capability != "" && !sess.Supports(capability) {
			continue
		}
		out = append(out, plugin.PeerRef{DeviceID: id, Info: sess.PeerInfo()})
	}
	return out
}

func (h pluginHost) Allows(deviceID string, capability string) bool {
	return h.s.trust.Allows(deviceID, capability)
}

func (h pluginHost) Emit(event plugin.Event) {
	// The files plugin's "incoming"/"progress" events have dedicated
	// frontend listeners (transfer:incoming/transfer:progress) predating
	// the plugin architecture — preserve those exact wire names. Every
	// other plugin's state (e.g. health readings) is read back out through
	// GetState, so raising an event just needs the next state push to
	// happen.
	if event.Plugin == files.ID {
		switch event.Name {
		case "incoming":
			h.s.emit("transfer:incoming", event.Payload)
		case "progress":
			h.s.emit("transfer:progress", event.Payload)
		}
	}
	h.s.pushState()
}

func (h pluginHost) ShowWindow() {
	h.s.showWindow()
}

func (h pluginHost) Toast(level, message string) {
	h.s.toast(level, message)
}

// DialTransfer opens a new outbound connection to a peer for a file
// transfer, which needs its own connection (separate from the shared
// control session) so a large file cannot stall clipboard sync or
// keepalives behind it.
func (h pluginHost) DialTransfer(deviceID string) (plugin.TransferConn, protocol.DeviceInfo, error) {
	if !h.s.trust.IsTrusted(deviceID) {
		return nil, protocol.DeviceInfo{}, fmt.Errorf("that device is not in your ecosystem")
	}
	peer, ok := h.s.disc.Peer(deviceID)
	if !ok {
		return nil, protocol.DeviceInfo{}, fmt.Errorf("%s is not on the network right now", h.s.peerName(deviceID, ""))
	}
	key, trusted := h.s.trust.TrustedKey(deviceID)
	if !trusted {
		return nil, protocol.DeviceInfo{}, fmt.Errorf("device is not paired")
	}

	local := transport.LocalInfo{
		Identity:   h.s.identity,
		Name:       h.s.deviceName(),
		Platform:   runtime.GOOS,
		FormFactor: protocol.FormDesktop,
	}
	address := fmt.Sprintf("%s:%d", peer.IP, peer.TCPPort)
	result, err := transport.Dial(address, local, protocol.IntentTransfer, key, 8*time.Second)
	if err != nil {
		return nil, protocol.DeviceInfo{}, err
	}
	return result.Conn, result.Peer, nil
}

// LoadPluginSettings bridges each plugin's own settings shape from the
// existing shared storage.Settings struct, until the settings/capability
// de-hardcoding migration (see plan) gives every plugin real, independently
// persisted settings. Read fresh every call, matching how the pre-plugin
// code always read s.currentSettings() live rather than caching a copy.
func (h pluginHost) LoadPluginSettings(id plugin.ID) []byte {
	settings := h.s.currentSettings()
	switch id {
	case notifications.ID:
		data, _ := json.Marshal(notifications.Settings{Receive: settings.ReceiveNotifications})
		return data
	case clipboard.ID:
		data, _ := json.Marshal(clipboard.Settings{
			AutoSync: settings.AutoSyncClipboard,
			Receive:  settings.ReceiveClipboard,
			MaxChars: settings.ClipboardMaxChars,
		})
		return data
	case media.ID:
		data, _ := json.Marshal(media.Settings{AllowControl: settings.AllowMediaControl})
		return data
	case remoteinput.ID:
		data, _ := json.Marshal(remoteinput.Settings{AllowControl: settings.AllowMediaControl})
		return data
	case files.ID:
		data, _ := json.Marshal(files.Settings{
			AutoAccept:  settings.AutoAcceptFiles,
			DownloadDir: settings.DownloadDir,
		})
		return data
	case workspace.ID:
		data, _ := json.Marshal(workspace.Settings{AllowAutomation: settings.AllowAutomation})
		return data
	}
	return nil
}

// SavePluginSettings is unused so far — every plugin's settings today are
// still owned by storage.Settings and changed through UpdateSettings
// (api.go), not through the plugin itself.
func (h pluginHost) SavePluginSettings(id plugin.ID, data []byte) error { return nil }

func (s *WeDropService) onDeviceInfo(session *transport.Session, info protocol.DeviceInfo) {
	// Keep the stored display name in step with what the peer calls itself.
	if device, ok := s.trust.Get(session.DeviceID()); ok && info.Name != "" && device.Name != info.Name {
		s.trust.Rename(session.DeviceID(), info.Name)
	}
	s.pushState()
}

func (s *WeDropService) onUnpair(session *transport.Session, msg protocol.Unpair) {
	name := s.peerName(session.DeviceID(), session.PeerInfo().Name)
	s.trust.Remove(session.DeviceID())
	s.manager.Disconnect(session.DeviceID())
	s.toast("info", fmt.Sprintf("%s left your ecosystem", name))
	s.pushState()
}

func (s *WeDropService) onClosed(session *transport.Session, err error) {
	if err != nil {
		log.Printf("wedrop: session with %s ended: %v", session.DeviceID(), err)
	}
}

// ---------------------------------------------------------------- helpers

func (s *WeDropService) peerName(deviceID, fallback string) string {
	if device, ok := s.trust.Get(deviceID); ok && device.Name != "" {
		return device.Name
	}
	if fallback != "" {
		return fallback
	}
	if len(deviceID) > 8 {
		return deviceID[:8]
	}
	return deviceID
}

func (s *WeDropService) emit(event string, data ...interface{}) {
	if s.ctx == nil {
		return
	}
	wailsRuntime.EventsEmit(s.ctx, event, data...)
}

func (s *WeDropService) toast(level, message string) {
	s.emit("toast", map[string]string{"level": level, "message": message})
}

func (s *WeDropService) showWindow() {
	if s.ctx == nil {
		return
	}
	wailsRuntime.WindowShow(s.ctx)
	wailsRuntime.WindowUnminimise(s.ctx)
}

// pushState coalesces state broadcasts. Discovery, sessions and transfers all
// call it, and without coalescing a busy moment would serialise the whole state
// to the frontend dozens of times a second.
func (s *WeDropService) pushState() {
	if s.ctx == nil {
		return
	}

	s.emitMu.Lock()
	if s.emitPending {
		s.emitMu.Unlock()
		return
	}
	s.emitPending = true
	s.emitMu.Unlock()

	go func() {
		time.Sleep(80 * time.Millisecond)

		s.emitMu.Lock()
		s.emitPending = false
		s.lastEmitted = time.Now()
		s.emitMu.Unlock()

		s.emit("state", s.GetState())
	}()
}

// shutdown tears everything down when the app really exits.
func (s *WeDropService) shutdown(ctx context.Context) {
	s.stopOnce.Do(func() { close(s.stopChan) })

	if s.registry != nil {
		s.registry.StopAll()
	}
	if s.manager != nil {
		s.manager.Stop()
	}
	if s.disc != nil {
		s.disc.Stop()
	}
}

// platformLabel gives the UI something friendlier than "windows".
func platformLabel(platform string) string {
	switch strings.ToLower(platform) {
	case "windows":
		return "Windows"
	case "darwin":
		return "macOS"
	case "linux":
		return "Linux"
	case "android":
		return "Android"
	case "ios":
		return "iOS"
	}
	return platform
}
