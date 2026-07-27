// Package transfer moves files over an authenticated WeDrop connection.
//
// A transfer always runs on its own connection with intent "transfer". Keeping
// it off the control session means a large file cannot stall clipboard sync or
// keepalives behind it, and a failed transfer cannot take the session down.
package transfer

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"os"
	"path/filepath"
	"time"

	"wedrop/core/crypto"
	"wedrop/core/protocol"
	"wedrop/core/transport"
)

// ChunkSize is deliberately modest: a phone holding a 1 MiB chunk plus its
// encrypted copy plus the framing buffer for every concurrent transfer adds up
// fast, and 256 KiB already saturates typical Wi-Fi.
const ChunkSize = 256 * 1024

// Progress reports transfer progress. It is called often, so implementations
// should be cheap — the desktop UI throttles before touching the DOM.
type Progress func(transferred, total int64)

// Sender pushes one file down an established transfer connection.
type Sender struct {
	conn *transport.SecureConn
	// OnProgress, if set, is called after each chunk.
	OnProgress Progress
}

// NewSender wraps a connection.
func NewSender(conn *transport.SecureConn) *Sender {
	return &Sender{conn: conn}
}

// ErrRejected means the receiving user or their settings declined the file.
var ErrRejected = errors.New("the receiving device declined the file")

// SendFile offers a file and, if accepted, streams it.
func (s *Sender) SendFile(transferID, path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("cannot read %s: %w", path, err)
	}
	if info.IsDir() {
		return fmt.Errorf("%s is a folder; send files individually or zip it first", filepath.Base(path))
	}

	checksum, err := crypto.HashFile(path)
	if err != nil {
		return fmt.Errorf("cannot checksum %s: %w", path, err)
	}

	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()

	size := info.Size()
	chunkCount := int((size + ChunkSize - 1) / ChunkSize)
	filename := filepath.Base(path)

	offer := protocol.TransferOffer{
		Type:       protocol.TypeTransferOffer,
		TransferID: transferID,
		Filename:   filename,
		Size:       size,
		Checksum:   checksum,
		MimeType:   mime.TypeByExtension(filepath.Ext(filename)),
		ChunkSize:  ChunkSize,
		ChunkCount: chunkCount,
	}
	if err := s.conn.WriteJSON(offer); err != nil {
		return fmt.Errorf("offering file: %w", err)
	}

	// The receiver may be showing a prompt, so allow a generous window before
	// giving up on the verdict.
	s.conn.SetReadDeadline(time.Now().Add(3 * time.Minute))
	replyBytes, err := s.conn.ReadEncrypted()
	if err != nil {
		return fmt.Errorf("waiting for the receiver: %w", err)
	}

	var accept protocol.TransferAccept
	if err := json.Unmarshal(replyBytes, &accept); err != nil {
		return fmt.Errorf("malformed reply from the receiver: %w", err)
	}
	if !accept.Accepted {
		if accept.Reason != "" {
			return fmt.Errorf("%w: %s", ErrRejected, accept.Reason)
		}
		return ErrRejected
	}

	buf := make([]byte, ChunkSize)
	var sent int64
	for index := 0; index < chunkCount; index++ {
		// io.ReadFull matters here: a plain Read may return a short buffer for
		// reasons that have nothing to do with end-of-file, and the old code
		// treated that as a full chunk, silently truncating the file.
		n, err := io.ReadFull(file, buf)
		if err != nil && err != io.ErrUnexpectedEOF && err != io.EOF {
			return fmt.Errorf("reading %s: %w", filename, err)
		}
		if n == 0 {
			break
		}

		header := protocol.TransferChunk{
			Type:       protocol.TypeTransferChunk,
			TransferID: transferID,
			Index:      index,
			Size:       n,
		}
		if err := s.conn.WriteJSON(header); err != nil {
			return fmt.Errorf("sending chunk %d: %w", index, err)
		}
		if err := s.conn.WriteEncrypted(buf[:n]); err != nil {
			return fmt.Errorf("sending chunk %d: %w", index, err)
		}

		sent += int64(n)
		if s.OnProgress != nil {
			s.OnProgress(sent, size)
		}
	}

	done := protocol.TransferDone{
		Type:       protocol.TypeTransferDone,
		TransferID: transferID,
		Checksum:   checksum,
	}
	if err := s.conn.WriteJSON(done); err != nil {
		return fmt.Errorf("finishing transfer: %w", err)
	}

	// Wait for the receiver to confirm it verified the checksum, so "sent"
	// in the UI means the file actually landed intact.
	s.conn.SetReadDeadline(time.Now().Add(2 * time.Minute))
	finalBytes, err := s.conn.ReadEncrypted()
	if err != nil {
		return fmt.Errorf("waiting for confirmation: %w", err)
	}
	msgType, _ := protocol.ParseMessageType(finalBytes)
	if msgType == protocol.TypeError {
		var e protocol.ErrorMessage
		json.Unmarshal(finalBytes, &e)
		return fmt.Errorf("receiver reported a problem: %s", e.Message)
	}
	return nil
}
