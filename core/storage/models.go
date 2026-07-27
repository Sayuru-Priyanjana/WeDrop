package storage

// DeviceConfig represents the local device's configuration and identity
type DeviceConfig struct {
	DeviceID   string `json:"device_id"`
	Name       string `json:"name"`
	Platform   string `json:"platform"`
	PublicKey         string `json:"public_key"`  // base64 ed25519
	PrivateKey        string `json:"private_key"` // base64 ed25519
	AutoSyncClipboard bool   `json:"auto_sync_clipboard"`
}

// TrustedDevice represents a device that has been paired with the local device
type TrustedDevice struct {
	DeviceID  string `json:"device_id"`
	Name      string `json:"name"`
	PublicKey string `json:"public_key"` // base64 ed25519
	Trusted   bool   `json:"trusted"`
}
