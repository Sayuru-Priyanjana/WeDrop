package pairing

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"sync"
	"wedrop/core/storage"
)

// TrustStore manages trusted devices
type TrustStore struct {
	store   *storage.Store
	devices map[string]storage.TrustedDevice
	mu      sync.RWMutex
}

// NewTrustStore initializes the trust store
func NewTrustStore(store *storage.Store) (*TrustStore, error) {
	ts := &TrustStore{
		store:   store,
		devices: make(map[string]storage.TrustedDevice),
	}

	if store.FileExists("trusted_devices.json") {
		var list []storage.TrustedDevice
		if err := store.LoadEncryptedJSON("trusted_devices.json", &list); err != nil {
			return nil, err
		}
		for _, d := range list {
			ts.devices[d.DeviceID] = d
		}
	}

	return ts, nil
}

// AddTrustedDevice adds a device to the trusted list
func (ts *TrustStore) AddTrustedDevice(device storage.TrustedDevice) error {
	ts.mu.Lock()
	defer ts.mu.Unlock()

	device.Trusted = true
	ts.devices[device.DeviceID] = device
	return ts.save()
}

// RemoveTrustedDevice removes a device from the trusted list
func (ts *TrustStore) RemoveTrustedDevice(deviceID string) error {
	ts.mu.Lock()
	defer ts.mu.Unlock()

	delete(ts.devices, deviceID)
	return ts.save()
}

// IsTrusted checks if a device is trusted
func (ts *TrustStore) IsTrusted(deviceID string) bool {
	ts.mu.RLock()
	defer ts.mu.RUnlock()

	d, exists := ts.devices[deviceID]
	return exists && d.Trusted
}

// GetPublicKey gets the public key of a trusted device
func (ts *TrustStore) GetPublicKey(deviceID string) (string, error) {
	ts.mu.RLock()
	defer ts.mu.RUnlock()

	d, exists := ts.devices[deviceID]
	if !exists {
		return "", fmt.Errorf("device not found in trust store")
	}
	return d.PublicKey, nil
}

// GetAll returns all trusted devices
func (ts *TrustStore) GetAll() []storage.TrustedDevice {
	ts.mu.RLock()
	defer ts.mu.RUnlock()

	var list []storage.TrustedDevice
	for _, d := range ts.devices {
		list = append(list, d)
	}
	return list
}

func (ts *TrustStore) save() error {
	var list []storage.TrustedDevice
	for _, d := range ts.devices {
		list = append(list, d)
	}
	return ts.store.SaveEncryptedJSON("trusted_devices.json", list)
}

// GenerateVerificationCode generates a 6-digit code from the shared secret
func GenerateVerificationCode(sharedSecret []byte) string {
	hash := sha256.Sum256(sharedSecret)
	// Take first 4 bytes of hash
	val := binary.BigEndian.Uint32(hash[:4])
	// Modulo 1,000,000 to get a 6 digit number
	code := val % 1000000
	return fmt.Sprintf("%06d", code)
}
