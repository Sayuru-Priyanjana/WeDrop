package health

import (
	"net"
	"strings"
)

// netInterfaceSummary returns a coarse network type ("wifi"/"ethernet"/
// "offline") and a human label for the first active, non-loopback IPv4
// interface. It is deliberately heuristic: distinguishing Wi-Fi from wired
// portably means matching adapter names, which is imperfect but adequate for a
// status pill and needs no platform-specific API.
func netInterfaceSummary() (string, string) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return "offline", ""
	}

	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		hasIPv4 := false
		for _, a := range addrs {
			if ipNet, ok := a.(*net.IPNet); ok && ipNet.IP.To4() != nil && !ipNet.IP.IsLinkLocalUnicast() {
				hasIPv4 = true
				break
			}
		}
		if !hasIPv4 {
			continue
		}

		name := strings.ToLower(iface.Name)
		switch {
		case strings.Contains(name, "wi-fi") || strings.Contains(name, "wifi") ||
			strings.Contains(name, "wlan") || strings.HasPrefix(name, "wl"):
			return "wifi", iface.Name
		case strings.Contains(name, "ethernet") || strings.HasPrefix(name, "eth") ||
			strings.HasPrefix(name, "en"):
			return "ethernet", iface.Name
		default:
			return "wifi", iface.Name // assume Wi-Fi on a laptop when unsure
		}
	}
	return "offline", ""
}
