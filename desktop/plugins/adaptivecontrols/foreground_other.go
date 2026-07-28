//go:build !windows

package adaptivecontrols

// currentForegroundProcess is not implemented on this platform yet; an
// honest "" (never resolves to a known profile) rather than a guess.
func currentForegroundProcess() string { return "" }
