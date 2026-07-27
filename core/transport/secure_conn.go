package transport

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"wedrop/core/crypto"
)

// SecureConn wraps a net.Conn and provides AES-256-GCM encryption
type SecureConn struct {
	net.Conn
	SharedSecret []byte
}

// NewSecureConn creates a SecureConn
func NewSecureConn(conn net.Conn, secret []byte) *SecureConn {
	return &SecureConn{
		Conn:         conn,
		SharedSecret: secret,
	}
}

// WriteEncrypted encrypts and writes a message to the connection
func (sc *SecureConn) WriteEncrypted(plaintext []byte) error {
	ciphertext, err := crypto.Encrypt(sc.SharedSecret, plaintext)
	if err != nil {
		return err
	}

	return WriteFrame(sc.Conn, ciphertext)
}

// ReadEncrypted reads and decrypts a message from the connection
func (sc *SecureConn) ReadEncrypted() ([]byte, error) {
	ciphertext, err := ReadFrame(sc.Conn)
	if err != nil {
		return nil, err
	}

	plaintext, err := crypto.Decrypt(sc.SharedSecret, ciphertext)
	if err != nil {
		return nil, err
	}

	return plaintext, nil
}

// WriteFrame writes a length-prefixed frame to the connection
func WriteFrame(conn net.Conn, data []byte) error {
	lengthBuf := make([]byte, 4)
	binary.BigEndian.PutUint32(lengthBuf, uint32(len(data)))
	if _, err := conn.Write(lengthBuf); err != nil {
		return err
	}
	if _, err := conn.Write(data); err != nil {
		return err
	}
	return nil
}

// ReadFrame reads a length-prefixed frame from the connection
func ReadFrame(conn net.Conn) ([]byte, error) {
	lengthBuf := make([]byte, 4)
	if _, err := io.ReadFull(conn, lengthBuf); err != nil {
		return nil, err
	}

	length := binary.BigEndian.Uint32(lengthBuf)
	if length > 20*1024*1024 { // 20MB max message size for safety
		return nil, fmt.Errorf("message too large: %d", length)
	}

	data := make([]byte, length)
	if _, err := io.ReadFull(conn, data); err != nil {
		return nil, err
	}

	return data, nil
}
