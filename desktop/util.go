package main

import (
	"encoding/json"
	"os"
	"strings"

	"wedrop/core/crypto"
)

func unmarshalJSON(data []byte, v interface{}) error {
	return json.Unmarshal(data, v)
}

func hashText(text string) string {
	return crypto.HashBytes([]byte(text))
}

func statSize(path string) (int64, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}

func trimName(name string) string {
	name = strings.TrimSpace(name)
	if len(name) > 48 {
		name = name[:48]
	}
	return name
}

// fingerprint renders a public key as short grouped hex, which is far easier to
// compare across two screens than 44 characters of base64.
func fingerprint(publicKeyBase64 string) string {
	sum := crypto.HashBytes([]byte(publicKeyBase64))
	if len(sum) < 16 {
		return sum
	}

	var parts []string
	for i := 0; i < 16; i += 4 {
		parts = append(parts, strings.ToUpper(sum[i:i+4]))
	}
	return strings.Join(parts, " ")
}
