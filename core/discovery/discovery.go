// Package discovery announces this device on the LAN and tracks the peers it
// hears from.
package discovery

import (
	"encoding/json"
	"fmt"
	"net"
	"sync"
	"time"

	"wedrop/core/protocol"
)

const (
	// MulticastIP is an administratively scoped local multicast group.
	MulticastIP = "239.255.90.90"
	// AnnounceInterval is how often we re-announce ourselves. Peers that go
	// quiet for PeerTTL are treated as offline.
	AnnounceInterval = 5 * time.Second
	// PeerTTL is deliberately several announce intervals so a single dropped
	// UDP packet — routine on congested Wi-Fi — never flickers a device offline.
	PeerTTL = 18 * time.Second
	// reapInterval controls how often stale peers are swept.
	reapInterval = 3 * time.Second
	// maxDatagram bounds the read buffer; announcements are a few hundred bytes.
	maxDatagram = 4096
)

// Peer is a device heard on the network, with the moment we last heard it.
type Peer struct {
	protocol.DiscoveryMessage
	LastSeen time.Time `json:"last_seen"`
}

// Service manages LAN presence. All exported methods are safe for concurrent
// use; the previous version exposed a bare map, which the UI polled while the
// receive goroutine wrote to it and crashed the process with a concurrent map
// access fault.
type Service struct {
	mu     sync.RWMutex
	config protocol.DiscoveryMessage
	peers  map[string]*Peer

	connUnicast *net.UDPConn // bound to the discovery port, receives broadcasts
	connMcast   *net.UDPConn

	stopChan  chan struct{}
	stopOnce  sync.Once
	wg        sync.WaitGroup
	announceC chan struct{}

	// OnPeer fires when a peer is seen for the first time or comes back after
	// being reaped. It never fires for routine keepalive announcements, so the
	// UI is not woken up every five seconds per device.
	OnPeer func(peer Peer)
	// OnPeerLost fires when a peer's TTL expires.
	OnPeerLost func(deviceID string)
}

// NewService creates a discovery service for the given local device.
func NewService(config protocol.DiscoveryMessage) *Service {
	config.Type = protocol.TypeDiscovery
	config.Version = protocol.Version
	return &Service{
		config:    config,
		peers:     make(map[string]*Peer),
		stopChan:  make(chan struct{}),
		announceC: make(chan struct{}, 1),
	}
}

// UpdateConfig replaces the announced device details (used after a rename) and
// pushes an immediate announcement so peers see the change without waiting.
func (s *Service) UpdateConfig(config protocol.DiscoveryMessage) {
	config.Type = protocol.TypeDiscovery
	config.Version = protocol.Version
	s.mu.Lock()
	s.config = config
	s.mu.Unlock()
	s.AnnounceNow()
}

// Start begins listening and announcing. It returns an error only if no socket
// at all could be opened; a failure on just one of the two sockets is tolerated
// because many networks permit only broadcast or only multicast.
func (s *Service) Start() error {
	unicastAddr := &net.UDPAddr{IP: net.IPv4zero, Port: protocol.DiscoveryPort}
	if conn, err := net.ListenUDP("udp4", unicastAddr); err == nil {
		s.connUnicast = conn
		s.wg.Add(1)
		go s.listen(conn)
	}

	mcastAddr := &net.UDPAddr{IP: net.ParseIP(MulticastIP), Port: protocol.DiscoveryPort}
	if conn, err := net.ListenMulticastUDP("udp4", nil, mcastAddr); err == nil {
		conn.SetReadBuffer(maxDatagram * 8)
		s.connMcast = conn
		s.wg.Add(1)
		go s.listen(conn)
	}

	if s.connUnicast == nil && s.connMcast == nil {
		return fmt.Errorf("discovery: could not bind UDP port %d (is another copy of WeDrop running?)", protocol.DiscoveryPort)
	}

	s.wg.Add(2)
	go s.announceLoop()
	go s.reapLoop()

	// Ask anyone already on the network to identify themselves immediately,
	// so a freshly started app populates its list in milliseconds rather than
	// waiting up to a full announce interval.
	s.sendQuery()
	return nil
}

// Stop halts the service and says goodbye so peers drop us promptly.
func (s *Service) Stop() {
	s.stopOnce.Do(func() {
		s.sendBye()
		close(s.stopChan)
		if s.connUnicast != nil {
			s.connUnicast.Close()
		}
		if s.connMcast != nil {
			s.connMcast.Close()
		}
		s.wg.Wait()
	})
}

// AnnounceNow requests an out-of-band announcement without blocking.
func (s *Service) AnnounceNow() {
	select {
	case s.announceC <- struct{}{}:
	default:
	}
}

// Peers returns a snapshot of every peer currently within its TTL.
func (s *Service) Peers() []Peer {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]Peer, 0, len(s.peers))
	cutoff := time.Now().Add(-PeerTTL)
	for _, p := range s.peers {
		if p.LastSeen.After(cutoff) {
			out = append(out, *p)
		}
	}
	return out
}

// Peer looks up a single peer by device ID.
func (s *Service) Peer(deviceID string) (Peer, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	p, ok := s.peers[deviceID]
	if !ok || time.Since(p.LastSeen) > PeerTTL {
		return Peer{}, false
	}
	return *p, true
}

// IsOnline reports whether a device has announced itself recently.
func (s *Service) IsOnline(deviceID string) bool {
	_, ok := s.Peer(deviceID)
	return ok
}

func (s *Service) listen(conn *net.UDPConn) {
	defer s.wg.Done()

	buf := make([]byte, maxDatagram)
	for {
		select {
		case <-s.stopChan:
			return
		default:
		}

		// The deadline is what lets this goroutine notice Stop; without it a
		// blocked ReadFromUDP would keep the process alive after shutdown.
		conn.SetReadDeadline(time.Now().Add(time.Second))
		n, remoteAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			return // socket closed
		}

		s.handleDatagram(buf[:n], remoteAddr)
	}
}

func (s *Service) handleDatagram(data []byte, remote *net.UDPAddr) {
	msgType, err := protocol.ParseMessageType(data)
	if err != nil {
		return
	}

	switch msgType {
	case protocol.TypeDiscoveryQuery:
		// Somebody just joined and wants the room to speak up.
		var q protocol.DiscoveryMessage
		if json.Unmarshal(data, &q) == nil && q.DeviceID == s.localID() {
			return // our own query
		}
		s.AnnounceNow()

	case protocol.TypeDiscoveryBye:
		var msg protocol.DiscoveryMessage
		if err := json.Unmarshal(data, &msg); err != nil || msg.DeviceID == s.localID() {
			return
		}
		s.mu.Lock()
		_, existed := s.peers[msg.DeviceID]
		delete(s.peers, msg.DeviceID)
		s.mu.Unlock()
		if existed && s.OnPeerLost != nil {
			s.OnPeerLost(msg.DeviceID)
		}

	case protocol.TypeDiscovery:
		var msg protocol.DiscoveryMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return
		}
		if msg.DeviceID == "" || msg.DeviceID == s.localID() {
			return
		}
		if msg.Version != protocol.Version {
			return // incompatible build; ignore rather than fail later
		}
		if msg.PublicKey == "" || msg.TCPPort <= 0 {
			return // malformed announcement
		}

		// Trust the packet's source address over whatever the peer claimed.
		// A phone acting as a hotspot, or any host with several interfaces,
		// routinely advertises an address we cannot route to — the old code
		// believed the payload and every connection attempt timed out.
		if remote != nil && remote.IP != nil {
			if ip4 := remote.IP.To4(); ip4 != nil {
				msg.IP = ip4.String()
			}
		}
		if msg.IP == "" {
			return
		}

		s.recordPeer(msg)
	}
}

func (s *Service) recordPeer(msg protocol.DiscoveryMessage) {
	now := time.Now()

	s.mu.Lock()
	existing, known := s.peers[msg.DeviceID]
	isNew := !known || now.Sub(existing.LastSeen) > PeerTTL
	// Detect a peer that reinstalled the app or moved to a new address, so the
	// connection manager can drop a session pinned to stale details.
	changed := known && (existing.IP != msg.IP || existing.PublicKey != msg.PublicKey || existing.Name != msg.Name)
	peer := &Peer{DiscoveryMessage: msg, LastSeen: now}
	s.peers[msg.DeviceID] = peer
	s.mu.Unlock()

	if (isNew || changed) && s.OnPeer != nil {
		s.OnPeer(*peer)
	}
}

func (s *Service) localID() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.config.DeviceID
}

func (s *Service) snapshotConfig() protocol.DiscoveryMessage {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.config
}

func (s *Service) announceLoop() {
	defer s.wg.Done()

	ticker := time.NewTicker(AnnounceInterval)
	defer ticker.Stop()

	s.announce()
	for {
		select {
		case <-s.stopChan:
			return
		case <-ticker.C:
			s.announce()
		case <-s.announceC:
			s.announce()
		}
	}
}

func (s *Service) reapLoop() {
	defer s.wg.Done()

	ticker := time.NewTicker(reapInterval)
	defer ticker.Stop()

	for {
		select {
		case <-s.stopChan:
			return
		case <-ticker.C:
			var lost []string
			cutoff := time.Now().Add(-PeerTTL)

			s.mu.Lock()
			for id, p := range s.peers {
				if p.LastSeen.Before(cutoff) {
					delete(s.peers, id)
					lost = append(lost, id)
				}
			}
			s.mu.Unlock()

			if s.OnPeerLost != nil {
				for _, id := range lost {
					s.OnPeerLost(id)
				}
			}
		}
	}
}

func (s *Service) announce() {
	cfg := s.snapshotConfig()
	if data, err := json.Marshal(cfg); err == nil {
		s.sendToAll(data)
	}
}

func (s *Service) sendQuery() {
	query := protocol.DiscoveryMessage{
		Type:     protocol.TypeDiscoveryQuery,
		Version:  protocol.Version,
		DeviceID: s.localID(),
	}
	if data, err := json.Marshal(query); err == nil {
		s.sendToAll(data)
	}
}

func (s *Service) sendBye() {
	bye := protocol.DiscoveryMessage{
		Type:     protocol.TypeDiscoveryBye,
		Version:  protocol.Version,
		DeviceID: s.localID(),
	}
	if data, err := json.Marshal(bye); err == nil {
		s.sendToAll(data)
	}
}

// sendToAll fans a datagram out over multicast, the global broadcast address,
// and every interface's directed broadcast address. Networks vary wildly in
// which of these they permit — Windows mobile hotspots in particular drop
// 255.255.255.255 but pass directed broadcasts — so we use all three rather
// than trying to detect the environment.
func (s *Service) sendToAll(data []byte) {
	send := func(ip net.IP) {
		addr := &net.UDPAddr{IP: ip, Port: protocol.DiscoveryPort}
		conn, err := net.DialUDP("udp4", nil, addr)
		if err != nil {
			return
		}
		conn.SetWriteDeadline(time.Now().Add(time.Second))
		conn.Write(data)
		conn.Close()
	}

	send(net.ParseIP(MulticastIP))
	send(net.IPv4bcast)

	interfaces, err := net.Interfaces()
	if err != nil {
		return
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if iface.Flags&net.FlagBroadcast == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipNet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipNet.IP.To4()
			if ip == nil || len(ipNet.Mask) != 4 {
				continue
			}
			bcast := make(net.IP, 4)
			for i := 0; i < 4; i++ {
				bcast[i] = ip[i] | ^ipNet.Mask[i]
			}
			send(bcast)
		}
	}
}
