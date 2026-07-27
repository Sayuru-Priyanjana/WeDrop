package crypto

import (
	"crypto/rand"
	"fmt"
	"golang.org/x/crypto/curve25519"
)

// KeyExchange represents an ephemeral X25519 keypair for session negotiation
type KeyExchange struct {
	PrivateKey []byte
	PublicKey  []byte
}

// GenerateKeyExchange creates a new ephemeral X25519 keypair
func GenerateKeyExchange() (*KeyExchange, error) {
	var priv [32]byte
	if _, err := rand.Read(priv[:]); err != nil {
		return nil, fmt.Errorf("failed to generate random bytes: %w", err)
	}

	var pub [32]byte
	curve25519.ScalarBaseMult(&pub, &priv)

	return &KeyExchange{
		PrivateKey: priv[:],
		PublicKey:  pub[:],
	}, nil
}

// DeriveSharedSecret computes the X25519 shared secret
func (kx *KeyExchange) DeriveSharedSecret(peerPublicKey []byte) ([]byte, error) {
	if len(peerPublicKey) != 32 {
		return nil, fmt.Errorf("invalid peer public key length")
	}

	var priv, peerPub [32]byte
	copy(priv[:], kx.PrivateKey)
	copy(peerPub[:], peerPublicKey)

	var secret [32]byte
	curve25519.ScalarMult(&secret, &priv, &peerPub)

	return secret[:], nil
}
