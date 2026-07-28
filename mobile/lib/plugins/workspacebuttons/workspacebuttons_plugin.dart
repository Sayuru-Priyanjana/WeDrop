import '../../core/plugin/plugin.dart';
import '../../core/protocol/messages.dart';

/// The "My Workspace" buttons plugin: receives this device's own button
/// list, authored entirely on the desktop. Broadcast-only in the other
/// direction (this plugin never sends anything — tapping a button calls
/// AppService.sendWorkspaceAction directly with the button's own action, the
/// same call every other workspace action already makes). Conceptual mirror
/// of AdaptiveControlsPlugin/MinimizedAppsPlugin.
class WorkspaceButtonsPlugin implements WeDropPlugin {
  late PluginApi _api;

  /// Latest state reported by each peer, keyed by device id.
  final Map<String, WorkspaceButtonsState> _peerState = {};

  @override
  PluginId get id => Capability.workspace;

  @override
  List<String> get messageTypes => [MsgType.workspaceButtons];

  @override
  void init(PluginApi api) {
    _api = api;
  }

  @override
  Future<void> handleMessage(PeerRef from, String msgType, Map<String, dynamic> raw) async {
    _peerState[from.deviceId] = WorkspaceButtonsState.fromJson(raw);
    _api.emit('state_changed', null);
  }

  @override
  void onPeerConnected(PeerRef peer) {}

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

  /// This device's own buttons, or an empty list if none have been
  /// configured yet (or nothing has been reported).
  List<WorkspaceButtonDef> buttonsOf(String deviceId) => _peerState[deviceId]?.buttons ?? const [];
}
