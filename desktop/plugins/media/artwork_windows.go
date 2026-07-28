//go:build windows

package media

import (
	"encoding/base64"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"unsafe"
)

// windowsArtworkProvider extracts album art via wedrop_artwork.dll — a small
// native helper (source: artwork_native/artwork.cpp) built with real,
// compiler-checked C++/WinRT projection calls, not hand-rolled COM
// vtables/GUIDs.
//
// Windows' SMTC only exposes album art via
// GlobalSystemMediaTransportControlsSessionMediaProperties.Thumbnail, which
// returns an IRandomAccessStreamReference — turning that into JPEG bytes
// needs a chain of further WinRT calls (OpenReadAsync, decoding, re-encoding)
// this package's own go-ole/go-libnp-based vtable calls could only reach by
// guessing several more GUIDs and vtable layouts. Rather than do that,
// artwork_native/artwork.cpp does the same thing KDE Connect's own Windows
// mpriscontrol plugin does — real C++/WinRT (TryGetMediaPropertiesAsync ->
// Thumbnail -> OpenReadAsync -> decode -> re-encode as JPEG) — compiled to a
// DLL and loaded here via a plain C ABI, since cgo on Windows expects a
// gcc-compatible compiler and C++/WinRT needs MSVC. See
// artwork_native/build.ps1 to rebuild it after changing the C++ source.
type windowsArtworkProvider struct {
	loadOnce sync.Once
	loadErr  error
	getProc  *syscall.Proc
	freeProc *syscall.Proc

	warnOnce sync.Once
}

func newArtworkProvider() ArtworkProvider { return &windowsArtworkProvider{} }

func (p *windowsArtworkProvider) ensureLoaded() error {
	p.loadOnce.Do(func() {
		path, err := findArtworkDLL()
		if err != nil {
			p.loadErr = err
			return
		}
		dll, err := syscall.LoadDLL(path)
		if err != nil {
			p.loadErr = fmt.Errorf("loading %s: %w", path, err)
			return
		}
		getProc, err := dll.FindProc("WedropGetArtworkJpeg")
		if err != nil {
			p.loadErr = err
			return
		}
		freeProc, err := dll.FindProc("WedropFreeArtwork")
		if err != nil {
			p.loadErr = err
			return
		}
		p.getProc = getProc
		p.freeProc = freeProc
	})
	return p.loadErr
}

// findArtworkDLL looks next to the running executable first (where a
// packaged build ships it), falling back to its source location for `wails
// dev`/`go run`, which run from the desktop/ module root before any
// packaging step copies the DLL alongside a built exe.
func findArtworkDLL() (string, error) {
	const name = "wedrop_artwork.dll"

	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(exe), name)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}

	candidate := filepath.Join("plugins", "media", "artwork_native", name)
	if _, err := os.Stat(candidate); err == nil {
		return candidate, nil
	}

	return "", fmt.Errorf("%s not found next to the executable or at %s", name, candidate)
}

func (p *windowsArtworkProvider) Artwork() string {
	if err := p.ensureLoaded(); err != nil {
		p.warnOnce.Do(func() {
			log.Printf("wedrop: artwork disabled, %v (logging this once)", err)
		})
		return ""
	}

	var dataPtr uintptr
	var length uint32
	rc, _, _ := p.getProc.Call(uintptr(unsafe.Pointer(&dataPtr)), uintptr(unsafe.Pointer(&length)))
	if rc != 0 || dataPtr == 0 || length == 0 {
		return ""
	}
	defer p.freeProc.Call(dataPtr)

	data := unsafe.Slice((*byte)(unsafe.Pointer(dataPtr)), length)
	return base64.StdEncoding.EncodeToString(data)
}
