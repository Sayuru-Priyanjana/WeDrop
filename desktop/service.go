package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
	"wedrop/core/crypto"
	"wedrop/core/discovery"
	"wedrop/core/pairing"
	"wedrop/core/protocol"
	"wedrop/core/storage"
	"wedrop/core/transfer"
	"wedrop/core/transport"
	"net"
	"time"
	"github.com/atotto/clipboard"
)

// WeDropService bridges the Wails frontend with the Go core
type WeDropService struct {
	ctx          context.Context
	store        *storage.Store
	trustStore   *pairing.TrustStore
	discovery       *discovery.Service
	connManager     *transport.ConnectionManager
	deviceConfig    *protocol.DiscoveryMessage
	Identity        *crypto.Identity
	pendingPairings map[string]chan bool
	lastClipboard   string
}

// NewWeDropService creates a new WeDropService instance
func NewWeDropService() *WeDropService {
	return &WeDropService{
		pendingPairings: make(map[string]chan bool),
	}
}

// startup is called when the app starts. The context is saved
func (s *WeDropService) startup(ctx context.Context) {
	s.ctx = ctx
	
	err := s.initCore()
	if err != nil {
		fmt.Printf("Failed to init core: %v\n", err)
	}
}

func getMasterKeyDir() string {
	if runtime.GOOS == "windows" {
		appdata := os.Getenv("APPDATA")
		return filepath.Join(appdata, "WeDrop")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".wedrop")
}

func (s *WeDropService) initCore() error {
	dir := getMasterKeyDir()
	os.MkdirAll(dir, 0700)
	keyPath := filepath.Join(dir, "master.key")
	
	masterKey := make([]byte, 32)
	if _, err := os.Stat(keyPath); err == nil {
		keyBytes, err := os.ReadFile(keyPath)
		if err == nil && len(keyBytes) == 32 {
			copy(masterKey, keyBytes)
		} else {
			io.ReadFull(rand.Reader, masterKey)
			os.WriteFile(keyPath, masterKey, 0600)
		}
	} else {
		io.ReadFull(rand.Reader, masterKey)
		os.WriteFile(keyPath, masterKey, 0600)
	}

	store, err := storage.NewStore(masterKey)
	if err != nil {
		return err
	}
	s.store = store

	ts, err := pairing.NewTrustStore(store)
	if err != nil {
		return err
	}
	s.trustStore = ts

	var devConfig storage.DeviceConfig
	if store.FileExists("device.json") {
		store.LoadEncryptedJSON("device.json", &devConfig)
		
		pub, _ := base64.StdEncoding.DecodeString(devConfig.PublicKey)
		priv, _ := base64.StdEncoding.DecodeString(devConfig.PrivateKey)
		
		s.Identity = &crypto.Identity{
			DeviceID:   devConfig.DeviceID,
			PublicKey:  ed25519.PublicKey(pub),
			PrivateKey: ed25519.PrivateKey(priv),
		}
	} else {
		id, err := crypto.GenerateIdentity()
		if err != nil {
			return err
		}
		s.Identity = id
		devConfig = storage.DeviceConfig{
			DeviceID:   id.DeviceID,
			Name:       "My PC",
			Platform:   runtime.GOOS,
			PublicKey:  base64.StdEncoding.EncodeToString(id.PublicKey),
			PrivateKey: base64.StdEncoding.EncodeToString(id.PrivateKey),
		}
		store.SaveEncryptedJSON("device.json", &devConfig)
	}

	s.deviceConfig = &protocol.DiscoveryMessage{
		Type:      protocol.TypeDiscovery,
		Version:   "1.0",
		DeviceID:  devConfig.DeviceID,
		Name:      devConfig.Name,
		Platform:  devConfig.Platform,
		TCPPort:   47821,
		PublicKey: devConfig.PublicKey,
	}

	s.discovery = discovery.NewService(s.deviceConfig)
	s.discovery.Start()

	s.connManager = transport.NewConnectionManager(s.Identity, s.discovery, s.trustStore)
	s.connManager.OnClipboard = func(deviceID, text string) {
		// Only write to clipboard if auto-sync is enabled
		if s.GetSettings().AutoSyncClipboard {
			clipboard.WriteAll(text)
			s.lastClipboard = text
		}
	}
	s.connManager.OnTransfer = func(deviceID string, startMsg *protocol.TransferStart, secureConn *transport.SecureConn) {
		saveDir := filepath.Join(getMasterKeyDir(), "Downloads")
		receiver := transfer.NewReceiver(secureConn, saveDir)
		if err := receiver.ReceiveFile(startMsg); err == nil {
			wailsRuntime.EventsEmit(s.ctx, "transfer_complete", startMsg.Filename)
		}
	}
	s.connManager.Start()

	s.startServer()
	
	// Start clipboard watcher
	go s.clipboardWatcher()

	return nil
}

func (s *WeDropService) clipboardWatcher() {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			if s.GetSettings().AutoSyncClipboard {
				text, err := clipboard.ReadAll()
				if err == nil && text != "" && text != s.lastClipboard {
					s.lastClipboard = text
					s.connManager.BroadcastClipboard(text)
				}
			}
		}
	}
}

// GetDevices returns the list of discovered devices
func (s *WeDropService) GetDevices() []protocol.DiscoveryMessage {
	if s.discovery == nil {
		return nil
	}
	
	devices := make([]protocol.DiscoveryMessage, 0)
	for _, peer := range s.discovery.Peers {
		devices = append(devices, *peer)
	}
	return devices
}

// GetSettings returns current device config settings
func (s *WeDropService) GetSettings() storage.DeviceConfig {
	var cfg storage.DeviceConfig
	s.store.LoadEncryptedJSON("device.json", &cfg)
	return cfg
}

// SetAutoSyncClipboard toggles clipboard sync
func (s *WeDropService) SetAutoSyncClipboard(enabled bool) {
	var cfg storage.DeviceConfig
	if err := s.store.LoadEncryptedJSON("device.json", &cfg); err == nil {
		cfg.AutoSyncClipboard = enabled
		s.store.SaveEncryptedJSON("device.json", &cfg)
	}
}

// EnsureModels forces Wails to generate TS bindings for protocol messages used only in events
func (s *WeDropService) EnsureModels() (protocol.PairingReq, protocol.PairingResp) {
	return protocol.PairingReq{}, protocol.PairingResp{}
}

// GetTrustedDevices returns the list of paired devices
func (s *WeDropService) GetTrustedDevices() []storage.TrustedDevice {
	if s.trustStore == nil {
		return nil
	}
	return s.trustStore.GetAll()
}

// RemoveTrustedDevice removes a device from the ecosystem
func (s *WeDropService) RemoveTrustedDevice(deviceID string) error {
	return s.trustStore.RemoveTrustedDevice(deviceID)
}

// SelectFile opens a file selection dialog and returns the absolute path
func (s *WeDropService) SelectFile() (string, error) {
	return wailsRuntime.OpenFileDialog(s.ctx, wailsRuntime.OpenDialogOptions{
		Title: "Select File to Send",
	})
}

// SendFile connects to a peer and sends a file
func (s *WeDropService) SendFile(deviceID string, filePath string) error {
	peer, exists := s.discovery.Peers[deviceID]
	if !exists {
		return fmt.Errorf("device not found")
	}

	conn, err := net.Dial("tcp", fmt.Sprintf("%s:%d", peer.IP, peer.TCPPort))
	if err != nil {
		return err
	}

	secureConn, err := transport.PerformHandshakeAsClient(conn, s.Identity, peer.PublicKey)
	if err != nil {
		conn.Close()
		return fmt.Errorf("handshake failed: %w", err)
	}

	sender := transfer.NewSender(secureConn)
	filename := filepath.Base(filePath)
	
	err = sender.SendFile(filePath, filename)
	secureConn.Close()
	return err
}

// SyncClipboard sends clipboard text to a peer
func (s *WeDropService) SyncClipboard(deviceID string, text string) error {
	peer, exists := s.discovery.Peers[deviceID]
	if !exists {
		return fmt.Errorf("device not found")
	}

	conn, err := net.Dial("tcp", fmt.Sprintf("%s:%d", peer.IP, peer.TCPPort))
	if err != nil {
		return err
	}
	defer conn.Close()

	secureConn, err := transport.PerformHandshakeAsClient(conn, s.Identity, peer.PublicKey)
	if err != nil {
		return fmt.Errorf("handshake failed: %w", err)
	}
	defer secureConn.Close()

	msg := protocol.ClipboardMessage{
		Type: protocol.TypeClipboard,
		Text: text,
	}
	
	msgBytes, _ := json.Marshal(msg)
	return secureConn.WriteEncrypted(msgBytes)
}

func (s *WeDropService) startServer() {
	listener, err := net.Listen("tcp", ":47821")
	if err != nil {
		fmt.Printf("Server failed to start: %v\n", err)
		return
	}

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				continue
			}
			go s.handleConnection(conn)
		}
	}()
}

func (s *WeDropService) RequestPairing(deviceID string) error {
	peer, exists := s.discovery.Peers[deviceID]
	if !exists {
		return fmt.Errorf("device not found")
	}
	
	conn, err := net.Dial("tcp", fmt.Sprintf("%s:%d", peer.IP, peer.TCPPort))
	if err != nil {
		return err
	}
	defer conn.Close()

	req := protocol.PairingReq{
		Type:      protocol.TypePairingReq,
		DeviceID:  s.Identity.DeviceID,
		Name:      s.deviceConfig.Name,
		PublicKey: base64.StdEncoding.EncodeToString(s.Identity.PublicKey),
	}
	reqBytes, _ := json.Marshal(req)
	
	if err := transport.WriteFrame(conn, reqBytes); err != nil {
		return err
	}

	respBytes, err := transport.ReadFrame(conn)
	if err != nil {
		return err
	}

	var resp protocol.PairingResp
	if err := json.Unmarshal(respBytes, &resp); err != nil {
		return err
	}

	if resp.Accepted {
		s.trustStore.AddTrustedDevice(storage.TrustedDevice{
			DeviceID:  peer.DeviceID,
			Name:      peer.Name,
			PublicKey: peer.PublicKey,
		})
		return nil
	}
	return fmt.Errorf("pairing rejected by peer")
}

func (s *WeDropService) AcceptPairing(deviceID string) {
	if ch, ok := s.pendingPairings[deviceID]; ok {
		ch <- true
	}
}

func (s *WeDropService) RejectPairing(deviceID string) {
	if ch, ok := s.pendingPairings[deviceID]; ok {
		ch <- false
	}
}

func (s *WeDropService) handleConnection(conn net.Conn) {
	defer conn.Close()

	initBytes, err := transport.ReadFrame(conn)
	if err != nil {
		return
	}

	msgType, err := protocol.ParseMessageType(initBytes)
	if err != nil {
		return
	}

	if msgType == protocol.TypePairingReq {
		var req protocol.PairingReq
		json.Unmarshal(initBytes, &req)

		ch := make(chan bool)
		s.pendingPairings[req.DeviceID] = ch
		
		wailsRuntime.EventsEmit(s.ctx, "pairing_request", req)

		accepted := <-ch
		delete(s.pendingPairings, req.DeviceID)

		resp := protocol.PairingResp{
			Type:     protocol.TypePairingResp,
			DeviceID: s.Identity.DeviceID,
			Accepted: accepted,
		}
		respBytes, _ := json.Marshal(resp)
		transport.WriteFrame(conn, respBytes)

		if accepted {
			s.trustStore.AddTrustedDevice(storage.TrustedDevice{
				DeviceID:  req.DeviceID,
				Name:      req.Name,
				PublicKey: req.PublicKey,
			})
		}
		return
	}

	secureConn, err := transport.PerformHandshakeAsServer(conn, initBytes, s.Identity, func(deviceID string) (string, error) {
		peer, exists := s.discovery.Peers[deviceID]
		if !exists {
			return "", fmt.Errorf("device not discovered")
		}
		return peer.PublicKey, nil
	})

	if err != nil {
		fmt.Printf("Handshake failed: %v\n", err)
		return
	}

	msgBytes, err := secureConn.ReadEncrypted()
	if err != nil {
		return
	}

	var startMsg protocol.TransferStart
	if err := json.Unmarshal(msgBytes, &startMsg); err != nil {
		return
	}

	if startMsg.Type == protocol.TypeTransferStart {
		saveDir := filepath.Join(getMasterKeyDir(), "Downloads")
		receiver := transfer.NewReceiver(secureConn, saveDir)
		err := receiver.ReceiveFile(&startMsg)
		if err == nil {
			wailsRuntime.EventsEmit(s.ctx, "transfer_complete", startMsg.Filename)
		} else {
			fmt.Printf("Transfer failed: %v\n", err)
		}
	} else if startMsg.Type == protocol.TypeClipboard {
		var clipMsg protocol.ClipboardMessage
		json.Unmarshal(msgBytes, &clipMsg)
		if s.GetSettings().AutoSyncClipboard {
			clipboard.WriteAll(clipMsg.Text)
			s.lastClipboard = clipMsg.Text
		}
	}
}

// shutdown is called when the app closes
func (s *WeDropService) shutdown(ctx context.Context) {
	if s.discovery != nil {
		s.discovery.Stop()
	}
	if s.connManager != nil {
		s.connManager.Stop()
	}
}
