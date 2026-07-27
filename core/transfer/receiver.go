package transfer

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"wedrop/core/crypto"
	"wedrop/core/protocol"
	"wedrop/core/transport"
)

// Receiver handles receiving files over a secure connection
type Receiver struct {
	Conn    *transport.SecureConn
	SaveDir string
}

// NewReceiver creates a new file receiver
func NewReceiver(conn *transport.SecureConn, saveDir string) *Receiver {
	return &Receiver{
		Conn:    conn,
		SaveDir: saveDir,
	}
}

// ReceiveFile reads incoming file chunks and writes them to disk
func (r *Receiver) ReceiveFile(startMsg *protocol.TransferStart) error {
	if err := os.MkdirAll(r.SaveDir, 0755); err != nil {
		return err
	}

	savePath := filepath.Join(r.SaveDir, startMsg.Filename)
	file, err := os.Create(savePath)
	if err != nil {
		return err
	}
	defer file.Close()

	for i := 0; i < startMsg.ChunkCount; i++ {
		// Read chunk metadata
		metaBytes, err := r.Conn.ReadEncrypted()
		if err != nil {
			return err
		}

		var chunkMsg protocol.TransferChunk
		if err := json.Unmarshal(metaBytes, &chunkMsg); err != nil {
			return err
		}

		if chunkMsg.Type != protocol.TypeTransferChunk {
			return fmt.Errorf("expected TransferChunk, got %s", chunkMsg.Type)
		}
		if chunkMsg.Index != i {
			return fmt.Errorf("chunk index mismatch: expected %d, got %d", i, chunkMsg.Index)
		}

		// Read actual chunk data
		chunkData, err := r.Conn.ReadEncrypted()
		if err != nil {
			return err
		}
		
		if len(chunkData) != chunkMsg.Size {
			return fmt.Errorf("chunk size mismatch")
		}

		if _, err := file.Write(chunkData); err != nil {
			return err
		}
	}

	// Verify checksum
	receivedChecksum, err := crypto.HashFile(savePath)
	if err != nil {
		return err
	}

	if receivedChecksum != startMsg.Checksum {
		return fmt.Errorf("checksum mismatch: expected %s, got %s", startMsg.Checksum, receivedChecksum)
	}

	return nil
}
