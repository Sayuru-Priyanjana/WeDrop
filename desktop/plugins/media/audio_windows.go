//go:build windows

package media

// Output-device listing/switching and per-application volume — the rest of
// what KDE Connect's Windows systemvolume plugin covers, alongside the
// system-wide volume already in volume_windows.go.
//
// Device enumeration and per-app volume use github.com/moutend/go-wca, a
// published, independently maintained Go binding for Windows' Core Audio API
// (IMMDeviceEnumerator, IAudioSessionManager2, ISimpleAudioVolume, etc.) —
// all fully documented, synchronous COM interfaces, cross-checked here
// against the vtable orders in this machine's own installed Windows SDK
// headers (mmdeviceapi.h, Propsys.h, audiopolicy.h, Audioclient.h) before
// use, the same rigor as volume_windows.go's own hand-rolled interfaces.
//
// Switching the *default* output device is different: Windows has never
// shipped a public, documented API for it. Every tool that does it —
// including KDE Connect's own Windows systemvolume plugin (PolicyConfig.h)
// — goes through IPolicyConfig, an undocumented interface with no
// Microsoft compatibility guarantee. The GUIDs and vtable order below are
// taken verbatim from that same KDE Connect source (itself sourced from
// EreTIk's widely-reused PolicyConfig.h), not guessed. The user explicitly
// asked for this despite the risk after being told it could break on a
// future Windows update with no fix path from Microsoft.
import (
	"fmt"
	"syscall"
	"unsafe"

	ole "github.com/go-ole/go-ole"
	"github.com/moutend/go-wca/pkg/wca"
	"golang.org/x/sys/windows"
)

// ---- Output device listing (public, documented API) ----

// AudioDevice describes one playback (render) endpoint.
type AudioDevice struct {
	ID      string
	Name    string
	Default bool
}

const (
	edataFlowRenderWca = 0
	deviceStateActive  = 1
)

// ensureAudioComInit joins the calling OS thread to a multi-threaded COM
// apartment. Unlike smtc_windows.go's ensureSMTCInit (a sync.Once, so it only
// ever actually initializes the first OS thread it happens to run on), this
// is called on every entry point here and ignores its result — Go can
// migrate a goroutine to a different OS thread between calls, and each
// distinct OS thread that makes a COM call needs to have joined the
// apartment itself; CoInitializeEx is cheap and returns harmlessly
// (S_FALSE) if that thread already has.
func ensureAudioComInit() {
	_ = ole.CoInitializeEx(0, ole.COINIT_MULTITHREADED)
}

func listAudioDevices() ([]AudioDevice, error) {
	ensureAudioComInit()
	var enumerator *wca.IMMDeviceEnumerator
	if err := wca.CoCreateInstance(wca.CLSID_MMDeviceEnumerator, 0, clsctxAll, wca.IID_IMMDeviceEnumerator, &enumerator); err != nil {
		return nil, err
	}
	defer enumerator.Release()

	var defaultID string
	var defaultDevice *wca.IMMDevice
	if err := enumerator.GetDefaultAudioEndpoint(edataFlowRenderWca, eroleMultimedia, &defaultDevice); err == nil {
		defaultDevice.GetId(&defaultID)
		defaultDevice.Release()
	}

	var collection *wca.IMMDeviceCollection
	if err := enumerator.EnumAudioEndpoints(edataFlowRenderWca, deviceStateActive, &collection); err != nil {
		return nil, err
	}
	defer collection.Release()

	var count uint32
	if err := collection.GetCount(&count); err != nil {
		return nil, err
	}

	devices := make([]AudioDevice, 0, count)
	for i := uint32(0); i < count; i++ {
		var device *wca.IMMDevice
		if err := collection.Item(i, &device); err != nil {
			continue
		}

		var id string
		device.GetId(&id)

		name := id
		var store *wca.IPropertyStore
		if err := device.OpenPropertyStore(0 /* STGM_READ */, &store); err == nil {
			var v wca.PROPVARIANT
			if err := store.GetValue(&wca.PKEY_Device_FriendlyName, &v); err == nil {
				if s := v.String(); s != "" {
					name = s
				}
			}
			store.Release()
		}

		devices = append(devices, AudioDevice{ID: id, Name: name, Default: id != "" && id == defaultID})
		device.Release()
	}

	return devices, nil
}

// ---- Output device switching (undocumented API, user-accepted risk) ----

var (
	clsidPolicyConfig = ole.NewGUID("{870af99c-171d-4f9e-af0d-e63df40c2bc9}")
	iidPolicyConfig   = ole.NewGUID("{f8679f50-850a-41cf-9c72-430f290290c8}")
)

type policyConfig struct{ ole.IUnknown }

// Only SetDefaultEndpoint is used; every slot before it must still be
// declared, in order, so its offset in the vtable is correct — order taken
// verbatim from kdeconnect-kde's plugins/systemvolume/PolicyConfig.h.
type policyConfigVtbl struct {
	ole.IUnknownVtbl
	GetMixFormat         uintptr
	GetDeviceFormat      uintptr
	ResetDeviceFormat    uintptr
	SetDeviceFormat      uintptr
	GetProcessingPeriod  uintptr
	SetProcessingPeriod  uintptr
	GetShareMode         uintptr
	SetShareMode         uintptr
	GetPropertyValue     uintptr
	SetPropertyValue     uintptr
	SetDefaultEndpoint   uintptr
	SetEndpointVisibility uintptr
}

func (v *policyConfig) vtable() *policyConfigVtbl {
	return (*policyConfigVtbl)(unsafe.Pointer(v.RawVTable))
}

func (v *policyConfig) setDefaultEndpoint(deviceID string, role int32) error {
	idPtr, err := syscall.UTF16PtrFromString(deviceID)
	if err != nil {
		return err
	}
	hr, _, _ := syscall.Syscall(
		v.vtable().SetDefaultEndpoint,
		3,
		uintptr(unsafe.Pointer(v)),
		uintptr(unsafe.Pointer(idPtr)),
		uintptr(role),
	)
	if hr != 0 {
		return ole.NewError(hr)
	}
	return nil
}

// ERole values, per Windows' mmdeviceapi.h.
const (
	eRoleConsole        int32 = 0
	eRoleMultimedia     int32 = 1
	eRoleCommunications int32 = 2
)

// setDefaultAudioDevice makes deviceID the default render endpoint for every
// role — matching what the Windows Sound settings page and most third-party
// switchers (including KDE Connect's) do, rather than leaving some roles
// pointed at the old device.
func setDefaultAudioDevice(deviceID string) error {
	ensureAudioComInit()
	unk, err := ole.CreateInstance(clsidPolicyConfig, iidPolicyConfig)
	if err != nil {
		return fmt.Errorf("IPolicyConfig is undocumented and can fail on some Windows builds: %w", err)
	}
	pc := (*policyConfig)(unsafe.Pointer(unk))
	defer pc.Release()

	for _, role := range []int32{eRoleConsole, eRoleMultimedia, eRoleCommunications} {
		if err := pc.setDefaultEndpoint(deviceID, role); err != nil {
			return err
		}
	}
	return nil
}

// ---- Per-application volume (public, documented API) ----

// AppVolume describes one active playback session — roughly, one running
// app currently making sound.
type AppVolume struct {
	ID     string // this process's id, as a string; stable enough for a single poll/control round-trip
	Name   string
	Volume int
	Muted  bool
}

func listAppVolumes() ([]AppVolume, error) {
	sessions, cleanup, err := openAudioSessions()
	if err != nil {
		return nil, err
	}
	defer cleanup()

	out := make([]AppVolume, 0, len(sessions))
	for _, s := range sessions {
		out = append(out, AppVolume{
			ID:     s.id,
			Name:   s.name,
			Volume: s.volumePercent(),
			Muted:  s.muted(),
		})
	}
	return out, nil
}

func setAppVolumePercent(id string, percent int) error {
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	sessions, cleanup, err := openAudioSessions()
	if err != nil {
		return err
	}
	defer cleanup()

	for _, s := range sessions {
		if s.id == id {
			return s.volume.SetMasterVolume(float32(percent)/100, nil)
		}
	}
	return fmt.Errorf("no active audio session for process %s", id)
}

func setAppMute(id string, muted bool) error {
	sessions, cleanup, err := openAudioSessions()
	if err != nil {
		return err
	}
	defer cleanup()

	for _, s := range sessions {
		if s.id == id {
			return s.volume.SetMute(muted, nil)
		}
	}
	return fmt.Errorf("no active audio session for process %s", id)
}

// audioSession bundles one running app's session control with the simple
// volume interface for the SAME session (obtained via QueryInterface on the
// identical underlying object, not a separate lookup), so a caller can read
// or set its volume without re-enumerating.
type audioSession struct {
	id     string
	name   string
	volume *wca.ISimpleAudioVolume
}

func (s audioSession) volumePercent() int {
	var level float32
	if err := s.volume.GetMasterVolume(&level); err != nil {
		return -1
	}
	percent := int(level*100 + 0.5)
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	return percent
}

func (s audioSession) muted() bool {
	var muted bool
	if err := s.volume.GetMute(&muted); err != nil {
		return false
	}
	return muted
}

// openAudioSessions enumerates every active playback session on the default
// render device and resolves each to a friendly process name. The returned
// cleanup function releases every underlying COM object; callers must call
// it once done with the sessions (and not use them afterward).
func openAudioSessions() ([]audioSession, func(), error) {
	ensureAudioComInit()
	var enumerator *wca.IMMDeviceEnumerator
	if err := wca.CoCreateInstance(wca.CLSID_MMDeviceEnumerator, 0, clsctxAll, wca.IID_IMMDeviceEnumerator, &enumerator); err != nil {
		return nil, func() {}, err
	}
	defer enumerator.Release()

	var device *wca.IMMDevice
	if err := enumerator.GetDefaultAudioEndpoint(edataFlowRenderWca, eroleMultimedia, &device); err != nil {
		return nil, func() {}, err
	}
	defer device.Release()

	var sessionManager *wca.IAudioSessionManager2
	if err := device.Activate(wca.IID_IAudioSessionManager2, clsctxAll, nil, &sessionManager); err != nil {
		return nil, func() {}, err
	}

	var sessionEnum *wca.IAudioSessionEnumerator
	if err := sessionManager.GetSessionEnumerator(&sessionEnum); err != nil {
		sessionManager.Release()
		return nil, func() {}, err
	}

	var count int
	if err := sessionEnum.GetCount(&count); err != nil {
		sessionEnum.Release()
		sessionManager.Release()
		return nil, func() {}, err
	}

	var released []*wca.ISimpleAudioVolume
	cleanup := func() {
		for _, v := range released {
			v.Release()
		}
		sessionEnum.Release()
		sessionManager.Release()
	}

	sessions := make([]audioSession, 0, count)
	for i := 0; i < count; i++ {
		var control *wca.IAudioSessionControl
		if err := sessionEnum.GetSession(i, &control); err != nil {
			continue
		}

		control2Unknown, err := control.QueryInterface(wca.IID_IAudioSessionControl2)
		control.Release()
		if err != nil {
			continue
		}
		control2 := (*wca.IAudioSessionControl2)(unsafe.Pointer(control2Unknown))

		// Skip the system sounds session (id 0/notifications) — there is no
		// single "app" to attach it to, and Windows' own volume mixer hides
		// it from the per-app list the same way.
		if control2.IsSystemSoundsSession() == nil {
			control2.Release()
			continue
		}

		var pid uint32
		control2.GetProcessId(&pid)
		control2.Release()
		if pid == 0 {
			continue
		}

		volUnknown, err := control2.QueryInterface(wca.IID_ISimpleAudioVolume)
		if err != nil {
			continue
		}
		vol := (*wca.ISimpleAudioVolume)(unsafe.Pointer(volUnknown))
		released = append(released, vol)

		sessions = append(sessions, audioSession{
			id:     fmt.Sprintf("%d", pid),
			name:   processName(pid),
			volume: vol,
		})
	}

	return sessions, cleanup, nil
}

// processName resolves a friendly-ish name for pid ("Spotify" rather than
// "C:\...\Spotify.exe") — the same fallback Windows' own volume mixer uses
// when an app hasn't registered a nicer display name with its audio session.
func processName(pid uint32) string {
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return fmt.Sprintf("Process %d", pid)
	}
	defer windows.CloseHandle(handle)

	buf := make([]uint16, windows.MAX_PATH)
	size := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(handle, 0, &buf[0], &size); err != nil {
		return fmt.Sprintf("Process %d", pid)
	}

	full := syscall.UTF16ToString(buf[:size])
	base := full
	for i := len(full) - 1; i >= 0; i-- {
		if full[i] == '\\' || full[i] == '/' {
			base = full[i+1:]
			break
		}
	}
	for i := len(base) - 1; i >= 0; i-- {
		if base[i] == '.' {
			return base[:i]
		}
	}
	return base
}
