//go:build windows

package main

import (
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"

	"wedrop/core/protocol"
)

// This file gathers the desktop's own vitals for the remote's health panel,
// using Win32 syscalls directly so no cgo or third-party dependency is needed.

var (
	kernel32               = windows.NewLazySystemDLL("kernel32.dll")
	procGetSystemPowerStat = kernel32.NewProc("GetSystemPowerStatus")
	procGetSystemTimes     = kernel32.NewProc("GetSystemTimes")
	procGlobalMemoryStatus = kernel32.NewProc("GlobalMemoryStatusEx")
)

type systemPowerStatus struct {
	ACLineStatus        byte
	BatteryFlag         byte
	BatteryLifePercent  byte
	SystemStatusFlag    byte
	BatteryLifeTime     uint32
	BatteryFullLifeTime uint32
}

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

// cpuSampler keeps the previous kernel/idle counters so each reading is the
// load over the interval since the last call, which is what a meter should show
// rather than an average since boot.
type cpuSampler struct {
	lastIdle   uint64
	lastKernel uint64
	lastUser   uint64
	primed     bool
}

func fileTimeToUint64(ft syscall.Filetime) uint64 {
	return uint64(ft.HighDateTime)<<32 | uint64(ft.LowDateTime)
}

func (c *cpuSampler) sample() int {
	var idle, kernel, user syscall.Filetime
	ret, _, _ := procGetSystemTimes.Call(
		uintptr(unsafe.Pointer(&idle)),
		uintptr(unsafe.Pointer(&kernel)),
		uintptr(unsafe.Pointer(&user)),
	)
	if ret == 0 {
		return -1
	}

	idleT := fileTimeToUint64(idle)
	kernelT := fileTimeToUint64(kernel)
	userT := fileTimeToUint64(user)

	if !c.primed {
		c.lastIdle, c.lastKernel, c.lastUser = idleT, kernelT, userT
		c.primed = true
		return -1 // first call has no interval to compare against
	}

	// Kernel time already includes idle time on Windows, so total busy time is
	// (kernel - idle) + user over the interval.
	idleDelta := idleT - c.lastIdle
	kernelDelta := kernelT - c.lastKernel
	userDelta := userT - c.lastUser
	c.lastIdle, c.lastKernel, c.lastUser = idleT, kernelT, userT

	total := kernelDelta + userDelta
	if total == 0 {
		return 0
	}
	busy := total - idleDelta
	percent := int(busy * 100 / total)
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	return percent
}

var globalCPUSampler = &cpuSampler{}

// collectHealth reads battery, CPU, memory and network into a DeviceHealth.
func collectHealth(deviceID string) protocol.DeviceHealth {
	health := protocol.DeviceHealth{
		Type:        protocol.TypeHealth,
		DeviceID:    deviceID,
		Battery:     -1,
		CPUPercent:  globalCPUSampler.sample(),
		MemPercent:  -1,
		NetworkType: "offline",
	}

	var power systemPowerStatus
	if ret, _, _ := procGetSystemPowerStat.Call(uintptr(unsafe.Pointer(&power))); ret != 0 {
		// 255 means "unknown", which laptops report briefly and desktops report
		// always — surfaced as -1 rather than a bogus percentage.
		if power.BatteryLifePercent != 255 {
			health.Battery = int(power.BatteryLifePercent)
		}
		health.Charging = power.ACLineStatus == 1
	}

	var mem memoryStatusEx
	mem.Length = uint32(unsafe.Sizeof(mem))
	if ret, _, _ := procGlobalMemoryStatus.Call(uintptr(unsafe.Pointer(&mem))); ret != 0 {
		health.MemPercent = int(mem.MemoryLoad)
	}

	fillNetwork(&health)
	return health
}

// fillNetwork labels the active connection. Wi-Fi vs wired is inferred from the
// adapter name, which is enough for a status pill without the heavier IP Helper
// APIs. netInterfaceSummary is shared across platforms in health_net.go.
func fillNetwork(health *protocol.DeviceHealth) {
	if t, name := netInterfaceSummary(); t != "" {
		health.NetworkType = t
		health.NetworkName = name
	}
}

// healthInterval is how often vitals are refreshed and broadcast.
const healthInterval = 8 * time.Second
