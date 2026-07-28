//go:build windows

package main

// This file reaches two System Media Transport Controls (SMTC) interfaces
// that github.com/delthas/go-libnp exposes the activation/vtable machinery
// for but does not itself wrap: TimelineProperties (real playback position
// and track duration) and PlaybackInfo (real playing/paused status).
//
// Nothing here is guessed. The vtable slot order for both new interfaces was
// cross-checked against microsoft/windows-rs's metadata-generated bindings
// (which are produced mechanically from the same WinMD Microsoft ships, not
// hand-written), and every activation/async-completion call reuses
// go-libnp's own exported types and GUIDs verbatim — the same plumbing that
// already retrieves this device's title/artist correctly. Both new getters
// added here (Position, EndTime, PlaybackStatus) are synchronous property
// reads, the same low-risk "syscall one vtable slot, read one out-value"
// shape go-libnp's own GetTitle/GetTrackNumber already use — there is no new
// async completion handshake, and so no new GUID that could be wrong.
//
// Seek (TryChangePlaybackPositionAsync) is also implemented, but not via a
// registered completion callback: that would need the WinRT-computed IID for
// the parameterized IAsyncOperationCompletedHandler<Boolean>, which could not
// be independently verified, and a wrong async-completion IID hangs forever
// rather than failing cleanly. Instead this polls the operation's Status
// through IAsyncInfo — a fixed, non-parameterized, publicly documented
// interface every WinRT async operation implements (IID
// 00000036-0000-0000-C000-000000000046, confirmed against the Windows SDK's
// own asyncinfo.h) — obtained via plain COM QueryInterface, which needs no
// generic-instantiation GUID at all. Verified empirically against a live
// session before shipping: a real TryChangePlaybackPositionAsync call
// completed and reported success entirely through this polling path.
import (
	"context"
	"errors"
	"fmt"
	"sync"
	"syscall"
	"time"
	"unsafe"

	libnp "github.com/delthas/go-libnp"
	ole "github.com/go-ole/go-ole"
)

// PlaybackStatus values, per Microsoft's documented enum.
const (
	playbackStatusPlaying int32 = 4
)

var (
	smtcInitOnce sync.Once
	smtcInitErr  error
)

func ensureSMTCInit() error {
	smtcInitOnce.Do(func() {
		smtcInitErr = ole.CoInitializeEx(0, ole.COINIT_MULTITHREADED)
	})
	return smtcInitErr
}

// smtcSnapshot is everything this device can honestly report about what is
// currently loaded in the system's media session.
type smtcSnapshot struct {
	Title      string
	Artist     string
	Playing    bool
	PositionMs int64 // -1 when unknown
	DurationMs int64 // -1 when unknown
}

// readSMTCSnapshot performs one full session query: title/artist (via
// go-libnp's own verified TryGetMediaPropertiesAsync) plus real position,
// duration and playing state (via this file's additions). The two async
// waits (for the manager and for the media properties) are each bounded by
// ctx, since — rarely, in testing — the completion callback for the very
// first of these can take unusually long to arrive; a bounded wait turns
// that into "try again next cycle" instead of blocking the broadcaster.
func readSMTCSnapshot(ctx context.Context) (*smtcSnapshot, error) {
	session, err := getCurrentSMTCSession(ctx)
	if err != nil || session == nil {
		return nil, err
	}
	// Every WinRT/COM call below hands back an independently reference-counted
	// object that must be released once we are done with it — a rule this file
	// did not follow at first. Never releasing these leaked one COM reference
	// per poll cycle (every 2 seconds, for the life of the process), which
	// manifested as the whole app becoming progressively less responsive the
	// longer it ran.
	defer session.Release()

	propsAsync, err := session.TryGetMediaPropertiesAsync()
	if err != nil {
		return nil, err
	}
	defer propsAsync.Release()

	props, err := waitBounded(ctx, func() (*libnp.IGlobalSystemMediaTransportControlsSessionMediaProperties, error) {
		return propsAsync.WaitResult("84593A3D-951A-55B6-8353-5205E577797B")
	})
	if err != nil {
		return nil, err
	}
	defer props.Release()

	title, err := props.GetTitle()
	if err != nil {
		return nil, err
	}
	artist, err := props.GetArtist()
	if err != nil {
		return nil, err
	}

	snapshot := &smtcSnapshot{Title: title, Artist: artist, PositionMs: -1, DurationMs: -1}

	// Timeline and playback status are best-effort: some sources never
	// populate them, so a failure here should not discard the title/artist
	// we already have.
	if timeline, err := getTimelineProperties(session); err == nil {
		if pos, err := timeline.Position(); err == nil {
			snapshot.PositionMs = pos / 10000
		}
		if end, err := timeline.EndTime(); err == nil {
			snapshot.DurationMs = end / 10000
		}
		timeline.Release()
	}
	if info, err := getPlaybackInfo(session); err == nil {
		if status, err := info.PlaybackStatus(); err == nil {
			snapshot.Playing = status == playbackStatusPlaying
		}
		info.Release()
	}

	return snapshot, nil
}

// waitBounded races a blocking WaitResult-style call against ctx, so a rare
// stalled completion callback yields "try again next cycle" instead of
// blocking the caller indefinitely.
func waitBounded[T any](ctx context.Context, fn func() (*T, error)) (*T, error) {
	type result struct {
		v   *T
		err error
	}
	ch := make(chan result, 1)
	go func() {
		v, err := fn()
		ch <- result{v, err}
	}()

	select {
	case r := <-ch:
		return r.v, r.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// getCurrentSMTCSession activates the session manager and returns whatever
// Windows currently considers the "current" session, or (nil, nil) if
// nothing is loaded anywhere.
func getCurrentSMTCSession(ctx context.Context) (*libnp.IGlobalSystemMediaTransportControlsSession, error) {
	if err := ensureSMTCInit(); err != nil {
		return nil, err
	}

	ins, err := ole.RoGetActivationFactory(
		"Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager",
		ole.NewGUID("2050C4EE-11A0-57DE-AED7-C97C70338245"),
	)
	if err != nil {
		return nil, err
	}
	managerStatics := (*libnp.IGlobalSystemMediaTransportControlsSessionManagerStatics)(unsafe.Pointer(ins))
	defer managerStatics.Release()

	managerAsync, err := managerStatics.RequestAsync()
	if err != nil {
		return nil, err
	}
	defer managerAsync.Release()

	manager, err := waitBounded(ctx, func() (*libnp.IGlobalSystemMediaTransportControlsSessionManager, error) {
		return managerAsync.WaitResult("10F0074E-923D-5510-8F4A-DDE37754CA0E")
	})
	if err != nil {
		return nil, err
	}
	defer manager.Release()

	// GetCurrentSession hands back an independently reference-counted pointer
	// the caller owns and must Release when done; releasing manager/managerAsync
	// above does not affect it.
	return manager.GetCurrentSession()
}

// ---- Seek, via IAsyncInfo status polling (see the file comment for why) ----

var iidAsyncInfo = ole.NewGUID("00000036-0000-0000-C000-000000000046")

// asyncOpHandle is a minimal, TResult-agnostic view of any WinRT async
// operation: enough to QueryInterface for IAsyncInfo and to read a boolean
// result off the operation's own GetResults slot.
type asyncOpHandle struct {
	ole.IInspectable
}

type asyncOpHandleVtbl struct {
	ole.IInspectableVtbl
	PutCompleted uintptr
	GetCompleted uintptr
	GetResults   uintptr
}

func (v *asyncOpHandle) vtable() *asyncOpHandleVtbl {
	return (*asyncOpHandleVtbl)(unsafe.Pointer(v.RawVTable))
}

func (v *asyncOpHandle) getResultBool() (bool, error) {
	var r int32
	hr, _, _ := syscall.Syscall(v.vtable().GetResults, 2, uintptr(unsafe.Pointer(v)), uintptr(unsafe.Pointer(&r)), 0)
	if hr != 0 {
		return false, ole.NewError(hr)
	}
	return r != 0, nil
}

type winrtAsyncInfo struct {
	ole.IInspectable
}

type winrtAsyncInfoVtbl struct {
	ole.IInspectableVtbl
	GetId        uintptr
	GetStatus    uintptr
	GetErrorCode uintptr
	Cancel       uintptr
	Close        uintptr
}

func (v *winrtAsyncInfo) vtable() *winrtAsyncInfoVtbl {
	return (*winrtAsyncInfoVtbl)(unsafe.Pointer(v.RawVTable))
}

func (v *winrtAsyncInfo) status() (int32, error) {
	var r int32
	hr, _, _ := syscall.Syscall(v.vtable().GetStatus, 2, uintptr(unsafe.Pointer(v)), uintptr(unsafe.Pointer(&r)), 0)
	if hr != 0 {
		return 0, ole.NewError(hr)
	}
	return r, nil
}

// AsyncStatus values, per Windows.Foundation.AsyncStatus: 0 Started,
// 1 Completed, 2 Canceled, 3 Error.
const (
	asyncStatusStarted   = 0
	asyncStatusCompleted = 1
)

// waitAsyncOpByPolling waits for a WinRT async operation to leave the
// Started state by polling IAsyncInfo.Status, then reports whether it
// completed successfully.
func waitAsyncOpByPolling(op *asyncOpHandle, timeout time.Duration) (bool, error) {
	defer op.Release()

	var info *winrtAsyncInfo
	if err := op.PutQueryInterface(iidAsyncInfo, &info); err != nil {
		return false, err
	}
	defer info.Release()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		status, err := info.status()
		if err != nil {
			return false, err
		}
		if status != asyncStatusStarted {
			if status != asyncStatusCompleted {
				return false, fmt.Errorf("seek did not complete (status=%d)", status)
			}
			return op.getResultBool()
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false, errors.New("timed out waiting for seek to complete")
}

// trySeek jumps the given session to an absolute position, in milliseconds.
func trySeek(session *libnp.IGlobalSystemMediaTransportControlsSession, positionMs int64) (bool, error) {
	var opPtr unsafe.Pointer
	hr, _, _ := syscall.Syscall(
		session.VTable().TryChangePlaybackPositionAsync,
		3,
		uintptr(unsafe.Pointer(session)),
		uintptr(positionMs*10000), // milliseconds -> 100ns units
		uintptr(unsafe.Pointer(&opPtr)),
	)
	if hr != 0 {
		return false, ole.NewError(hr)
	}
	return waitAsyncOpByPolling((*asyncOpHandle)(opPtr), 5*time.Second)
}

// trySeekPlatform is the cross-platform entry point applyMediaCommand's
// caller uses for a seek request; see media_other.go for the non-Windows stub.
func trySeekPlatform(positionMs int64) error {
	return seekCurrentSession(positionMs)
}

// seekCurrentSession finds whatever session Windows currently considers
// active and seeks it. Used for a remote's seek command, which only ever
// targets "the" session the remote is already looking at.
func seekCurrentSession(positionMs int64) error {
	ctx, cancel := context.WithTimeout(context.Background(), nowPlayingTimeout)
	defer cancel()

	session, err := getCurrentSMTCSession(ctx)
	if err != nil {
		return err
	}
	if session == nil {
		return errors.New("nothing is currently playing")
	}
	defer session.Release()

	ok, err := trySeek(session, positionMs)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("the current player declined the seek")
	}
	return nil
}

// ---- TimelineProperties (position / duration) ----

type timelineProperties struct {
	ole.IInspectable
}

type timelinePropertiesVtbl struct {
	ole.IInspectableVtbl
	StartTime       uintptr
	EndTime         uintptr
	MinSeekTime     uintptr
	MaxSeekTime     uintptr
	Position        uintptr
	LastUpdatedTime uintptr
}

func (v *timelineProperties) vtable() *timelinePropertiesVtbl {
	return (*timelinePropertiesVtbl)(unsafe.Pointer(v.RawVTable))
}

func getTimeSpan(self unsafe.Pointer, method uintptr) (int64, error) {
	var r int64
	hr, _, _ := syscall.Syscall(method, 2, uintptr(self), uintptr(unsafe.Pointer(&r)), 0)
	if hr != 0 {
		return 0, ole.NewError(hr)
	}
	return r, nil
}

func (v *timelineProperties) Position() (int64, error) {
	return getTimeSpan(unsafe.Pointer(v), v.vtable().Position)
}

func (v *timelineProperties) EndTime() (int64, error) {
	return getTimeSpan(unsafe.Pointer(v), v.vtable().EndTime)
}

// ---- PlaybackInfo (playing / paused) ----

type playbackInfo struct {
	ole.IInspectable
}

type playbackInfoVtbl struct {
	ole.IInspectableVtbl
	Controls        uintptr
	PlaybackStatus  uintptr
	PlaybackType    uintptr
	AutoRepeatMode  uintptr
	PlaybackRate    uintptr
	IsShuffleActive uintptr
}

func (v *playbackInfo) vtable() *playbackInfoVtbl {
	return (*playbackInfoVtbl)(unsafe.Pointer(v.RawVTable))
}

func (v *playbackInfo) PlaybackStatus() (int32, error) {
	var r int32
	hr, _, _ := syscall.Syscall(v.vtable().PlaybackStatus, 2, uintptr(unsafe.Pointer(v)), uintptr(unsafe.Pointer(&r)), 0)
	if hr != 0 {
		return 0, ole.NewError(hr)
	}
	return r, nil
}

func getObjectResult(self unsafe.Pointer, method uintptr) (unsafe.Pointer, error) {
	var r unsafe.Pointer
	hr, _, _ := syscall.Syscall(method, 2, uintptr(self), uintptr(unsafe.Pointer(&r)), 0)
	if hr != 0 {
		return nil, ole.NewError(hr)
	}
	return r, nil
}

func getTimelineProperties(session *libnp.IGlobalSystemMediaTransportControlsSession) (*timelineProperties, error) {
	p, err := getObjectResult(unsafe.Pointer(session), session.VTable().GetTimelineProperties)
	if err != nil {
		return nil, err
	}
	return (*timelineProperties)(p), nil
}

func getPlaybackInfo(session *libnp.IGlobalSystemMediaTransportControlsSession) (*playbackInfo, error) {
	p, err := getObjectResult(unsafe.Pointer(session), session.VTable().GetPlaybackInfo)
	if err != nil {
		return nil, err
	}
	return (*playbackInfo)(p), nil
}
