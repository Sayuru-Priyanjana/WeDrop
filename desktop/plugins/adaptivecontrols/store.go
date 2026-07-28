package adaptivecontrols

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"wedrop/core/protocol"
)

// AppAction is one editable action belonging to an AppProfile. Predefined
// actions (seeded from seedDefaults below) are ordinary, fully-editable
// entries — Predefined only drives a "built-in" badge in the desktop editor,
// it grants no special protection from being edited or removed.
type AppAction struct {
	ID         string                   `json:"id"`
	Label      string                   `json:"label"`
	Icon       string                   `json:"icon"`        // key into mobile's kWorkspaceIcons
	ColorValue int                      `json:"color_value"` // ARGB, 0 = no override (phone picks a default)
	Predefined bool                     `json:"predefined"`
	Action     protocol.WorkspaceAction `json:"action"`
}

// AppProfile is one application's whole set of Dynamic Controls buttons.
type AppProfile struct {
	Exe         string      `json:"exe"` // lowercased, e.g. "code.exe" — the store's key
	DisplayName string      `json:"display_name"`
	Actions     []AppAction `json:"actions"`
}

// Store is the persisted, user-editable replacement for what used to be a
// hardcoded Go map: every recognized app's buttons, plus whatever the user
// has since added or changed, in one plain JSON file. There is deliberately
// no "generic fallback" profile here — an app with no entry gets zero
// predefined controls (see plugin.go's currentState), and the user adds
// their own via the desktop's App Actions editor or the phone's "Configure
// this app" prompt.
type Store struct {
	mu       sync.RWMutex
	path     string
	profiles map[string]*AppProfile // key: lowercased exe
}

func newStore(path string) *Store {
	st := &Store{path: path, profiles: map[string]*AppProfile{}}
	st.load()
	return st
}

func (s *Store) load() {
	data, err := os.ReadFile(s.path)
	if err != nil {
		s.seedDefaults()
		return
	}

	var list []AppProfile
	if err := json.Unmarshal(data, &list); err != nil {
		// A corrupt file must not stop the app from starting, and must not
		// silently discard the user's edits by re-seeding over them — leave
		// the store empty (no predefined controls anywhere) and let the
		// editor rebuild it, rather than guessing.
		return
	}
	for i := range list {
		p := list[i]
		s.profiles[strings.ToLower(p.Exe)] = &p
	}
}

func (s *Store) save() error {
	s.mu.RLock()
	list := s.list()
	s.mu.RUnlock()

	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(s.path, data, 0o600)
}

// list returns every profile sorted by display name — callers must hold at
// least a read lock.
func (s *Store) list() []AppProfile {
	out := make([]AppProfile, 0, len(s.profiles))
	for _, p := range s.profiles {
		out = append(out, *p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].DisplayName < out[j].DisplayName })
	return out
}

// List returns every profile, sorted by display name.
func (s *Store) List() []AppProfile {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.list()
}

// Get returns the profile for a lowercased exe name, if one exists.
func (s *Store) Get(exe string) (AppProfile, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	p, ok := s.profiles[strings.ToLower(exe)]
	if !ok {
		return AppProfile{}, false
	}
	return *p, true
}

// Upsert replaces (or creates) a whole profile — the same "resend the whole
// edited object" pattern the mobile side already uses for WorkspaceButton
// lists, rather than granular per-field RPCs.
func (s *Store) Upsert(profile AppProfile) error {
	exe := strings.ToLower(strings.TrimSpace(profile.Exe))
	if exe == "" {
		return fmt.Errorf("an application executable name is required")
	}
	profile.Exe = exe
	if profile.DisplayName == "" {
		profile.DisplayName = friendlyName(exe)
	}
	for i := range profile.Actions {
		if profile.Actions[i].ID == "" {
			profile.Actions[i].ID = fmt.Sprintf("custom-%d", i)
		}
	}

	s.mu.Lock()
	s.profiles[exe] = &profile
	s.mu.Unlock()
	return s.save()
}

// Delete removes a whole profile.
func (s *Store) Delete(exe string) error {
	s.mu.Lock()
	delete(s.profiles, strings.ToLower(exe))
	s.mu.Unlock()
	return s.save()
}

// selfExeNames are this app's own possible executable names (wails.json's
// outputfilename plus the "-dev" suffix wails dev builds under) — sending
// e.g. Ctrl+W to itself is nonsensical (and could close the very window
// showing these controls), so this is the one app that never gets a profile
// or a "configure this app" prompt.
var selfExeNames = map[string]bool{
	"desktop.exe":     true,
	"desktop-dev.exe": true,
}

// friendlyName turns "notepad.exe" into "Notepad" — the label shown for an
// app with no profile yet, both in the "Now on desktop" line and as the
// pre-filled name when the user configures it.
func friendlyName(exeName string) string {
	name := strings.TrimSuffix(exeName, ".exe")
	if name == "" {
		return exeName
	}
	return strings.ToUpper(name[:1]) + name[1:]
}

var (
	ctrl      = []string{protocol.ModifierCtrl}
	ctrlShift = []string{protocol.ModifierCtrl, protocol.ModifierShift}
	alt       = []string{protocol.ModifierAlt}
)

func action(id, label, icon string, wsAction protocol.WorkspaceAction) AppAction {
	return AppAction{ID: id, Label: label, Icon: icon, Predefined: true, Action: wsAction}
}

func shortcut(modifiers []string, key string) protocol.WorkspaceAction {
	return protocol.WorkspaceAction{
		Type:      protocol.TypeWorkspaceAction,
		Action:    protocol.WorkspaceShortcut,
		Modifiers: modifiers,
		Key:       key,
	}
}

// seedDefaults populates the store with WeDrop's own two built-in profiles
// the first time it runs on a machine with no app_actions.json yet — after
// this, the file is the source of truth and this never runs again, so
// editing (or deleting) these two profiles sticks.
func (s *Store) seedDefaults() {
	s.profiles["code.exe"] = &AppProfile{
		Exe:         "code.exe",
		DisplayName: "Visual Studio Code",
		Actions: []AppAction{
			action("save", "Save", "save", shortcut(ctrl, "s")),
			action("undo", "Undo", "undo", shortcut(ctrl, "z")),
			action("redo", "Redo", "redo", shortcut(ctrl, "y")),
			action("search", "Search", "search", shortcut(ctrlShift, "f")),
			action("terminal", "Terminal", "terminal", shortcut(ctrl, "`")),
			action("git", "Git", "git", shortcut(ctrlShift, "g")),
			action("explorer", "Explorer", "folder", shortcut(ctrlShift, "e")),
			action("run", "Run", "run", shortcut(ctrl, protocol.KeyF5)),
			action("debug", "Debug", "debug", shortcut(nil, protocol.KeyF5)),
		},
	}
	s.profiles["chrome.exe"] = &AppProfile{
		Exe:         "chrome.exe",
		DisplayName: "Chrome",
		Actions: []AppAction{
			action("back", "Back", "back", shortcut(alt, protocol.KeyLeft)),
			action("forward", "Forward", "forward", shortcut(alt, protocol.KeyRight)),
			action("refresh", "Refresh", "refresh", shortcut(nil, protocol.KeyF5)),
			action("newtab", "New tab", "apps", shortcut(ctrl, "t")),
			action("bookmark", "Bookmark", "star", shortcut(ctrl, "d")),
		},
	}
	_ = s.save()
}
