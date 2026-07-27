package crypto

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// These tests write and read a fixture file shared with the Dart side. Running
// them in both languages against the same vectors is what proves a Go-sealed
// frame opens on a phone, and a phone-derived session key matches the desktop's
// — the interop that no amount of same-language testing can guarantee.

type interopVectors struct {
	Key             string `json:"key"`               // hex, 32 bytes
	Plaintext       string `json:"plaintext"`         // utf-8
	SharedSecret    string `json:"shared_secret"`     // hex, 32 bytes
	NonceClient     string `json:"nonce_client"`      // hex, 16 bytes
	NonceServer     string `json:"nonce_server"`      // hex, 16 bytes
	ExpectedSession string `json:"expected_session"`  // hex, 32 bytes
	ExpectedCode    string `json:"expected_code"`     // 6 digits
}

func fixturePath(t *testing.T) string {
	t.Helper()
	// Written under the repo so the Dart test can read the same bytes.
	dir := filepath.Join("..", "..", "testdata")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("could not create testdata dir: %v", err)
	}
	return filepath.Join(dir, "crypto_interop.json")
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("bad hex %q: %v", s, err)
	}
	return b
}

// TestWriteInteropVectors derives every value from fixed inputs and records it.
// The Dart test reads this file and must reproduce the same outputs.
func TestWriteInteropVectors(t *testing.T) {
	key := "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
	plaintext := "hello from the ecosystem"
	sharedSecret := "2a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748ab"
	nonceClient := "aabbccddeeff00112233445566778899"
	nonceServer := "99887766554433221100ffeeddccbbaa"

	session, err := DeriveSessionKey(mustHex(t, sharedSecret), mustHex(t, nonceClient), mustHex(t, nonceServer))
	if err != nil {
		t.Fatalf("derive session key: %v", err)
	}

	vectors := interopVectors{
		Key:             key,
		Plaintext:       plaintext,
		SharedSecret:    sharedSecret,
		NonceClient:     nonceClient,
		NonceServer:     nonceServer,
		ExpectedSession: hex.EncodeToString(session),
		ExpectedCode:    VerificationCode(session),
	}

	data, err := json.MarshalIndent(vectors, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fixturePath(t), data, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
}

// TestSessionKeyIsDeterministic guards the derivation the Dart test mirrors.
func TestSessionKeyIsDeterministic(t *testing.T) {
	secret := mustHex(t, "2a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748ab")
	nc := mustHex(t, "aabbccddeeff00112233445566778899")
	ns := mustHex(t, "99887766554433221100ffeeddccbbaa")

	a, err := DeriveSessionKey(secret, nc, ns)
	if err != nil {
		t.Fatal(err)
	}
	b, err := DeriveSessionKey(secret, nc, ns)
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(a) != hex.EncodeToString(b) {
		t.Fatal("session key derivation is not deterministic")
	}
	if len(a) != 32 {
		t.Fatalf("session key is %d bytes, want 32", len(a))
	}
}

// TestEncryptDecryptRoundTrip is the Go half of the cross-language frame test.
func TestEncryptDecryptRoundTrip(t *testing.T) {
	key := mustHex(t, "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
	plaintext := []byte("hello from the ecosystem")

	sealed, err := Encrypt(key, plaintext)
	if err != nil {
		t.Fatal(err)
	}
	// nonce(12) + ciphertext(len) + tag(16)
	if len(sealed) != 12+len(plaintext)+16 {
		t.Fatalf("sealed frame is %d bytes, expected %d", len(sealed), 12+len(plaintext)+16)
	}

	opened, err := Decrypt(key, sealed)
	if err != nil {
		t.Fatal(err)
	}
	if string(opened) != string(plaintext) {
		t.Fatalf("round trip gave %q", opened)
	}
}
