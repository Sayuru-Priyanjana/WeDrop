package discovery

import (
	"encoding/json"
	"fmt"
	"net"
	"time"
	"wedrop/core/protocol"
)

const (
	DiscoveryPort          = 47820
	DiscoveryMulticastIP   = "239.255.90.90" // Administratively scoped local multicast
	DiscoveryBroadcastIP   = "255.255.255.255"
	DiscoveryInterval      = 5 * time.Second
)

// Service manages discovering peers on the LAN
type Service struct {
	DeviceConfig *protocol.DiscoveryMessage
	connMcast    *net.UDPConn
	connBcast    *net.UDPConn
	stopChan     chan struct{}
	Peers        map[string]*protocol.DiscoveryMessage
	PeerChan     chan *protocol.DiscoveryMessage
}

// NewService creates a new discovery service
func NewService(config *protocol.DiscoveryMessage) *Service {
	return &Service{
		DeviceConfig: config,
		stopChan:     make(chan struct{}),
		Peers:        make(map[string]*protocol.DiscoveryMessage),
		PeerChan:     make(chan *protocol.DiscoveryMessage, 100),
	}
}

// Start begins broadcasting and listening for peers
func (s *Service) Start() error {
	// 1. Listen for Broadcasts (0.0.0.0:47820)
	bcastAddr, _ := net.ResolveUDPAddr("udp4", fmt.Sprintf("0.0.0.0:%d", DiscoveryPort))
	if connBcast, err := net.ListenUDP("udp4", bcastAddr); err == nil {
		s.connBcast = connBcast
		go s.listen(s.connBcast)
	}

	// 2. Listen for Multicast (239.255.90.90:47820)
	mcastAddr, _ := net.ResolveUDPAddr("udp4", fmt.Sprintf("%s:%d", DiscoveryMulticastIP, DiscoveryPort))
	if connMcast, err := net.ListenMulticastUDP("udp4", nil, mcastAddr); err == nil {
		s.connMcast = connMcast
		go s.listen(s.connMcast)
	}

	go s.broadcastLoop()
	return nil
}

// Stop halts the discovery service
func (s *Service) Stop() {
	close(s.stopChan)
	if s.connBcast != nil {
		s.connBcast.Close()
	}
	if s.connMcast != nil {
		s.connMcast.Close()
	}
}

func (s *Service) listen(conn *net.UDPConn) {
	buf := make([]byte, 2048)
	for {
		select {
		case <-s.stopChan:
			return
		default:
			if conn == nil {
				return
			}
			
			// Set a read deadline so we can periodically check stopChan
			conn.SetReadDeadline(time.Now().Add(1 * time.Second))
			n, remoteAddr, err := conn.ReadFromUDP(buf)
			if err != nil {
				continue
			}

			var msg protocol.DiscoveryMessage
			if err := json.Unmarshal(buf[:n], &msg); err != nil {
				continue
			}

			if msg.Type != protocol.TypeDiscovery {
				continue
			}

			// Ignore our own messages
			if msg.DeviceID == s.DeviceConfig.DeviceID {
				continue
			}

			// Override the IP with the actual source IP if not provided
			if msg.IP == "" && remoteAddr != nil {
				msg.IP = remoteAddr.IP.String()
			}

			s.Peers[msg.DeviceID] = &msg
			select {
			case s.PeerChan <- &msg:
			default:
				// non-blocking send if channel is full
			}
		}
	}
}

func (s *Service) broadcastLoop() {
	ticker := time.NewTicker(DiscoveryInterval)
	defer ticker.Stop()

	sendAll := func() {
		data, err := json.Marshal(s.DeviceConfig)
		if err != nil {
			return
		}

		// Always try multicast
		mcastAddr, _ := net.ResolveUDPAddr("udp4", fmt.Sprintf("%s:%d", DiscoveryMulticastIP, DiscoveryPort))
		if c, err := net.DialUDP("udp4", nil, mcastAddr); err == nil {
			c.Write(data)
			c.Close()
		}
		
		// Send to 255.255.255.255
		bcastAddr, _ := net.ResolveUDPAddr("udp4", fmt.Sprintf("255.255.255.255:%d", DiscoveryPort))
		if c, err := net.DialUDP("udp4", nil, bcastAddr); err == nil {
			c.Write(data)
			c.Close()
		}

		// Subnet directed broadcasts (vital for Windows Hotspots)
		interfaces, err := net.Interfaces()
		if err != nil {
			return
		}
		for _, iface := range interfaces {
			if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
				continue
			}
			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}
			for _, a := range addrs {
				ipNet, ok := a.(*net.IPNet)
				if !ok || ipNet.IP.To4() == nil {
					continue
				}
				ip := ipNet.IP.To4()
				mask := ipNet.Mask
				if len(mask) == 4 {
					bcastIP := make(net.IP, 4)
					for i := 0; i < 4; i++ {
						bcastIP[i] = ip[i] | ^mask[i]
					}
					target, _ := net.ResolveUDPAddr("udp4", fmt.Sprintf("%s:%d", bcastIP.String(), DiscoveryPort))
					if c, err := net.DialUDP("udp4", nil, target); err == nil {
						c.Write(data)
						c.Close()
					}
				}
			}
		}
	}

	sendAll() // initial send
	for {
		select {
		case <-s.stopChan:
			return
		case <-ticker.C:
			sendAll()
		}
	}
}
