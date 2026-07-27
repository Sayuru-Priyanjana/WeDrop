package transport

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"time"

	"wedrop/core/crypto"
	"wedrop/core/protocol"
)

// nonceSize is the length of each side's handshake nonce.
const nonceSize = 16

// LocalInfo describes this device to the peer during a handshake.
type LocalInfo struct {
	Identity   *crypto.Identity
	Name       string
	Platform   string
	FormFactor protocol.FormFactor
}

// PeerAuthorizer answers the two questions the handshake must ask before it
// will hand out a session key.
type PeerAuthorizer interface {
	// TrustedKey returns the identity key stored for a device when — and only
	// when — that device is in the ecosystem.
	TrustedKey(deviceID string) (publicKey string, trusted bool)
	// PairingAllowed reports whether this device is currently willing to
	// consider new pairing requests at all.
	PairingAllowed() bool
}

// HandshakeResult is a completed, authenticated session.
type HandshakeResult struct {
	Conn   *SecureConn
	Intent protocol.Intent
	Peer   protocol.DeviceInfo
	// PeerPublicKey is the key the peer proved possession of during this
	// handshake. Pairing stores this rather than anything from a UDP
	// announcement, which is unauthenticated and trivially spoofed.
	PeerPublicKey string
	// VerificationCode is shown to both users when pairing.
	VerificationCode string
}

// Dial opens an authenticated connection to a peer.
//
// expectedKey is the identity key we require the peer to prove. It must be
// supplied for session and transfer intents; for pairing it is empty, because
// the whole point of pairing is that we do not know the key yet — the users
// compare the displayed verification code instead.
func Dial(address string, local LocalInfo, intent protocol.Intent, expectedKey string, timeout time.Duration) (*HandshakeResult, error) {
	conn, err := net.DialTimeout("tcp", address, timeout)
	if err != nil {
		return nil, fmt.Errorf("could not reach %s: %w", address, err)
	}

	if tcp, ok := conn.(*net.TCPConn); ok {
		// Small control messages should go out immediately; Nagle's algorithm
		// otherwise adds up to 40ms of latency to every clipboard sync.
		tcp.SetNoDelay(true)
		tcp.SetKeepAlive(true)
		tcp.SetKeepAlivePeriod(30 * time.Second)
	}

	result, err := handshakeClient(conn, local, intent, expectedKey)
	if err != nil {
		conn.Close()
		return nil, err
	}
	return result, nil
}

func handshakeClient(conn net.Conn, local LocalInfo, intent protocol.Intent, expectedKey string) (*HandshakeResult, error) {
	deadline := time.Now().Add(HandshakeTimeout)
	conn.SetDeadline(deadline)
	defer conn.SetDeadline(time.Time{})

	kx, err := crypto.GenerateKeyExchange()
	if err != nil {
		return nil, err
	}
	nonceClient := make([]byte, nonceSize)
	if _, err := io.ReadFull(rand.Reader, nonceClient); err != nil {
		return nil, err
	}

	localPub := []byte(local.Identity.PublicKey)
	init := protocol.HandshakeInit{
		Type:         protocol.TypeHandshakeInit,
		Version:      protocol.Version,
		Intent:       intent,
		DeviceID:     local.Identity.DeviceID,
		Name:         local.Name,
		Platform:     local.Platform,
		FormFactor:   local.FormFactor,
		PublicKey:    base64.StdEncoding.EncodeToString(localPub),
		EphemeralPub: base64.StdEncoding.EncodeToString(kx.PublicKey),
		Nonce:        base64.StdEncoding.EncodeToString(nonceClient),
	}
	initBytes, err := json.Marshal(init)
	if err != nil {
		return nil, err
	}
	if err := WriteFrame(conn, initBytes); err != nil {
		return nil, fmt.Errorf("sending handshake: %w", err)
	}

	respBytes, err := ReadFrame(conn)
	if err != nil {
		return nil, fmt.Errorf("waiting for handshake reply: %w", err)
	}

	// The peer may refuse us outright — most often because we are not paired.
	// Surfacing its reason is what turns a bare "handshake failed" into
	// something the user can act on.
	if msgType, err := protocol.ParseMessageType(respBytes); err == nil && msgType == protocol.TypeError {
		var e protocol.ErrorMessage
		json.Unmarshal(respBytes, &e)
		return nil, &PeerError{Code: e.Code, Message: e.Message}
	}

	var resp protocol.HandshakeResp
	if err := json.Unmarshal(respBytes, &resp); err != nil {
		return nil, fmt.Errorf("malformed handshake reply: %w", err)
	}
	if resp.Type != protocol.TypeHandshakeResp {
		return nil, fmt.Errorf("expected handshake_resp, got %q", resp.Type)
	}
	if resp.Version != protocol.Version {
		return nil, &PeerError{Code: protocol.ErrVersionMismatch,
			Message: fmt.Sprintf("peer speaks protocol v%d, this device speaks v%d", resp.Version, protocol.Version)}
	}

	// For an established peer, the key must be exactly the one we stored. A
	// different key means either a reinstall or an impostor, and we cannot tell
	// which, so we refuse and let the user re-pair deliberately.
	if expectedKey != "" && resp.PublicKey != expectedKey {
		return nil, &PeerError{Code: protocol.ErrKeyMismatch,
			Message: "this device's identity key changed; remove it and pair again"}
	}

	peerPub, err := crypto.DecodePublicKey(resp.PublicKey)
	if err != nil {
		return nil, fmt.Errorf("peer sent an invalid identity key: %w", err)
	}
	peerEph, err := base64.StdEncoding.DecodeString(resp.EphemeralPub)
	if err != nil || len(peerEph) != 32 {
		return nil, fmt.Errorf("peer sent an invalid ephemeral key")
	}
	nonceServer, err := base64.StdEncoding.DecodeString(resp.Nonce)
	if err != nil || len(nonceServer) != nonceSize {
		return nil, fmt.Errorf("peer sent an invalid nonce")
	}
	peerSig, err := base64.StdEncoding.DecodeString(resp.Signature)
	if err != nil {
		return nil, fmt.Errorf("peer sent an invalid signature")
	}

	serverTranscript := crypto.Transcript(crypto.RoleServer,
		init.DeviceID, resp.DeviceID,
		localPub, peerPub,
		kx.PublicKey, peerEph,
		nonceClient, nonceServer)

	if !crypto.Verify(peerPub, serverTranscript, peerSig) {
		return nil, &PeerError{Code: protocol.ErrBadSignature,
			Message: "peer could not prove it owns its identity key"}
	}

	// Only now that the peer is authenticated do we sign anything ourselves.
	clientTranscript := crypto.Transcript(crypto.RoleClient,
		init.DeviceID, resp.DeviceID,
		localPub, peerPub,
		kx.PublicKey, peerEph,
		nonceClient, nonceServer)

	confirm := protocol.HandshakeConfirm{
		Type:      protocol.TypeHandshakeConfirm,
		Signature: base64.StdEncoding.EncodeToString(local.Identity.Sign(clientTranscript)),
	}
	confirmBytes, _ := json.Marshal(confirm)
	if err := WriteFrame(conn, confirmBytes); err != nil {
		return nil, fmt.Errorf("sending handshake confirmation: %w", err)
	}

	secret, err := kx.DeriveSharedSecret(peerEph)
	if err != nil {
		return nil, err
	}
	key, err := crypto.DeriveSessionKey(secret, nonceClient, nonceServer)
	if err != nil {
		return nil, err
	}

	secure := NewSecureConn(conn, key)
	secure.PeerDeviceID = resp.DeviceID
	secure.PeerName = resp.Name
	secure.VerificationCode = crypto.VerificationCode(key)

	return &HandshakeResult{
		Conn:   secure,
		Intent: intent,
		Peer: protocol.DeviceInfo{
			Type:       protocol.TypeDeviceInfo,
			DeviceID:   resp.DeviceID,
			Name:       resp.Name,
			Platform:   resp.Platform,
			FormFactor: resp.FormFactor,
		},
		PeerPublicKey:    resp.PublicKey,
		VerificationCode: secure.VerificationCode,
	}, nil
}

// Accept completes the listening side of a handshake on an already-accepted
// TCP connection. On refusal it writes an error frame so the dialler can tell
// the user why, then returns the error.
func Accept(conn net.Conn, local LocalInfo, auth PeerAuthorizer) (*HandshakeResult, error) {
	conn.SetDeadline(time.Now().Add(HandshakeTimeout))
	defer conn.SetDeadline(time.Time{})

	if tcp, ok := conn.(*net.TCPConn); ok {
		tcp.SetNoDelay(true)
		tcp.SetKeepAlive(true)
		tcp.SetKeepAlivePeriod(30 * time.Second)
	}

	initBytes, err := ReadFrame(conn)
	if err != nil {
		return nil, fmt.Errorf("reading handshake: %w", err)
	}

	var init protocol.HandshakeInit
	if err := json.Unmarshal(initBytes, &init); err != nil {
		return nil, fmt.Errorf("malformed handshake: %w", err)
	}
	if init.Type != protocol.TypeHandshakeInit {
		return nil, fmt.Errorf("expected handshake_init, got %q", init.Type)
	}
	if init.Version != protocol.Version {
		refuse(conn, protocol.ErrVersionMismatch,
			fmt.Sprintf("this device speaks protocol v%d", protocol.Version))
		return nil, fmt.Errorf("peer speaks protocol v%d", init.Version)
	}

	peerPub, err := crypto.DecodePublicKey(init.PublicKey)
	if err != nil {
		refuse(conn, protocol.ErrBadSignature, "invalid identity key")
		return nil, fmt.Errorf("peer sent an invalid identity key: %w", err)
	}

	// Authorise before spending any time on key agreement.
	switch init.Intent {
	case protocol.IntentSession, protocol.IntentTransfer:
		storedKey, trusted := auth.TrustedKey(init.DeviceID)
		if !trusted {
			refuse(conn, protocol.ErrNotPaired, "this device is not in the ecosystem")
			return nil, fmt.Errorf("rejected %s: not paired", init.DeviceID)
		}
		if storedKey != init.PublicKey {
			refuse(conn, protocol.ErrKeyMismatch, "identity key does not match the paired device")
			return nil, fmt.Errorf("rejected %s: identity key mismatch", init.DeviceID)
		}
	case protocol.IntentPair:
		if !auth.PairingAllowed() {
			refuse(conn, protocol.ErrNotPermitted, "this device is not accepting new pairings")
			return nil, fmt.Errorf("rejected %s: pairing disabled", init.DeviceID)
		}
	default:
		refuse(conn, protocol.ErrInternal, "unknown connection intent")
		return nil, fmt.Errorf("unknown intent %q", init.Intent)
	}

	peerEph, err := base64.StdEncoding.DecodeString(init.EphemeralPub)
	if err != nil || len(peerEph) != 32 {
		refuse(conn, protocol.ErrInternal, "invalid ephemeral key")
		return nil, fmt.Errorf("peer sent an invalid ephemeral key")
	}
	nonceClient, err := base64.StdEncoding.DecodeString(init.Nonce)
	if err != nil || len(nonceClient) != nonceSize {
		refuse(conn, protocol.ErrInternal, "invalid nonce")
		return nil, fmt.Errorf("peer sent an invalid nonce")
	}

	kx, err := crypto.GenerateKeyExchange()
	if err != nil {
		return nil, err
	}
	nonceServer := make([]byte, nonceSize)
	if _, err := io.ReadFull(rand.Reader, nonceServer); err != nil {
		return nil, err
	}

	localPub := []byte(local.Identity.PublicKey)
	serverTranscript := crypto.Transcript(crypto.RoleServer,
		init.DeviceID, local.Identity.DeviceID,
		peerPub, localPub,
		peerEph, kx.PublicKey,
		nonceClient, nonceServer)

	resp := protocol.HandshakeResp{
		Type:         protocol.TypeHandshakeResp,
		Version:      protocol.Version,
		DeviceID:     local.Identity.DeviceID,
		Name:         local.Name,
		Platform:     local.Platform,
		FormFactor:   local.FormFactor,
		PublicKey:    base64.StdEncoding.EncodeToString(localPub),
		EphemeralPub: base64.StdEncoding.EncodeToString(kx.PublicKey),
		Nonce:        base64.StdEncoding.EncodeToString(nonceServer),
		Signature:    base64.StdEncoding.EncodeToString(local.Identity.Sign(serverTranscript)),
	}
	respBytes, _ := json.Marshal(resp)
	if err := WriteFrame(conn, respBytes); err != nil {
		return nil, fmt.Errorf("sending handshake reply: %w", err)
	}

	confirmBytes, err := ReadFrame(conn)
	if err != nil {
		return nil, fmt.Errorf("waiting for handshake confirmation: %w", err)
	}
	var confirm protocol.HandshakeConfirm
	if err := json.Unmarshal(confirmBytes, &confirm); err != nil {
		return nil, fmt.Errorf("malformed handshake confirmation: %w", err)
	}
	if confirm.Type != protocol.TypeHandshakeConfirm {
		return nil, fmt.Errorf("expected handshake_confirm, got %q", confirm.Type)
	}
	clientSig, err := base64.StdEncoding.DecodeString(confirm.Signature)
	if err != nil {
		return nil, fmt.Errorf("invalid confirmation signature encoding")
	}

	clientTranscript := crypto.Transcript(crypto.RoleClient,
		init.DeviceID, local.Identity.DeviceID,
		peerPub, localPub,
		peerEph, kx.PublicKey,
		nonceClient, nonceServer)

	if !crypto.Verify(peerPub, clientTranscript, clientSig) {
		refuse(conn, protocol.ErrBadSignature, "signature did not verify")
		return nil, fmt.Errorf("peer could not prove it owns its identity key")
	}

	secret, err := kx.DeriveSharedSecret(peerEph)
	if err != nil {
		return nil, err
	}
	key, err := crypto.DeriveSessionKey(secret, nonceClient, nonceServer)
	if err != nil {
		return nil, err
	}

	secure := NewSecureConn(conn, key)
	secure.PeerDeviceID = init.DeviceID
	secure.PeerName = init.Name
	secure.VerificationCode = crypto.VerificationCode(key)

	return &HandshakeResult{
		Conn:   secure,
		Intent: init.Intent,
		Peer: protocol.DeviceInfo{
			Type:       protocol.TypeDeviceInfo,
			DeviceID:   init.DeviceID,
			Name:       init.Name,
			Platform:   init.Platform,
			FormFactor: init.FormFactor,
		},
		PeerPublicKey:    init.PublicKey,
		VerificationCode: secure.VerificationCode,
	}, nil
}

// refuse sends a plaintext error frame before the connection is dropped.
func refuse(conn net.Conn, code, message string) {
	data, err := json.Marshal(protocol.NewError(code, message))
	if err != nil {
		return
	}
	WriteFrame(conn, data)
}

// PeerError is an explicit refusal from the other device, as opposed to a
// network or parsing failure on our side.
type PeerError struct {
	Code    string
	Message string
}

func (e *PeerError) Error() string {
	if e.Message == "" {
		return e.Code
	}
	return e.Message
}

// IsNotPaired reports whether an error is the peer telling us we are unknown to
// it — the one failure the UI should turn into "pair this device again".
func IsNotPaired(err error) bool {
	pe, ok := err.(*PeerError)
	return ok && (pe.Code == protocol.ErrNotPaired || pe.Code == protocol.ErrKeyMismatch)
}
