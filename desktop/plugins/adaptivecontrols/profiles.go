package adaptivecontrols

import (
	"strings"

	"wedrop/core/protocol"
)

// profile is one recognized app's built-in control set.
type profile struct {
	displayName string
	controls    []protocol.AdaptiveControl
}

// profiles maps a lowercased executable name to its built-in profile.
//
// VLC is deliberately not included here even though the original spec lists
// it: its example controls (play/pause/next/previous/volume) are already
// fully covered by the existing media plugin's multi-player Now Playing
// card via Windows' own SMTC integration — a second "dynamic controls"
// surface for the same buttons would be redundant, not new capability.
var profiles = map[string]profile{
	"code.exe": {
		displayName: "Visual Studio Code",
		controls: []protocol.AdaptiveControl{
			control("save", "Save", "save", shortcut(ctrl, "s")),
			control("undo", "Undo", "undo", shortcut(ctrl, "z")),
			control("redo", "Redo", "redo", shortcut(ctrl, "y")),
			control("search", "Search", "search", shortcut(ctrlShift, "f")),
			control("terminal", "Terminal", "terminal", shortcut(ctrl, "`")),
			control("git", "Git", "git", shortcut(ctrlShift, "g")),
			control("explorer", "Explorer", "folder", shortcut(ctrlShift, "e")),
			control("run", "Run", "run", shortcut(ctrl, protocol.KeyF5)),
			control("debug", "Debug", "debug", shortcut(nil, protocol.KeyF5)),
		},
	},
	"chrome.exe": {
		displayName: "Chrome",
		controls: []protocol.AdaptiveControl{
			control("back", "Back", "back", shortcut(alt, protocol.KeyLeft)),
			control("forward", "Forward", "forward", shortcut(alt, protocol.KeyRight)),
			control("refresh", "Refresh", "refresh", shortcut(nil, protocol.KeyF5)),
			control("newtab", "New tab", "apps", shortcut(ctrl, "t")),
			control("bookmark", "Bookmark", "star", shortcut(ctrl, "d")),
		},
	},
}

var (
	ctrl      = []string{protocol.ModifierCtrl}
	ctrlShift = []string{protocol.ModifierCtrl, protocol.ModifierShift}
	alt       = []string{protocol.ModifierAlt}
)

// genericControls is the fallback for any app that isn't one of the
// specific profiles above — the handful of keyboard shortcuts that hold
// their documented meaning in nearly every desktop app (a text editor, a
// browser, an office app, a file manager), the same idea KDE Connect's own
// generic keyboard-shortcut controls rely on. This is what makes dynamic
// controls show *something* for every app rather than only the two
// hardcoded profiles.
var genericControls = []protocol.AdaptiveControl{
	control("save", "Save", "save", shortcut(ctrl, "s")),
	control("undo", "Undo", "undo", shortcut(ctrl, "z")),
	control("redo", "Redo", "redo", shortcut(ctrl, "y")),
	control("copy", "Copy", "copy", shortcut(ctrl, "c")),
	control("paste", "Paste", "paste", shortcut(ctrl, "v")),
	control("cut", "Cut", "cut", shortcut(ctrl, "x")),
	control("selectall", "Select all", "selectall", shortcut(ctrl, "a")),
	control("find", "Find", "search", shortcut(ctrl, "f")),
	control("close", "Close", "close", shortcut(ctrl, "w")),
}

// selfExeNames are this app's own possible executable names (wails.json's
// outputfilename plus the "-dev" suffix wails dev builds under) — sending
// e.g. Ctrl+W to itself is nonsensical (and could close the very window
// showing these controls), so this is the one exclusion from "every app
// gets the generic fallback".
var selfExeNames = map[string]bool{
	"desktop.exe":     true,
	"desktop-dev.exe": true,
}

func control(id, label, icon string, action protocol.WorkspaceAction) protocol.AdaptiveControl {
	return protocol.AdaptiveControl{ID: id, Label: label, Icon: icon, Action: action}
}

func shortcut(modifiers []string, key string) protocol.WorkspaceAction {
	return protocol.WorkspaceAction{
		Type:      protocol.TypeWorkspaceAction,
		Action:    protocol.WorkspaceShortcut,
		Modifiers: modifiers,
		Key:       key,
	}
}

// profileFor resolves a lowercased executable name (e.g. "code.exe") to
// controls and a display name: its specific built-in profile if one exists,
// the generic fallback (with a friendly name derived from the exe itself)
// for anything else, or (nil, "") for an unresolvable name or this app's
// own process.
func profileFor(exeName string) ([]protocol.AdaptiveControl, string) {
	if exeName == "" || selfExeNames[exeName] {
		return nil, ""
	}
	if p, ok := profiles[exeName]; ok {
		return p.controls, p.displayName
	}
	return genericControls, friendlyName(exeName)
}

// friendlyName turns "notepad.exe" into "Notepad" — good enough for a
// generic label; not meant to match every app's own preferred display name
// the way the specific profiles above do.
func friendlyName(exeName string) string {
	name := strings.TrimSuffix(exeName, ".exe")
	if name == "" {
		return exeName
	}
	return strings.ToUpper(name[:1]) + name[1:]
}
