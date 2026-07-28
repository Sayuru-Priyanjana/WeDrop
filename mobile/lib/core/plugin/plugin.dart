import 'dart:async';

import '../protocol/messages.dart';

/// Identifies a plugin. A plugin's id doubles as the capability string it
/// advertises to peers (see [DeviceInfo.capabilities]) and as the key under
/// which its settings and per-device permissions are stored.
///
/// This is the Dart-side conceptual mirror of `core/plugin` (Go) — mobile
/// has no shared Go code, so the wire protocol and this plugin boundary are
/// kept in sync by hand, the same way the rest of the transport layer is.
typedef PluginId = String;

/// The minimal peer handle a plugin receives — deliberately not the raw
/// [Session], so a plugin cannot reach into transport internals or address
/// a peer outside the API's capability checks.
class PeerRef {
  final String deviceId;
  final DeviceInfo info;
  const PeerRef(this.deviceId, this.info);
}

/// A (plugin, name, payload) tuple a plugin raises through [PluginApi.emit].
/// The host (AppService) maps these to its own ChangeNotifier/notification
/// mechanism; the plugin layer itself knows nothing about Flutter widgets.
class PluginEvent {
  final PluginId plugin;
  final String name;
  final Object? payload;
  const PluginEvent(this.plugin, this.name, this.payload);
}

/// Everything core exposes to a plugin. Issued once per plugin, so
/// send/broadcast/connectedPeers implicitly scope to that plugin's own
/// capability — a plugin cannot address a peer that has not granted it that
/// capability, and never needs to check permissions itself.
abstract class PluginApi {
  Future<void> send(String deviceId, Map<String, dynamic> message);
  void broadcast(Map<String, dynamic> message);
  List<PeerRef> connectedPeers();
  void emit(String name, Object? payload);

  /// This plugin's own settings, previously saved via [saveSettings], as a
  /// raw map (empty if never saved). Core stores this opaquely — it does
  /// not know or care about a plugin's settings shape.
  Map<String, dynamic> settings();
  Future<void> saveSettings(Map<String, dynamic> value);

  /// Whether this plugin is currently enabled. A disabled plugin still
  /// exists in the registry (so it can be re-enabled) but receives no
  /// messages and has had its background work stopped.
  bool get enabled;

  void logf(String message);
}

/// The contract every feature implements. A plugin has no knowledge of
/// Flutter widgets or any other plugin — only of the [PluginApi] it is
/// handed by [init].
abstract class WeDropPlugin {
  /// This plugin's stable identifier and capability string.
  PluginId get id;

  /// The wire message types (see MsgType) this plugin handles. The registry
  /// rejects registering two plugins that claim the same type.
  List<String> get messageTypes;

  /// Called once, before [start], with the API this plugin must use for
  /// everything it needs from core.
  void init(PluginApi api);

  /// Called for every inbound message whose type this plugin claimed in
  /// [messageTypes]. [raw] is the still-decoded JSON map; the plugin
  /// interprets it as its own message shape.
  Future<void> handleMessage(PeerRef from, String msgType, Map<String, dynamic> raw);

  /// Notifies a plugin of session lifecycle changes, so it can maintain any
  /// per-peer state it needs.
  void onPeerConnected(PeerRef peer);
  void onPeerDisconnected(String deviceId);

  /// Begins any background work (polling, broadcasting) the plugin needs.
  Future<void> start();

  /// Ends the plugin's background work. Called when disabled or the app is
  /// disposed.
  void stop();
}
