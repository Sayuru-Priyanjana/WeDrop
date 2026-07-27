// Package transport carries WeDrop's framed, authenticated-encryption channel
// over plain TCP.
package transport

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"wedrop/core/crypto"
)

const (
	// MaxFrameSize caps a single frame. Chunks are 256 KiB plus GCM overhead,
	// so this leaves generous headroom while keeping a hostile or corrupt
	// length prefix from making us allocate hundreds of megabytes.
	MaxFrameSize = 1 << 20 // 1 MiB
	// WriteTimeout bounds a blocked write, which is what a peer that has
	// silently dropped off Wi-Fi looks like.
	WriteTimeout = 30 * time.Second
	// HandshakeTimeout bounds the whole plaintext handshake.
	HandshakeTimeout = 10 * time.Second
)

// SecureConn wraps a net.Conn with AES-256-GCM framing.
//
// Reads and writes are each serialised by their own mutex. The previous version
// had no locking at all: the clipboard broadcaster and the keepalive pinger
// could interleave halves of two frames on the same socket, which the peer then
// failed to decrypt and reported as a handshake/decryption error.
type SecureConn struct {
	conn net.Conn
	key  []byte

	writeMu sync.Mutex
	readMu  sync.Mutex

	closeOnce sync.Once
	closed    chan struct{}

	// PeerDeviceID and PeerName are filled in by the handshake.
	PeerDeviceID string
	PeerName     string
	// VerificationCode is the 6-digit code both sides show while pairing.
	VerificationCode string
}

// NewSecureConn wraps a connection with an established session key.
func NewSecureConn(conn net.Conn, key []byte) *SecureConn {
	return &SecureConn{
		conn:   conn,
		key:    key,
		closed: make(chan struct{}),
	}
}

// Close shuts the underlying socket. It is safe to call more than once and from
// several goroutines, which matters because both the read loop and the owner
// race to close a broken connection.
func (sc *SecureConn) Close() error {
	var err error
	sc.closeOnce.Do(func() {
		close(sc.closed)
		err = sc.conn.Close()
	})
	return err
}

// Closed returns a channel closed when the connection is shut down.
func (sc *SecureConn) Closed() <-chan struct{} { return sc.closed }

// RemoteAddr exposes the peer address for logging.
func (sc *SecureConn) RemoteAddr() net.Addr { return sc.conn.RemoteAddr() }

// SetReadDeadline sets the read deadline on the underlying socket.
func (sc *SecureConn) SetReadDeadline(t time.Time) error {
	return sc.conn.SetReadDeadline(t)
}

// WriteEncrypted seals and writes one frame.
func (sc *SecureConn) WriteEncrypted(plaintext []byte) error {
	ciphertext, err := crypto.Encrypt(sc.key, plaintext)
	if err != nil {
		return err
	}

	sc.writeMu.Lock()
	defer sc.writeMu.Unlock()

	sc.conn.SetWriteDeadline(time.Now().Add(WriteTimeout))
	return writeFrameLocked(sc.conn, ciphertext)
}

// WriteJSON marshals a message and writes it as one encrypted frame.
func (sc *SecureConn) WriteJSON(v interface{}) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return sc.WriteEncrypted(data)
}

// ReadEncrypted reads and opens one frame.
func (sc *SecureConn) ReadEncrypted() ([]byte, error) {
	sc.readMu.Lock()
	defer sc.readMu.Unlock()

	ciphertext, err := ReadFrame(sc.conn)
	if err != nil {
		return nil, err
	}
	plaintext, err := crypto.Decrypt(sc.key, ciphertext)
	if err != nil {
		return nil, fmt.Errorf("frame failed authentication: %w", err)
	}
	return plaintext, nil
}

// WriteFrame writes a length-prefixed frame to a raw connection.
func WriteFrame(conn net.Conn, data []byte) error {
	conn.SetWriteDeadline(time.Now().Add(WriteTimeout))
	return writeFrameLocked(conn, data)
}

// writeFrameLocked emits the header and body in a single write so that a frame
// can never be split across two syscalls and interleaved with another writer.
func writeFrameLocked(conn net.Conn, data []byte) error {
	if len(data) > MaxFrameSize {
		return fmt.Errorf("frame too large to send: %d bytes", len(data))
	}

	buf := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(buf[:4], uint32(len(data)))
	copy(buf[4:], data)

	if _, err := conn.Write(buf); err != nil {
		return err
	}
	return nil
}

// ReadFrame reads one length-prefixed frame from a raw connection.
func ReadFrame(conn net.Conn) ([]byte, error) {
	var lengthBuf [4]byte
	if _, err := io.ReadFull(conn, lengthBuf[:]); err != nil {
		return nil, err
	}

	length := binary.BigEndian.Uint32(lengthBuf[:])
	if length == 0 {
		return []byte{}, nil
	}
	if length > MaxFrameSize {
		return nil, fmt.Errorf("frame too large: %d bytes (peer may be speaking another protocol)", length)
	}

	data := make([]byte, length)
	if _, err := io.ReadFull(conn, data); err != nil {
		return nil, err
	}
	return data, nil
}
