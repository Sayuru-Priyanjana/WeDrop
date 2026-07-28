import 'dart:async';
import 'dart:io';

import '../../core/platform/native_bridge.dart';
import '../../core/plugin/plugin.dart';
import '../../core/protocol/messages.dart';
import '../../core/transfer/transfer.dart';
import '../../core/transport/framing.dart';
import '../../core/transport/handshake.dart';

enum TransferStatus { pending, active, completed, failed, declined }

/// One file transfer, in progress or finished.
class TransferView {
  final String id;
  final String deviceId;
  final String deviceName;
  final String filename;
  int size;
  int transferred;
  final bool incoming;
  TransferStatus status;
  String error;
  String savedPath;
  final int startedAt;

  TransferView({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.filename,
    this.size = 0,
    this.transferred = 0,
    required this.incoming,
    this.status = TransferStatus.active,
    this.error = '',
    this.savedPath = '',
    int? startedAt,
  }) : startedAt = startedAt ?? DateTime.now().millisecondsSinceEpoch;
}

/// An inbound file awaiting the user's decision.
class IncomingFilePrompt {
  final TransferOffer offer;
  final String deviceName;
  final Completer<bool> completer;
  const IncomingFilePrompt(this.offer, this.deviceName, this.completer);
}

/// Keeps a fast transfer from rebuilding the widget tree on every chunk.
class _ProgressThrottle {
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  bool should(int done, int total) {
    if (done >= total) return true;
    final now = DateTime.now();
    if (now.difference(_last) < const Duration(milliseconds: 150)) return false;
    _last = now;
    return true;
  }
}

/// The files/transfer plugin: sends and receives files over a dedicated
/// connection per transfer, and keeps the local transfer history the UI
/// renders from.
///
/// Unlike every other plugin, transfers never run over the shared control
/// session — each one dials (or accepts) its own connection — so this
/// plugin claims no control-session message type; ConnectionManager calls
/// [handleTransferOffer] directly for an inbound connection, and
/// [sendFiles] dials outbound ones itself via [PluginApi.dialTransfer].
///
/// Conceptual mirror of desktop/plugins/files (Go) — see the plugin
/// architecture refactor plan.
class FilesPlugin implements WeDropPlugin {
  /// Resolves a peer's display name — the trusted name if set, else the
  /// session's/discovery's advertised name (passed as fallback).
  final String Function(String deviceId, String fallback) resolveName;
  final String Function() generateId;
  final String Function() downloadDir;

  late PluginApi _api;

  final List<TransferView> transfers = [];
  IncomingFilePrompt? incomingFilePrompt;

  FilesPlugin({
    required this.resolveName,
    required this.generateId,
    required this.downloadDir,
  });

  @override
  PluginId get id => Capability.files;

  // Transfers use a dedicated connection (Intent.transfer), not the shared
  // control session, so this plugin claims no control-session message type.
  @override
  List<String> get messageTypes => const [];

  @override
  void init(PluginApi api) {
    _api = api;
  }

  @override
  Future<void> handleMessage(PeerRef from, String msgType, Map<String, dynamic> raw) async {}

  @override
  void onPeerConnected(PeerRef peer) {}

  @override
  void onPeerDisconnected(String deviceId) {}

  @override
  Future<void> start() async {}

  @override
  void stop() {}

  /// Handles an inbound transfer connection — called directly by
  /// ConnectionManager.onTransferOffer (see the class doc for why this
  /// isn't routed through handleMessage).
  Future<void> handleTransferOffer(
    SecureConnection conn,
    DeviceInfo peer,
    TransferOffer offer,
  ) async {
    final name = resolveName(peer.deviceId, peer.name);
    final receiver = FileReceiver(conn, downloadDir());

    try {
      if (!_api.allows(peer.deviceId)) {
        await receiver.decline(offer, 'file transfers from this device are switched off');
        return;
      }

      final view = TransferView(
        id: offer.transferId,
        deviceId: peer.deviceId,
        deviceName: name,
        filename: offer.filename,
        size: offer.size,
        incoming: true,
        status: TransferStatus.pending,
      );
      _pushTransfer(view);

      final settings = _settings();
      if (!settings.autoAccept) {
        final completer = Completer<bool>();
        incomingFilePrompt = IncomingFilePrompt(offer, name, completer);
        _api.emit('changed', null);

        final accepted = await completer.future.timeout(
          const Duration(minutes: 2),
          onTimeout: () => false,
        );
        incomingFilePrompt = null;

        if (!accepted) {
          await receiver.decline(offer, 'declined');
          view.status = TransferStatus.declined;
          _api.emit('changed', null);
          return;
        }
      }

      view.status = TransferStatus.active;
      _api.emit('changed', null);

      final throttle = _ProgressThrottle();
      final tracked = FileReceiver(
        conn,
        downloadDir(),
        onProgress: (done, total) {
          view.transferred = done;
          if (throttle.should(done, total)) _api.emit('progress', null);
        },
      );

      final savedPath = await tracked.receive(offer);
      view
        ..status = TransferStatus.completed
        ..transferred = offer.size
        ..savedPath = savedPath;

      NativeBridge.showNotification(
        title: 'File received',
        body: '${offer.filename} from $name',
        tag: offer.transferId,
      );
      _api.emit('toast', 'Received ${offer.filename}');
    } catch (error) {
      final view = transfers.firstWhere(
        (t) => t.id == offer.transferId,
        orElse: () => TransferView(
          id: offer.transferId,
          deviceId: peer.deviceId,
          deviceName: name,
          filename: offer.filename,
          incoming: true,
        ),
      );
      view
        ..status = TransferStatus.failed
        ..error = error.toString();
      _api.emit('toast', 'Could not receive ${offer.filename}');
    } finally {
      await conn.close();
      _api.emit('changed', null);
    }
  }

  /// Answers the pending incoming file prompt.
  void respondToIncomingFile(bool accept) {
    final prompt = incomingFilePrompt;
    if (prompt == null || prompt.completer.isCompleted) return;
    prompt.completer.complete(accept);
  }

  /// Sends one or more files to a paired device.
  Future<void> sendFiles(String targetDeviceId, List<String> paths) async {
    for (final path in paths) {
      unawaited(_sendOneFile(targetDeviceId, path));
    }
  }

  Future<void> _sendOneFile(String targetDeviceId, String path) async {
    final file = File(path);
    final name = resolveName(targetDeviceId, '');
    final transferId = generateId();

    final view = TransferView(
      id: transferId,
      deviceId: targetDeviceId,
      deviceName: name,
      filename: path.split(Platform.pathSeparator).last,
      incoming: false,
    );
    try {
      view.size = await file.length();
    } catch (_) {}
    _pushTransfer(view);

    HandshakeResult? result;
    try {
      // A transfer gets its own connection so a big file cannot stall the
      // control session carrying clipboard sync and keepalives.
      result = await _api.dialTransfer(targetDeviceId);

      final throttle = _ProgressThrottle();
      final sender = FileSender(
        result.connection,
        onProgress: (done, total) {
          view.transferred = done;
          view.size = total;
          if (throttle.should(done, total)) _api.emit('progress', null);
        },
      );

      await sender.send(transferId: transferId, file: file);
      view
        ..status = TransferStatus.completed
        ..transferred = view.size;
      _api.emit('toast', 'Sent ${view.filename} to $name');
    } catch (error) {
      view
        ..status = error is TransferDeclined ? TransferStatus.declined : TransferStatus.failed
        ..error = error.toString();
      _api.emit('toast', 'Could not send ${view.filename}');
    } finally {
      await result?.connection.close();
      _api.emit('changed', null);
    }
  }

  void _pushTransfer(TransferView view) {
    transfers.insert(0, view);
    if (transfers.length > 40) transfers.removeLast();
    _api.emit('changed', null);
  }

  _Settings _settings() {
    final raw = _api.settings();
    return _Settings(
      autoAccept: raw['auto_accept'] == true,
      downloadDir: raw['download_dir'] as String? ?? '',
    );
  }
}

class _Settings {
  final bool autoAccept;
  final String downloadDir;
  const _Settings({required this.autoAccept, required this.downloadDir});
}
