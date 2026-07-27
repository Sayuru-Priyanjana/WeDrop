import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'crypto/identity.dart';
import 'discovery/discovery_service.dart';
import 'platform/native_bridge.dart';
import 'protocol/messages.dart';
import 'storage/store.dart';
import 'transfer/transfer.dart';
import 'transport/connection_manager.dart';
import 'transport/framing.dart';
import 'transport/handshake.dart';
import 'transport/session.dart';

/// A device as the UI sees it: trust store, discovery and session state merged.
class DeviceView {
  final String deviceId;
  final String name;
  final String platform;
  final String formFactor;
  final String ip;
  final bool paired;
  final bool online;
  final bool connected;
  final int lastSeen;

  final bool allowClipboard;
  final bool allowFiles;
  final bool allowNotifications;
  final bool allowMedia;

  const DeviceView({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.formFactor,
    this.ip = '',
    this.paired = false,
    this.online = false,
    this.connected = false,
    this.lastSeen = 0,
    this.allowClipboard = true,
    this.allowFiles = true,
    this.allowNotifications = true,
    this.allowMedia = true,
  });
}

enum TransferStatus { pending, active, completed, failed, declined }

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

/// An inbound pairing request awaiting the user's decision.
class PairingPrompt {
  final PairingRequest request;
  final Completer<PairingDecision> completer;
  const PairingPrompt(this.request, this.completer);
}

/// An inbound file awaiting the user's decision.
class IncomingFilePrompt {
  final TransferOffer offer;
  final String deviceName;
  final Completer<bool> completer;
  const IncomingFilePrompt(this.offer, this.deviceName, this.completer);
}

/// The whole mobile app behind one listenable object.
///
/// The UI reads state from here and calls methods on it; nothing else touches
/// the network stack directly.
class AppService extends ChangeNotifier implements PeerAuthorizer {
  static const _uuid = Uuid();
  static const _clipboardPoll = Duration(seconds: 2);

  late WeDropStore _store;
  late DiscoveryService _discovery;
  late ConnectionManager _manager;

  /// True once the network stack is fully constructed. Guards the late fields
  /// above so a startup that fails partway — or a test host with no platform
  /// channels — can still be disposed without a LateInitializationError.
  bool _started = false;

  bool ready = false;
  String startupError = '';
  String downloadDir = '';

  final List<TransferView> transfers = [];
  final List<ClipboardEntry> clipboardHistory = [];
  final List<NotificationEntry> notifications = [];

  PairingPrompt? pairingPrompt;
  IncomingFilePrompt? incomingFilePrompt;

  /// Outgoing pairing in flight, so the UI can show the verification code.
  String? outgoingPairingName;
  String? outgoingPairingCode;

  final _toastController = StreamController<String>.broadcast();
  Stream<String> get toasts => _toastController.stream;

  Timer? _clipboardTimer;
  StreamSubscription? _nativeEvents;
  String _lastClipboardHash = '';
  int _clipboardSeq = 0;
  bool _notificationAccess = false;

  // -------------------------------------------------------------- getters

  WeDropStore get store => _store;
  Settings get settings => _store.settings;
  String get deviceName => _store.deviceName;
  String get deviceId => _store.deviceId;
  String get publicKey => _store.identity.publicKeyBase64;
  bool get hasNotificationAccess => _notificationAccess;
  int get connectedCount => _started ? _manager.connectedDevices.length : 0;

  /// Paired devices, merged with live discovery and session state.
  List<DeviceView> get pairedDevices {
    if (!_started) return const [];
    final online = {for (final p in _discovery.peers) p.deviceId: p};

    return _store.trustedDevices.map((device) {
      final peer = online[device.deviceId];
      return DeviceView(
        deviceId: device.deviceId,
        name: device.name,
        platform: device.platform,
        formFactor: device.formFactor,
        ip: peer?.ip ?? '',
        paired: true,
        online: peer != null,
        connected: _manager.isConnected(device.deviceId),
        lastSeen: device.lastSeen,
        allowClipboard: device.allowClipboard,
        allowFiles: device.allowFiles,
        allowNotifications: device.allowNotifications,
        allowMedia: device.allowMedia,
      );
    }).toList();
  }

  /// Devices seen nearby that are not yet part of the ecosystem.
  List<DeviceView> get discoveredDevices {
    if (!_started) return const [];
    final list = _discovery.peers
        .where((p) => !_store.isTrusted(p.deviceId) && p.deviceId != deviceId)
        .map((p) => DeviceView(
              deviceId: p.deviceId,
              name: p.name,
              platform: p.platform,
              formFactor: p.formFactor,
              ip: p.ip,
              online: true,
            ))
        .toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  // ---------------------------------------------------------------- start

  Future<void> start() async {
    try {
      _store = await WeDropStore.open();

      // Adopt the handset's own model name the first time, so the user is not
      // faced with three devices all called "My Phone".
      if (_store.deviceName == 'My Phone') {
        final model = await NativeBridge.deviceModelName();
        if (model != null && model.isNotEmpty) await _store.setDeviceName(model);
      }

      final dir = await _resolveDownloadDir();
      downloadDir = dir;

      _discovery = DiscoveryService(DiscoveryMessage(
        deviceId: deviceId,
        name: deviceName,
        platform: Platform.operatingSystem,
        formFactor: FormFactor.phone,
        tcpPort: transportPort,
        publicKey: publicKey,
      ));

      _manager = ConnectionManager(
        local: _localInfo,
        discovery: _discovery,
        auth: this,
        localDeviceInfo: _localDeviceInfo,
        handler: SessionHandler(
          onClipboard: _onClipboard,
          onNotification: _onNotification,
          onMedia: _onMedia,
          onDeviceInfo: _onDeviceInfo,
          onUnpair: _onUnpair,
          onClosed: (_, error) => _refreshServiceStatus(),
        ),
        onPairingRequest: _onPairingRequest,
        onTransferOffer: _onTransferOffer,
        onSessionChange: (deviceId, connected) {
          if (connected) _store.touchLastSeen(deviceId);
          _refreshServiceStatus();
          notifyListeners();
        },
      );

      final port = await _manager.start();
      // The network stack is now safe to touch and tear down.
      _started = true;

      // Announce the port actually bound, not the one we hoped for.
      _discovery.updateConfig(DiscoveryMessage(
        deviceId: deviceId,
        name: deviceName,
        platform: Platform.operatingSystem,
        formFactor: FormFactor.phone,
        tcpPort: port,
        publicKey: publicKey,
      ));

      _discovery.onPeer.listen((_) => notifyListeners());
      _discovery.onPeerLost.listen((_) => notifyListeners());

      if (settings.discoverable) await _discovery.start();

      _startClipboardWatcher();
      await _wireNativeBridge();

      ready = true;
    } catch (error) {
      startupError = error.toString();
    }
    notifyListeners();
  }

  LocalInfo get _localInfo => LocalInfo(
        identity: _store.identity,
        name: deviceName,
        platform: Platform.operatingSystem,
        formFactor: FormFactor.phone,
      );

  DeviceInfo _localDeviceInfo() => DeviceInfo(
        deviceId: deviceId,
        name: deviceName,
        platform: Platform.operatingSystem,
        formFactor: FormFactor.phone,
        capabilities: settings.capabilities,
        battery: -1,
      );

  Future<String> _resolveDownloadDir() async {
    try {
      // Downloads/WeDrop is where a user would look for a received file; the
      // app's own directory is the fallback when it is not reachable.
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return '${downloads.path}${Platform.pathSeparator}WeDrop';
    } catch (_) {}

    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}${Platform.pathSeparator}WeDrop';
  }

  Future<void> _wireNativeBridge() async {
    if (settings.runInBackground) {
      await NativeBridge.startBackgroundService(status: 'Keeping your devices in sync');
    }
    await NativeBridge.requestPostNotifications();
    _notificationAccess = await NativeBridge.hasNotificationAccess();

    _nativeEvents = NativeBridge.events.listen(_onNativeEvent);

    // Drain anything shared before Dart was listening.
    final pending = await NativeBridge.consumePendingShares();
    if (pending.isNotEmpty) pendingSharedFiles.addAll(pending);
  }

  /// Files handed to WeDrop through the Android share sheet, waiting for the
  /// user to pick a destination device.
  final List<String> pendingSharedFiles = [];

  void _onNativeEvent(Map<String, dynamic> event) {
    switch (event['type'] as String?) {
      case 'shared_files':
        final paths = (event['paths'] as List?)?.map((e) => e.toString()) ?? const [];
        pendingSharedFiles.addAll(paths);
        notifyListeners();
        break;

      case 'notification_posted':
        _forwardLocalNotification(event);
        break;
    }
  }

  /// Mirrors one of this phone's notifications to the rest of the ecosystem.
  void _forwardLocalNotification(Map<String, dynamic> event) {
    if (!settings.shareNotifications) return;

    final app = event['app'] as String? ?? '';
    // WeDrop's own ongoing service notification would otherwise echo endlessly.
    if (app.contains('wedrop')) return;

    _manager.broadcast(
      Capability.notifications,
      NotificationMessage(
        id: event['id'] as String? ?? _uuid.v4(),
        app: event['app_label'] as String? ?? app,
        title: event['title'] as String? ?? '',
        body: event['body'] as String? ?? '',
        time: event['time'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ).toJson(),
    );
  }

  // ----------------------------------------------------- PeerAuthorizer

  @override
  String? trustedKey(String deviceId) => _store.trustedKey(deviceId);

  @override
  bool get pairingAllowed => settings.acceptNewPairing;

  // ------------------------------------------------------- session events

  void _onClipboard(Session session, ClipboardMessage message) async {
    if (!settings.receiveClipboard) return;
    if (!_store.allows(session.deviceId, Capability.clipboard)) return;
    if (message.text.isEmpty || message.text.length > settings.clipboardMaxChars) return;

    final hash =
        message.hash.isNotEmpty ? message.hash : await sha256Hex(message.text.codeUnits);

    // Record the hash before writing, so our own watcher does not see the text
    // we just pasted in as a fresh local copy and bounce it around forever.
    if (hash == _lastClipboardHash) return;
    _lastClipboardHash = hash;

    await Clipboard.setData(ClipboardData(text: message.text));

    final name = _store.trusted(session.deviceId)?.name ?? session.peerInfo.name;
    _pushClipboardEntry(ClipboardEntry(text: message.text, originName: name, incoming: true));
    _toastController.add('Clipboard from $name');
    notifyListeners();
  }

  void _onNotification(Session session, NotificationMessage message) {
    if (!settings.receiveNotifications) return;
    if (!_store.allows(session.deviceId, Capability.notifications)) return;

    final name = _store.trusted(session.deviceId)?.name ?? session.peerInfo.name;
    notifications.insert(
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
    if (notifications.length > 100) notifications.removeLast();

    NativeBridge.showNotification(
      title: message.title.isEmpty ? '$name · ${message.app}' : message.title,
      body: message.body,
      tag: message.id,
    );
    notifyListeners();
  }

  void _onMedia(Session session, String command) {
    if (!settings.allowMediaControl) return;
    if (!_store.allows(session.deviceId, Capability.media)) return;
    NativeBridge.applyMediaCommand(command);
  }

  void _onDeviceInfo(Session session, DeviceInfo info) {
    if (info.name.isNotEmpty) _store.renameTrusted(session.deviceId, info.name);
    notifyListeners();
  }

  void _onUnpair(Session session) async {
    final name = _store.trusted(session.deviceId)?.name ?? 'A device';
    await _store.removeTrusted(session.deviceId);
    await _manager.disconnect(session.deviceId);
    _toastController.add('$name left your ecosystem');
    notifyListeners();
  }

  Future<PairingDecision> _onPairingRequest(PairingRequest request) async {
    if (!settings.acceptNewPairing) {
      return const PairingDecision(false, 'this device is not accepting new pairings');
    }
    // One at a time: a second request while the user is deciding is refused
    // rather than queued, so nobody can bury a malicious request under a
    // legitimate one.
    if (pairingPrompt != null) {
      return const PairingDecision(false, 'another pairing request is already open');
    }

    final completer = Completer<PairingDecision>();
    pairingPrompt = PairingPrompt(request, completer);
    notifyListeners();

    // Time out rather than holding the connection open forever on a request
    // the user never saw.
    final decision = await completer.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () => const PairingDecision(false, 'no response in time'),
    );

    pairingPrompt = null;
    notifyListeners();

    if (decision.accepted) {
      // Store the key proved during the handshake, never one from a UDP
      // announcement — announcements are unauthenticated and easily forged.
      await _store.addTrusted(TrustedDevice(
        deviceId: request.deviceId,
        name: request.name,
        platform: request.platform,
        formFactor: request.formFactor,
        publicKey: request.publicKey,
      ));
      _toastController.add('${request.name} joined your ecosystem');
      notifyListeners();
    }
    return decision;
  }

  Future<void> _onTransferOffer(
    SecureConnection conn,
    DeviceInfo peer,
    TransferOffer offer,
  ) async {
    final name = _store.trusted(peer.deviceId)?.name ?? peer.name;
    final receiver = FileReceiver(conn, downloadDir);

    try {
      if (!_store.allows(peer.deviceId, Capability.files)) {
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

      if (!settings.autoAcceptFiles) {
        final completer = Completer<bool>();
        incomingFilePrompt = IncomingFilePrompt(offer, name, completer);
        notifyListeners();

        final accepted = await completer.future.timeout(
          const Duration(minutes: 2),
          onTimeout: () => false,
        );
        incomingFilePrompt = null;

        if (!accepted) {
          await receiver.decline(offer, 'declined');
          view.status = TransferStatus.declined;
          notifyListeners();
          return;
        }
      }

      view.status = TransferStatus.active;
      notifyListeners();

      final throttle = _ProgressThrottle();
      final tracked = FileReceiver(
        conn,
        downloadDir,
        onProgress: (done, total) {
          view.transferred = done;
          if (throttle.should(done, total)) notifyListeners();
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
      _toastController.add('Received ${offer.filename}');
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
      _toastController.add('Could not receive ${offer.filename}');
    } finally {
      await conn.close();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------- user actions

  /// Asks a discovered device to join this ecosystem.
  Future<void> pairWith(String targetDeviceId) async {
    final peer = _discovery.peer(targetDeviceId);
    if (peer == null) throw Exception('that device is no longer on the network');
    if (_store.isTrusted(targetDeviceId)) {
      throw Exception('${peer.name} is already in your ecosystem');
    }

    HandshakeResult? result;
    try {
      result = await dialHandshake(
        host: peer.ip,
        port: peer.tcpPort,
        local: _localInfo,
        intent: Intent.pair,
      );

      // Show the code while the other user decides, so both screens can be
      // compared before anyone taps Accept.
      outgoingPairingName = peer.name;
      outgoingPairingCode = result.verificationCode;
      notifyListeners();

      final reply = await result.connection.readJson().timeout(const Duration(seconds: 90));
      if (reply['accepted'] != true) {
        final reason = reply['reason'] as String? ?? '';
        throw Exception(
          reason.isEmpty ? '${peer.name} declined the request' : '${peer.name} declined: $reason',
        );
      }

      await _store.addTrusted(TrustedDevice(
        deviceId: targetDeviceId,
        name: (reply['name'] as String?)?.isNotEmpty == true
            ? reply['name'] as String
            : peer.name,
        platform: peer.platform,
        formFactor: peer.formFactor,
        publicKey: result.peerPublicKey,
      ));

      _manager.reconnectNow(targetDeviceId);
      _toastController.add('${peer.name} joined your ecosystem');
    } finally {
      await result?.connection.close();
      outgoingPairingName = null;
      outgoingPairingCode = null;
      notifyListeners();
    }
  }

  /// Answers the pending inbound pairing prompt.
  void respondToPairing(bool accept) {
    final prompt = pairingPrompt;
    if (prompt == null || prompt.completer.isCompleted) return;
    prompt.completer.complete(PairingDecision(accept, accept ? '' : 'declined'));
  }

  /// Answers the pending incoming file prompt.
  void respondToIncomingFile(bool accept) {
    final prompt = incomingFilePrompt;
    if (prompt == null || prompt.completer.isCompleted) return;
    prompt.completer.complete(accept);
  }

  /// Removes a device and tells it, so both sides forget each other.
  Future<void> unpair(String targetDeviceId) async {
    final session = _manager.session(targetDeviceId);
    if (session != null) {
      try {
        await session.send(unpairMessage(deviceId));
      } catch (_) {
        // The peer is already gone; removing locally is still correct.
      }
    }
    await _manager.disconnect(targetDeviceId);
    await _store.removeTrusted(targetDeviceId);
    notifyListeners();
  }

  Future<void> setPermission(String targetDeviceId, String capability, bool allowed) async {
    await _store.setPermission(targetDeviceId, capability, allowed);
    notifyListeners();
  }

  /// Sends one or more files to a paired device.
  Future<void> sendFiles(String targetDeviceId, List<String> paths) async {
    final peer = _discovery.peer(targetDeviceId);
    final key = _store.trustedKey(targetDeviceId);
    if (peer == null) throw Exception('that device is not on the network right now');
    if (key == null) throw Exception('that device is not in your ecosystem');

    for (final path in paths) {
      unawaited(_sendOneFile(targetDeviceId, peer, key, path));
    }
  }

  Future<void> _sendOneFile(
    String targetDeviceId,
    DiscoveryMessage peer,
    String expectedKey,
    String path,
  ) async {
    final file = File(path);
    final name = _store.trusted(targetDeviceId)?.name ?? peer.name;
    final transferId = _uuid.v4();

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
      result = await dialHandshake(
        host: peer.ip,
        port: peer.tcpPort,
        local: _localInfo,
        intent: Intent.transfer,
        expectedKey: expectedKey,
        timeout: const Duration(seconds: 8),
      );

      final throttle = _ProgressThrottle();
      final sender = FileSender(
        result.connection,
        onProgress: (done, total) {
          view.transferred = done;
          view.size = total;
          if (throttle.should(done, total)) notifyListeners();
        },
      );

      await sender.send(transferId: transferId, file: file);
      view
        ..status = TransferStatus.completed
        ..transferred = view.size;
      _toastController.add('Sent ${view.filename} to $name');
    } catch (error) {
      view
        ..status =
            error is TransferDeclined ? TransferStatus.declined : TransferStatus.failed
        ..error = error.toString();
      _toastController.add('Could not send ${view.filename}');
    } finally {
      await result?.connection.close();
      notifyListeners();
    }
  }

  /// Sends the current clipboard to the ecosystem immediately.
  Future<void> pushClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) throw Exception('the clipboard is empty');
    if (_manager.connectedDevices.isEmpty) {
      throw Exception('no devices are connected right now');
    }
    await _broadcastClipboard(text);
    _toastController.add('Clipboard sent');
  }

  Future<void> copyToClipboard(String text) async {
    _lastClipboardHash = await sha256Hex(text.codeUnits);
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// Reads the clipboard and shares it if it changed, called when WeDrop
  /// returns to the foreground.
  ///
  /// On Android an app may only read the clipboard while it is the focused app,
  /// so a copy made in another app (Chrome, a chat) cannot be picked up by the
  /// background poller. Syncing on resume is the one reliable moment to catch
  /// it: the user copies elsewhere, switches back to WeDrop, and it goes out.
  Future<void> syncClipboardOnResume() async {
    if (!_started) return;
    // Clipboard access is only granted once the window is fully focused, which
    // trails the resume event by a moment on some Android versions; without a
    // short settle the read can still return the previous value.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _checkClipboard();
  }

  Future<void> sendMediaCommand(String targetDeviceId, String command) =>
      _manager.sendTo(targetDeviceId, mediaMessage(command));

  Future<void> updateSettings(Settings next) async {
    final previous = settings;
    await _store.saveSettings(next);

    if (next.discoverable != previous.discoverable) {
      if (next.discoverable) {
        await _discovery.start();
      } else {
        await _discovery.stop();
      }
    }

    if (next.runInBackground != previous.runInBackground) {
      if (next.runInBackground) {
        await NativeBridge.startBackgroundService(status: 'Keeping your devices in sync');
      } else {
        await NativeBridge.stopBackgroundService();
      }
    }

    // Peers must learn immediately that a receive switch changed, otherwise
    // they keep sending data this device will now silently drop.
    await _manager.broadcastDeviceInfo();
    notifyListeners();
  }

  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw Exception('the device name cannot be empty');

    await _store.setDeviceName(trimmed);
    _discovery.updateConfig(DiscoveryMessage(
      deviceId: deviceId,
      name: trimmed,
      platform: Platform.operatingSystem,
      formFactor: FormFactor.phone,
      tcpPort: _manager.port,
      publicKey: publicKey,
    ));
    await _manager.broadcastDeviceInfo();
    notifyListeners();
  }

  Future<void> refreshNotificationAccess() async {
    _notificationAccess = await NativeBridge.hasNotificationAccess();
    notifyListeners();
  }

  void clearSharedFiles() {
    pendingSharedFiles.clear();
    notifyListeners();
  }

  void clearClipboardHistory() {
    clipboardHistory.clear();
    notifyListeners();
  }

  void clearNotifications() {
    notifications.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------- internals

  void _startClipboardWatcher() {
    _clipboardTimer = Timer.periodic(_clipboardPoll, (_) => _checkClipboard());
  }

  Future<void> _checkClipboard() async {
    if (!settings.autoSyncClipboard) return;
    // Nothing to broadcast to, so do not even read the clipboard — on Android
    // that read is a cross-process call and shows a toast on some versions.
    if (_manager.connectedDevices.isEmpty) return;

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty || text.length > settings.clipboardMaxChars) return;

    final hash = await sha256Hex(text.codeUnits);
    if (hash == _lastClipboardHash) return;
    _lastClipboardHash = hash;

    await _broadcastClipboard(text, hash: hash);
  }

  Future<void> _broadcastClipboard(String text, {String? hash}) async {
    final digest = hash ?? await sha256Hex(text.codeUnits);
    _lastClipboardHash = digest;

    _pushClipboardEntry(
      ClipboardEntry(text: text, originName: deviceName, incoming: false),
    );

    await _manager.broadcast(
      Capability.clipboard,
      ClipboardMessage(
        text: text,
        origin: deviceId,
        sequence: ++_clipboardSeq,
        hash: digest,
      ).toJson(),
    );
    notifyListeners();
  }

  void _pushClipboardEntry(ClipboardEntry entry) {
    clipboardHistory.insert(0, entry);
    if (clipboardHistory.length > 50) clipboardHistory.removeLast();
  }

  void _pushTransfer(TransferView view) {
    transfers.insert(0, view);
    if (transfers.length > 40) transfers.removeLast();
    notifyListeners();
  }

  void _refreshServiceStatus() {
    if (!settings.runInBackground) return;
    final count = _manager.connectedDevices.length;
    NativeBridge.updateServiceStatus(
      count == 0 ? 'Waiting for your devices' : '$count device${count == 1 ? '' : 's'} connected',
    );
  }

  @override
  void dispose() {
    _clipboardTimer?.cancel();
    _nativeEvents?.cancel();
    // Only tear down the network stack if it actually came up; a startup that
    // failed early leaves these late fields unset.
    if (_started) {
      _manager.stop();
      _discovery.dispose();
    }
    _toastController.close();
    super.dispose();
  }
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
