package crypto

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
)

// HashBytes computes the SHA256 hash of a byte slice
func HashBytes(data []byte) string {
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

// HashFile computes the SHA256 hash of a file
func HashFile(filepath string) (string, error) {
	file, err := os.Open(filepath)
	if err != nil {
		return "", err
	}
	defer file.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}

	return hex.EncodeToString(hash.Sum(nil)), nil
}
