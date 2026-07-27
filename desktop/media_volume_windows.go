//go:build windows

package main

// Real system volume via WASAPI's IAudioEndpointVolume — classic, fully
// synchronous COM (no async completion callbacks, no WinRT parameterized
// GUIDs), so none of the risk that applies to the SMTC pieces in this
// package applies here. Every GUID and vtable slot below was cross-checked
// against the Windows SDK's own mmdeviceapi.h/endpointvolume.h headers and
// verified empirically against this machine's real audio endpoint (a
// round-trip get/set/get before this was wired into the app) before being
// added to the build.
import (
	"syscall"
	"unsafe"

	ole "github.com/go-ole/go-ole"
)

const (
	edataFlowRender = 0
	eroleMultimedia = 1
	clsctxAll       = 23 // CLSCTX_INPROC_SERVER|LOCAL_SERVER|REMOTE_SERVER|INPROC_HANDLER
)

var (
	clsidMMDeviceEnumerator = ole.NewGUID("BCDE0395-E52F-467C-8E3D-C4579291692E")
	iidMMDeviceEnumerator   = ole.NewGUID("A95664D2-9614-4F35-A746-DE8DB63617E6")
	iidAudioEndpointVolume  = ole.NewGUID("5CDF2C82-841E-4546-9722-0CF74078229A")
)

type immDeviceEnumerator struct{ ole.IUnknown }

type immDeviceEnumeratorVtbl struct {
	ole.IUnknownVtbl
	EnumAudioEndpoints                     uintptr
	GetDefaultAudioEndpoint                uintptr
	GetDevice                              uintptr
	RegisterEndpointNotificationCallback   uintptr
	UnregisterEndpointNotificationCallback uintptr
}

func (v *immDeviceEnumerator) vtable() *immDeviceEnumeratorVtbl {
	return (*immDeviceEnumeratorVtbl)(unsafe.Pointer(v.RawVTable))
}

type immDevice struct{ ole.IUnknown }

type immDeviceVtbl struct {
	ole.IUnknownVtbl
	Activate          uintptr
	OpenPropertyStore uintptr
	GetId             uintptr
	GetState          uintptr
}

func (v *immDevice) vtable() *immDeviceVtbl {
	return (*immDeviceVtbl)(unsafe.Pointer(v.RawVTable))
}

type audioEndpointVolume struct{ ole.IUnknown }

type audioEndpointVolumeVtbl struct {
	ole.IUnknownVtbl
	RegisterControlChangeNotify   uintptr
	UnregisterControlChangeNotify uintptr
	GetChannelCount               uintptr
	SetMasterVolumeLevel          uintptr
	SetMasterVolumeLevelScalar    uintptr
	GetMasterVolumeLevel          uintptr
	GetMasterVolumeLevelScalar    uintptr
	SetChannelVolumeLevel         uintptr
	SetChannelVolumeLevelScalar   uintptr
	GetChannelVolumeLevel         uintptr
	GetChannelVolumeLevelScalar   uintptr
	SetMute                       uintptr
	GetMute                       uintptr
}

func (v *audioEndpointVolume) vtable() *audioEndpointVolumeVtbl {
	return (*audioEndpointVolumeVtbl)(unsafe.Pointer(v.RawVTable))
}

func (v *audioEndpointVolume) getMasterVolumeLevelScalar() (float32, error) {
	var r float32
	hr, _, _ := syscall.Syscall(v.vtable().GetMasterVolumeLevelScalar, 2, uintptr(unsafe.Pointer(v)), uintptr(unsafe.Pointer(&r)), 0)
	if hr != 0 {
		return 0, ole.NewError(hr)
	}
	return r, nil
}

func (v *audioEndpointVolume) setMasterVolumeLevelScalar(level float32) error {
	hr, _, _ := syscall.Syscall(
		v.vtable().SetMasterVolumeLevelScalar,
		3,
		uintptr(unsafe.Pointer(v)),
		uintptr(*(*uint32)(unsafe.Pointer(&level))),
		0, // pguidEventContext = NULL
	)
	if hr != 0 {
		return ole.NewError(hr)
	}
	return nil
}

// openDefaultVolumeEndpoint activates IAudioEndpointVolume for the system's
// default playback device. Every call re-activates rather than caching,
// since the "default" device can change (headphones plugged in, etc.) between
// calls and this is cheap and infrequent (called only on user action or the
// health/now-playing poll).
func openDefaultVolumeEndpoint() (*audioEndpointVolume, error) {
	unk, err := ole.CreateInstance(clsidMMDeviceEnumerator, iidMMDeviceEnumerator)
	if err != nil {
		return nil, err
	}
	enumerator := (*immDeviceEnumerator)(unsafe.Pointer(unk))

	var devicePtr unsafe.Pointer
	hr, _, _ := syscall.Syscall6(
		enumerator.vtable().GetDefaultAudioEndpoint,
		4,
		uintptr(unsafe.Pointer(enumerator)),
		edataFlowRender,
		eroleMultimedia,
		uintptr(unsafe.Pointer(&devicePtr)),
		0, 0)
	if hr != 0 {
		return nil, ole.NewError(hr)
	}
	device := (*immDevice)(devicePtr)

	var volPtr unsafe.Pointer
	hr2, _, _ := syscall.Syscall6(
		device.vtable().Activate,
		5,
		uintptr(unsafe.Pointer(device)),
		uintptr(unsafe.Pointer(iidAudioEndpointVolume)),
		clsctxAll,
		0, // pActivationParams = NULL
		uintptr(unsafe.Pointer(&volPtr)),
		0)
	if hr2 != 0 {
		return nil, ole.NewError(hr2)
	}
	return (*audioEndpointVolume)(volPtr), nil
}

// getSystemVolumePercent reads the default playback device's current volume,
// 0-100, or -1 if it could not be read.
func getSystemVolumePercent() int {
	volume, err := openDefaultVolumeEndpoint()
	if err != nil {
		return -1
	}
	level, err := volume.getMasterVolumeLevelScalar()
	if err != nil {
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

// setSystemVolumePercent sets the default playback device's volume, 0-100.
func setSystemVolumePercent(percent int) error {
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	volume, err := openDefaultVolumeEndpoint()
	if err != nil {
		return err
	}
	return volume.setMasterVolumeLevelScalar(float32(percent) / 100)
}

// setVolumePlatform is the cross-platform entry point for an absolute
// volume-set request; see media_other.go for the non-Windows stub.
func setVolumePlatform(percent int) error {
	return setSystemVolumePercent(percent)
}
