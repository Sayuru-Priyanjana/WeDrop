import 'dart:async';

import '../../core/platform/native_bridge.dart';
import '../../core/plugin/plugin.dart';
import '../../core/protocol/messages.dart';

/// The device-health plugin: periodically broadcasts this device's
/// battery/CPU/memory/network vitals and remembers the last reading each
/// peer sent, so the UI can render a status panel per device.
///
/// Conceptual mirror of desktop/plugins/health (Go) — see the plugin
/// architecture refactor plan.
class HealthPlugin implements WeDropPlugin {
  /// This device's own identifier, used as DeviceHealth.deviceId when
  /// broadcasting.
  final String deviceId;

  late PluginApi _api;
  Timer? _timer;
  final Map<String, DeviceHealth> _peers = {};

  HealthPlugin(this.deviceId);

  @override
  PluginId get id => Capability.health;

  @override
  List<String> get messageTypes => [MsgType.health];

  @override
  void init(PluginApi api) {
    _api = api;
  }

  @override
  Future<void> handleMessage(PeerRef from, String msgType, Map<String, dynamic> raw) async {
    _peers[from.deviceId] = DeviceHealth.fromJson(raw);
    _api.emit('changed', null);
  }

  @override
  void onPeerConnected(PeerRef peer) {}

  /// Drops a peer's last-known reading — the UI only ever reads it while a
  /// device shows connected, so this is housekeeping rather than a visible
  /// behaviour change.
  @override
  void onPeerDisconnected(String deviceId) {
    _peers.remove(deviceId);
  }

  @override
  Future<void> start() async {
    // An initial reading shortly after connecting, then on a steady
    // interval, so a remote's panel populates quickly and stays fresh.
    Timer(const Duration(seconds: 2), _broadcast);
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _broadcast());
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _broadcast() async {
    if (_api.connectedPeers().isEmpty) return;

    final raw = await NativeBridge.deviceHealth();
    final health = DeviceHealth(
      deviceId: deviceId,
      battery: raw['battery'] as int? ?? -1,
      charging: raw['charging'] as bool? ?? false,
      cpuPercent: raw['cpu_percent'] as int? ?? -1,
      memPercent: raw['mem_percent'] as int? ?? -1,
      networkType: raw['network_type'] as String? ?? 'offline',
      networkName: raw['network_name'] as String? ?? '',
    );
    _api.broadcast(health.toJson());
  }

  /// The latest health reported by a peer, or null if none yet.
  DeviceHealth? healthOf(String deviceId) => _peers[deviceId];
}
