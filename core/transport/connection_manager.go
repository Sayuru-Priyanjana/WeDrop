package transport

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"net"
	"sync"
	"time"

	"wedrop/core/discovery"
	"wedrop/core/protocol"
)

const (
	dialTimeout    = 4 * time.Second
	reconnectEvery = 3 * time.Second
	minBackoff     = 2 * time.Second
	maxBackoff     = 60 * time.Second
)

// PairingDecision is what the UI returns when a device asks to join.
type PairingDecision struct {
	Accepted bool
	Reason   string
}

// Manager owns the TCP listener, keeps a session open to every trusted peer
// that is online, and routes inbound connections by intent.
//
// The dialling loop deliberately never holds the session lock across a network
// call. The previous version dialled with the mutex held, so one unreachable
// peer froze clipboard sync and the device list for the full dial timeout on
// every tick.
type Manager struct {
	local     LocalInfo
	discovery *discovery.Service
	auth      PeerAuthorizer

	mu       sync.RWMutex
	sessions map[string]*sessionEntry
	dialing  map[string]struct{}
	backoff  map[string]*backoffState

	listener net.Listener
	port     int

	stopChan chan struct{}
	stopOnce sync.Once
	wg       sync.WaitGroup

	// Handler receives control messages from every session.
	Handler SessionHandler
	// OnPairingRequest is called when an untrusted device asks to join. It is
	// invoked on its own goroutine and may block while the user decides.
	OnPairingRequest func(req PairingRequest) PairingDecision
	// OnTransferOffer is called for an inbound transfer connection. The callee
	// owns the connection and must close it.
	OnTransferOffer func(conn *SecureConn, peer protocol.DeviceInfo, offer protocol.TransferOffer)
	// OnSessionChange fires whenever a peer connects or disconnects.
	OnSessionChange func(deviceID string, connected bool)
	// LocalDeviceInfo supplies the device info sent when a session opens.
	LocalDeviceInfo func() protocol.DeviceInfo
	// Logf receives diagnostics; nil disables logging.
	Logf func(format string, args ...interface{})
}

// PairingRequest describes an authenticated device asking to be added.
type PairingRequest struct {
	DeviceID         string
	Name             string
	Platform         string
	FormFactor       protocol.FormFactor
	PublicKey        string
	VerificationCode string
	Address          string
}

type sessionEntry struct {
	session  *Session
	outbound bool
}

type backoffState struct {
	next     time.Time
	duration time.Duration
}

// NewManager creates a connection manager. It does not touch the network until
// Start is called.
func NewManager(local LocalInfo, disc *discovery.Service, auth PeerAuthorizer) *Manager {
	return &Manager{
		local:     local,
		discovery: disc,
		auth:      auth,
		sessions:  make(map[string]*sessionEntry),
		dialing:   make(map[string]struct{}),
		backoff:   make(map[string]*backoffState),
		stopChan:  make(chan struct{}),
	}
}

// Start binds the listener and begins maintaining sessions. It returns the port
// actually bound, which the caller should announce over discovery — the old
// code advertised a hard-coded port even when the bind had failed, so peers
// spent their time dialling a socket that was not there.
func (m *Manager) Start() (int, error) {
	listener, err := net.Listen("tcp", fmt.Sprintf(":%d", protocol.TransportPort))
	if err != nil {
		// Fall back to an ephemeral port so a second instance, or a leftover
		// socket in TIME_WAIT, degrades instead of disabling the app.
		listener, err = net.Listen("tcp", ":0")
		if err != nil {
			return 0, fmt.Errorf("could not open a listening socket: %w", err)
		}
	}
	m.listener = listener
	m.port = listener.Addr().(*net.TCPAddr).Port

	m.wg.Add(2)
	go m.acceptLoop()
	go m.maintainLoop()
	return m.port, nil
}

// Port is the TCP port peers should connect to.
func (m *Manager) Port() int { return m.port }

// Stop closes the listener and every session.
func (m *Manager) Stop() {
	m.stopOnce.Do(func() {
		close(m.stopChan)
		if m.listener != nil {
			m.listener.Close()
		}

		m.mu.Lock()
		sessions := make([]*sessionEntry, 0, len(m.sessions))
		for _, e := range m.sessions {
			sessions = append(sessions, e)
		}
		m.sessions = make(map[string]*sessionEntry)
		m.mu.Unlock()

		for _, e := range sessions {
			e.session.Close()
		}
		m.wg.Wait()
	})
}

func (m *Manager) logf(format string, args ...interface{}) {
	if m.Logf != nil {
		m.Logf(format, args...)
	}
}

// ---------------------------------------------------------------- inbound

func (m *Manager) acceptLoop() {
	defer m.wg.Done()

	for {
		conn, err := m.listener.Accept()
		if err != nil {
			select {
			case <-m.stopChan:
				return
			default:
			}
			// A transient accept error should not kill the listener, but
			// spinning on a permanent one would burn a core.
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go m.handleInbound(conn)
	}
}

func (m *Manager) handleInbound(conn net.Conn) {
	result, err := Accept(conn, m.local, m.auth)
	if err != nil {
		m.logf("rejected connection from %s: %v", conn.RemoteAddr(), err)
		conn.Close()
		return
	}

	switch result.Intent {
	case protocol.IntentPair:
		m.handlePairing(result, conn.RemoteAddr().String())
	case protocol.IntentSession:
		m.adoptSession(result, false)
	case protocol.IntentTransfer:
		m.handleInboundTransfer(result)
	default:
		result.Conn.Close()
	}
}

func (m *Manager) handlePairing(result *HandshakeResult, address string) {
	defer result.Conn.Close()

	if m.OnPairingRequest == nil {
		result.Conn.WriteJSON(protocol.PairingResp{
			Type: protocol.TypePairingResp, DeviceID: m.local.Identity.DeviceID,
			Accepted: false, Reason: "device cannot accept pairing right now",
		})
		return
	}

	decision := m.OnPairingRequest(PairingRequest{
		DeviceID:         result.Peer.DeviceID,
		Name:             result.Peer.Name,
		Platform:         result.Peer.Platform,
		FormFactor:       result.Peer.FormFactor,
		PublicKey:        result.PeerPublicKey,
		VerificationCode: result.VerificationCode,
		Address:          address,
	})

	local := protocol.DeviceInfo{}
	if m.LocalDeviceInfo != nil {
		local = m.LocalDeviceInfo()
	}

	result.Conn.WriteJSON(protocol.PairingResp{
		Type:     protocol.TypePairingResp,
		DeviceID: m.local.Identity.DeviceID,
		Name:     local.Name,
		Accepted: decision.Accepted,
		Reason:   decision.Reason,
	})

	if decision.Accepted {
		// Connect straight away rather than waiting for the next maintenance
		// tick, so the device turns green the moment the user taps Accept.
		m.AnnounceAndReconnect(result.Peer.DeviceID)
	}
}

func (m *Manager) handleInboundTransfer(result *HandshakeResult) {
	if m.OnTransferOffer == nil {
		result.Conn.Close()
		return
	}

	result.Conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	msgBytes, err := result.Conn.ReadEncrypted()
	if err != nil {
		result.Conn.Close()
		return
	}

	msgType, err := protocol.ParseMessageType(msgBytes)
	if err != nil || msgType != protocol.TypeTransferOffer {
		result.Conn.Close()
		return
	}

	var offer protocol.TransferOffer
	if err := json.Unmarshal(msgBytes, &offer); err != nil {
		result.Conn.Close()
		return
	}

	// The callee owns the connection from here, including closing it.
	m.OnTransferOffer(result.Conn, result.Peer, offer)
}

// ---------------------------------------------------------------- outbound

func (m *Manager) maintainLoop() {
	defer m.wg.Done()

	ticker := time.NewTicker(reconnectEvery)
	defer ticker.Stop()

	for {
		select {
		case <-m.stopChan:
			return
		case <-ticker.C:
			m.connectMissing()
		}
	}
}

// connectMissing dials every trusted, online peer we are not already talking
// to. Each dial runs on its own goroutine so a slow peer never delays the rest.
func (m *Manager) connectMissing() {
	for _, peer := range m.discovery.Peers() {
		key, trusted := m.auth.TrustedKey(peer.DeviceID)
		if !trusted {
			continue
		}
		if !m.shouldDial(peer.DeviceID) {
			continue
		}

		m.mu.Lock()
		m.dialing[peer.DeviceID] = struct{}{}
		m.mu.Unlock()

		go m.dialPeer(peer, key)
	}
}

func (m *Manager) shouldDial(deviceID string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()

	if _, connected := m.sessions[deviceID]; connected {
		return false
	}
	if _, inFlight := m.dialing[deviceID]; inFlight {
		return false
	}
	if b, ok := m.backoff[deviceID]; ok && time.Now().Before(b.next) {
		return false
	}
	return true
}

func (m *Manager) dialPeer(peer discovery.Peer, expectedKey string) {
	defer func() {
		m.mu.Lock()
		delete(m.dialing, peer.DeviceID)
		m.mu.Unlock()
	}()

	address := net.JoinHostPort(peer.IP, fmt.Sprint(peer.TCPPort))
	result, err := Dial(address, m.local, protocol.IntentSession, expectedKey, dialTimeout)
	if err != nil {
		m.noteFailure(peer.DeviceID)
		m.logf("connect to %s (%s) failed: %v", peer.Name, address, err)
		return
	}

	m.clearBackoff(peer.DeviceID)
	m.adoptSession(result, true)
}

func (m *Manager) noteFailure(deviceID string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	b, ok := m.backoff[deviceID]
	if !ok {
		b = &backoffState{duration: minBackoff}
		m.backoff[deviceID] = b
	} else {
		b.duration *= 2
		if b.duration > maxBackoff {
			b.duration = maxBackoff
		}
	}
	// Jitter keeps a roomful of devices from retrying in lockstep after the
	// Wi-Fi access point restarts.
	jitter := time.Duration(rand.Int63n(int64(b.duration / 4)))
	b.next = time.Now().Add(b.duration + jitter)
}

func (m *Manager) clearBackoff(deviceID string) {
	m.mu.Lock()
	delete(m.backoff, deviceID)
	m.mu.Unlock()
}

// AnnounceAndReconnect clears any backoff for a device and tries it at once.
func (m *Manager) AnnounceAndReconnect(deviceID string) {
	m.clearBackoff(deviceID)
	m.discovery.AnnounceNow()

	peer, ok := m.discovery.Peer(deviceID)
	if !ok {
		return
	}
	key, trusted := m.auth.TrustedKey(deviceID)
	if !trusted || !m.shouldDial(deviceID) {
		return
	}

	m.mu.Lock()
	m.dialing[deviceID] = struct{}{}
	m.mu.Unlock()

	go m.dialPeer(peer, key)
}

// ---------------------------------------------------------------- sessions

// adoptSession installs a new session, resolving the case where both devices
// dialled each other at the same moment.
//
// Both ends apply the same rule — keep the connection dialled by whichever
// device has the smaller ID — so they independently agree on which socket
// survives, instead of each closing the other's and ending up with none.
func (m *Manager) adoptSession(result *HandshakeResult, outbound bool) {
	deviceID := result.Peer.DeviceID

	m.mu.Lock()
	if existing, ok := m.sessions[deviceID]; ok {
		preferOutbound := m.local.Identity.DeviceID < deviceID
		if existing.outbound == preferOutbound || outbound != preferOutbound {
			// The session we already have is the preferred one (or this new
			// one is not); drop the duplicate.
			m.mu.Unlock()
			result.Conn.Close()
			return
		}
		delete(m.sessions, deviceID)
		m.mu.Unlock()
		existing.session.Close()
		m.mu.Lock()
	}

	session := NewSession(result.Conn, result.Peer, m)
	m.sessions[deviceID] = &sessionEntry{session: session, outbound: outbound}
	m.mu.Unlock()

	if m.LocalDeviceInfo != nil {
		session.Send(m.LocalDeviceInfo())
	}
	if m.OnSessionChange != nil {
		m.OnSessionChange(deviceID, true)
	}

	go session.Run()
}

// Session returns the live session for a device, if any.
func (m *Manager) Session(deviceID string) (*Session, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	e, ok := m.sessions[deviceID]
	if !ok {
		return nil, false
	}
	return e.session, true
}

// ConnectedDevices lists the device IDs with a live session.
func (m *Manager) ConnectedDevices() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()

	out := make([]string, 0, len(m.sessions))
	for id := range m.sessions {
		out = append(out, id)
	}
	return out
}

// IsConnected reports whether a session is live for a device.
func (m *Manager) IsConnected(deviceID string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	_, ok := m.sessions[deviceID]
	return ok
}

// Disconnect closes the session with a device, if one is open.
func (m *Manager) Disconnect(deviceID string) {
	m.mu.Lock()
	e, ok := m.sessions[deviceID]
	delete(m.sessions, deviceID)
	m.mu.Unlock()

	if ok {
		e.session.Close()
	}
}

// Broadcast sends a message to every connected peer that advertised the given
// capability. An empty capability sends to everyone.
func (m *Manager) Broadcast(capability string, v interface{}) {
	m.mu.RLock()
	sessions := make([]*Session, 0, len(m.sessions))
	for _, e := range m.sessions {
		sessions = append(sessions, e.session)
	}
	m.mu.RUnlock()

	for _, s := range sessions {
		if capability != "" && !s.Supports(capability) {
			continue
		}
		if err := s.Send(v); err != nil {
			m.logf("send to %s failed: %v", s.DeviceID(), err)
			s.Close()
		}
	}
}

// SendTo delivers a message to one peer.
func (m *Manager) SendTo(deviceID string, v interface{}) error {
	session, ok := m.Session(deviceID)
	if !ok {
		return fmt.Errorf("device is not connected")
	}
	return session.Send(v)
}

// BroadcastDeviceInfo re-advertises our capabilities, called after a settings
// change so peers stop sending things the user just switched off.
func (m *Manager) BroadcastDeviceInfo() {
	if m.LocalDeviceInfo == nil {
		return
	}
	m.Broadcast("", m.LocalDeviceInfo())
}

// ------------------------------------------- SessionHandler (forwarding)

func (m *Manager) OnMessage(s *Session, msgType protocol.MessageType, raw []byte) {
	if m.Handler != nil {
		m.Handler.OnMessage(s, msgType, raw)
	}
}

func (m *Manager) OnDeviceInfo(s *Session, info protocol.DeviceInfo) {
	if m.Handler != nil {
		m.Handler.OnDeviceInfo(s, info)
	}
}

func (m *Manager) OnUnpair(s *Session, msg protocol.Unpair) {
	if m.Handler != nil {
		m.Handler.OnUnpair(s, msg)
	}
}

func (m *Manager) OnClosed(s *Session, err error) {
	deviceID := s.DeviceID()

	m.mu.Lock()
	// Only forget the session if it is still the registered one; a replaced
	// duplicate closing later must not evict the connection that superseded it.
	if e, ok := m.sessions[deviceID]; ok && e.session == s {
		delete(m.sessions, deviceID)
	}
	m.mu.Unlock()

	if m.OnSessionChange != nil {
		m.OnSessionChange(deviceID, false)
	}
	if m.Handler != nil {
		m.Handler.OnClosed(s, err)
	}
}
