//go:build windows

package remoteinput

import (
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"

	"wedrop/core/protocol"
)

// Remote input injection via SendInput. This is what makes a phone a mouse and
// keyboard for the desktop: each RemoteInput message becomes a synthetic input
// event the OS delivers to whatever window has focus.
//
// user32 used to be declared once in media_windows.go and shared across
// package main by both features; now that media has moved to its own plugin
// package (desktop/plugins/media), remote input (not yet extracted — see the
// plugin architecture refactor plan) needs its own handle to user32.dll.
var user32 = windows.NewLazySystemDLL("user32.dll")

var procSendInput = user32.NewProc("SendInput")

const (
	inputMouse    = 0
	inputKeyboard = 1

	mouseeventfMove       = 0x0001
	mouseeventfLeftDown   = 0x0002
	mouseeventfLeftUp     = 0x0004
	mouseeventfRightDown  = 0x0008
	mouseeventfRightUp    = 0x0010
	mouseeventfMiddleDown = 0x0020
	mouseeventfMiddleUp   = 0x0040
	mouseeventfWheel      = 0x0800

	keyeventfKeyUp   = 0x0002
	keyeventfUnicode = 0x0004

	wheelDelta = 120
)

// mouseInput/keyboardInput mirror the real Win32 INPUT struct's layout on
// amd64 — not just its size. INPUT is `DWORD type` followed by a union of
// MOUSEINPUT/KEYBDINPUT/HARDWAREINPUT; because that union's largest member
// (MOUSEINPUT) contains a ULONG_PTR needing 8-byte alignment, the union
// itself — and so every field after `type` — starts 8 bytes into the
// struct, not 4. The previous version of these structs only padded the
// *end* to reach the right total size (matching a comment claiming that was
// sufficient), which is wrong: every field from dx/wVk onward was actually
// sitting 4 bytes earlier than SendInput expects, so it was reading
// shifted/garbage flags and deltas. Confirmed by direct testing: the
// original layout never moved the OS cursor at all (SendInput either read a
// dwFlags value that didn't include MOUSEEVENTF_MOVE, or the keyboard
// variant's resulting wrong total size — 32 bytes instead of the required
// 40 — made SendInput reject the call outright). This is the same
// leading-padding fix any C compiler applies automatically, made explicit
// since Go does not know about C's union-alignment rules.
type mouseInput struct {
	typ       uint32
	_pad      uint32
	dx        int32
	dy        int32
	mouseData uint32
	dwFlags   uint32
	time      uint32
	dwExtra   uintptr
}

type keyboardInput struct {
	typ     uint32
	_pad    uint32
	wVk     uint16
	wScan   uint16
	dwFlags uint32
	time    uint32
	dwExtra uintptr
	// KEYBDINPUT is smaller than MOUSEINPUT, but the union's total size in a
	// real INPUT struct is always the largest member's size (40 bytes
	// overall) — SendInput requires cbSize to equal that exactly regardless
	// of which variant is populated, so this pads out to match.
	_ [8]byte
}

func sendMouse(flags uint32, dx, dy int32, data uint32) {
	in := mouseInput{
		typ:       inputMouse,
		dx:        dx,
		dy:        dy,
		mouseData: data,
		dwFlags:   flags,
	}
	procSendInput.Call(1, uintptr(unsafe.Pointer(&in)), unsafe.Sizeof(in))
}

func sendKeyVK(vk uint16, up bool) {
	var flags uint32
	if up {
		flags = keyeventfKeyUp
	}
	in := keyboardInput{typ: inputKeyboard, wVk: vk, dwFlags: flags}
	procSendInput.Call(1, uintptr(unsafe.Pointer(&in)), unsafe.Sizeof(in))
}

// sendUnicode types one Unicode rune, which sidesteps keyboard-layout mapping
// entirely — the character the user typed on the phone is the character that
// appears, regardless of the desktop's layout.
func sendUnicode(r rune) {
	down := keyboardInput{typ: inputKeyboard, wScan: uint16(r), dwFlags: keyeventfUnicode}
	up := keyboardInput{typ: inputKeyboard, wScan: uint16(r), dwFlags: keyeventfUnicode | keyeventfKeyUp}
	procSendInput.Call(1, uintptr(unsafe.Pointer(&down)), unsafe.Sizeof(down))
	procSendInput.Call(1, uintptr(unsafe.Pointer(&up)), unsafe.Sizeof(up))
}

// applyRemoteInput injects one event onto this machine.
func applyRemoteInput(in protocol.RemoteInput) {
	switch in.Action {
	case protocol.InputMouseMove:
		// A speed multiplier makes the touchpad feel responsive without the
		// phone having to send high-resolution deltas.
		sendMouse(mouseeventfMove, int32(in.DX*1.6), int32(in.DY*1.6), 0)

	case protocol.InputMouseLeft:
		sendMouse(mouseeventfLeftDown, 0, 0, 0)
		sendMouse(mouseeventfLeftUp, 0, 0, 0)
	case protocol.InputMouseRight:
		sendMouse(mouseeventfRightDown, 0, 0, 0)
		sendMouse(mouseeventfRightUp, 0, 0, 0)
	case protocol.InputMouseMiddle:
		sendMouse(mouseeventfMiddleDown, 0, 0, 0)
		sendMouse(mouseeventfMiddleUp, 0, 0, 0)
	case protocol.InputMouseDown:
		sendMouse(mouseeventfLeftDown, 0, 0, 0)
	case protocol.InputMouseUp:
		sendMouse(mouseeventfLeftUp, 0, 0, 0)

	case protocol.InputScroll:
		sendMouse(mouseeventfWheel, 0, 0, uint32(int32(in.DY*wheelDelta)))

	case protocol.InputType:
		for _, r := range in.Text {
			sendUnicode(r)
		}
	case protocol.InputKey:
		pressNamedKey(in.Key)

	case protocol.InputPresentNext:
		tapVK(vkRight)
	case protocol.InputPresentPrev:
		tapVK(vkLeft)
	case protocol.InputPresentStart:
		tapVK(vkF5)
	case protocol.InputPresentEnd:
		tapVK(vkEscape)
	case protocol.InputPresentBlank:
		tapVK('B') // most slideshow apps blank the screen on B
	}
}

func tapVK(vk uint16) {
	sendKeyVK(vk, false)
	sendKeyVK(vk, true)
}

// Virtual key codes for the named keys and presentation controls.
const (
	vkBack   = 0x08
	vkTab    = 0x09
	vkReturn = 0x0D
	vkEscape = 0x1B
	vkSpace  = 0x20
	vkEnd    = 0x23
	vkHome   = 0x24
	vkLeft   = 0x25
	vkUp     = 0x26
	vkRight  = 0x27
	vkDown   = 0x28
	vkDelete = 0x2E
	vkF5     = 0x74
)

func pressNamedKey(key string) {
	var vk uint16
	switch strings.ToLower(key) {
	case protocol.KeyBackspace:
		vk = vkBack
	case protocol.KeyEnter:
		vk = vkReturn
	case protocol.KeyTab:
		vk = vkTab
	case protocol.KeyEscape:
		vk = vkEscape
	case protocol.KeySpace:
		vk = vkSpace
	case protocol.KeyUp:
		vk = vkUp
	case protocol.KeyDown:
		vk = vkDown
	case protocol.KeyLeft:
		vk = vkLeft
	case protocol.KeyRight:
		vk = vkRight
	case protocol.KeyHome:
		vk = vkHome
	case protocol.KeyEnd:
		vk = vkEnd
	case protocol.KeyDelete:
		vk = vkDelete
	default:
		return
	}
	tapVK(vk)
}
