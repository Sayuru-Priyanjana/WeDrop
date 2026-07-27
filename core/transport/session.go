package transport

import (
	"encoding/json"
	"sync"
	"sync/atomic"
	"time"

	"wedrop/core/protocol"
)

const (
	// KeepaliveInterval is how often an idle session pings. It is long enough
	// that a phone's radio stays mostly asleep, short enough that a dead peer
	// is noticed within a few tens of seconds.
	KeepaliveInterval = 25 * time.Second
	// SessionReadTimeout is how long a session waits for any traffic before
	// declaring the peer gone. It must exceed KeepaliveInterval comfortably.
	SessionReadTimeout = 70 * time.Second
)

// SessionHandler receives decoded messages from a peer. Handlers are called
// from the session's own read goroutine, one at a time per session, so they
// must not block for long.
type SessionHandler interface {
	OnClipboard(s *Session, msg protocol.ClipboardMessage)
	OnNotification(s *Session, msg protocol.NotificationMessage)
	OnMedia(s *Session, msg protocol.MediaMessage)
	OnMediaState(s *Session, msg protocol.MediaState)
	OnHealth(s *Session, msg protocol.DeviceHealth)
	OnRemoteInput(s *Session, msg protocol.RemoteInput)
	OnDeviceInfo(s *Session, info protocol.DeviceInfo)
	OnUnpair(s *Session, msg protocol.Unpair)
	OnClosed(s *Session, err error)
}

// Session is a live control channel with one peer.
type Session struct {
	conn *SecureConn

	deviceID string
	mu       sync.RWMutex
	peerInfo protocol.DeviceInfo

	pingSeq  atomic.Int64
	lastSeen atomic.Int64 // unix nanos

	handler  SessionHandler
	stopOnce sync.Once
	done     chan struct{}
}

// NewSession wraps an authenticated connection in a control session.
func NewSession(conn *SecureConn, peer protocol.DeviceInfo, handler SessionHandler) *Session {
	s := &Session{
		conn:     conn,
		deviceID: conn.PeerDeviceID,
		peerInfo: peer,
		handler:  handler,
		done:     make(chan struct{}),
	}
	s.lastSeen.Store(time.Now().UnixNano())
	return s
}

// DeviceID is the peer's stable identifier.
func (s *Session) DeviceID() string { return s.deviceID }

// PeerInfo returns the last device info the peer sent.
func (s *Session) PeerInfo() protocol.DeviceInfo {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.peerInfo
}

// Supports reports whether the peer advertised a capability. Sending something
// a peer has switched off is not an error, but skipping it saves radio time
// and avoids pointless wakeups on the other device.
func (s *Session) Supports(capability string) bool {
	info := s.PeerInfo()
	// A peer that has not yet sent its capability list is assumed to support
	// everything, so the first moments of a session are not silently lossy.
	if len(info.Capabilities) == 0 {
		return true
	}
	return info.HasCapability(capability)
}

// Send writes a message to the peer.
func (s *Session) Send(v interface{}) error {
	return s.conn.WriteJSON(v)
}

// Close ends the session.
func (s *Session) Close() {
	s.stopOnce.Do(func() {
		close(s.done)
		s.conn.Close()
	})
}

// Done is closed when the session ends.
func (s *Session) Done() <-chan struct{} { return s.done }

// Run drives the session until the connection fails or Close is called. It
// blocks, and is normally started in its own goroutine.
func (s *Session) Run() {
	go s.keepaliveLoop()

	var err error
	for {
		s.conn.SetReadDeadline(time.Now().Add(SessionReadTimeout))
		msgBytes, readErr := s.conn.ReadEncrypted()
		if readErr != nil {
			err = readErr
			break
		}
		s.lastSeen.Store(time.Now().UnixNano())
		s.dispatch(msgBytes)
	}

	s.Close()
	if s.handler != nil {
		s.handler.OnClosed(s, err)
	}
}

func (s *Session) dispatch(msgBytes []byte) {
	msgType, err := protocol.ParseMessageType(msgBytes)
	if err != nil {
		return // unparseable frame; ignore rather than tear down the session
	}

	switch msgType {
	case protocol.TypePing:
		var ping protocol.Ping
		if json.Unmarshal(msgBytes, &ping) == nil {
			s.Send(protocol.Pong{Type: protocol.TypePong, Seq: ping.Seq})
		}

	case protocol.TypePong:
		// lastSeen already updated; nothing else to do.

	case protocol.TypeDeviceInfo:
		var info protocol.DeviceInfo
		if json.Unmarshal(msgBytes, &info) != nil {
			return
		}
		s.mu.Lock()
		s.peerInfo = info
		s.mu.Unlock()
		if s.handler != nil {
			s.handler.OnDeviceInfo(s, info)
		}

	case protocol.TypeClipboard:
		var msg protocol.ClipboardMessage
		if json.Unmarshal(msgBytes, &msg) == nil && s.handler != nil {
			s.handler.OnClipboard(s, msg)
		}

	case protocol.TypeNotification:
		var msg protocol.NotificationMessage
		if json.Unmarshal(msgBytes, &msg) == nil && s.handler != nil {
			s.handler.OnNotification(s, msg)
		}

	case protocol.TypeMedia:
		var msg protocol.MediaMessage
		if json.Unmarshal(msgBytes, &msg) == nil && s.handler != nil {
			s.handler.OnMedia(s, msg)
		}

	case protocol.TypeMediaState:
		var msg protocol.MediaState
		if json.Unmarshal(msgBytes, &msg) == nil && s.handler != nil {
			s.handler.OnMediaState(s, msg)
		}

	case protocol.TypeHealth:
		var msg protocol.DeviceHealth
		if json.Unmarshal(msgBytes, &msg) == nil && s.handler != nil {
			s.handler.OnHealth(s, msg)
		}

	case protocol.TypeRemoteInput:
		var msg protocol.RemoteInput
		if json.Unmarshal(msgBytes, &msg) == nil && s.handler != nil {
			s.handler.OnRemoteInput(s, msg)
		}

	case protocol.TypeUnpair:
		var msg protocol.Unpair
		if json.Unmarshal(msgBytes, &msg) == nil && s.handler != nil {
			s.handler.OnUnpair(s, msg)
		}
	}
}

func (s *Session) keepaliveLoop() {
	ticker := time.NewTicker(KeepaliveInterval)
	defer ticker.Stop()

	for {
		select {
		case <-s.done:
			return
		case <-ticker.C:
			ping := protocol.Ping{Type: protocol.TypePing, Seq: s.pingSeq.Add(1)}
			if err := s.Send(ping); err != nil {
				s.Close()
				return
			}
		}
	}
}
