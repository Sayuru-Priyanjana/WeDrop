import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../discovery/discovery_service.dart';
import '../protocol/messages.dart';
import 'framing.dart';
import 'handshake.dart';
import 'session.dart';

const Duration _dialTimeout = Duration(seconds: 5);
const Duration _reconnectEvery = Duration(seconds: 4);
const Duration _minBackoff = Duration(seconds: 2);
const Duration _maxBackoff = Duration(seconds: 60);

/// A device asking to join this ecosystem, already authenticated.
class PairingRequest {
  final String deviceId;
  final String name;
  final String platform;
  final String formFactor;
  final String publicKey;
  final String verificationCode;
  final String address;

  const PairingRequest({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.formFactor,
    required this.publicKey,
    required this.verificationCode,
    required this.address,
  });
}

/// The user's verdict on a [PairingRequest].
class PairingDecision {
  final bool accepted;
  final String reason;
  const PairingDecision(this.accepted, [this.reason = '']);
}

class _Backoff {
  DateTime next = DateTime.fromMillisecondsSinceEpoch(0);
  Duration duration = _minBackoff;
}

class _SessionEntry {
  final Session session;
  final bool outbound;
  const _SessionEntry(this.session, this.outbound);
}

/// Owns the TCP listener, keeps a session open to every trusted peer that is
/// online, and routes inbound connections by intent.
class ConnectionManager {
  final LocalInfo local;
  final DiscoveryService discovery;
  final PeerAuthorizer auth;
  final SessionHandler handler;

  /// Called when an untrusted device asks to join. May await the user.
  final Future<PairingDecision> Function(PairingRequest request)? onPairingRequest;

  /// Called for an inbound transfer connection. The callee owns the connection
  /// and must close it.
  final Future<void> Function(SecureConnection conn, DeviceInfo peer, TransferOffer offer)?
      onTransferOffer;

  /// Fires whenever a peer connects or disconnects.
  final void Function(String deviceId, bool connected)? onSessionChange;

  /// Supplies the device info sent when a session opens.
  final DeviceInfo Function() localDeviceInfo;

  ServerSocket? _server;
  Timer? _maintainTimer;

  final Map<String, _SessionEntry> _sessions = {};
  final Set<String> _dialing = {};
  final Map<String, _Backoff> _backoff = {};
  final _random = Random();

  ConnectionManager({
    required this.local,
    required this.discovery,
    required this.auth,
    required this.handler,
    required this.localDeviceInfo,
    this.onPairingRequest,
    this.onTransferOffer,
    this.onSessionChange,
  });

  int get port => _server?.port ?? 0;

  List<String> get connectedDevices => _sessions.keys.toList();

  bool isConnected(String deviceId) => _sessions.containsKey(deviceId);

  Session? session(String deviceId) => _sessions[deviceId]?.session;

  /// Binds the listener and begins maintaining sessions, returning the port
  /// actually bound. Announcing a port the listener failed to claim is what
  /// made peers report endless connection failures with no visible cause.
  Future<int> start() async {
    if (_server != null) return _server!.port;

    ServerSocket server;
    try {
      server = await ServerSocket.bind(InternetAddress.anyIPv4, transportPort, shared: false);
    } catch (_) {
      // Fall back to an ephemeral port rather than disabling the app entirely.
      server = await ServerSocket.bind(InternetAddress.anyIPv4, 0, shared: false);
    }

    _server = server;
    server.listen(
      _handleInbound,
      onError: (_) {},
      cancelOnError: false,
    );

    _maintainTimer = Timer.periodic(_reconnectEvery, (_) => _connectMissing());
    return server.port;
  }

  Future<void> stop() async {
    _maintainTimer?.cancel();
    _maintainTimer = null;

    final sessions = _sessions.values.toList();
    _sessions.clear();
    for (final entry in sessions) {
      await entry.session.close();
    }

    await _server?.close();
    _server = null;
  }

  // ------------------------------------------------------------- inbound

  Future<void> _handleInbound(Socket socket) async {
    HandshakeResult result;
    try {
      result = await acceptHandshake(socket: socket, local: local, auth: auth);
    } catch (_) {
      // acceptHandshake already wrote a reason and destroyed the socket.
      return;
    }

    switch (result.intent) {
      case Intent.pair:
        await _handlePairing(result, socket.remoteAddress.address);
        break;
      case Intent.session:
        await _adoptSession(result, outbound: false);
        break;
      case Intent.transfer:
        await _handleInboundTransfer(result);
        break;
      default:
        await result.connection.close();
    }
  }

  Future<void> _handlePairing(HandshakeResult result, String address) async {
    try {
      if (onPairingRequest == null) {
        await result.connection.writeJson({
          'type': MsgType.pairingResp,
          'device_id': local.identity.deviceId,
          'accepted': false,
          'reason': 'this device cannot accept pairing right now',
        });
        return;
      }

      final decision = await onPairingRequest!(PairingRequest(
        deviceId: result.peer.deviceId,
        name: result.peer.name,
        platform: result.peer.platform,
        formFactor: result.peer.formFactor,
        publicKey: result.peerPublicKey,
        verificationCode: result.verificationCode,
        address: address,
      ));

      await result.connection.writeJson({
        'type': MsgType.pairingResp,
        'device_id': local.identity.deviceId,
        'name': local.name,
        'accepted': decision.accepted,
        if (decision.reason.isNotEmpty) 'reason': decision.reason,
      });

      if (decision.accepted) {
        // Connect straight away rather than waiting for the next tick, so the
        // device turns green the moment the user taps Accept.
        reconnectNow(result.peer.deviceId);
      }
    } catch (_) {
      // The peer hung up mid-decision; nothing left to do.
    } finally {
      await result.connection.close();
    }
  }

  Future<void> _handleInboundTransfer(HandshakeResult result) async {
    if (onTransferOffer == null) {
      await result.connection.close();
      return;
    }

    try {
      final message = await result.connection.readJson().timeout(const Duration(seconds: 30));
      if (message['type'] != MsgType.transferOffer) {
        await result.connection.close();
        return;
      }
      // The callee owns the connection from here, including closing it.
      await onTransferOffer!(
        result.connection,
        result.peer,
        TransferOffer.fromJson(message),
      );
    } catch (_) {
      await result.connection.close();
    }
  }

  // ------------------------------------------------------------ outbound

  Future<void> _connectMissing() async {
    for (final peer in discovery.peers) {
      final key = auth.trustedKey(peer.deviceId);
      if (key == null) continue;
      if (!_shouldDial(peer.deviceId)) continue;

      _dialing.add(peer.deviceId);
      // Deliberately not awaited: one slow peer must never delay the rest.
      unawaited(_dialPeer(peer, key));
    }
  }

  bool _shouldDial(String deviceId) {
    if (_sessions.containsKey(deviceId)) return false;
    if (_dialing.contains(deviceId)) return false;

    final backoff = _backoff[deviceId];
    if (backoff != null && DateTime.now().isBefore(backoff.next)) return false;
    return true;
  }

  Future<void> _dialPeer(DiscoveryMessage peer, String expectedKey) async {
    try {
      final result = await dialHandshake(
        host: peer.ip,
        port: peer.tcpPort,
        local: local,
        intent: Intent.session,
        expectedKey: expectedKey,
        timeout: _dialTimeout,
      );
      _backoff.remove(peer.deviceId);
      await _adoptSession(result, outbound: true);
    } catch (_) {
      _noteFailure(peer.deviceId);
    } finally {
      _dialing.remove(peer.deviceId);
    }
  }

  void _noteFailure(String deviceId) {
    final backoff = _backoff.putIfAbsent(deviceId, _Backoff.new);
    backoff.duration = Duration(
      milliseconds: min(backoff.duration.inMilliseconds * 2, _maxBackoff.inMilliseconds),
    );
    // Jitter keeps a roomful of devices from retrying in lockstep after the
    // access point restarts.
    final jitter = _random.nextInt(max(1, backoff.duration.inMilliseconds ~/ 4));
    backoff.next = DateTime.now().add(backoff.duration + Duration(milliseconds: jitter));
  }

  /// Clears any backoff for a device and tries it immediately.
  void reconnectNow(String deviceId) {
    _backoff.remove(deviceId);
    discovery.announce();

    final peer = discovery.peer(deviceId);
    final key = auth.trustedKey(deviceId);
    if (peer == null || key == null || !_shouldDial(deviceId)) return;

    _dialing.add(deviceId);
    unawaited(_dialPeer(peer, key));
  }

  /// Retries every trusted, currently-visible peer at once, clearing backoff.
  ///
  /// Called when the app returns to the foreground: a stretch backgrounded may
  /// have let Android throttle timers under Doze, so peers can look stale even
  /// though they never actually left the network. This collapses the wait back
  /// to "now" instead of the remaining backoff or the next maintenance tick.
  void retryAllNow() {
    discovery.announce();
    for (final peer in discovery.peers) {
      if (auth.trustedKey(peer.deviceId) == null) continue;
      _backoff.remove(peer.deviceId);
      if (!_shouldDial(peer.deviceId)) continue;
      _dialing.add(peer.deviceId);
      unawaited(_dialPeer(peer, auth.trustedKey(peer.deviceId)!));
    }
  }

  // ------------------------------------------------------------ sessions

  /// Installs a new session, resolving the case where both devices dialled each
  /// other at the same moment.
  ///
  /// Both ends apply the same rule — keep the connection dialled by whichever
  /// device has the smaller ID — so they independently agree on which socket
  /// survives, instead of each closing the other's and ending up with none.
  Future<void> _adoptSession(HandshakeResult result, {required bool outbound}) async {
    final deviceId = result.peer.deviceId;
    final existing = _sessions[deviceId];

    if (existing != null) {
      final preferOutbound = local.identity.deviceId.compareTo(deviceId) < 0;
      if (existing.outbound == preferOutbound || outbound != preferOutbound) {
        await result.connection.close();
        return;
      }
      _sessions.remove(deviceId);
      await existing.session.close();
    }

    final session = Session(
      connection: result.connection,
      peerInfo: result.peer,
      handler: SessionHandler(
        onMessage: handler.onMessage,
        onDeviceInfo: handler.onDeviceInfo,
        onUnpair: handler.onUnpair,
        onClosed: (s, error) {
          // Only forget the session if it is still the registered one; a
          // replaced duplicate closing later must not evict its successor.
          if (identical(_sessions[s.deviceId]?.session, s)) {
            _sessions.remove(s.deviceId);
            onSessionChange?.call(s.deviceId, false);
          }
          handler.onClosed?.call(s, error);
        },
      ),
    );

    _sessions[deviceId] = _SessionEntry(session, outbound);
    onSessionChange?.call(deviceId, true);

    unawaited(session.send(localDeviceInfo().toJson()).catchError((_) {}));
    unawaited(session.run());
  }

  Future<void> disconnect(String deviceId) async {
    final entry = _sessions.remove(deviceId);
    await entry?.session.close();
  }

  /// Sends a message to every connected peer that advertised [capability].
  /// An empty capability sends to everyone.
  Future<void> broadcast(String capability, Map<String, dynamic> message) async {
    for (final entry in _sessions.values.toList()) {
      if (capability.isNotEmpty && !entry.session.supports(capability)) continue;
      try {
        await entry.session.send(message);
      } catch (_) {
        await entry.session.close();
      }
    }
  }

  Future<void> sendTo(String deviceId, Map<String, dynamic> message) async {
    final entry = _sessions[deviceId];
    if (entry == null) throw StateError('that device is not connected');
    await entry.session.send(message);
  }

  /// Re-advertises capabilities after a settings change, so peers stop sending
  /// things the user just switched off.
  Future<void> broadcastDeviceInfo() => broadcast('', localDeviceInfo().toJson());
}
