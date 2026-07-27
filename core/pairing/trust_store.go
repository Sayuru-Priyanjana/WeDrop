// Package pairing keeps the list of devices that belong to this ecosystem.
//
// Membership is the security boundary for the whole app: clipboard text,
// notifications, media commands and files are only ever exchanged with devices
// in this store, and only after they have proved possession of the exact
// identity key recorded here.
package pairing

import (
	"fmt"
	"sort"
	"sync"
	"time"

	"wedrop/core/storage"
)

const trustFile = "trusted_devices.json"

// TrustStore manages trusted devices, persisted encrypted at rest.
type TrustStore struct {
	store   *storage.Store
	mu      sync.RWMutex
	devices map[string]storage.TrustedDevice

	// OnChange fires after any mutation, so the UI can refresh.
	OnChange func()
}

// NewTrustStore loads the trust store from disk.
func NewTrustStore(store *storage.Store) (*TrustStore, error) {
	ts := &TrustStore{
		store:   store,
		devices: make(map[string]storage.TrustedDevice),
	}

	if !store.FileExists(trustFile) {
		return ts, nil
	}

	var list []storage.TrustedDevice
	if err := store.LoadEncryptedJSON(trustFile, &list); err != nil {
		// A corrupt or undecryptable trust file must not stop the app from
		// starting; the user can re-pair. Losing the file is recoverable,
		// refusing to launch is not.
		return ts, fmt.Errorf("trusted device list could not be read (%w) — devices must be paired again", err)
	}
	for _, d := range list {
		ts.devices[d.DeviceID] = d
	}
	return ts, nil
}

// Add inserts or updates a trusted device, preserving the pairing timestamp and
// per-device permissions of an existing entry.
func (ts *TrustStore) Add(device storage.TrustedDevice) error {
	ts.mu.Lock()
	if existing, ok := ts.devices[device.DeviceID]; ok {
		device.PairedAt = existing.PairedAt
		device.AllowClipboard = existing.AllowClipboard
		device.AllowFiles = existing.AllowFiles
		device.AllowNotifications = existing.AllowNotifications
		device.AllowMedia = existing.AllowMedia
	} else {
		device.PairedAt = time.Now().UnixMilli()
		device.DefaultPermissions()
	}
	ts.devices[device.DeviceID] = device
	err := ts.saveLocked()
	ts.mu.Unlock()

	ts.notify()
	return err
}

// Remove drops a device from the ecosystem.
func (ts *TrustStore) Remove(deviceID string) error {
	ts.mu.Lock()
	delete(ts.devices, deviceID)
	err := ts.saveLocked()
	ts.mu.Unlock()

	ts.notify()
	return err
}

// SetPermission flips one per-device switch.
func (ts *TrustStore) SetPermission(deviceID, capability string, allowed bool) error {
	ts.mu.Lock()
	device, ok := ts.devices[deviceID]
	if !ok {
		ts.mu.Unlock()
		return fmt.Errorf("device is not in the ecosystem")
	}
	switch capability {
	case "clipboard":
		device.AllowClipboard = allowed
	case "files":
		device.AllowFiles = allowed
	case "notifications":
		device.AllowNotifications = allowed
	case "media":
		device.AllowMedia = allowed
	default:
		ts.mu.Unlock()
		return fmt.Errorf("unknown capability %q", capability)
	}
	ts.devices[deviceID] = device
	err := ts.saveLocked()
	ts.mu.Unlock()

	ts.notify()
	return err
}

// Rename updates the stored display name for a device.
func (ts *TrustStore) Rename(deviceID, name string) error {
	ts.mu.Lock()
	device, ok := ts.devices[deviceID]
	if !ok {
		ts.mu.Unlock()
		return fmt.Errorf("device is not in the ecosystem")
	}
	device.Name = name
	ts.devices[deviceID] = device
	err := ts.saveLocked()
	ts.mu.Unlock()

	ts.notify()
	return err
}

// TouchLastSeen records that we just heard from a device. It skips the disk
// write when the stored value is already recent, so an idle ecosystem is not
// re-encrypting and rewriting the trust file every few seconds.
func (ts *TrustStore) TouchLastSeen(deviceID string) {
	now := time.Now().UnixMilli()

	ts.mu.Lock()
	defer ts.mu.Unlock()

	device, ok := ts.devices[deviceID]
	if !ok || now-device.LastSeen < 60_000 {
		return
	}
	device.LastSeen = now
	ts.devices[deviceID] = device
	ts.saveLocked()
}

// IsTrusted reports membership in the ecosystem.
func (ts *TrustStore) IsTrusted(deviceID string) bool {
	ts.mu.RLock()
	defer ts.mu.RUnlock()
	_, ok := ts.devices[deviceID]
	return ok
}

// Get returns a copy of one trusted device.
func (ts *TrustStore) Get(deviceID string) (storage.TrustedDevice, bool) {
	ts.mu.RLock()
	defer ts.mu.RUnlock()
	d, ok := ts.devices[deviceID]
	return d, ok
}

// TrustedKey implements transport.PeerAuthorizer.
func (ts *TrustStore) TrustedKey(deviceID string) (string, bool) {
	ts.mu.RLock()
	defer ts.mu.RUnlock()
	d, ok := ts.devices[deviceID]
	if !ok {
		return "", false
	}
	return d.PublicKey, true
}

// Allows reports whether a capability is permitted for a specific device.
func (ts *TrustStore) Allows(deviceID, capability string) bool {
	ts.mu.RLock()
	defer ts.mu.RUnlock()
	d, ok := ts.devices[deviceID]
	if !ok {
		return false
	}
	return d.Allows(capability)
}

// All returns every trusted device, newest pairing first.
func (ts *TrustStore) All() []storage.TrustedDevice {
	ts.mu.RLock()
	list := make([]storage.TrustedDevice, 0, len(ts.devices))
	for _, d := range ts.devices {
		list = append(list, d)
	}
	ts.mu.RUnlock()

	sort.Slice(list, func(i, j int) bool { return list[i].PairedAt > list[j].PairedAt })
	return list
}

// Count returns the number of paired devices.
func (ts *TrustStore) Count() int {
	ts.mu.RLock()
	defer ts.mu.RUnlock()
	return len(ts.devices)
}

func (ts *TrustStore) saveLocked() error {
	list := make([]storage.TrustedDevice, 0, len(ts.devices))
	for _, d := range ts.devices {
		list = append(list, d)
	}
	return ts.store.SaveEncryptedJSON(trustFile, list)
}

func (ts *TrustStore) notify() {
	if ts.OnChange != nil {
		ts.OnChange()
	}
}
