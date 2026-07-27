package transport

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"wedrop/core/crypto"
	"wedrop/core/protocol"
)

// PerformHandshakeAsClient initiates a handshake to a server
func PerformHandshakeAsClient(conn net.Conn, localIdentity *crypto.Identity, peerPubKey string) (*SecureConn, error) {
	kx, err := crypto.GenerateKeyExchange()
	if err != nil {
		return nil, err
	}

	sig := localIdentity.Sign(kx.PublicKey)

	initMsg := protocol.HandshakeInit{
		Type:            protocol.TypeHandshakeInit,
		DeviceID:        localIdentity.DeviceID,
		EphemeralPub:    base64.StdEncoding.EncodeToString(kx.PublicKey),
		EphemeralPubSig: base64.StdEncoding.EncodeToString(sig),
	}

	initBytes, _ := json.Marshal(initMsg)
	if err := WriteFrame(conn, initBytes); err != nil {
		return nil, err
	}

	respBytes, err := ReadFrame(conn)
	if err != nil {
		return nil, err
	}

	var respMsg protocol.HandshakeResp
	if err := json.Unmarshal(respBytes, &respMsg); err != nil {
		return nil, err
	}
	if respMsg.Type != protocol.TypeHandshakeResp {
		return nil, fmt.Errorf("expected HandshakeResp, got %s", respMsg.Type)
	}

	peerPubKeyBytes, err := crypto.DecodePublicKey(peerPubKey)
	if err != nil {
		return nil, err
	}

	peerEphemeralPub, _ := base64.StdEncoding.DecodeString(respMsg.EphemeralPub)
	peerSig, _ := base64.StdEncoding.DecodeString(respMsg.EphemeralPubSig)

	if !crypto.Verify(peerPubKeyBytes, peerEphemeralPub, peerSig) {
		return nil, fmt.Errorf("handshake failed: invalid peer signature")
	}

	sharedSecret, err := kx.DeriveSharedSecret(peerEphemeralPub)
	if err != nil {
		return nil, err
	}

	return NewSecureConn(conn, sharedSecret), nil
}

// PerformHandshakeAsServer accepts a handshake from a client
func PerformHandshakeAsServer(conn net.Conn, initBytes []byte, localIdentity *crypto.Identity, getPeerPubKey func(deviceID string) (string, error)) (*SecureConn, error) {

	var initMsg protocol.HandshakeInit
	if err := json.Unmarshal(initBytes, &initMsg); err != nil {
		return nil, err
	}
	if initMsg.Type != protocol.TypeHandshakeInit {
		return nil, fmt.Errorf("expected HandshakeInit, got %s", initMsg.Type)
	}

	peerPubKey, err := getPeerPubKey(initMsg.DeviceID)
	if err != nil {
		return nil, fmt.Errorf("unauthorized device: %w", err)
	}

	peerPubKeyBytes, err := crypto.DecodePublicKey(peerPubKey)
	if err != nil {
		return nil, err
	}

	peerEphemeralPub, _ := base64.StdEncoding.DecodeString(initMsg.EphemeralPub)
	peerSig, _ := base64.StdEncoding.DecodeString(initMsg.EphemeralPubSig)

	if !crypto.Verify(peerPubKeyBytes, peerEphemeralPub, peerSig) {
		return nil, fmt.Errorf("handshake failed: invalid peer signature")
	}

	kx, err := crypto.GenerateKeyExchange()
	if err != nil {
		return nil, err
	}

	sig := localIdentity.Sign(kx.PublicKey)

	respMsg := protocol.HandshakeResp{
		Type:            protocol.TypeHandshakeResp,
		DeviceID:        localIdentity.DeviceID,
		EphemeralPub:    base64.StdEncoding.EncodeToString(kx.PublicKey),
		EphemeralPubSig: base64.StdEncoding.EncodeToString(sig),
	}

	respBytes, _ := json.Marshal(respMsg)
	if err := WriteFrame(conn, respBytes); err != nil {
		return nil, err
	}

	sharedSecret, err := kx.DeriveSharedSecret(peerEphemeralPub)
	if err != nil {
		return nil, err
	}

	return NewSecureConn(conn, sharedSecret), nil
}
