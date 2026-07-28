//go:build !windows

package minimizedapps

import "wedrop/core/protocol"

// currentMinimizedWindows is not implemented on this platform yet — an
// honest empty list rather than a guess.
func currentMinimizedWindows() []protocol.MinimizedWindow { return nil }
