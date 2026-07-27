package transfer

import (
	"encoding/json"
	"io"
	"os"
	"wedrop/core/crypto"
	"wedrop/core/protocol"
	"wedrop/core/transport"
)

const ChunkSize = 1024 * 1024 // 1MB

// Sender handles sending a file over a secure connection
type Sender struct {
	Conn *transport.SecureConn
}

// NewSender creates a new file sender
func NewSender(conn *transport.SecureConn) *Sender {
	return &Sender{
		Conn: conn,
	}
}

// SendFile reads a file and sends it chunk by chunk
func (s *Sender) SendFile(filepath string, filename string) error {
	fileInfo, err := os.Stat(filepath)
	if err != nil {
		return err
	}
	
	checksum, err := crypto.HashFile(filepath)
	if err != nil {
		return err
	}
	
	file, err := os.Open(filepath)
	if err != nil {
		return err
	}
	defer file.Close()
	
	size := fileInfo.Size()
	chunkCount := int((size + ChunkSize - 1) / ChunkSize)
	
	startMsg := protocol.TransferStart{
		Type:       protocol.TypeTransferStart,
		Filename:   filename,
		Size:       size,
		Checksum:   checksum,
		ChunkCount: chunkCount,
	}
	
	startBytes, _ := json.Marshal(startMsg)
	if err := s.Conn.WriteEncrypted(startBytes); err != nil {
		return err
	}
	
	buf := make([]byte, ChunkSize)
	for i := 0; i < chunkCount; i++ {
		n, err := file.Read(buf)
		if err != nil && err != io.EOF {
			return err
		}
		if n == 0 {
			break
		}
		
		chunkData := buf[:n]
		
		chunkMsg := protocol.TransferChunk{
			Type:     protocol.TypeTransferChunk,
			Filename: filename,
			Index:    i,
			Size:     n,
		}
		
		chunkBytes, _ := json.Marshal(chunkMsg)
		if err := s.Conn.WriteEncrypted(chunkBytes); err != nil {
			return err
		}
		
		// Send raw chunk data securely
		if err := s.Conn.WriteEncrypted(chunkData); err != nil {
			return err
		}
	}
	
	return nil
}
