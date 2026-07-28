package main

import (
	"encoding/base64"
	"fmt"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"time"

	"github.com/atotto/clipboard"
	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"

	"wedrop/core/protocol"
	"wedrop/core/storage"
	"wedrop/core/transfer"
	"wedrop/core/transport"
)

// This file holds every method bound into the frontend. They are the app's
// public surface, so each one validates its inputs and returns an error the UI
// can show verbatim rather than a raw Go error.

// GetState returns the full snapshot the UI renders from.
func (s *WeDropService) GetState() AppState {
	s.mu.RLock()
	ready, initErr, device, settings := s.ready, s.initErr, s.device, s.settings
	s.mu.RUnlock()

	state := AppState{
		Ready:    ready,
		Error:    initErr,
		Settings: settings,
		Self: DeviceView{
			DeviceID:   device.DeviceID,
			Name:       device.Name,
			Platform:   platformLabel(device.Platform),
			FormFactor: protocol.FormDesktop,
			Online:     true,
			Connected:  true,
		},
		PublicKey: device.PublicKey,
		Paired:    []DeviceView{},
		Discovered: []DeviceView{},
		Transfers: []TransferView{},
		Clipboard: s.clipHistory.Snapshot(),
		Notifs:    s.notifs.Snapshot(),
	}

	if !ready {
		return state
	}

	state.ListenPort = s.manager.Port()

	// Index live peers so paired devices can be marked online in one pass.
	peers := make(map[string]protocol.DiscoveryMessage)
	for _, p := range s.disc.Peers() {
		peers[p.DeviceID] = p.DiscoveryMessage
	}

	pairedIDs := make(map[string]bool)
	for _, device := range s.trust.All() {
		pairedIDs[device.DeviceID] = true

		view := DeviceView{
			DeviceID:           device.DeviceID,
			Name:               device.Name,
			Platform:           platformLabel(device.Platform),
			FormFactor:         device.FormFactor,
			Paired:             true,
			Connected:          s.manager.IsConnected(device.DeviceID),
			AllowClipboard:     device.AllowClipboard,
			AllowFiles:         device.AllowFiles,
			AllowNotifications: device.AllowNotifications,
			AllowMedia:         device.AllowMedia,
			PairedAt:           device.PairedAt,
			LastSeen:           device.LastSeen,
			Battery:            -1,
		}
		if peer, ok := peers[device.DeviceID]; ok {
			view.Online = true
			view.IP = peer.IP
			if view.FormFactor == "" {
				view.FormFactor = peer.FormFactor
			}
		}
		if view.Connected {
			if h, ok := s.healthPlugin.HealthOf(device.DeviceID); ok {
				hc := h
				view.Health = &hc
				view.Battery = h.Battery
			}
			s.peerStateMu.RLock()
			if m, ok := s.peerMedia[device.DeviceID]; ok && m.HasMedia {
				mc := m
				view.Media = &mc
			}
			s.peerStateMu.RUnlock()
		}
		state.Paired = append(state.Paired, view)
	}

	for id, peer := range peers {
		if pairedIDs[id] || id == device.DeviceID {
			continue
		}
		state.Discovered = append(state.Discovered, DeviceView{
			DeviceID:   peer.DeviceID,
			Name:       peer.Name,
			Platform:   platformLabel(peer.Platform),
			FormFactor: peer.FormFactor,
			IP:         peer.IP,
			Online:     true,
			Battery:    -1,
		})
	}
	sort.Slice(state.Discovered, func(i, j int) bool {
		return state.Discovered[i].Name < state.Discovered[j].Name
	})

	s.transfersMu.Lock()
	for _, t := range s.transfers {
		state.Transfers = append(state.Transfers, *t)
	}
	s.transfersMu.Unlock()
	sort.Slice(state.Transfers, func(i, j int) bool {
		return state.Transfers[i].StartedAt > state.Transfers[j].StartedAt
	})
	if len(state.Transfers) > 40 {
		state.Transfers = state.Transfers[:40]
	}

	s.pairingMu.Lock()
	state.Pairing = s.pairingPrompt
	s.pairingMu.Unlock()

	return state
}

// ---------------------------------------------------------------- settings

// UpdateSettings replaces the settings and applies the side effects that some
// of them have — starting or stopping discovery, re-advertising capabilities,
// and registering for login startup.
func (s *WeDropService) UpdateSettings(settings storage.Settings) error {
	if !s.isReady() {
		return fmt.Errorf("WeDrop is still starting up")
	}

	previous := s.currentSettings()
	if err := s.saveSettings(settings); err != nil {
		return fmt.Errorf("could not save settings: %w", err)
	}
	applied := s.currentSettings()

	if applied.Discoverable != previous.Discoverable {
		if applied.Discoverable {
			if err := s.disc.Start(); err != nil {
				return fmt.Errorf("could not start discovery: %w", err)
			}
		} else {
			s.disc.Stop()
		}
	}

	// Peers must learn immediately that a receive switch changed, otherwise
	// they keep sending data this device will now silently drop.
	s.manager.BroadcastDeviceInfo()

	if applied.StartOnLogin != previous.StartOnLogin {
		if err := setStartOnLogin(applied.StartOnLogin); err != nil {
			return fmt.Errorf("settings saved, but start-on-login failed: %w", err)
		}
	}

	s.pushState()
	return nil
}

// SetDeviceName renames this device everywhere it appears.
func (s *WeDropService) SetDeviceName(name string) error {
	name = trimName(name)
	if name == "" {
		return fmt.Errorf("the device name cannot be empty")
	}

	s.mu.Lock()
	s.device.Name = name
	device := s.device
	s.mu.Unlock()

	if err := s.store.SaveEncryptedJSON(deviceFile, &device); err != nil {
		return fmt.Errorf("could not save the name: %w", err)
	}

	s.updateAnnouncement(s.manager.Port())
	s.manager.BroadcastDeviceInfo()
	s.pushState()
	return nil
}

// ---------------------------------------------------------------- pairing

// PairDevice asks a discovered device to join this ecosystem. It blocks until
// the other user accepts, declines, or the attempt times out.
func (s *WeDropService) PairDevice(deviceID string) error {
	if !s.isReady() {
		return fmt.Errorf("WeDrop is still starting up")
	}

	peer, ok := s.disc.Peer(deviceID)
	if !ok {
		return fmt.Errorf("that device is no longer on the network")
	}
	if s.trust.IsTrusted(deviceID) {
		return fmt.Errorf("%s is already in your ecosystem", peer.Name)
	}

	local := transport.LocalInfo{
		Identity:   s.identity,
		Name:       s.deviceName(),
		Platform:   runtime.GOOS,
		FormFactor: protocol.FormDesktop,
	}

	address := fmt.Sprintf("%s:%d", peer.IP, peer.TCPPort)
	result, err := transport.Dial(address, local, protocol.IntentPair, "", 6*time.Second)
	if err != nil {
		return fmt.Errorf("could not reach %s: %w", peer.Name, err)
	}
	defer result.Conn.Close()

	// Show the code while the other user decides, so both screens can be
	// compared before anyone taps Accept.
	s.emit("pairing:outgoing", map[string]interface{}{
		"device_id":         deviceID,
		"name":              peer.Name,
		"verification_code": result.VerificationCode,
	})

	result.Conn.SetReadDeadline(time.Now().Add(pairingTimeout))
	replyBytes, err := result.Conn.ReadEncrypted()
	if err != nil {
		return fmt.Errorf("%s did not answer in time", peer.Name)
	}

	var reply protocol.PairingResp
	if err := unmarshalJSON(replyBytes, &reply); err != nil {
		return fmt.Errorf("%s sent an unexpected reply", peer.Name)
	}
	if !reply.Accepted {
		if reply.Reason != "" {
			return fmt.Errorf("%s declined: %s", peer.Name, reply.Reason)
		}
		return fmt.Errorf("%s declined the request", peer.Name)
	}

	name := reply.Name
	if name == "" {
		name = peer.Name
	}

	if err := s.trust.Add(storage.TrustedDevice{
		DeviceID:   deviceID,
		Name:       name,
		Platform:   peer.Platform,
		FormFactor: peer.FormFactor,
		PublicKey:  result.PeerPublicKey,
	}); err != nil {
		return fmt.Errorf("could not save the device: %w", err)
	}

	s.manager.AnnounceAndReconnect(deviceID)
	s.toast("success", fmt.Sprintf("%s joined your ecosystem", name))
	s.pushState()
	return nil
}

// RespondToPairing answers the pending inbound pairing prompt.
func (s *WeDropService) RespondToPairing(deviceID string, accept bool) error {
	s.pairingMu.Lock()
	prompt, reply := s.pairingPrompt, s.pairingReply
	s.pairingMu.Unlock()

	if prompt == nil || reply == nil {
		return fmt.Errorf("there is no pairing request waiting")
	}
	if prompt.DeviceID != deviceID {
		return fmt.Errorf("that request is no longer current")
	}

	select {
	case reply <- accept:
		return nil
	default:
		return fmt.Errorf("that request has already been answered")
	}
}

// UnpairDevice removes a device and tells it, so both sides forget each other.
func (s *WeDropService) UnpairDevice(deviceID string) error {
	if !s.isReady() {
		return fmt.Errorf("WeDrop is still starting up")
	}

	// Send the notice first, while the session still exists.
	if session, ok := s.manager.Session(deviceID); ok {
		session.Send(protocol.Unpair{Type: protocol.TypeUnpair, DeviceID: s.identity.DeviceID})
		time.Sleep(120 * time.Millisecond) // let the frame reach the wire
	}

	s.manager.Disconnect(deviceID)
	if err := s.trust.Remove(deviceID); err != nil {
		return fmt.Errorf("could not remove the device: %w", err)
	}

	s.pushState()
	return nil
}

// SetDevicePermission flips one capability for one paired device.
func (s *WeDropService) SetDevicePermission(deviceID, capability string, allowed bool) error {
	if err := s.trust.SetPermission(deviceID, capability, allowed); err != nil {
		return err
	}
	s.pushState()
	return nil
}

// ---------------------------------------------------------------- files

// SelectFiles opens the native picker and returns the chosen paths.
func (s *WeDropService) SelectFiles() ([]string, error) {
	paths, err := wailsRuntime.OpenMultipleFilesDialog(s.ctx, wailsRuntime.OpenDialogOptions{
		Title: "Send with WeDrop",
	})
	if err != nil {
		return nil, err
	}
	return paths, nil
}

// SendFiles sends one or more files to a paired device. It returns as soon as
// the transfers are queued; progress arrives as events.
func (s *WeDropService) SendFiles(deviceID string, paths []string) error {
	if !s.isReady() {
		return fmt.Errorf("WeDrop is still starting up")
	}
	if len(paths) == 0 {
		return nil
	}
	if !s.trust.IsTrusted(deviceID) {
		return fmt.Errorf("that device is not in your ecosystem")
	}

	peer, ok := s.disc.Peer(deviceID)
	if !ok {
		return fmt.Errorf("%s is not on the network right now", s.peerName(deviceID, ""))
	}

	for _, path := range paths {
		go s.sendOneFile(deviceID, peer.IP, peer.TCPPort, path)
	}
	return nil
}

func (s *WeDropService) sendOneFile(deviceID, ip string, port int, path string) {
	name := s.peerName(deviceID, "")
	transferID := newTransferID()

	view := &TransferView{
		ID:         transferID,
		DeviceID:   deviceID,
		DeviceName: name,
		Filename:   filepath.Base(path),
		Incoming:   false,
		State:      TransferActive,
		StartedAt:  nowMillis(),
		UpdatedAt:  nowMillis(),
	}
	if info, err := statSize(path); err == nil {
		view.Size = info
	}
	s.putTransfer(view)

	fail := func(err error) {
		s.updateTransfer(transferID, func(t *TransferView) {
			t.State = TransferFailed
			t.Error = err.Error()
		})
		s.toast("error", fmt.Sprintf("Could not send %s: %v", filepath.Base(path), err))
	}

	key, trusted := s.trust.TrustedKey(deviceID)
	if !trusted {
		fail(fmt.Errorf("device is not paired"))
		return
	}

	local := transport.LocalInfo{
		Identity:   s.identity,
		Name:       s.deviceName(),
		Platform:   runtime.GOOS,
		FormFactor: protocol.FormDesktop,
	}

	// A transfer gets its own connection so a big file cannot stall the
	// control session that carries clipboard sync and keepalives.
	result, err := transport.Dial(fmt.Sprintf("%s:%d", ip, port), local, protocol.IntentTransfer, key, 8*time.Second)
	if err != nil {
		fail(err)
		return
	}
	defer result.Conn.Close()

	sender := transfer.NewSender(result.Conn)
	throttle := newProgressThrottle()
	sender.OnProgress = func(done, total int64) {
		if throttle.should(done, total) {
			s.updateTransfer(transferID, func(t *TransferView) {
				t.Transferred = done
				t.Size = total
			})
		}
	}

	if err := sender.SendFile(transferID, path); err != nil {
		fail(err)
		return
	}

	s.updateTransfer(transferID, func(t *TransferView) {
		t.State = TransferCompleted
		t.Transferred = t.Size
	})
	s.toast("success", fmt.Sprintf("Sent %s to %s", filepath.Base(path), name))
}

// RespondToTransfer answers a pending incoming file prompt.
func (s *WeDropService) RespondToTransfer(transferID string, accept bool) error {
	s.transfersMu.Lock()
	decision, ok := s.pendingIn[transferID]
	s.transfersMu.Unlock()

	if !ok {
		return fmt.Errorf("that transfer is no longer waiting")
	}

	select {
	case decision <- accept:
		return nil
	default:
		return fmt.Errorf("that transfer has already been answered")
	}
}

// ChooseDownloadDir opens a folder picker and stores the result.
func (s *WeDropService) ChooseDownloadDir() (string, error) {
	dir, err := wailsRuntime.OpenDirectoryDialog(s.ctx, wailsRuntime.OpenDialogOptions{
		Title: "Where should WeDrop save incoming files?",
	})
	if err != nil || dir == "" {
		return "", err
	}

	settings := s.currentSettings()
	settings.DownloadDir = dir
	if err := s.saveSettings(settings); err != nil {
		return "", err
	}

	s.pushState()
	return dir, nil
}

// OpenDownloadsFolder reveals the download directory in the file manager.
func (s *WeDropService) OpenDownloadsFolder() error {
	return openInFileManager(s.currentSettings().DownloadDir)
}

// RevealFile opens the folder containing a received file.
func (s *WeDropService) RevealFile(path string) error {
	if path == "" {
		return fmt.Errorf("that file is no longer available")
	}
	return openInFileManager(filepath.Dir(path))
}

// ---------------------------------------------------------------- clipboard

// PushClipboard sends the current clipboard to the ecosystem immediately, which
// is what the "Send clipboard now" button does when auto-sync is off.
func (s *WeDropService) PushClipboard() error {
	if !s.isReady() {
		return fmt.Errorf("WeDrop is still starting up")
	}

	text, err := clipboard.ReadAll()
	if err != nil {
		return fmt.Errorf("could not read the clipboard: %w", err)
	}
	if text == "" {
		return fmt.Errorf("the clipboard is empty")
	}
	if connected := s.manager.ConnectedDevices(); len(connected) == 0 {
		return fmt.Errorf("no devices are connected right now")
	}

	s.clipMu.Lock()
	s.clipSeq++
	seq := s.clipSeq
	s.lastClipHash = hashText(text)
	s.clipMu.Unlock()

	s.clipHistory.Push(ClipboardEntry{
		Text:       text,
		Origin:     s.identity.DeviceID,
		OriginName: s.deviceName(),
		Time:       nowMillis(),
	})

	s.manager.Broadcast(protocol.CapClipboard, protocol.ClipboardMessage{
		Type:     protocol.TypeClipboard,
		Text:     text,
		Origin:   s.identity.DeviceID,
		Sequence: seq,
		Hash:     hashText(text),
	})

	s.pushState()
	return nil
}

// CopyToClipboard puts a history entry back on the local clipboard.
func (s *WeDropService) CopyToClipboard(text string) error {
	if text == "" {
		return nil
	}
	s.clipMu.Lock()
	s.lastClipHash = hashText(text)
	s.clipMu.Unlock()
	return clipboard.WriteAll(text)
}

// ClearClipboardHistory empties the local history feed.
func (s *WeDropService) ClearClipboardHistory() {
	s.clipHistory.Clear()
	s.pushState()
}

// ---------------------------------------------------------------- media

// SendMediaCommand asks a paired device to act on its playback.
func (s *WeDropService) SendMediaCommand(deviceID, command string) error {
	switch command {
	case protocol.MediaPlayPause, protocol.MediaNext, protocol.MediaPrev,
		protocol.MediaStop, protocol.MediaVolUp, protocol.MediaVolDown, protocol.MediaMute:
	default:
		return fmt.Errorf("unknown media command %q", command)
	}

	if !s.trust.IsTrusted(deviceID) {
		return fmt.Errorf("that device is not in your ecosystem")
	}

	return s.manager.SendTo(deviceID, protocol.MediaMessage{
		Type:    protocol.TypeMedia,
		Command: command,
	})
}

// ControlLocalMedia applies a media command to this machine.
func (s *WeDropService) ControlLocalMedia(command string) error {
	return applyMediaCommand(command)
}

// ---------------------------------------------------------------- remote input

// SendMouseMove drives a peer's cursor by a relative delta.
func (s *WeDropService) SendMouseMove(deviceID string, dx, dy float64) error {
	return s.sendRemoteInput(deviceID, protocol.RemoteInput{
		Type: protocol.TypeRemoteInput, Action: protocol.InputMouseMove, DX: dx, DY: dy,
	})
}

// SendMouseClick sends a click; button is "left", "right" or "middle".
func (s *WeDropService) SendMouseClick(deviceID, button string) error {
	action := protocol.InputMouseLeft
	switch button {
	case "right":
		action = protocol.InputMouseRight
	case "middle":
		action = protocol.InputMouseMiddle
	}
	return s.sendRemoteInput(deviceID, protocol.RemoteInput{Type: protocol.TypeRemoteInput, Action: action})
}

// SendScroll scrolls a peer by the given vertical amount.
func (s *WeDropService) SendScroll(deviceID string, dy float64) error {
	return s.sendRemoteInput(deviceID, protocol.RemoteInput{
		Type: protocol.TypeRemoteInput, Action: protocol.InputScroll, DY: dy,
	})
}

// SendText types literal text on a peer.
func (s *WeDropService) SendText(deviceID, text string) error {
	return s.sendRemoteInput(deviceID, protocol.RemoteInput{
		Type: protocol.TypeRemoteInput, Action: protocol.InputType, Text: text,
	})
}

// SendKey presses a named special key on a peer.
func (s *WeDropService) SendKey(deviceID, key string) error {
	return s.sendRemoteInput(deviceID, protocol.RemoteInput{
		Type: protocol.TypeRemoteInput, Action: protocol.InputKey, Key: key,
	})
}

// SendPresentation sends a presentation control; action is one of
// "next", "prev", "start", "end", "blank".
func (s *WeDropService) SendPresentation(deviceID, action string) error {
	table := map[string]string{
		"next": protocol.InputPresentNext, "prev": protocol.InputPresentPrev,
		"start": protocol.InputPresentStart, "end": protocol.InputPresentEnd,
		"blank": protocol.InputPresentBlank,
	}
	mapped, ok := table[action]
	if !ok {
		return fmt.Errorf("unknown presentation action %q", action)
	}
	return s.sendRemoteInput(deviceID, protocol.RemoteInput{Type: protocol.TypeRemoteInput, Action: mapped})
}

func (s *WeDropService) sendRemoteInput(deviceID string, input protocol.RemoteInput) error {
	if !s.trust.IsTrusted(deviceID) {
		return fmt.Errorf("that device is not in your ecosystem")
	}
	return s.manager.SendTo(deviceID, input)
}

// ---------------------------------------------------------------- notifications

// MarkNotificationsRead clears the unread badge.
func (s *WeDropService) MarkNotificationsRead() {
	s.notifs.Update(func(n *NotificationView) { n.Read = true })
	s.pushState()
}

// ClearNotifications empties the notification feed.
func (s *WeDropService) ClearNotifications() {
	s.notifs.Clear()
	s.pushState()
}

// ---------------------------------------------------------------- diagnostics

// Diagnostics reports the information needed to explain a connection problem,
// so a user can see whether discovery, the listener, or pairing is at fault
// instead of guessing at a generic "handshake failed".
type Diagnostics struct {
	DeviceID     string   `json:"device_id"`
	ListenPort   int      `json:"listen_port"`
	Discoverable bool     `json:"discoverable"`
	PeersSeen    int      `json:"peers_seen"`
	Paired       int      `json:"paired"`
	Connected    []string `json:"connected"`
	DataDir      string   `json:"data_dir"`
	DownloadDir  string   `json:"download_dir"`
	Fingerprint  string   `json:"fingerprint"`
}

// GetDiagnostics returns a snapshot for the troubleshooting panel.
func (s *WeDropService) GetDiagnostics() Diagnostics {
	d := Diagnostics{
		DataDir:     dataDir(),
		DownloadDir: s.currentSettings().DownloadDir,
	}
	if !s.isReady() {
		return d
	}

	d.DeviceID = s.identity.DeviceID
	d.ListenPort = s.manager.Port()
	d.Discoverable = s.currentSettings().Discoverable
	d.PeersSeen = len(s.disc.Peers())
	d.Paired = s.trust.Count()
	d.Connected = s.manager.ConnectedDevices()
	d.Fingerprint = fingerprint(base64.StdEncoding.EncodeToString(s.identity.PublicKey))
	return d
}

func (s *WeDropService) isReady() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.ready
}

// openInFileManager opens a folder using whatever the platform provides.
func openInFileManager(path string) error {
	if path == "" {
		return fmt.Errorf("no folder to open")
	}

	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("explorer", path)
	case "darwin":
		cmd = exec.Command("open", path)
	default:
		cmd = exec.Command("xdg-open", path)
	}

	// Windows Explorer returns a non-zero exit code even on success, so the
	// error is deliberately not propagated there.
	err := cmd.Start()
	if runtime.GOOS == "windows" {
		return nil
	}
	return err
}
