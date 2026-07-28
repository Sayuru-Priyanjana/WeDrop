import '../../core/plugin/plugin.dart';
import '../../core/protocol/messages.dart';

/// The minimized-apps plugin: receives the peer's currently-minimized
/// top-level windows, so the mobile UI can render them generically and
/// restore one with a tap.
///
/// Broadcast-only in the other direction (this plugin never sends anything —
/// tapping a window just calls AppService.restoreWindow, which sends a
/// WorkspaceAction the same way "My Workspace" buttons already do).
/// Conceptual mirror of desktop/plugins/minimizedapps (Go) and, on the mobile
/// side, of AdaptiveControlsPlugin.
class MinimizedAppsPlugin implements WeDropPlugin {
  late PluginApi _api;

  /// Latest state reported by each peer, keyed by device id.
  final Map<String, MinimizedAppsState> _peerState = {};

  @override
  PluginId get id => Capability.minimizedApps;

  @override
  List<String> get messageTypes => [MsgType.minimizedApps];

  @override
  void init(PluginApi api) {
    _api = api;
  }

  @override
  Future<void> handleMessage(PeerRef from, String msgType, Map<String, dynamic> raw) async {
    _peerState[from.deviceId] = MinimizedAppsState.fromJson(raw);
    _api.emit('state_changed', null);
  }

  @override
  void onPeerConnected(PeerRef peer) {}

  /// Stops showing stale windows for a device that just dropped.
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

  /// The peer's currently-minimized windows, or null if nothing has been
  /// reported yet.
  MinimizedAppsState? stateOf(String deviceId) => _peerState[deviceId];
}
