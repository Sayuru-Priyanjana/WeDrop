package transport

import (
	"encoding/json"
	"fmt"
	"net"
	"sync"
	"time"
	"wedrop/core/crypto"
	"wedrop/core/discovery"
	"wedrop/core/pairing"
	"wedrop/core/protocol"
)

type ConnectionManager struct {
	identity    *crypto.Identity
	discovery   *discovery.Service
	trustStore  *pairing.TrustStore
	connections map[string]*SecureConn
	mu          sync.RWMutex
	stopChan    chan struct{}
	
	// Callbacks for received messages
	OnClipboard func(deviceID, text string)
	OnTransfer  func(deviceID string, startMsg *protocol.TransferStart, secureConn *SecureConn)
}

func NewConnectionManager(id *crypto.Identity, d *discovery.Service, ts *pairing.TrustStore) *ConnectionManager {
	return &ConnectionManager{
		identity:    id,
		discovery:   d,
		trustStore:  ts,
		connections: make(map[string]*SecureConn),
		stopChan:    make(chan struct{}),
	}
}

func (cm *ConnectionManager) Start() {
	go cm.monitorLoop()
}

func (cm *ConnectionManager) Stop() {
	close(cm.stopChan)
	cm.mu.Lock()
	defer cm.mu.Unlock()
	for _, conn := range cm.connections {
		conn.Close()
	}
}

func (cm *ConnectionManager) monitorLoop() {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-cm.stopChan:
			return
		case <-ticker.C:
			cm.checkConnections()
		}
	}
}

func (cm *ConnectionManager) checkConnections() {
	// For every discovered device, if it's trusted and not connected, connect to it
	cm.mu.Lock()
	defer cm.mu.Unlock()

	for _, peer := range cm.discovery.Peers {
		if !cm.trustStore.IsTrusted(peer.DeviceID) {
			continue
		}

		if _, exists := cm.connections[peer.DeviceID]; exists {
			continue // Already connected
		}

		// Dial
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", peer.IP, peer.TCPPort), 2*time.Second)
		if err != nil {
			continue
		}

		pubKey, err := cm.trustStore.GetPublicKey(peer.DeviceID)
		if err != nil {
			conn.Close()
			continue
		}

		secureConn, err := PerformHandshakeAsClient(conn, cm.identity, pubKey)
		if err != nil {
			conn.Close()
			continue
		}

		cm.connections[peer.DeviceID] = secureConn
		go cm.handleConnection(peer.DeviceID, secureConn)
	}
}

func (cm *ConnectionManager) handleConnection(deviceID string, secureConn *SecureConn) {
	defer func() {
		cm.mu.Lock()
		delete(cm.connections, deviceID)
		cm.mu.Unlock()
		secureConn.Close()
	}()

	for {
		msgBytes, err := secureConn.ReadEncrypted()
		if err != nil {
			return
		}

		msgType, err := protocol.ParseMessageType(msgBytes)
		if err != nil {
			continue
		}

		if msgType == protocol.TypeClipboard {
			if cm.OnClipboard != nil {
				var clip protocol.ClipboardMessage
				if err := json.Unmarshal(msgBytes, &clip); err == nil {
					cm.OnClipboard(deviceID, clip.Text)
				}
			}
		} else if msgType == protocol.TypeTransferStart {
			if cm.OnTransfer != nil {
				var start protocol.TransferStart
				if err := json.Unmarshal(msgBytes, &start); err == nil {
					cm.OnTransfer(deviceID, &start, secureConn)
					// Break because transfer takes over the connection stream
					return
				}
			}
		}
	}
}

func (cm *ConnectionManager) BroadcastClipboard(text string) {
	cm.mu.RLock()
	defer cm.mu.RUnlock()

	msg := protocol.ClipboardMessage{
		Type: protocol.TypeClipboard,
		Text: text,
	}
	msgBytes, _ := json.Marshal(msg)

	for _, conn := range cm.connections {
		conn.WriteEncrypted(msgBytes)
	}
}
