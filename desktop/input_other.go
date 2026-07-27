//go:build !windows

package main

import "wedrop/core/protocol"

// applyRemoteInput is a no-op on platforms without an input backend yet.
// Remote control from a phone simply does nothing here rather than failing;
// a Linux/macOS implementation can inject via XTest / CGEvent later.
func applyRemoteInput(in protocol.RemoteInput) {}
