package transport

import (
	"encoding/base64"
	"net"
	"testing"
	"time"

	"wedrop/core/crypto"
	"wedrop/core/protocol"
)

// fakeAuth is a trust store stand-in driven entirely by the test.
type fakeAuth struct {
	keys        map[string]string
	allowPairing bool
}

func (f *fakeAuth) TrustedKey(deviceID string) (string, bool) {
	k, ok := f.keys[deviceID]
	return k, ok
}

func (f *fakeAuth) PairingAllowed() bool { return f.allowPairing }

func newLocal(t *testing.T, name string) LocalInfo {
	t.Helper()
	id, err := crypto.GenerateIdentity()
	if err != nil {
		t.Fatalf("generate identity: %v", err)
	}
	return LocalInfo{Identity: id, Name: name, Platform: "test", FormFactor: protocol.FormDesktop}
}

func encodedKey(l LocalInfo) string {
	return base64.StdEncoding.EncodeToString(l.Identity.PublicKey)
}

// runHandshake wires the two halves over a real TCP pair and returns both ends.
func runHandshake(t *testing.T, client, server LocalInfo, auth PeerAuthorizer, intent protocol.Intent, expectedKey string) (*HandshakeResult, *HandshakeResult, error, error) {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	type acceptOutcome struct {
		result *HandshakeResult
		err    error
	}
	accepted := make(chan acceptOutcome, 1)

	go func() {
		conn, err := listener.Accept()
		if err != nil {
			accepted <- acceptOutcome{nil, err}
			return
		}
		res, err := Accept(conn, server, auth)
		if err != nil {
			conn.Close()
		}
		accepted <- acceptOutcome{res, err}
	}()

	clientResult, clientErr := Dial(listener.Addr().String(), client, intent, expectedKey, 5*time.Second)

	select {
	case out := <-accepted:
		return clientResult, out.result, clientErr, out.err
	case <-time.After(5 * time.Second):
		t.Fatal("handshake timed out")
		return nil, nil, nil, nil
	}
}

func TestHandshakeSessionBetweenTrustedPeers(t *testing.T) {
	client := newLocal(t, "Laptop")
	server := newLocal(t, "Phone")

	auth := &fakeAuth{keys: map[string]string{client.Identity.DeviceID: encodedKey(client)}}

	c, s, cErr, sErr := runHandshake(t, client, server, auth, protocol.IntentSession, encodedKey(server))
	if cErr != nil || sErr != nil {
		t.Fatalf("handshake failed: client=%v server=%v", cErr, sErr)
	}
	defer c.Conn.Close()
	defer s.Conn.Close()

	// Both sides must derive the same key, which is exactly what the old code
	// got wrong in subtle ways; a mismatch shows up here rather than as an
	// unexplained decryption failure at runtime.
	if c.VerificationCode != s.VerificationCode {
		t.Fatalf("verification codes differ: %s vs %s", c.VerificationCode, s.VerificationCode)
	}
	if len(c.VerificationCode) != 6 {
		t.Fatalf("expected a 6-digit code, got %q", c.VerificationCode)
	}
	if c.Peer.DeviceID != server.Identity.DeviceID {
		t.Errorf("client saw peer %q, want %q", c.Peer.DeviceID, server.Identity.DeviceID)
	}
	if s.Peer.DeviceID != client.Identity.DeviceID {
		t.Errorf("server saw peer %q, want %q", s.Peer.DeviceID, client.Identity.DeviceID)
	}

	// And the channel must actually work in both directions.
	done := make(chan []byte, 1)
	go func() {
		msg, err := s.Conn.ReadEncrypted()
		if err != nil {
			t.Errorf("server read: %v", err)
			done <- nil
			return
		}
		done <- msg
	}()

	if err := c.Conn.WriteEncrypted([]byte("hello ecosystem")); err != nil {
		t.Fatalf("client write: %v", err)
	}
	if got := string(<-done); got != "hello ecosystem" {
		t.Fatalf("round trip gave %q", got)
	}
}

func TestHandshakeRejectsUnpairedDevice(t *testing.T) {
	client := newLocal(t, "Stranger")
	server := newLocal(t, "Phone")

	auth := &fakeAuth{keys: map[string]string{}} // client is not in the ecosystem

	_, _, cErr, sErr := runHandshake(t, client, server, auth, protocol.IntentSession, encodedKey(server))
	if sErr == nil {
		t.Fatal("server accepted a device that is not paired")
	}
	if cErr == nil {
		t.Fatal("client did not see a refusal")
	}
	if !IsNotPaired(cErr) {
		t.Fatalf("expected a not_paired refusal, got %v", cErr)
	}
}

func TestHandshakeRejectsWrongIdentityKey(t *testing.T) {
	client := newLocal(t, "Laptop")
	server := newLocal(t, "Phone")
	impostor := newLocal(t, "Impostor")

	// The server has the client's ID on file but with somebody else's key,
	// which is what a spoofed device ID looks like.
	auth := &fakeAuth{keys: map[string]string{client.Identity.DeviceID: encodedKey(impostor)}}

	_, _, cErr, sErr := runHandshake(t, client, server, auth, protocol.IntentSession, encodedKey(server))
	if sErr == nil {
		t.Fatal("server accepted a mismatched identity key")
	}
	if cErr == nil || !IsNotPaired(cErr) {
		t.Fatalf("expected a key_mismatch refusal, got %v", cErr)
	}
}

func TestHandshakeClientRejectsUnexpectedServerKey(t *testing.T) {
	client := newLocal(t, "Laptop")
	server := newLocal(t, "Phone")
	impostor := newLocal(t, "Impostor")

	auth := &fakeAuth{keys: map[string]string{client.Identity.DeviceID: encodedKey(client)}}

	// The client expects the impostor's key; the real server must be refused
	// by the client itself, not merely trusted because it answered.
	_, _, cErr, _ := runHandshake(t, client, server, auth, protocol.IntentSession, encodedKey(impostor))
	if cErr == nil {
		t.Fatal("client accepted a server presenting an unexpected key")
	}
	pe, ok := cErr.(*PeerError)
	if !ok || pe.Code != protocol.ErrKeyMismatch {
		t.Fatalf("expected key_mismatch, got %v", cErr)
	}
}

func TestHandshakePairingDoesNotRequireTrust(t *testing.T) {
	client := newLocal(t, "New Phone")
	server := newLocal(t, "Laptop")

	auth := &fakeAuth{keys: map[string]string{}, allowPairing: true}

	c, s, cErr, sErr := runHandshake(t, client, server, auth, protocol.IntentPair, "")
	if cErr != nil || sErr != nil {
		t.Fatalf("pairing handshake failed: client=%v server=%v", cErr, sErr)
	}
	defer c.Conn.Close()
	defer s.Conn.Close()

	if c.VerificationCode != s.VerificationCode {
		t.Fatalf("verification codes differ: %s vs %s", c.VerificationCode, s.VerificationCode)
	}
	// Pairing must record the key proved during the handshake, not one taken
	// from an unauthenticated UDP announcement.
	if s.PeerPublicKey != encodedKey(client) {
		t.Error("server did not capture the client's proven identity key")
	}
	if s.Intent != protocol.IntentPair {
		t.Errorf("server saw intent %q", s.Intent)
	}
}

func TestHandshakePairingRefusedWhenDisabled(t *testing.T) {
	client := newLocal(t, "New Phone")
	server := newLocal(t, "Laptop")

	auth := &fakeAuth{keys: map[string]string{}, allowPairing: false}

	_, _, cErr, sErr := runHandshake(t, client, server, auth, protocol.IntentPair, "")
	if sErr == nil {
		t.Fatal("server accepted pairing while pairing was switched off")
	}
	pe, ok := cErr.(*PeerError)
	if !ok || pe.Code != protocol.ErrNotPermitted {
		t.Fatalf("expected not_permitted, got %v", cErr)
	}
}

func TestSessionKeysAreUniquePerHandshake(t *testing.T) {
	client := newLocal(t, "Laptop")
	server := newLocal(t, "Phone")
	auth := &fakeAuth{keys: map[string]string{client.Identity.DeviceID: encodedKey(client)}}

	c1, s1, err1, err2 := runHandshake(t, client, server, auth, protocol.IntentSession, encodedKey(server))
	if err1 != nil || err2 != nil {
		t.Fatalf("first handshake failed: %v %v", err1, err2)
	}
	defer c1.Conn.Close()
	defer s1.Conn.Close()

	c2, s2, err3, err4 := runHandshake(t, client, server, auth, protocol.IntentSession, encodedKey(server))
	if err3 != nil || err4 != nil {
		t.Fatalf("second handshake failed: %v %v", err3, err4)
	}
	defer c2.Conn.Close()
	defer s2.Conn.Close()

	// Fresh nonces and ephemeral keys must give a different session key every
	// time, so a recorded session can never be replayed against a later one.
	if c1.VerificationCode == c2.VerificationCode {
		t.Fatal("two handshakes between the same devices produced the same session key")
	}
}
