import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'discovery/discovery_service.dart';
import 'platform/native_bridge.dart';
import 'plugin/plugin.dart';
import 'plugin/registry.dart';
import 'protocol/messages.dart';
import 'storage/store.dart';
import 'transport/connection_manager.dart';
import 'transport/handshake.dart';
import 'transport/session.dart';
import '../plugins/clipboard/clipboard_plugin.dart';
import '../plugins/files/files_plugin.dart';
import '../plugins/health/health_plugin.dart';
import '../plugins/media/media_plugin.dart';
import '../plugins/notifications/notifications_plugin.dart';

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

/// An inbound pairing request awaiting the user's decision.
class PairingPrompt {
  final PairingRequest request;
  final Completer<PairingDecision> completer;
  const PairingPrompt(this.request, this.completer);
}

/// The whole mobile app behind one listenable object.
///
/// The UI reads state from here and calls methods on it; nothing else touches
/// the network stack directly.
class AppService extends ChangeNotifier implements PeerAuthorizer {
  static const _uuid = Uuid();

  late WeDropStore _store;
  late DiscoveryService _discovery;
  late ConnectionManager _manager;
  late PluginRegistry _plugins;
  late HealthPlugin _healthPlugin;
  late NotificationsPlugin _notifsPlugin;
  late ClipboardPlugin _clipPlugin;
  late MediaPlugin _mediaPlugin;
  late FilesPlugin _filesPlugin;

  /// True once the network stack is fully constructed. Guards the late fields
  /// above so a startup that fails partway — or a test host with no platform
  /// channels — can still be disposed without a LateInitializationError.
  bool _started = false;

  bool ready = false;
  String startupError = '';
  String downloadDir = '';

  /// The notifications feed — owned by _notifsPlugin; exposed here so the UI
  /// keeps reading it off AppService like everything else.
  List<NotificationEntry> get notifications => _notifsPlugin.items;

  /// The clipboard history feed — owned by _clipPlugin; exposed here so the
  /// UI keeps reading it off AppService like everything else.
  List<ClipboardEntry> get clipboardHistory => _clipPlugin.items;

  /// The transfer history — owned by _filesPlugin; exposed here so the UI
  /// keeps reading it off AppService like everything else.
  List<TransferView> get transfers => _filesPlugin.transfers;

  /// An inbound file awaiting the user's decision — owned by _filesPlugin.
  IncomingFilePrompt? get incomingFilePrompt => _filesPlugin.incomingFilePrompt;

  PairingPrompt? pairingPrompt;

  /// Outgoing pairing in flight, so the UI can show the verification code.
  String? outgoingPairingName;
  String? outgoingPairingCode;

  final _toastController = StreamController<String>.broadcast();
  Stream<String> get toasts => _toastController.stream;

  Timer? _mediaTicker;
  StreamSubscription? _nativeEvents;
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
          onMessage: _onMessage,
          onDeviceInfo: _onDeviceInfo,
          onUnpair: _onUnpair,
          onClosed: (_, error) => _refreshServiceStatus(),
        ),
        onPairingRequest: _onPairingRequest,
        // A closure, not a direct tear-off: _filesPlugin is assigned after
        // this ConnectionManager is constructed (same pattern as _plugins
        // below), so evaluating _filesPlugin.handleTransferOffer here
        // directly would throw before it exists. Deferring to a closure
        // means it is only read once a transfer actually arrives.
        onTransferOffer: (conn, peer, offer) =>
            _filesPlugin.handleTransferOffer(conn, peer, offer),
        onSessionChange: (deviceId, connected) {
          if (connected) {
            _store.touchLastSeen(deviceId);
            final session = _manager.session(deviceId);
            if (session != null) {
              _plugins.onPeerConnected(PeerRef(deviceId, session.peerInfo));
            }
          } else {
            // Media's onPeerDisconnected stops showing "now playing" for a
            // device that just dropped.
            _plugins.onPeerDisconnected(deviceId);
          }
          // Connections changing is exactly what the ongoing "connected
          // devices" notification exists to reflect.
          _refreshServiceStatus();
          notifyListeners();
        },
      );

      _plugins = PluginRegistry(_PluginHost(this));
      _healthPlugin = HealthPlugin(deviceId);
      _plugins.register(_healthPlugin);
      _notifsPlugin = NotificationsPlugin(
        resolveName: (deviceId, fallback) => _store.trusted(deviceId)?.name ?? fallback,
        generateId: () => _uuid.v4(),
      );
      _plugins.register(_notifsPlugin);
      _clipPlugin = ClipboardPlugin(
        deviceId: deviceId,
        deviceName: () => deviceName,
        resolveName: (deviceId, fallback) => _store.trusted(deviceId)?.name ?? fallback,
      );
      _plugins.register(_clipPlugin);
      _mediaPlugin = MediaPlugin(
        resolveName: (deviceId, fallback) => _store.trusted(deviceId)?.name ?? fallback,
      );
      _plugins.register(_mediaPlugin);
      _filesPlugin = FilesPlugin(
        resolveName: (deviceId, fallback) => _store.trusted(deviceId)?.name ?? fallback,
        generateId: () => _uuid.v4(),
        downloadDir: () => downloadDir,
      );
      _plugins.register(_filesPlugin);

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

      await _plugins.startAll();
      _startMediaTicker();
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
    // The ongoing "connected devices" notification is always on — it is the
    // one persistent, undismissable proof the ecosystem is actually reachable,
    // so it does not make sense to hide it behind the background-sync toggle.
    await NativeBridge.startBackgroundService(status: 'Waiting for your devices');
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

  /// True from the moment a share-sheet intent arrives until the native side
  /// finishes copying the shared bytes out of the content:// URI — lets the
  /// UI show a spinner during that (now background-thread) copy instead of
  /// appearing to do nothing.
  bool importingSharedFiles = false;

  void _onNativeEvent(Map<String, dynamic> event) {
    switch (event['type'] as String?) {
      case 'shared_files_importing':
        importingSharedFiles = true;
        notifyListeners();
        break;

      case 'shared_files':
        importingSharedFiles = false;
        final paths = (event['paths'] as List?)?.map((e) => e.toString()) ?? const [];
        pendingSharedFiles.addAll(paths);
        notifyListeners();
        break;

      case 'notification_posted':
        _notifsPlugin.forwardLocal(event);
        break;

      case 'notification_action':
        _onNotificationAction(event);
        break;

      case 'media_state_local':
        _mediaPlugin.broadcastLocalState(event);
        break;
    }
  }

  /// Handles a tap on the media or "Send clipboard" notification action
  /// buttons, forwarded up from [NotificationActionReceiver] on the Android
  /// side. If this fires while the app is not actually connected to anything
  /// (e.g. the process had been killed and this was queued from before), the
  /// underlying calls fail silently rather than throwing into native code.
  void _onNotificationAction(Map<String, dynamic> event) {
    switch (event['kind'] as String?) {
      case 'clipboard':
        // The native side just brought the app's window to the foreground
        // (see NotificationActionReceiver.ACTION_SEND_CLIPBOARD) so this can
        // actually read the clipboard, but that focus change trails this
        // event by a moment on some Android versions — same settle used by
        // resyncOnResume for the identical restriction.
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          pushClipboard().catchError((error) {
            _toastController.add(error.toString());
          });
        });
        break;
      case 'media':
        final targetDeviceId = event['device_id'] as String?;
        final command = event['command'] as String?;
        if (targetDeviceId != null && command != null) {
          // The notification's session callback (a drag on the lock-screen or
          // inline scrubber) carries the seek target in `position`; button taps
          // for the other commands don't set it.
          final position = event['position'] as int?;
          sendMediaCommand(targetDeviceId, command, position: position).catchError((_) {});
        }
        break;
    }
  }


  // ----------------------------------------------------- PeerAuthorizer

  @override
  String? trustedKey(String deviceId) => _store.trustedKey(deviceId);

  @override
  bool get pairingAllowed => settings.acceptNewPairing;

  // ------------------------------------------------------- session events

  /// Reproduces, verbatim, the dispatch that used to be a fixed callback per
  /// feature on transport's SessionHandler — this is Step 0 of the
  /// plugin-architecture migration (see plan): the interface core exposes
  /// has shrunk to a single generic onMessage, but until each feature is
  /// actually extracted into its own plugin, this switch keeps behaving
  /// exactly as before. Later steps replace each case with a plugin lookup.
  void _onMessage(Session session, String msgType, Map<String, dynamic> raw) {
    // Every feature message type is now handled by a registered plugin
    // (device-health, notifications, clipboard, media); this just offers it
    // to the registry, which silently no-ops for anything unclaimed.
    _plugins.onMessage(session, msgType, raw);
  }

  /// The latest health reported by a peer, or null if none yet.
  DeviceHealth? healthOf(String deviceId) => _healthPlugin.healthOf(deviceId);

  /// The latest media state reported by a peer, or null if none yet.
  MediaState? mediaOf(String deviceId) => _mediaPlugin.mediaOf(deviceId);

  /// The peer's playback position interpolated forward to "now" — see
  /// MediaPlugin.interpolatedMediaOf for why this is needed.
  MediaState? interpolatedMediaOf(String deviceId) => _mediaPlugin.interpolatedMediaOf(deviceId);

  /// Sends one remote-input event to a device, if it is connected.
  Future<void> sendRemoteInput(String deviceId, RemoteInput input) async {
    try {
      await _manager.sendTo(deviceId, input.toJson());
    } catch (_) {
      // The device dropped off; the UI will reflect it on the next rebuild.
    }
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

    // The in-app dialog only appears while the app is actually in the
    // foreground; without this, a request arriving while the phone is
    // locked or the app is backgrounded produced no visible sign at all.
    // A high-priority, full-screen-intent notification wakes the screen and
    // opens the app the same way an incoming call would.
    unawaited(NativeBridge.showPairingRequest(request.name));

    // Time out rather than holding the connection open forever on a request
    // the user never saw.
    final decision = await completer.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () => const PairingDecision(false, 'no response in time'),
    );

    pairingPrompt = null;
    unawaited(NativeBridge.clearPairingRequest());
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
  void respondToIncomingFile(bool accept) => _filesPlugin.respondToIncomingFile(accept);

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
  Future<void> sendFiles(String targetDeviceId, List<String> paths) =>
      _filesPlugin.sendFiles(targetDeviceId, paths);

  /// Sends the current clipboard to the ecosystem immediately.
  Future<void> pushClipboard() async {
    await _clipPlugin.pushNow();
    _toastController.add('Clipboard sent');
  }

  Future<void> copyToClipboard(String text) => _clipPlugin.setClipboard(text);

  /// Called when WeDrop returns to the foreground: resyncs the clipboard and
  /// kicks every trusted peer to reconnect immediately.
  ///
  /// Two separate Android restrictions motivate this. First, an app may only
  /// read the clipboard while it is the focused app, so a copy made in another
  /// app (Chrome, a chat) cannot be picked up by the background poller —
  /// resuming is the one reliable moment to catch it. Second, a backgrounded
  /// app's timers can be throttled under Doze, so a peer that never actually
  /// left the network can still look disconnected until the normal retry timer
  /// gets around to it; kicking every peer on resume collapses that wait to
  /// "now" instead of however long backoff has left.
  Future<void> resyncOnResume() async {
    if (!_started) return;

    _manager.retryAllNow();

    // Clipboard access is only granted once the window is fully focused, which
    // trails the resume event by a moment on some Android versions; without a
    // short settle the read can still return the previous value.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _clipPlugin.checkNow();
  }

  /// Sends a media command to a peer.
  ///
  /// Failures (most commonly "device is not connected") are surfaced as a
  /// toast rather than left as a silently dropped Future — pressing play/pause
  /// with no visible effect and no error either is indistinguishable from the
  /// button simply not working.
  Future<void> sendMediaCommand(
    String targetDeviceId,
    String command, {
    int? position,
    int? volume,
    String? playerId,
    String? deviceId,
    String? appId,
    bool? muted,
  }) async {
    try {
      await _mediaPlugin.sendCommand(
        targetDeviceId,
        command,
        position: position,
        volume: volume,
        playerId: playerId,
        deviceId: deviceId,
        appId: appId,
        muted: muted,
      );
    } catch (error) {
      final name = _store.trusted(targetDeviceId)?.name ?? 'that device';
      _toastController.add('Could not reach $name: $error');
      rethrow;
    }
  }

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

    // The connected-devices notification/service is always on now (see
    // _wireNativeBridge), so this setting no longer starts or stops it; it is
    // left in place only as a stored preference in case it is needed again.

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
    _clipPlugin.clear();
    notifyListeners();
  }

  void clearNotifications() {
    notifications.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------- internals

  /// Wakes the UI once a second while any known peer is actively playing with
  /// a known duration, so [interpolatedMediaOf] has a reason to be re-read and
  /// progress bars visibly move. It is a no-op — no timer work, no rebuilds —
  /// whenever nothing currently qualifies (nothing playing, or a source like
  /// Windows that cannot report a duration to interpolate against).
  void _startMediaTicker() {
    _mediaTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_mediaPlugin.anyAnimating()) notifyListeners();
    });
  }

  void _refreshServiceStatus() {
    final connected = _manager.connectedDevices
        .map((id) => _store.trusted(id)?.name)
        .whereType<String>()
        .toList();

    final status = switch (connected.length) {
      0 => 'Waiting for your devices',
      1 => '${connected.first} connected',
      2 => '${connected[0]} and ${connected[1]} connected',
      _ => '${connected.length} devices connected',
    };
    NativeBridge.updateServiceStatus(status);
  }

  /// Lets _PluginHost.emit trigger a rebuild without exposing the protected
  /// ChangeNotifier.notifyListeners() outside this class.
  void _notifyPlugins() => notifyListeners();

  @override
  void dispose() {
    _mediaTicker?.cancel();
    _nativeEvents?.cancel();
    // Only tear down the network stack if it actually came up; a startup that
    // failed early leaves these late fields unset.
    if (_started) {
      _plugins.stopAll();
      _manager.stop();
      _discovery.dispose();
    }
    _toastController.close();
    super.dispose();
  }
}

/// Gives every registered plugin's API a way to reach real peers and
/// surface events, without any plugin importing ConnectionManager or
/// Flutter directly. A plugin event is mapped to notifyListeners() since
/// today no plugin event has a dedicated UI listener — a plugin's state
/// (e.g. health readings) is read back out through AppService's own
/// passthrough getters, so a rebuild is all a listener needs.
class _PluginHost implements PluginHost {
  final AppService _service;
  _PluginHost(this._service);

  @override
  Future<void> send(String deviceId, Map<String, dynamic> message) =>
      _service._manager.sendTo(deviceId, message);

  @override
  void broadcast(String capability, Map<String, dynamic> message) {
    _service._manager.broadcast(capability, message);
  }

  @override
  List<PeerRef> connectedPeers(String capability) {
    final out = <PeerRef>[];
    for (final deviceId in _service._manager.connectedDevices) {
      final session = _service._manager.session(deviceId);
      if (session == null) continue;
      if (capability.isNotEmpty && !session.supports(capability)) continue;
      out.add(PeerRef(deviceId, session.peerInfo));
    }
    return out;
  }

  @override
  bool allows(String deviceId, String capability) => _service._store.allows(deviceId, capability);

  @override
  void emit(PluginEvent event) {
    // Clipboard's "received" event carries the sender's display name and
    // used to always surface a toast. Files' "toast" event carries a
    // ready-made message directly. Both predate the plugin architecture as
    // specific UI side effects beyond a rebuild.
    if (event.plugin == Capability.clipboard && event.name == 'received') {
      _service._toastController.add('Clipboard from ${event.payload}');
    } else if (event.plugin == Capability.files && event.name == 'toast') {
      _service._toastController.add(event.payload as String);
    }
    _service._notifyPlugins();
  }

  @override
  Future<HandshakeResult> dialTransfer(String deviceId) async {
    final peer = _service._discovery.peer(deviceId);
    final key = _service._store.trustedKey(deviceId);
    if (peer == null) throw Exception('that device is not on the network right now');
    if (key == null) throw Exception('that device is not in your ecosystem');

    return dialHandshake(
      host: peer.ip,
      port: peer.tcpPort,
      local: _service._localInfo,
      intent: Intent.transfer,
      expectedKey: key,
      timeout: const Duration(seconds: 8),
    );
  }

  // Bridges each plugin's own settings shape from the existing shared
  // Settings object, until the settings/capability de-hardcoding migration
  // gives every plugin real, independently persisted settings. Read fresh
  // every call, matching how the pre-plugin code always read
  // AppService.settings live rather than caching a copy.
  @override
  Map<String, dynamic> loadPluginSettings(PluginId id) {
    switch (id) {
      case Capability.notifications:
        return {
          'receive': _service.settings.receiveNotifications,
          'share': _service.settings.shareNotifications,
        };
      case Capability.clipboard:
        return {
          'auto_sync': _service.settings.autoSyncClipboard,
          'receive': _service.settings.receiveClipboard,
          'max_chars': _service.settings.clipboardMaxChars,
        };
      case Capability.media:
        return {'allow_control': _service.settings.allowMediaControl};
      case Capability.files:
        return {
          'auto_accept': _service.settings.autoAcceptFiles,
          'download_dir': _service.downloadDir,
        };
    }
    return const {};
  }

  @override
  Future<void> savePluginSettings(PluginId id, Map<String, dynamic> data) async {}
}

