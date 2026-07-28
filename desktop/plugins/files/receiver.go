package files

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"wedrop/core/crypto"
	"wedrop/core/protocol"
	"wedrop/core/transport"
)

// Receiver writes one incoming file to disk.
type Receiver struct {
	conn    *transport.SecureConn
	saveDir string
	// OnProgress, if set, is called after each chunk.
	OnProgress Progress
}

// NewReceiver wraps a connection and the directory to save into.
func NewReceiver(conn *transport.SecureConn, saveDir string) *Receiver {
	return &Receiver{conn: conn, saveDir: saveDir}
}

// Decline tells the sender the file was refused.
func (r *Receiver) Decline(offer protocol.TransferOffer, reason string) error {
	return r.conn.WriteJSON(protocol.TransferAccept{
		Type:       protocol.TypeTransferAccept,
		TransferID: offer.TransferID,
		Accepted:   false,
		Reason:     reason,
	})
}

// Receive accepts an offer and streams the file to disk. It returns the path
// the file was saved to.
func (r *Receiver) Receive(offer protocol.TransferOffer) (string, error) {
	if offer.Size < 0 || offer.ChunkSize <= 0 || offer.ChunkSize > transport.MaxFrameSize {
		r.Decline(offer, "malformed transfer offer")
		return "", fmt.Errorf("malformed transfer offer")
	}

	if err := os.MkdirAll(r.saveDir, 0o755); err != nil {
		r.Decline(offer, "receiver cannot write to its download folder")
		return "", err
	}

	savePath, err := uniquePath(r.saveDir, offer.Filename)
	if err != nil {
		r.Decline(offer, "invalid file name")
		return "", err
	}

	// Write to a temporary file and rename on success. A half-received file
	// must never appear under the real name, where the user would open it and
	// find it truncated.
	tmpPath := savePath + ".wedrop-part"
	file, err := os.Create(tmpPath)
	if err != nil {
		r.Decline(offer, "receiver cannot create the file")
		return "", err
	}

	cleanup := func() {
		file.Close()
		os.Remove(tmpPath)
	}

	if err := r.conn.WriteJSON(protocol.TransferAccept{
		Type:       protocol.TypeTransferAccept,
		TransferID: offer.TransferID,
		Accepted:   true,
	}); err != nil {
		cleanup()
		return "", err
	}

	var received int64
	for {
		r.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		headerBytes, err := r.conn.ReadEncrypted()
		if err != nil {
			cleanup()
			return "", fmt.Errorf("connection lost during transfer: %w", err)
		}

		msgType, err := protocol.ParseMessageType(headerBytes)
		if err != nil {
			cleanup()
			return "", fmt.Errorf("malformed frame during transfer")
		}

		if msgType == protocol.TypeTransferDone {
			var done protocol.TransferDone
			if err := json.Unmarshal(headerBytes, &done); err != nil {
				cleanup()
				return "", err
			}
			if done.Checksum != offer.Checksum {
				cleanup()
				return "", fmt.Errorf("sender's checksum changed mid-transfer")
			}
			break
		}

		if msgType != protocol.TypeTransferChunk {
			cleanup()
			return "", fmt.Errorf("expected a chunk, got %q", msgType)
		}

		var header protocol.TransferChunk
		if err := json.Unmarshal(headerBytes, &header); err != nil {
			cleanup()
			return "", err
		}
		if header.Size <= 0 || header.Size > offer.ChunkSize {
			cleanup()
			return "", fmt.Errorf("chunk %d declares an impossible size", header.Index)
		}
		if received+int64(header.Size) > offer.Size {
			// Refuse to let a sender write more than it offered; otherwise a
			// misbehaving peer could fill the disk.
			cleanup()
			return "", fmt.Errorf("sender exceeded the offered file size")
		}

		chunk, err := r.conn.ReadEncrypted()
		if err != nil {
			cleanup()
			return "", fmt.Errorf("connection lost during transfer: %w", err)
		}
		if len(chunk) != header.Size {
			cleanup()
			return "", fmt.Errorf("chunk %d arrived with the wrong length", header.Index)
		}
		if _, err := file.Write(chunk); err != nil {
			cleanup()
			return "", fmt.Errorf("writing to disk: %w", err)
		}

		received += int64(header.Size)
		if r.OnProgress != nil {
			r.OnProgress(received, offer.Size)
		}
	}

	if err := file.Sync(); err != nil {
		cleanup()
		return "", err
	}
	if err := file.Close(); err != nil {
		os.Remove(tmpPath)
		return "", err
	}

	if received != offer.Size {
		os.Remove(tmpPath)
		r.conn.WriteJSON(protocol.NewError(protocol.ErrInternal, "incomplete file"))
		return "", fmt.Errorf("file is incomplete: got %d of %d bytes", received, offer.Size)
	}

	actual, err := crypto.HashFile(tmpPath)
	if err != nil {
		os.Remove(tmpPath)
		return "", err
	}
	if actual != offer.Checksum {
		os.Remove(tmpPath)
		r.conn.WriteJSON(protocol.NewError(protocol.ErrInternal, "checksum mismatch"))
		return "", fmt.Errorf("the file arrived corrupted (checksum mismatch)")
	}

	if err := os.Rename(tmpPath, savePath); err != nil {
		os.Remove(tmpPath)
		return "", err
	}

	r.conn.WriteJSON(protocol.TransferDone{
		Type:       protocol.TypeTransferDone,
		TransferID: offer.TransferID,
		Checksum:   actual,
	})
	return savePath, nil
}

// sanitiseFilename reduces a peer-supplied name to a single safe path element.
//
// The name comes from another machine, so it cannot be trusted: "../../.ssh/
// authorized_keys" would otherwise let a paired device write anywhere the app
// can reach. Only the base name survives, and reserved Windows device names are
// pushed aside.
func sanitiseFilename(name string) (string, error) {
	name = strings.ReplaceAll(name, "\\", "/")
	name = filepath.Base(filepath.FromSlash(name))
	name = strings.TrimSpace(name)

	if name == "" || name == "." || name == ".." {
		return "", fmt.Errorf("unusable file name")
	}

	// Strip characters Windows refuses and that would confuse shells elsewhere.
	var b strings.Builder
	for _, r := range name {
		switch r {
		case '<', '>', ':', '"', '|', '?', '*', 0:
			b.WriteRune('_')
		default:
			if r < 32 {
				b.WriteRune('_')
			} else {
				b.WriteRune(r)
			}
		}
	}
	name = b.String()

	reserved := map[string]bool{
		"CON": true, "PRN": true, "AUX": true, "NUL": true,
		"COM1": true, "COM2": true, "COM3": true, "COM4": true,
		"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true,
	}
	if reserved[strings.ToUpper(strings.TrimSuffix(name, filepath.Ext(name)))] {
		name = "_" + name
	}

	if len(name) > 200 {
		ext := filepath.Ext(name)
		name = name[:200-len(ext)] + ext
	}
	return name, nil
}

// uniquePath returns a path in dir that does not collide with an existing file,
// appending " (2)", " (3)" and so on rather than overwriting what is there.
func uniquePath(dir, filename string) (string, error) {
	safe, err := sanitiseFilename(filename)
	if err != nil {
		return "", err
	}

	candidate := filepath.Join(dir, safe)
	if _, err := os.Stat(candidate); os.IsNotExist(err) {
		return candidate, nil
	}

	ext := filepath.Ext(safe)
	stem := strings.TrimSuffix(safe, ext)
	for i := 2; i < 10000; i++ {
		candidate = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, i, ext))
		if _, err := os.Stat(candidate); os.IsNotExist(err) {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("too many files named %q", safe)
}
