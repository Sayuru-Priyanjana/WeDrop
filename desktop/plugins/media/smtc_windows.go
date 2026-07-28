//go:build windows

package media

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
	"golang.org/x/sys/windows"

	"wedrop/core/protocol"
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
// readSMTCSnapshotOf queries a specific, already-resolved session (e.g. a
// remote's selected player, via resolvePlayerSession, or "whatever is
// current" when none is selected). The caller owns session and must Release
// it — this function never does.
//
// Every WinRT/COM call below hands back an independently reference-counted
// object that must be released once we are done with it — a rule this file
// did not follow at first. Never releasing these leaked one COM reference
// per poll cycle (every 2 seconds, for the life of the process), which
// manifested as the whole app becoming progressively less responsive the
// longer it ran.
func readSMTCSnapshotOf(ctx context.Context, session *libnp.IGlobalSystemMediaTransportControlsSession) (*smtcSnapshot, error) {
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

	// Playing status is read first: the position correction below needs it.
	if info, err := getPlaybackInfo(session); err == nil {
		if status, err := info.PlaybackStatus(); err == nil {
			snapshot.Playing = status == playbackStatusPlaying
		}
		info.Release()
	}

	// Timeline and playback status are best-effort: some sources never
	// populate them, so a failure here should not discard the title/artist
	// we already have.
	if timeline, err := getTimelineProperties(session); err == nil {
		if pos, err := timeline.Position(); err == nil {
			// Windows only updates TimelineProperties.Position on player
			// events (track change, seek, pause) — not continuously — so
			// while playing, the raw value is already stale by however long
			// it's been since the last such event, before it even reaches
			// the wire. KDE Connect's own Windows mpriscontrol plugin
			// (getPlayerPosition in mpriscontrolplugin-win.cpp) corrects for
			// exactly this by adding elapsed time since LastUpdatedTime;
			// same fix here, instead of compounding it with the receiving
			// side's own interpolation against an already-stale base value.
			if snapshot.Playing {
				if lastUpdated, err := timeline.LastUpdatedTime(); err == nil {
					pos += currentDateTimeTicks() - lastUpdated
				}
			}
			snapshot.PositionMs = pos / 10000
		}
		if end, err := timeline.EndTime(); err == nil {
			snapshot.DurationMs = end / 10000
		}
		timeline.Release()
	}

	// The correction above can occasionally overshoot past the end of the
	// track (e.g. right as it finishes, before the next TimelinePropertiesChanged
	// event lands) — clamp rather than show a position past the known duration.
	if snapshot.DurationMs > 0 && snapshot.PositionMs > snapshot.DurationMs {
		snapshot.PositionMs = snapshot.DurationMs
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

// getSessionManager activates and returns the SMTC session manager — the
// entry point for both "whatever Windows calls current" (getCurrentSMTCSession)
// and "every active session" (listPlayers/findSessionByPlayerID).
func getSessionManager(ctx context.Context) (*libnp.IGlobalSystemMediaTransportControlsSessionManager, error) {
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

	return waitBounded(ctx, func() (*libnp.IGlobalSystemMediaTransportControlsSessionManager, error) {
		return managerAsync.WaitResult("10F0074E-923D-5510-8F4A-DDE37754CA0E")
	})
}

// getCurrentSMTCSession returns whatever Windows currently considers the
// "current" session, or (nil, nil) if nothing is loaded anywhere.
func getCurrentSMTCSession(ctx context.Context) (*libnp.IGlobalSystemMediaTransportControlsSession, error) {
	manager, err := getSessionManager(ctx)
	if err != nil {
		return nil, err
	}
	defer manager.Release()

	// GetCurrentSession hands back an independently reference-counted pointer
	// the caller owns and must Release when done; releasing manager above
	// does not affect it.
	return manager.GetCurrentSession()
}

// getSourceAppUserModelId reads a session's owning app identity — the same
// field KDE Connect's updatePlayerList keys its player list by. This slot
// sits before the missing TryPlayAsync slot in go-libnp's own session vtable
// (see sessionVtblFixed's comment), so unlike the Try*Async controls it is
// not affected by that bug and go-libnp's own vtable position is safe to use
// directly.
func getSourceAppUserModelId(session *libnp.IGlobalSystemMediaTransportControlsSession) (string, error) {
	var h ole.HString
	hr, _, _ := syscall.Syscall(
		session.VTable().GetSourceAppUserModelId,
		2,
		uintptr(unsafe.Pointer(session)),
		uintptr(unsafe.Pointer(&h)),
		0)
	if hr != 0 {
		return "", ole.NewError(hr)
	}
	return h.String(), nil
}

// PlayerInfo describes one active SMTC session, for a remote to list and
// choose which one it wants to control — mirroring KDE Connect's own
// mpriscontrol player list (playerList/updatePlayerList in
// mpriscontrolplugin-win.cpp), rather than always guessing at whichever
// session Windows itself currently considers "current".
type PlayerInfo struct {
	ID      string // SourceAppUserModelId; see findSessionByPlayerID for its limits
	Title   string
	Artist  string
	Playing bool
}

// listPlayers returns every session Windows' SMTC manager currently knows
// about, not just the "current" one.
func listPlayers() ([]PlayerInfo, error) {
	ctx, cancel := context.WithTimeout(context.Background(), nowPlayingTimeout)
	defer cancel()

	manager, err := getSessionManager(ctx)
	if err != nil {
		return nil, err
	}
	defer manager.Release()

	sessions, err := getSessionsVector(manager)
	if err != nil {
		return nil, err
	}
	defer sessions.Release()

	count, err := sessions.GetSize()
	if err != nil {
		return nil, err
	}

	players := make([]PlayerInfo, 0, count)
	for i := uint32(0); i < count; i++ {
		ptr, err := sessions.GetAt(i)
		if err != nil || ptr == nil {
			continue
		}
		session := (*libnp.IGlobalSystemMediaTransportControlsSession)(ptr)

		info := PlayerInfo{}
		info.ID, _ = getSourceAppUserModelId(session)
		if info.ID == "" {
			session.Release()
			continue
		}

		if props, err := session.TryGetMediaPropertiesAsync(); err == nil {
			if mp, err := waitBounded(ctx, func() (*libnp.IGlobalSystemMediaTransportControlsSessionMediaProperties, error) {
				return props.WaitResult("84593A3D-951A-55B6-8353-5205E577797B")
			}); err == nil {
				info.Title, _ = mp.GetTitle()
				info.Artist, _ = mp.GetArtist()
				mp.Release()
			}
			props.Release()
		}
		if info2, err := getPlaybackInfo(session); err == nil {
			if status, err := info2.PlaybackStatus(); err == nil {
				info.Playing = status == playbackStatusPlaying
			}
			info2.Release()
		}

		players = append(players, info)
		session.Release()
	}

	return players, nil
}

// findSessionByPlayerID returns the first session whose SourceAppUserModelId
// matches id, or (nil, nil) if none matches (the player may have quit).
// AppUserModelId is not guaranteed unique — two windows of the same app
// (e.g. two browser tabs) share one — so with more than one match this
// picks whichever GetSessions() happens to list first; acceptable for a
// single-selection remote control, same tradeoff KDE Connect's own
// dedup-by-suffix display naming implicitly accepts for the same reason.
func findSessionByPlayerID(ctx context.Context, id string) (*libnp.IGlobalSystemMediaTransportControlsSession, error) {
	manager, err := getSessionManager(ctx)
	if err != nil {
		return nil, err
	}
	defer manager.Release()

	sessions, err := getSessionsVector(manager)
	if err != nil {
		return nil, err
	}
	defer sessions.Release()

	count, err := sessions.GetSize()
	if err != nil {
		return nil, err
	}

	for i := uint32(0); i < count; i++ {
		ptr, err := sessions.GetAt(i)
		if err != nil || ptr == nil {
			continue
		}
		session := (*libnp.IGlobalSystemMediaTransportControlsSession)(ptr)

		sessionID, _ := getSourceAppUserModelId(session)
		if sessionID == id {
			return session, nil
		}
		session.Release()
	}

	return nil, nil
}

// getSessionsVector wraps GetSessions — correctly positioned in go-libnp's
// own manager vtable (cross-checked against microsoft/windows-rs; unlike the
// per-session Try*Async controls, this interface has no missing slot).
func getSessionsVector(manager *libnp.IGlobalSystemMediaTransportControlsSessionManager) (*libnp.IVectorView, error) {
	var r *libnp.IVectorView
	hr, _, _ := syscall.Syscall(
		manager.VTable().GetSessions,
		2,
		uintptr(unsafe.Pointer(manager)),
		uintptr(unsafe.Pointer(&r)),
		0)
	if hr != 0 {
		return nil, ole.NewError(hr)
	}
	return r, nil
}

// ---- Seek, via IAsyncInfo status polling (see the file comment for why) ----

// sessionVtblFixed is IGlobalSystemMediaTransportControlsSession's vtable,
// corrected. go-libnp's own IGlobalSystemMediaTransportControlsSessionVtbl
// (libnp_windows.go) omits the TryPlayAsync slot that the real interface has
// between GetPlaybackInfo and TryPauseAsync — confirmed against
// microsoft/windows-rs's mechanically-generated bindings, not guessed. That
// missing slot shifts every method after it by one, so go-libnp's own
// "TryChangePlaybackPositionAsync" field is actually bound to the real
// TryChangeShuffleActiveAsync: calling it "succeeds" (the async op completes
// and reports true) while never moving playback position, since it is really
// toggling shuffle. Confirmed by direct testing: a live seek call reported
// success with the position unchanged. This struct exists solely to reach
// the correctly-offset slot for the one call this file needs; every other
// call in this file (GetTimelineProperties, GetPlaybackInfo,
// TryGetMediaPropertiesAsync) sits before the missing slot and is unaffected.
type sessionVtblFixed struct {
	ole.IInspectableVtbl
	GetSourceAppUserModelId        uintptr
	TryGetMediaPropertiesAsync     uintptr
	GetTimelineProperties          uintptr
	GetPlaybackInfo                uintptr
	TryPlayAsync                   uintptr
	TryPauseAsync                  uintptr
	TryStopAsync                   uintptr
	TryRecordAsync                 uintptr
	TryFastForwardAsync            uintptr
	TryRewindAsync                 uintptr
	TrySkipNextAsync               uintptr
	TrySkipPreviousAsync           uintptr
	TryChangeChannelUpAsync        uintptr
	TryChangeChannelDownAsync      uintptr
	TryTogglePlayPauseAsync        uintptr
	TryChangeAutoRepeatModeAsync   uintptr
	TryChangePlaybackRateAsync     uintptr
	TryChangeShuffleActiveAsync    uintptr
	TryChangePlaybackPositionAsync uintptr
}

func sessionVtable(session *libnp.IGlobalSystemMediaTransportControlsSession) *sessionVtblFixed {
	return (*sessionVtblFixed)(unsafe.Pointer(session.RawVTable))
}

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
		sessionVtable(session).TryChangePlaybackPositionAsync,
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

// tryNoArgTransport calls one of the session's no-argument Try*Async
// transport controls (play/pause/toggle/next/previous), all IAsyncOperation<bool>
// like TryChangePlaybackPositionAsync, so the same IAsyncInfo-polling wait
// applies unchanged.
func tryNoArgTransport(session *libnp.IGlobalSystemMediaTransportControlsSession, method uintptr) (bool, error) {
	var opPtr unsafe.Pointer
	hr, _, _ := syscall.Syscall(
		method,
		2,
		uintptr(unsafe.Pointer(session)),
		uintptr(unsafe.Pointer(&opPtr)),
		0,
	)
	if hr != 0 {
		return false, ole.NewError(hr)
	}
	return waitAsyncOpByPolling((*asyncOpHandle)(opPtr), 5*time.Second)
}

// resolvePlayerSession finds the session a player-scoped command should act
// on: the specific one named by playerID, or whatever Windows calls
// "current" when playerID is empty (no player selected). Caller must
// Release the returned session.
func resolvePlayerSession(ctx context.Context, playerID string) (*libnp.IGlobalSystemMediaTransportControlsSession, error) {
	if playerID == "" {
		return getCurrentSMTCSession(ctx)
	}
	return findSessionByPlayerID(ctx, playerID)
}

// applyCommandToPlayer routes a play/pause/next/prev/stop command to a
// specific session's own transport controls — precise per-player control,
// unlike applyMediaCommand's simulated media keys, which only ever reach
// whichever session Windows itself currently treats as foreground. Used once
// a remote has picked a specific player from listPlayers() rather than
// leaving control to "whatever's current".
func applyCommandToPlayer(playerID, command string) error {
	ctx, cancel := context.WithTimeout(context.Background(), nowPlayingTimeout)
	defer cancel()

	session, err := resolvePlayerSession(ctx, playerID)
	if err != nil {
		return err
	}
	if session == nil {
		return errors.New("that player is no longer available")
	}
	defer session.Release()

	vt := sessionVtable(session)
	var method uintptr
	switch command {
	case protocol.MediaPlayPause:
		method = vt.TryTogglePlayPauseAsync
	case protocol.MediaNext:
		method = vt.TrySkipNextAsync
	case protocol.MediaPrev:
		method = vt.TrySkipPreviousAsync
	case protocol.MediaStop:
		method = vt.TryStopAsync
	default:
		return fmt.Errorf("unsupported per-player command %q", command)
	}

	ok, err := tryNoArgTransport(session, method)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("that player declined the command")
	}
	return nil
}

// seekPlayer seeks a specific player (or the current one, if playerID is
// empty) — the player-aware counterpart to seekCurrentSession.
func seekPlayer(playerID string, positionMs int64) error {
	ctx, cancel := context.WithTimeout(context.Background(), nowPlayingTimeout)
	defer cancel()

	session, err := resolvePlayerSession(ctx, playerID)
	if err != nil {
		return err
	}
	if session == nil {
		return errors.New("that player is no longer available")
	}
	defer session.Release()

	ok, err := trySeek(session, positionMs)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("that player declined the seek")
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

// LastUpdatedTime is a Windows.Foundation.DateTime (100ns ticks since
// 1601-01-01, the same epoch and unit FILETIME uses) — when Windows last
// updated Position, not "now". See currentDateTimeTicks and its call site in
// readSMTCSnapshot for why this matters.
func (v *timelineProperties) LastUpdatedTime() (int64, error) {
	return getTimeSpan(unsafe.Pointer(v), v.vtable().LastUpdatedTime)
}

// currentDateTimeTicks returns "now" in the same representation WinRT's
// DateTime uses (100ns ticks since 1601-01-01), via the plain Win32
// GetSystemTimeAsFileTime call — FILETIME shares that exact epoch and unit,
// so no conversion beyond combining the two 32-bit halves is needed.
func currentDateTimeTicks() int64 {
	var ft windows.Filetime
	windows.GetSystemTimeAsFileTime(&ft)
	return int64(uint64(ft.HighDateTime)<<32 | uint64(ft.LowDateTime))
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
