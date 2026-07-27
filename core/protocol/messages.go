package protocol

import "encoding/json"

// MessageType defines the type of a protocol message
type MessageType string

const (
	TypeDiscovery     MessageType = "wedrop_discovery"
	TypeHandshakeInit MessageType = "handshake_init"
	TypeHandshakeResp MessageType = "handshake_resp"
	TypePairingReq    MessageType = "pairing_req"
	TypePairingResp   MessageType = "pairing_resp"
	TypeTransferStart MessageType = "transfer_start"
	TypeTransferChunk MessageType = "transfer_chunk"
	TypeClipboard     MessageType = "clipboard"
	TypeError         MessageType = "error"
)

// BaseMessage represents the common fields for all JSON messages
type BaseMessage struct {
	Type MessageType `json:"type"`
}

// DiscoveryMessage is broadcasted over UDP
type DiscoveryMessage struct {
	Type      MessageType `json:"type"`
	Version   string      `json:"version"`
	DeviceID  string      `json:"device_id"`
	Name      string      `json:"name"`
	Platform  string      `json:"platform"`
	IP        string      `json:"ip"`
	TCPPort   int         `json:"tcp_port"`
	PublicKey string      `json:"public_key"`
}

// HandshakeInit initiates a TCP connection and key exchange
type HandshakeInit struct {
	Type            MessageType `json:"type"`
	DeviceID        string      `json:"device_id"`
	EphemeralPub    string      `json:"ephemeral_pub"`     // base64 X25519 public key
	EphemeralPubSig string      `json:"ephemeral_pub_sig"` // base64 Ed25519 signature of the EphemeralPub
}

// HandshakeResp replies to a HandshakeInit
type HandshakeResp struct {
	Type            MessageType `json:"type"`
	DeviceID        string      `json:"device_id"`
	EphemeralPub    string      `json:"ephemeral_pub"`     // base64 X25519 public key
	EphemeralPubSig string      `json:"ephemeral_pub_sig"` // base64 Ed25519 signature of the EphemeralPub
}

// PairingReq is sent to request being added to the ecosystem
type PairingReq struct {
	Type      MessageType `json:"type"`
	DeviceID  string      `json:"device_id"`
	Name      string      `json:"name"`
	PublicKey string      `json:"public_key"`
}

// PairingResp is the response to a pairing request
type PairingResp struct {
	Type     MessageType `json:"type"`
	DeviceID string      `json:"device_id"`
	Accepted bool        `json:"accepted"`
}

// TransferStart initiates a file transfer
type TransferStart struct {
	Type       MessageType `json:"type"`
	Filename   string      `json:"filename"`
	Size       int64       `json:"size"`
	Checksum   string      `json:"checksum"` // SHA256
	ChunkCount int         `json:"chunk_count"`
}

// TransferChunk represents metadata for a file chunk.
// The actual chunk data will follow this message as raw encrypted bytes to save overhead.
type TransferChunk struct {
	Type     MessageType `json:"type"`
	Filename string      `json:"filename"`
	Index    int         `json:"index"`
	Size     int         `json:"size"` // Size of the encrypted chunk payload to follow
}

// ClipboardMessage shares clipboard text
type ClipboardMessage struct {
	Type MessageType `json:"type"`
	Text string      `json:"text"`
}

// ParseMessage decodes the base type of a message
func ParseMessageType(data []byte) (MessageType, error) {
	var base BaseMessage
	if err := json.Unmarshal(data, &base); err != nil {
		return "", err
	}
	return base.Type, nil
}
