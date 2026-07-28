//go:build !windows

package health

import (
	"wedrop/core/protocol"
)

// collectHealth on non-Windows reports what is portable without extra deps:
// network state always, and CPU/battery left unknown. A Linux/macOS build can
// fill these in later via /proc or IOKit; reporting -1 renders as "unknown"
// rather than a wrong number.
func collectHealth(deviceID string) protocol.DeviceHealth {
	health := protocol.DeviceHealth{
		Type:        protocol.TypeHealth,
		DeviceID:    deviceID,
		Battery:     -1,
		CPUPercent:  -1,
		MemPercent:  -1,
		NetworkType: "offline",
	}
	if t, name := netInterfaceSummary(); t != "" {
		health.NetworkType = t
		health.NetworkName = name
	}
	return health
}
