import '../../core/plugin/plugin.dart';
import '../../core/protocol/messages.dart';

/// The adaptive-controls plugin: receives what the peer's currently focused
/// desktop app makes available, so the mobile UI can render it generically
/// with no per-app layout hardcoded here.
///
/// Broadcast-only in the other direction (this plugin never sends anything —
/// tapping a control just calls AppService.sendWorkspaceAction directly with
/// the control's own action, the same call "My Workspace" buttons already
/// make). Conceptual mirror of desktop/plugins/adaptivecontrols (Go).
class AdaptiveControlsPlugin implements WeDropPlugin {
  late PluginApi _api;

  /// Latest state reported by each peer, keyed by device id.
  final Map<String, AdaptiveControlsState> _peerState = {};

  @override
  PluginId get id => Capability.adaptiveControls;

  @override
  List<String> get messageTypes => [MsgType.adaptiveControls];

  @override
  void init(PluginApi api) {
    _api = api;
  }

  @override
  Future<void> handleMessage(PeerRef from, String msgType, Map<String, dynamic> raw) async {
    _peerState[from.deviceId] = AdaptiveControlsState.fromJson(raw);
    _api.emit('state_changed', null);
  }

  @override
  void onPeerConnected(PeerRef peer) {}

  /// Stops showing stale controls for a device that just dropped.
  @override
  void onPeerDisconnected(String deviceId) {
    if (_peerState.remove(deviceId) != null) {
      _api.emit('state_changed', null);
    }
  }

  @override
  Future<void> start() async {}

  @override
  void stop() {}

  /// What the peer's currently focused app makes available, or null if
  /// nothing has been reported yet.
  AdaptiveControlsState? stateOf(String deviceId) => _peerState[deviceId];
}
