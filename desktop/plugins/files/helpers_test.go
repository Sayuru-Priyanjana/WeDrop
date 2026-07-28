package files

import (
	"encoding/json"
	"net"
	"testing"
)

func netListen(t *testing.T) (net.Listener, error) {
	t.Helper()
	return net.Listen("tcp", "127.0.0.1:0")
}

func netDial(address string) (net.Conn, error) {
	return net.Dial("tcp", address)
}

func jsonUnmarshal(data []byte, v interface{}) error {
	return json.Unmarshal(data, v)
}
