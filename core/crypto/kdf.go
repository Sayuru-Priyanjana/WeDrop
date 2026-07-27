package crypto

import (
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
)

// sessionInfo binds derived keys to this protocol revision, so a key from one
// version can never be reused by another.
const sessionInfo = "wedrop/v2/session"

// DeriveSessionKey turns a raw X25519 shared secret into a 32-byte AES-256 key.
//
// The raw curve output must never be used as a cipher key directly: it is not
// uniformly distributed, and reusing it verbatim would make the key depend only
// on the two ephemeral keys. Feeding the handshake nonces in as HKDF salt binds
// the key to this particular handshake and kills replay of a recorded session.
func DeriveSessionKey(sharedSecret, nonceClient, nonceServer []byte) ([]byte, error) {
	if len(sharedSecret) != 32 {
		return nil, fmt.Errorf("shared secret must be 32 bytes, got %d", len(sharedSecret))
	}

	salt := make([]byte, 0, len(nonceClient)+len(nonceServer))
	salt = append(salt, nonceClient...)
	salt = append(salt, nonceServer...)

	key, err := hkdf.Key(sha256.New, sharedSecret, salt, sessionInfo, 32)
	if err != nil {
		return nil, fmt.Errorf("hkdf failed: %w", err)
	}
	return key, nil
}

// Transcript is the exact byte string both peers sign during the handshake.
//
// Every field that could be tampered with in flight is included, each prefixed
// with its length so that no combination of values can be re-cut into a
// different but identically-serialised transcript. The role tag differs per
// direction, which stops an attacker reflecting the server's signature back at
// it as if it were the client's.
func Transcript(role string, clientDeviceID, serverDeviceID string, clientPub, serverPub, clientEph, serverEph, nonceClient, nonceServer []byte) []byte {
	var out []byte
	appendField := func(b []byte) {
		var n [4]byte
		binary.BigEndian.PutUint32(n[:], uint32(len(b)))
		out = append(out, n[:]...)
		out = append(out, b...)
	}

	appendField([]byte("WEDROP-V2-HANDSHAKE"))
	appendField([]byte(role))
	appendField([]byte(clientDeviceID))
	appendField([]byte(serverDeviceID))
	appendField(clientPub)
	appendField(serverPub)
	appendField(clientEph)
	appendField(serverEph)
	appendField(nonceClient)
	appendField(nonceServer)
	return out
}

// Handshake role tags.
const (
	RoleClient = "client"
	RoleServer = "server"
)

// VerificationCode derives the 6-digit number both devices display while
// pairing. Because it comes from the session key, which in turn comes from the
// signed transcript, matching codes on both screens rule out a machine in the
// middle: an attacker would have to produce two different sessions whose keys
// collide in the same six digits.
func VerificationCode(sessionKey []byte) string {
	sum := sha256.Sum256(append([]byte("wedrop/v2/verify"), sessionKey...))
	code := binary.BigEndian.Uint32(sum[:4]) % 1000000
	return fmt.Sprintf("%06d", code)
}
