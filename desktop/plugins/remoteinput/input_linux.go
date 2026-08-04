//go:build linux

package remoteinput

/*
#cgo LDFLAGS: -lX11 -lXtst
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <X11/keysym.h>
#include <stdlib.h>
#include <string.h>

Display* display = NULL;

void ensure_display() {
    if (!display) {
        display = XOpenDisplay(NULL);
    }
}

void mouse_move_relative(int dx, int dy) {
    ensure_display();
    if (!display) return;
    XWarpPointer(display, None, None, 0, 0, 0, 0, dx, dy);
    XFlush(display);
}

void mouse_click(int button) {
    ensure_display();
    if (!display) return;
    XTestFakeButtonEvent(display, button, True, 0);
    XTestFakeButtonEvent(display, button, False, 0);
    XFlush(display);
}

void mouse_down(int button) {
    ensure_display();
    if (!display) return;
    XTestFakeButtonEvent(display, button, True, 0);
    XFlush(display);
}

void mouse_up(int button) {
    ensure_display();
    if (!display) return;
    XTestFakeButtonEvent(display, button, False, 0);
    XFlush(display);
}

void key_click(KeySym keysym) {
    ensure_display();
    if (!display) return;
    KeyCode keycode = XKeysymToKeycode(display, keysym);
    if (keycode != 0) {
        XTestFakeKeyEvent(display, keycode, True, 0);
        XTestFakeKeyEvent(display, keycode, False, 0);
        XFlush(display);
    }
}

void key_down(KeySym keysym) {
    ensure_display();
    if (!display) return;
    KeyCode keycode = XKeysymToKeycode(display, keysym);
    if (keycode != 0) {
        XTestFakeKeyEvent(display, keycode, True, 0);
        XFlush(display);
    }
}

void key_up(KeySym keysym) {
    ensure_display();
    if (!display) return;
    KeyCode keycode = XKeysymToKeycode(display, keysym);
    if (keycode != 0) {
        XTestFakeKeyEvent(display, keycode, False, 0);
        XFlush(display);
    }
}

void type_char(char c) {
    ensure_display();
    if (!display) return;
    
    char str[2] = {c, '\0'};
    KeySym sym = XStringToKeysym(str);
    if (sym == NoSymbol) {
        sym = (unsigned char)c;
    }
    
    KeyCode keycode = XKeysymToKeycode(display, sym);
    if (keycode != 0) {
        int requires_shift = 0;
        if (c >= 'A' && c <= 'Z') requires_shift = 1;
        
        if (requires_shift) {
            KeyCode shiftCode = XKeysymToKeycode(display, XK_Shift_L);
            XTestFakeKeyEvent(display, shiftCode, True, 0);
            XTestFakeKeyEvent(display, keycode, True, 0);
            XTestFakeKeyEvent(display, keycode, False, 0);
            XTestFakeKeyEvent(display, shiftCode, False, 0);
        } else {
            XTestFakeKeyEvent(display, keycode, True, 0);
            XTestFakeKeyEvent(display, keycode, False, 0);
        }
        XFlush(display);
    }
}
*/
import "C"
import (
	"fmt"
	"strings"

	"wedrop/core/protocol"
)

// applyRemoteInput injects one event onto this machine.
func applyRemoteInput(in protocol.RemoteInput) {
	switch in.Action {
	case protocol.InputMouseMove:
		dx := C.int(in.DX * 1.6)
		dy := C.int(in.DY * 1.6)
		C.mouse_move_relative(dx, dy)

	case protocol.InputMouseLeft:
		C.mouse_click(1)
	case protocol.InputMouseRight:
		C.mouse_click(3)
	case protocol.InputMouseMiddle:
		C.mouse_click(2)
	case protocol.InputMouseDown:
		C.mouse_down(1)
	case protocol.InputMouseUp:
		C.mouse_up(1)

	case protocol.InputScroll:
		if in.DY > 0 {
			C.mouse_click(5) // Scroll down
		} else if in.DY < 0 {
			C.mouse_click(4) // Scroll up
		}

	case protocol.InputType:
		for _, r := range in.Text {
			if r <= 255 {
				C.type_char(C.char(r))
			}
		}
	case protocol.InputKey:
		pressNamedKey(in.Key)

	case protocol.InputPresentNext:
		C.key_click(C.XK_Right)
	case protocol.InputPresentPrev:
		C.key_click(C.XK_Left)
	case protocol.InputPresentStart:
		C.key_click(C.XK_F5)
	case protocol.InputPresentEnd:
		C.key_click(C.XK_Escape)
	case protocol.InputPresentBlank:
		C.key_click(C.XK_b)
	}
}

func pressNamedKey(key string) {
	if sym, ok := resolveKeyX11(key); ok {
		C.key_click(sym)
	}
}

func resolveKeyX11(key string) (C.KeySym, bool) {
	switch strings.ToLower(key) {
	case protocol.KeyBackspace:
		return C.XK_BackSpace, true
	case protocol.KeyEnter:
		return C.XK_Return, true
	case protocol.KeyTab:
		return C.XK_Tab, true
	case protocol.KeyEscape:
		return C.XK_Escape, true
	case protocol.KeySpace:
		return C.XK_space, true
	case protocol.KeyUp:
		return C.XK_Up, true
	case protocol.KeyDown:
		return C.XK_Down, true
	case protocol.KeyLeft:
		return C.XK_Left, true
	case protocol.KeyRight:
		return C.XK_Right, true
	case protocol.KeyHome:
		return C.XK_Home, true
	case protocol.KeyEnd:
		return C.XK_End, true
	case protocol.KeyDelete:
		return C.XK_Delete, true
	}

	lower := strings.ToLower(key)
	if strings.HasPrefix(lower, "f") && len(lower) >= 2 {
		switch lower {
		case "f1": return C.XK_F1, true
		case "f2": return C.XK_F2, true
		case "f3": return C.XK_F3, true
		case "f4": return C.XK_F4, true
		case "f5": return C.XK_F5, true
		case "f6": return C.XK_F6, true
		case "f7": return C.XK_F7, true
		case "f8": return C.XK_F8, true
		case "f9": return C.XK_F9, true
		case "f10": return C.XK_F10, true
		case "f11": return C.XK_F11, true
		case "f12": return C.XK_F12, true
		}
	}

	if key == "`" {
		return C.XK_grave, true
	}

	if len(key) == 1 {
		char := []byte(strings.ToLower(key))[0]
		return C.KeySym(char), true
	}
	return 0, false
}

func modifierX11(name string) (C.KeySym, bool) {
	switch strings.ToLower(name) {
	case protocol.ModifierCtrl:
		return C.XK_Control_L, true
	case protocol.ModifierShift:
		return C.XK_Shift_L, true
	case protocol.ModifierAlt:
		return C.XK_Alt_L, true
	case protocol.ModifierMeta:
		return C.XK_Super_L, true
	}
	return 0, false
}

// PressShortcut holds down each modifier (in order), taps key, then releases.
func PressShortcut(modifiers []string, key string) error {
	sym, ok := resolveKeyX11(key)
	if !ok {
		return fmt.Errorf("unknown key %q", key)
	}

	var held []C.KeySym
	for _, m := range modifiers {
		if xmod, ok := modifierX11(m); ok {
			C.key_down(xmod)
			held = append(held, xmod)
		}
	}

	C.key_click(sym)

	for i := len(held) - 1; i >= 0; i-- {
		C.key_up(held[i])
	}
	return nil
}
