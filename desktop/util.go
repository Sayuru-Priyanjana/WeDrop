package main

import (
	"encoding/json"
	"strings"

	"wedrop/core/crypto"
)

func unmarshalJSON(data []byte, v interface{}) error {
	return json.Unmarshal(data, v)
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
