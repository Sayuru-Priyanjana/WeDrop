package transfer

import (
	"bytes"
	"crypto/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"wedrop/core/crypto"
	"wedrop/core/protocol"
	"wedrop/core/transport"
)

func TestSanitiseFilenameStripsTraversal(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"report.pdf", "report.pdf"},
		{"../../../etc/passwd", "passwd"},
		{`..\..\Windows\System32\drivers\etc\hosts`, "hosts"},
		{"/absolute/path/photo.jpg", "photo.jpg"},
		{`C:\Users\someone\.ssh\id_rsa`, "id_rsa"},
		{"weird:name?.txt", "weird_name_.txt"},
	}

	for _, tc := range cases {
		got, err := sanitiseFilename(tc.in)
		if err != nil {
			t.Errorf("sanitiseFilename(%q) returned error %v", tc.in, err)
			continue
		}
		if got != tc.want {
			t.Errorf("sanitiseFilename(%q) = %q, want %q", tc.in, got, tc.want)
		}
		// Whatever comes back must be a single path element, so joining it to
		// the download folder can never escape that folder.
		if strings.ContainsAny(got, `/\`) {
			t.Errorf("sanitiseFilename(%q) = %q still contains a separator", tc.in, got)
		}
	}

	for _, bad := range []string{"", "..", ".", "   "} {
		if _, err := sanitiseFilename(bad); err == nil {
			t.Errorf("sanitiseFilename(%q) should have been rejected", bad)
		}
	}
}

func TestUniquePathDoesNotOverwrite(t *testing.T) {
	dir := t.TempDir()

	first, err := uniquePath(dir, "notes.txt")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(first, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}

	second, err := uniquePath(dir, "notes.txt")
	if err != nil {
		t.Fatal(err)
	}
	if second == first {
		t.Fatal("uniquePath handed back a path that already exists")
	}
	if filepath.Base(second) != "notes (2).txt" {
		t.Errorf("expected 'notes (2).txt', got %q", filepath.Base(second))
	}

	// The original must be untouched.
	data, err := os.ReadFile(first)
	if err != nil || string(data) != "original" {
		t.Error("the existing file was modified")
	}
}

// connPair returns two SecureConns sharing a key over a real socket pair.
func connPair(t *testing.T) (*transport.SecureConn, *transport.SecureConn) {
	t.Helper()

	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		t.Fatal(err)
	}

	type result struct {
		conn *transport.SecureConn
		err  error
	}
	done := make(chan result, 1)

	listener, err := netListen(t)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	go func() {
		c, err := listener.Accept()
		if err != nil {
			done <- result{nil, err}
			return
		}
		done <- result{transport.NewSecureConn(c, key), nil}
	}()

	client, err := netDial(listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}

	r := <-done
	if r.err != nil {
		t.Fatal(r.err)
	}
	return transport.NewSecureConn(client, key), r.conn
}

func TestTransferRoundTrip(t *testing.T) {
	// A payload spanning several chunks with a ragged final chunk, which is
	// where short reads used to silently truncate the file.
	payload := make([]byte, ChunkSize*2+1234)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}

	srcDir := t.TempDir()
	srcPath := filepath.Join(srcDir, "payload.bin")
	if err := os.WriteFile(srcPath, payload, 0o600); err != nil {
		t.Fatal(err)
	}

	sendConn, recvConn := connPair(t)
	defer sendConn.Close()
	defer recvConn.Close()

	destDir := t.TempDir()

	sendErr := make(chan error, 1)
	go func() {
		sendErr <- NewSender(sendConn).SendFile("t-1", srcPath)
	}()

	offerBytes, err := recvConn.ReadEncrypted()
	if err != nil {
		t.Fatalf("reading offer: %v", err)
	}
	var offer protocol.TransferOffer
	if err := jsonUnmarshal(offerBytes, &offer); err != nil {
		t.Fatal(err)
	}
	if offer.Size != int64(len(payload)) {
		t.Fatalf("offer size %d, want %d", offer.Size, len(payload))
	}

	savedPath, err := NewReceiver(recvConn, destDir).Receive(offer)
	if err != nil {
		t.Fatalf("receive: %v", err)
	}
	if err := <-sendErr; err != nil {
		t.Fatalf("send: %v", err)
	}

	got, err := os.ReadFile(savedPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("received %d bytes, expected %d and identical content", len(got), len(payload))
	}

	// No partial file should be left behind.
	leftovers, _ := filepath.Glob(filepath.Join(destDir, "*.wedrop-part"))
	if len(leftovers) != 0 {
		t.Errorf("temporary files left behind: %v", leftovers)
	}

	sum, err := crypto.HashFile(savedPath)
	if err != nil {
		t.Fatal(err)
	}
	if sum != offer.Checksum {
		t.Error("saved file does not match the offered checksum")
	}
}

func TestReceiverDeclineIsReportedToSender(t *testing.T) {
	srcPath := filepath.Join(t.TempDir(), "small.txt")
	if err := os.WriteFile(srcPath, []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}

	sendConn, recvConn := connPair(t)
	defer sendConn.Close()
	defer recvConn.Close()

	sendErr := make(chan error, 1)
	go func() {
		sendErr <- NewSender(sendConn).SendFile("t-2", srcPath)
	}()

	offerBytes, err := recvConn.ReadEncrypted()
	if err != nil {
		t.Fatal(err)
	}
	var offer protocol.TransferOffer
	if err := jsonUnmarshal(offerBytes, &offer); err != nil {
		t.Fatal(err)
	}

	if err := NewReceiver(recvConn, t.TempDir()).Decline(offer, "user said no"); err != nil {
		t.Fatal(err)
	}

	err = <-sendErr
	if err == nil {
		t.Fatal("sender reported success for a declined transfer")
	}
	if !strings.Contains(err.Error(), "user said no") {
		t.Errorf("decline reason did not reach the sender: %v", err)
	}
}
