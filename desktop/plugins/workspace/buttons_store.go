package workspace

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"wedrop/core/protocol"
)

// ButtonStore is the desktop-authoritative home for this desktop's "My
// Workspace" buttons — one list, shared by every paired phone (App Actions
// and My Buttons are both attributes of the desktop being controlled, not
// of whichever phone happens to be controlling it). Buttons used to be
// created and edited on the phone itself; they now live here, edited from
// the desktop's My Buttons window (which reuses the same keyboard-capture
// shortcut recorder as the App Actions editor), and are pushed to every
// connected, permitted phone read-only. There is no seeding — this starts
// empty until configured, same as an app profile with nothing set up yet.
type ButtonStore struct {
	mu      sync.RWMutex
	path    string
	buttons []protocol.WorkspaceButtonDef
}

func newButtonStore(path string) *ButtonStore {
	s := &ButtonStore{path: path}
	s.load()
	return s
}

func (s *ButtonStore) load() {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return
	}
	// A corrupt file must not stop the app from starting, and must not
	// silently wipe the user's buttons — leave the store empty and let the
	// editor rebuild it, rather than guessing.
	_ = json.Unmarshal(data, &s.buttons)
}

func (s *ButtonStore) save() error {
	s.mu.RLock()
	data, err := json.MarshalIndent(s.buttons, "", "  ")
	s.mu.RUnlock()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(s.path, data, 0o600)
}

// Get returns the buttons, in saved order — always a non-nil slice (even
// when empty), because encoding/json marshals a nil slice as `null`, and the
// frontend calls .map() on the result without a null-check.
func (s *ButtonStore) Get() []protocol.WorkspaceButtonDef {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]protocol.WorkspaceButtonDef, len(s.buttons))
	copy(out, s.buttons)
	return out
}

// Set replaces the whole button list — the editor always resends the full
// edited list, the same pattern as the App Actions store's Upsert.
func (s *ButtonStore) Set(buttons []protocol.WorkspaceButtonDef) error {
	for i := range buttons {
		if buttons[i].ID == "" {
			buttons[i].ID = fmt.Sprintf("custom-%d-%d", time.Now().UnixNano(), i)
		}
	}

	s.mu.Lock()
	s.buttons = buttons
	s.mu.Unlock()
	return s.save()
}
