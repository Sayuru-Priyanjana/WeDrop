import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/crypto/identity.dart';
import '../../core/plugin/plugin.dart';
import '../../core/protocol/messages.dart';

/// One item of clipboard history.
class ClipboardEntry {
  final String text;
  final String originName;
  final bool incoming;
  final int time;

  ClipboardEntry({
    required this.text,
    required this.originName,
    required this.incoming,
    int? time,
  }) : time = time ?? DateTime.now().millisecondsSinceEpoch;
}

class _Settings {
  final bool autoSync;
  final bool receive;
  final int maxChars;
  const _Settings({required this.autoSync, required this.receive, required this.maxChars});
}

/// Interval at which the local clipboard is polled for changes.
const Duration _pollInterval = Duration(seconds: 2);

/// The clipboard plugin: watches the local clipboard and syncs it to paired
/// devices, and applies clipboard text received from them.
///
/// Conceptual mirror of desktop/plugins/clipboard (Go) — see the plugin
/// architecture refactor plan.
class ClipboardPlugin implements WeDropPlugin {
  final String deviceId;
  final String Function() deviceName;
  final String Function(String deviceId, String fallback) resolveName;

  late PluginApi _api;
  Timer? _timer;
  String _lastHash = '';
  int _seq = 0;

  final List<ClipboardEntry> items = [];

  ClipboardPlugin({
    required this.deviceId,
    required this.deviceName,
    required this.resolveName,
  });

  @override
  PluginId get id => Capability.clipboard;

  @override
  List<String> get messageTypes => [MsgType.clipboard];

  @override
  void init(PluginApi api) {
    _api = api;
  }

  @override
  Future<void> handleMessage(PeerRef from, String msgType, Map<String, dynamic> raw) async {
    final settings = _settings();
    if (!settings.receive) return;
    if (!_api.allows(from.deviceId)) return;

    final message = ClipboardMessage.fromJson(raw);
    if (message.text.isEmpty || message.text.length > settings.maxChars) return;

    final hash =
        message.hash.isNotEmpty ? message.hash : await sha256Hex(message.text.codeUnits);
    if (hash == _lastHash) return;

    await Clipboard.setData(ClipboardData(text: message.text));

    // Read back what Android actually stored rather than trusting the hash of
    // what we sent it — this is the fix for a real bounce-back bug: Android's
    // clipboard can return the text back slightly changed (it stores more
    // than one representation of a clip, and some keyboards/clipboard
    // managers normalise it further), so hashing the original message text
    // left a gap where the periodic watcher would see a "different"
    // clipboard a moment later and re-broadcast it — on a 3+ device
    // ecosystem this cascades into exactly the frequent, spurious resending
    // that was reported. Hashing whatever the OS reports back closes that
    // gap regardless of what it does to the content.
    final readBack = await Clipboard.getData(Clipboard.kTextPlain);
    _lastHash = readBack?.text != null ? await sha256Hex(readBack!.text!.codeUnits) : hash;

    final name = resolveName(from.deviceId, from.info.name);
    _push(ClipboardEntry(text: message.text, originName: name, incoming: true));
    _api.emit('received', name);
  }

  @override
  void onPeerConnected(PeerRef peer) {}

  @override
  void onPeerDisconnected(String deviceId) {}

  @override
  Future<void> start() async {
    _timer = Timer.periodic(_pollInterval, (_) => checkNow());
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Reads the clipboard and broadcasts it if it changed and auto-sync is
  /// on. Exposed (not private) so AppService.resyncOnResume can force a
  /// check right after the app regains focus, when a copy made in another
  /// app first becomes readable.
  Future<void> checkNow() async {
    final settings = _settings();
    if (!settings.autoSync) return;
    // Nothing to broadcast to, so do not even read the clipboard — on
    // Android that read is a cross-process call and shows a toast on some
    // versions.
    if (_api.connectedPeers().isEmpty) return;

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty || text.length > settings.maxChars) return;

    final hash = await sha256Hex(text.codeUnits);
    if (hash == _lastHash) return;
    _lastHash = hash;

    await _broadcast(text, hash: hash);
  }

  Future<void> _broadcast(String text, {String? hash}) async {
    final digest = hash ?? await sha256Hex(text.codeUnits);
    _lastHash = digest;

    _push(ClipboardEntry(text: text, originName: deviceName(), incoming: false));

    _api.broadcast(
      ClipboardMessage(text: text, origin: deviceId, sequence: ++_seq, hash: digest).toJson(),
    );
    _api.emit('changed', null);
  }

  /// Sends the current clipboard to the ecosystem immediately, regardless of
  /// the auto-sync setting — what "Send clipboard now" does.
  Future<void> pushNow() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) throw Exception('the clipboard is empty');
    if (_api.connectedPeers().isEmpty) {
      throw Exception('no devices are connected right now');
    }
    await _broadcast(text);
  }

  /// Puts a history entry back on the local clipboard.
  Future<void> setClipboard(String text) async {
    _lastHash = await sha256Hex(text.codeUnits);
    await Clipboard.setData(ClipboardData(text: text));
  }

  void _push(ClipboardEntry entry) {
    items.insert(0, entry);
    if (items.length > 50) items.removeLast();
  }

  void clear() => items.clear();

  _Settings _settings() {
    final raw = _api.settings();
    return _Settings(
      autoSync: raw['auto_sync'] == true,
      receive: raw['receive'] == true,
      maxChars: raw['max_chars'] as int? ?? 65536,
    );
  }
}
