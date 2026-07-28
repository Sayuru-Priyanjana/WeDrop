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

	"github.com/atotto/clipboard"
	"github.com/google/uuid"
	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"

	"wedrop/core/crypto"
	"wedrop/core/discovery"
	"wedrop/core/pairing"
	"wedrop/core/plugin"
	"wedrop/core/protocol"
	"wedrop/core/storage"
	"wedrop/core/transfer"
	"wedrop/core/transport"

	"desktop/plugins/health"
	"desktop/plugins/notifications"
)

const (
	settingsFile = "settings.json"
	deviceFile   = "device.json"
	masterKey    = "master.key"

	// clipboardPoll is the interval at which the local clipboard is read.
	// Windows offers no cheap change notification without a message loop, so
	// this polls — but it only compares a hash and does nothing else when the
	// clipboard is unchanged, which is the overwhelmingly common case.
	clipboardPoll = 700 * time.Millisecond

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

	transfersMu sync.Mutex
	transfers   map[string]*TransferView
	pendingIn   map[string]chan bool

	clipHistory  *ringBuffer[ClipboardEntry]
	lastClipHash string
	clipSeq      int64
	clipMu       sync.Mutex

	// Latest media state received from each peer, keyed by device ID. Health
	// and notifications moved to their own plugins (desktop/plugins/*) — see
	// s.registry.
	peerStateMu sync.RWMutex
	peerMedia   map[string]protocol.MediaState

	registry     *plugin.Registry
	healthPlugin *health.Plugin
	notifsPlugin *notifications.Plugin

	stopChan chan struct{}
	stopOnce sync.Once

	emitMu      sync.Mutex
	emitPending bool
	lastEmitted time.Time
}

// NewWeDropService constructs the service; no I/O happens until startup.
func NewWeDropService() *WeDropService {
	return &WeDropService{
		transfers:   make(map[string]*TransferView),
		pendingIn:   make(map[string]chan bool),
		clipHistory: newRingBuffer[ClipboardEntry](50),
		peerMedia:   make(map[string]protocol.MediaState),
		stopChan:    make(chan struct{}),
		settings:    storage.DefaultSettings(),
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
	s.manager.OnTransferOffer = s.handleTransferOffer

	s.registry = plugin.NewRegistry(pluginHost{s})
	s.healthPlugin = health.New(s.identity.DeviceID)
	if err := s.registry.Register(s.healthPlugin, true); err != nil {
		return fmt.Errorf("register health plugin: %w", err)
	}
	s.notifsPlugin = notifications.New(s.peerName)
	if err := s.registry.Register(s.notifsPlugin, true); err != nil {
		return fmt.Errorf("register notifications plugin: %w", err)
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

	go s.clipboardWatcher()
	go s.nowPlayingBroadcaster()
	return nil
}

// nowPlayingBroadcaster periodically shares what this device is playing, so a
// paired phone can show and control it. On platforms without an implementation
// (see media_now_playing_other.go), nowPlayingInterval is zero and this exits
// immediately rather than spinning on a zero-duration ticker.
func (s *WeDropService) nowPlayingBroadcaster() {
	if nowPlayingInterval <= 0 {
		return
	}

	ticker := time.NewTicker(nowPlayingInterval)
	defer ticker.Stop()

	for {
		select {
		case <-s.stopChan:
			return
		case <-ticker.C:
			s.broadcastNowPlaying()
		}
	}
}

func (s *WeDropService) broadcastNowPlaying() {
	if !s.currentSettings().AllowMediaControl {
		return
	}
	if len(s.manager.ConnectedDevices()) == 0 {
		return
	}
	s.manager.Broadcast(protocol.CapMedia, collectNowPlaying())
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

// ---------------------------------------------------------------- transfers

func (s *WeDropService) handleTransferOffer(conn *transport.SecureConn, peer protocol.DeviceInfo, offer protocol.TransferOffer) {
	defer conn.Close()

	settings := s.currentSettings()
	receiver := transfer.NewReceiver(conn, settings.DownloadDir)

	if !s.trust.Allows(peer.DeviceID, protocol.CapFiles) {
		receiver.Decline(offer, "file transfers from this device are switched off")
		return
	}

	name := s.peerName(peer.DeviceID, peer.Name)
	view := &TransferView{
		ID:         offer.TransferID,
		DeviceID:   peer.DeviceID,
		DeviceName: name,
		Filename:   offer.Filename,
		Size:       offer.Size,
		Incoming:   true,
		State:      TransferPending,
		StartedAt:  nowMillis(),
		UpdatedAt:  nowMillis(),
	}
	s.putTransfer(view)

	if !settings.AutoAcceptFiles {
		decision := make(chan bool, 1)

		s.transfersMu.Lock()
		s.pendingIn[offer.TransferID] = decision
		s.transfersMu.Unlock()

		s.emit("transfer:incoming", view)
		s.showWindow()

		var accepted bool
		select {
		case accepted = <-decision:
		case <-time.After(2 * time.Minute):
			accepted = false
		case <-s.stopChan:
			accepted = false
		}

		s.transfersMu.Lock()
		delete(s.pendingIn, offer.TransferID)
		s.transfersMu.Unlock()

		if !accepted {
			receiver.Decline(offer, "declined")
			s.updateTransfer(offer.TransferID, func(t *TransferView) {
				t.State = TransferDeclined
			})
			return
		}
	}

	s.updateTransfer(offer.TransferID, func(t *TransferView) { t.State = TransferActive })

	throttle := newProgressThrottle()
	receiver.OnProgress = func(done, total int64) {
		if throttle.should(done, total) {
			s.updateTransfer(offer.TransferID, func(t *TransferView) { t.Transferred = done })
		}
	}

	savedPath, err := receiver.Receive(offer)
	if err != nil {
		s.updateTransfer(offer.TransferID, func(t *TransferView) {
			t.State = TransferFailed
			t.Error = err.Error()
		})
		s.toast("error", fmt.Sprintf("Could not receive %s: %v", offer.Filename, err))
		return
	}

	s.updateTransfer(offer.TransferID, func(t *TransferView) {
		t.State = TransferCompleted
		t.Transferred = offer.Size
		t.SavedPath = savedPath
	})
	s.toast("success", fmt.Sprintf("Received %s from %s", offer.Filename, name))
}

func (s *WeDropService) putTransfer(view *TransferView) {
	s.transfersMu.Lock()
	s.transfers[view.ID] = view
	s.transfersMu.Unlock()
	s.pushState()
}

func (s *WeDropService) updateTransfer(id string, fn func(*TransferView)) {
	s.transfersMu.Lock()
	view, ok := s.transfers[id]
	if ok {
		fn(view)
		view.UpdatedAt = nowMillis()
	}
	copyOfView := *view
	s.transfersMu.Unlock()

	if !ok {
		return
	}
	s.emit("transfer:progress", copyOfView)
	if copyOfView.State != TransferActive {
		s.pushState()
	}
}

// progressThrottle keeps a fast transfer from flooding the UI bridge with an
// event per 256 KiB chunk, which costs more than the transfer itself.
type progressThrottle struct {
	last time.Time
}

func newProgressThrottle() *progressThrottle { return &progressThrottle{} }

func (p *progressThrottle) should(done, total int64) bool {
	if done >= total {
		return true
	}
	if time.Since(p.last) < 120*time.Millisecond {
		return false
	}
	p.last = time.Now()
	return true
}

// ---------------------------------------------------------------- clipboard

func (s *WeDropService) clipboardWatcher() {
	ticker := time.NewTicker(clipboardPoll)
	defer ticker.Stop()

	for {
		select {
		case <-s.stopChan:
			return
		case <-ticker.C:
			s.checkClipboard()
		}
	}
}

func (s *WeDropService) checkClipboard() {
	settings := s.currentSettings()
	if !settings.AutoSyncClipboard {
		return
	}
	// Nothing to broadcast to, so do not even touch the clipboard.
	if len(s.manager.ConnectedDevices()) == 0 {
		return
	}

	text, err := clipboard.ReadAll()
	if err != nil || text == "" {
		return
	}
	if len(text) > settings.ClipboardMaxChars {
		return
	}

	hash := crypto.HashBytes([]byte(text))

	s.clipMu.Lock()
	if hash == s.lastClipHash {
		s.clipMu.Unlock()
		return
	}
	s.lastClipHash = hash
	s.clipSeq++
	seq := s.clipSeq
	s.clipMu.Unlock()

	s.clipHistory.Push(ClipboardEntry{
		Text:       text,
		Origin:     s.identity.DeviceID,
		OriginName: s.deviceName(),
		Time:       nowMillis(),
		Incoming:   false,
	})

	s.manager.Broadcast(protocol.CapClipboard, protocol.ClipboardMessage{
		Type:     protocol.TypeClipboard,
		Text:     text,
		Origin:   s.identity.DeviceID,
		Sequence: seq,
		Hash:     hash,
	})
	s.pushState()
}

// ---------------------------------------------- transport.SessionHandler

// sessionHandler keeps the session callbacks off WeDropService itself. Wails
// binds every exported method of a bound struct, so implementing the interface
// directly on the service would publish these internal handlers to JavaScript
// and drag the whole transport package into the generated TypeScript models.
type sessionHandler struct{ s *WeDropService }

// OnMessage first offers the message to the plugin registry (features
// already extracted into their own package — today, device-health and
// notifications) and falls back to the not-yet-extracted feature switch
// below. registry silently no-ops for a message type nothing has claimed,
// so this ordering is always safe. Once every feature is extracted, the
// switch disappears entirely.
func (h sessionHandler) OnMessage(session *transport.Session, msgType protocol.MessageType, raw []byte) {
	h.s.registry.OnMessage(plugin.PeerRef{DeviceID: session.DeviceID(), Info: session.PeerInfo()}, msgType, raw)

	switch msgType {
	case protocol.TypeClipboard:
		var msg protocol.ClipboardMessage
		if json.Unmarshal(raw, &msg) == nil {
			h.s.onClipboard(session, msg)
		}
	case protocol.TypeMedia:
		var msg protocol.MediaMessage
		if json.Unmarshal(raw, &msg) == nil {
			h.s.onMedia(session, msg)
		}
	case protocol.TypeMediaState:
		var msg protocol.MediaState
		if json.Unmarshal(raw, &msg) == nil {
			h.s.onMediaState(session, msg)
		}
	case protocol.TypeRemoteInput:
		var msg protocol.RemoteInput
		if json.Unmarshal(raw, &msg) == nil {
			h.s.onRemoteInput(session, msg)
		}
	}
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
	// Today no plugin event has a dedicated frontend listener — a plugin's
	// state (e.g. health readings) is read back out through GetState, so a
	// plugin raising an event just needs the next state push to happen.
	h.s.pushState()
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
	}
	return nil
}

// SavePluginSettings is unused so far — every plugin's settings today are
// still owned by storage.Settings and changed through UpdateSettings
// (api.go), not through the plugin itself.
func (h pluginHost) SavePluginSettings(id plugin.ID, data []byte) error { return nil }

func (s *WeDropService) onClipboard(session *transport.Session, msg protocol.ClipboardMessage) {
	settings := s.currentSettings()
	if !settings.ReceiveClipboard {
		return
	}
	if !s.trust.Allows(session.DeviceID(), protocol.CapClipboard) {
		return
	}
	if msg.Text == "" || len(msg.Text) > settings.ClipboardMaxChars {
		return
	}

	hash := msg.Hash
	if hash == "" {
		hash = crypto.HashBytes([]byte(msg.Text))
	}

	// Record the hash before writing, so our own watcher does not see the text
	// we just pasted in as a fresh local copy and bounce it back around the
	// ecosystem forever.
	s.clipMu.Lock()
	if hash == s.lastClipHash {
		s.clipMu.Unlock()
		return
	}
	s.lastClipHash = hash
	s.clipMu.Unlock()

	if err := clipboard.WriteAll(msg.Text); err != nil {
		log.Printf("wedrop: could not write to the clipboard: %v", err)
		return
	}

	name := s.peerName(session.DeviceID(), session.PeerInfo().Name)
	s.clipHistory.Push(ClipboardEntry{
		Text:       msg.Text,
		Origin:     session.DeviceID(),
		OriginName: name,
		Time:       nowMillis(),
		Incoming:   true,
	})
	s.emit("clipboard:received", name)
	s.pushState()
}

func (s *WeDropService) onMedia(session *transport.Session, msg protocol.MediaMessage) {
	if !s.currentSettings().AllowMediaControl {
		return
	}
	if !s.trust.Allows(session.DeviceID(), protocol.CapMedia) {
		return
	}

	if msg.Command == protocol.MediaSeek {
		if err := trySeekPlatform(msg.Position); err != nil {
			log.Printf("wedrop: seek to %dms failed: %v", msg.Position, err)
			return
		}
		s.emit("media:applied", msg.Command)
		return
	}

	if msg.Command == protocol.MediaSetVolume {
		if err := setVolumePlatform(msg.Volume); err != nil {
			log.Printf("wedrop: set volume to %d%% failed: %v", msg.Volume, err)
			return
		}
		s.emit("media:applied", msg.Command)
		return
	}

	if err := applyMediaCommand(msg.Command); err != nil {
		log.Printf("wedrop: media command %q failed: %v", msg.Command, err)
		return
	}
	s.emit("media:applied", msg.Command)
}

func (s *WeDropService) onMediaState(session *transport.Session, msg protocol.MediaState) {
	s.peerStateMu.Lock()
	s.peerMedia[session.DeviceID()] = msg
	s.peerStateMu.Unlock()
	s.pushState()
}

func (s *WeDropService) onRemoteInput(session *transport.Session, msg protocol.RemoteInput) {
	// Remote control is gated by the same per-device media permission as the
	// media keys — turning off "control my media" also disarms the touchpad and
	// keyboard, so one switch covers "let this device drive me".
	if !s.currentSettings().AllowMediaControl {
		return
	}
	if !s.trust.Allows(session.DeviceID(), protocol.CapMedia) {
		return
	}
	applyRemoteInput(msg)
}

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

func newTransferID() string { return uuid.NewString() }

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
