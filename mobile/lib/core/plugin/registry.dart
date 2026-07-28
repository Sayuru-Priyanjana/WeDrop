import 'dart:async';

import '../transport/handshake.dart';
import '../transport/session.dart';
import 'plugin.dart';

/// What the registry needs from whatever embeds it (today, AppService) to
/// actually reach peers, persist settings, and surface events. The registry
/// is otherwise self-contained and knows nothing about Flutter widgets or
/// storage formats.
abstract class PluginHost {
  Future<void> send(String deviceId, Map<String, dynamic> message);
  void broadcast(String capability, Map<String, dynamic> message);
  List<PeerRef> connectedPeers(String capability);

  /// Whether deviceId has been granted capability — the per-device trust
  /// permission a user sets per paired device.
  bool allows(String deviceId, String capability);

  void emit(PluginEvent event);
  Future<HandshakeResult> dialTransfer(String deviceId);
  Map<String, dynamic> loadPluginSettings(PluginId id);
  Future<void> savePluginSettings(PluginId id, Map<String, dynamic> data);
}

class _Registered {
  final WeDropPlugin plugin;
  bool enabled;
  _Registered(this.plugin, this.enabled);
}

/// Holds every compiled-in plugin, routes inbound messages to the plugin
/// that claimed each message type, and lets a plugin be enabled or disabled
/// at runtime without touching any other plugin.
///
/// This is the "loadable/unloadable" mechanism: plugins are compiled into
/// the single Flutter app (Dart has no stable hot-load mechanism), but the
/// registry's enable/disable is a genuine runtime toggle — a disabled
/// plugin's messages are silently dropped and its background work is
/// stopped, without restarting the app or any other plugin.
class PluginRegistry {
  final PluginHost host;

  final Map<PluginId, _Registered> _plugins = {};
  final Map<String, PluginId> _byMsg = {};

  PluginRegistry(this.host);

  /// Adds a plugin, enabled by default unless [enabledByDefault] is false.
  /// Throws if another plugin already claimed one of its message types.
  void register(WeDropPlugin plugin, {bool enabledByDefault = true}) {
    if (_plugins.containsKey(plugin.id)) {
      throw StateError('plugin "${plugin.id}" already registered');
    }
    for (final type in plugin.messageTypes) {
      final owner = _byMsg[type];
      if (owner != null) {
        throw StateError('message type "$type" already claimed by plugin "$owner"');
      }
    }

    plugin.init(_PluginApiImpl(plugin.id, this));

    for (final type in plugin.messageTypes) {
      _byMsg[type] = plugin.id;
    }
    _plugins[plugin.id] = _Registered(plugin, enabledByDefault);
  }

  WeDropPlugin? plugin(PluginId id) => _plugins[id]?.plugin;

  List<PluginId> get ids => _plugins.keys.toList();

  bool isEnabled(PluginId id) => _plugins[id]?.enabled ?? false;

  /// Toggles a plugin at runtime. Disabling stops its background work and
  /// starts silently dropping its messages; re-enabling restarts it.
  Future<void> setEnabled(PluginId id, bool enabled) async {
    final entry = _plugins[id];
    if (entry == null) throw StateError('unknown plugin "$id"');
    if (entry.enabled == enabled) return;
    entry.enabled = enabled;
    if (enabled) {
      await entry.plugin.start();
    } else {
      entry.plugin.stop();
    }
  }

  Future<void> startAll() async {
    for (final entry in _plugins.values) {
      if (entry.enabled) await entry.plugin.start();
    }
  }

  void stopAll() {
    for (final entry in _plugins.values) {
      entry.plugin.stop();
    }
  }

  // ------------------------------------------------ SessionHandler surface

  /// Looks up which plugin claimed [msgType] and, if enabled, hands it the
  /// raw payload; an unclaimed or disabled plugin's message is dropped
  /// silently.
  void onMessage(Session session, String msgType, Map<String, dynamic> raw) {
    final id = _byMsg[msgType];
    if (id == null) return;
    final entry = _plugins[id];
    if (entry == null || !entry.enabled) return;
    unawaited(
      entry.plugin.handleMessage(
        PeerRef(session.deviceId, session.peerInfo),
        msgType,
        raw,
      ),
    );
  }

  void onPeerConnected(PeerRef peer) {
    for (final entry in _plugins.values) {
      if (entry.enabled) entry.plugin.onPeerConnected(peer);
    }
  }

  void onPeerDisconnected(String deviceId) {
    for (final entry in _plugins.values) {
      if (entry.enabled) entry.plugin.onPeerDisconnected(deviceId);
    }
  }
}

class _PluginApiImpl implements PluginApi {
  final PluginId _id;
  final PluginRegistry _registry;
  _PluginApiImpl(this._id, this._registry);

  @override
  Future<void> send(String deviceId, Map<String, dynamic> message) =>
      _registry.host.send(deviceId, message);

  @override
  void broadcast(Map<String, dynamic> message) => _registry.host.broadcast(_id, message);

  @override
  List<PeerRef> connectedPeers() => _registry.host.connectedPeers(_id);

  @override
  bool allows(String deviceId) => _registry.host.allows(deviceId, _id);

  @override
  void emit(String name, Object? payload) =>
      _registry.host.emit(PluginEvent(_id, name, payload));

  @override
  Future<HandshakeResult> dialTransfer(String deviceId) =>
      _registry.host.dialTransfer(deviceId);

  @override
  Map<String, dynamic> settings() => _registry.host.loadPluginSettings(_id);

  @override
  Future<void> saveSettings(Map<String, dynamic> value) =>
      _registry.host.savePluginSettings(_id, value);

  @override
  bool get enabled => _registry.isEnabled(_id);

  @override
  void logf(String message) {
    // ignore: avoid_print
    print('[$_id] $message');
  }
}
