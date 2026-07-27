package storage

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
)

// Store handles encrypted storage of local data
type Store struct {
	BaseDir       string
	EncryptionKey []byte // 32-byte key for AES-256
}

// NewStore initializes a new storage manager
func NewStore(encryptionKey []byte) (*Store, error) {
	if len(encryptionKey) != 32 {
		return nil, fmt.Errorf("encryption key must be 32 bytes")
	}

	dir, err := getDefaultDir()
	if err != nil {
		return nil, err
	}

	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}

	return &Store{
		BaseDir:       dir,
		EncryptionKey: encryptionKey,
	}, nil
}

func getDefaultDir() (string, error) {
	if runtime.GOOS == "windows" {
		appdata := os.Getenv("APPDATA")
		if appdata == "" {
			return "", fmt.Errorf("APPDATA environment variable not set")
		}
		return filepath.Join(appdata, "WeDrop"), nil
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".wedrop"), nil
}

// SaveEncryptedJSON marshals a struct to JSON, encrypts it, and saves it to a file
func (s *Store) SaveEncryptedJSON(filename string, data interface{}) error {
	jsonData, err := json.Marshal(data)
	if err != nil {
		return err
	}

	ciphertext, err := s.encrypt(jsonData)
	if err != nil {
		return err
	}

	return s.writeAtomic(filename, ciphertext)
}

// writeAtomic writes to a sibling temporary file and renames it into place.
//
// A plain WriteFile truncates first, so losing power (or being killed while
// closing) between truncate and write leaves a zero-length file — and for the
// trust store that silently empties the user's entire ecosystem.
func (s *Store) writeAtomic(filename string, data []byte) error {
	path := filepath.Join(s.BaseDir, filename)
	tmp := path + ".tmp"

	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// LoadEncryptedJSON reads an encrypted file, decrypts it, and unmarshals it
func (s *Store) LoadEncryptedJSON(filename string, v interface{}) error {
	path := filepath.Join(s.BaseDir, filename)
	ciphertext, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	plaintext, err := s.decrypt(ciphertext)
	if err != nil {
		return err
	}

	return json.Unmarshal(plaintext, v)
}

// SaveJSON marshals a struct to JSON and saves it without encryption
func (s *Store) SaveJSON(filename string, data interface{}) error {
	jsonData, err := json.Marshal(data)
	if err != nil {
		return err
	}
	return s.writeAtomic(filename, jsonData)
}

// LoadJSON reads a file and unmarshals it without decryption
func (s *Store) LoadJSON(filename string, v interface{}) error {
	path := filepath.Join(s.BaseDir, filename)
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

// FileExists checks if a file exists in the storage directory
func (s *Store) FileExists(filename string) bool {
	path := filepath.Join(s.BaseDir, filename)
	_, err := os.Stat(path)
	return err == nil
}

// GetPath returns the full path for a file
func (s *Store) GetPath(filename string) string {
	return filepath.Join(s.BaseDir, filename)
}

func (s *Store) encrypt(plaintext []byte) ([]byte, error) {
	block, err := aes.NewCipher(s.EncryptionKey)
	if err != nil {
		return nil, err
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}

	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

func (s *Store) decrypt(ciphertext []byte) ([]byte, error) {
	block, err := aes.NewCipher(s.EncryptionKey)
	if err != nil {
		return nil, err
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	nonceSize := gcm.NonceSize()
	if len(ciphertext) < nonceSize {
		return nil, fmt.Errorf("ciphertext too short")
	}

	nonce, encryptedMessage := ciphertext[:nonceSize], ciphertext[nonceSize:]
	return gcm.Open(nil, nonce, encryptedMessage, nil)
}
