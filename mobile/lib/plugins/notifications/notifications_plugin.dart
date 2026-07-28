import '../../core/platform/native_bridge.dart';
import '../../core/plugin/plugin.dart';
import '../../core/protocol/messages.dart';

/// One mirrored notification held in the local feed.
class NotificationEntry {
  final String id;
  final String deviceName;
  final String app;
  final String title;
  final String body;
  final int time;

  const NotificationEntry({
    required this.id,
    required this.deviceName,
    required this.app,
    required this.title,
    required this.body,
    required this.time,
  });
}

/// The notifications plugin: mirrors notifications from paired devices into
/// a local feed, and mirrors this phone's own notifications out to the
/// ecosystem.
///
/// Conceptual mirror of desktop/plugins/notifications (Go) — see the plugin
/// architecture refactor plan.
class NotificationsPlugin implements WeDropPlugin {
  /// Resolves a peer's display name — the trusted name if set, else the
  /// session's advertised name (passed as [fallback]).
  final String Function(String deviceId, String fallback) resolveName;

  /// Generates an id for a locally-mirrored notification that arrived
  /// without one.
  final String Function() generateId;

  late PluginApi _api;

  final List<NotificationEntry> items = [];

  NotificationsPlugin({required this.resolveName, required this.generateId});

  @override
  PluginId get id => Capability.notifications;

  @override
  List<String> get messageTypes => [MsgType.notification];

  @override
  void init(PluginApi api) {
    _api = api;
  }

  @override
  Future<void> handleMessage(PeerRef from, String msgType, Map<String, dynamic> raw) async {
    final settings = _api.settings();
    if (settings['receive'] != true) return;
    if (!_api.allows(from.deviceId)) return;

    final message = NotificationMessage.fromJson(raw);
    final name = resolveName(from.deviceId, from.info.name);

    items.insert(
      0,
      NotificationEntry(
        id: message.id,
        deviceName: name,
        app: message.app,
        title: message.title,
        body: message.body,
        time: message.time,
      ),
    );
    if (items.length > 100) items.removeLast();

    await NativeBridge.showNotification(
      title: message.title.isEmpty ? '$name · ${message.app}' : message.title,
      body: message.body,
      tag: message.id,
    );
    _api.emit('received', null);
  }

  @override
  void onPeerConnected(PeerRef peer) {}

  @override
  void onPeerDisconnected(String deviceId) {}

  @override
  Future<void> start() async {}

  @override
  void stop() {}

  void clear() => items.clear();

  /// Mirrors one of this phone's notifications to the rest of the
  /// ecosystem, forwarded up from the Android notification listener.
  void forwardLocal(Map<String, dynamic> event) {
    if (_api.settings()['share'] != true) return;

    final app = event['app'] as String? ?? '';
    // WeDrop's own ongoing service notification would otherwise echo endlessly.
    if (app.contains('wedrop')) return;

    _api.broadcast(
      NotificationMessage(
        id: event['id'] as String? ?? generateId(),
        app: event['app_label'] as String? ?? app,
        title: event['title'] as String? ?? '',
        body: event['body'] as String? ?? '',
        time: event['time'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ).toJson(),
    );
  }
}
