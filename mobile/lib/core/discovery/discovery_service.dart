import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol/messages.dart';

/// Announces this device on the LAN and tracks the peers it hears from.
///
/// The old version broadcast a hard-coded `127.0.0.1` as its address, so every
/// desktop that heard a phone tried to connect to itself and timed out. This
/// one leaves the address to the receiver, which reads it from the datagram's
/// real source — the only value guaranteed to be routable back.
class DiscoveryService {
  static const String multicastIP = '239.255.90.90';
  static const Duration announceInterval = Duration(seconds: 5);

  /// Several announce intervals, so one dropped UDP packet — routine on busy
  /// Wi-Fi — never flickers a device offline.
  static const Duration peerTtl = Duration(seconds: 18);

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _reapTimer;

  DiscoveryMessage config;

  final Map<String, DiscoveryMessage> _peers = {};
  final _peerController = StreamController<DiscoveryMessage>.broadcast();
  final _lostController = StreamController<String>.broadcast();

  Stream<DiscoveryMessage> get onPeer => _peerController.stream;
  Stream<String> get onPeerLost => _lostController.stream;

  DiscoveryService(this.config);

  /// A snapshot of every peer still within its TTL.
  List<DiscoveryMessage> get peers {
    final cutoff = DateTime.now().subtract(peerTtl);
    return _peers.values.where((p) => p.lastSeen.isAfter(cutoff)).toList();
  }

  DiscoveryMessage? peer(String deviceId) {
    final p = _peers[deviceId];
    if (p == null || DateTime.now().difference(p.lastSeen) > peerTtl) return null;
    return p;
  }

  bool isOnline(String deviceId) => peer(deviceId) != null;

  bool get isRunning => _socket != null;

  Future<void> start() async {
    if (_socket != null) return;

    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
      reusePort: false,
    );
    socket
      ..broadcastEnabled = true
      ..multicastHops = 1
      ..multicastLoopback = false;

    try {
      socket.joinMulticast(InternetAddress(multicastIP));
    } catch (_) {
      // Plenty of networks block multicast; the broadcast paths still work.
    }

    socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram != null) _handleDatagram(datagram);
      },
      onError: (_) {},
      cancelOnError: false,
    );

    _socket = socket;
    _announceTimer = Timer.periodic(announceInterval, (_) => announce());
    _reapTimer = Timer.periodic(const Duration(seconds: 3), (_) => _reap());

    // Ask anyone already on the network to speak up, so the list fills in
    // immediately instead of after a full announce interval.
    _sendQuery();
    announce();
  }

  /// Updates what we announce, e.g. after a rename, and re-announces at once.
  void updateConfig(DiscoveryMessage next) {
    config = next;
    if (_socket != null) announce();
  }

  void _handleDatagram(Datagram datagram) {
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map<String, dynamic>) return;
      json = decoded;
    } catch (_) {
      return;
    }

    final type = json['type'] as String?;
    final deviceId = json['device_id'] as String?;
    if (deviceId == null || deviceId == config.deviceId) return;

    switch (type) {
      case MsgType.discoveryQuery:
        announce();
        break;

      case MsgType.discoveryBye:
        if (_peers.remove(deviceId) != null) _lostController.add(deviceId);
        break;

      case MsgType.discovery:
        final msg = DiscoveryMessage.fromJson(json);
        if (msg.version != protocolVersion) return;
        if (msg.publicKey.isEmpty || msg.tcpPort <= 0) return;

        // Trust the datagram's source address over whatever the peer claimed.
        final peer = msg.copyWith(
          ip: datagram.address.address,
          lastSeen: DateTime.now(),
        );

        final existing = _peers[deviceId];
        final isNew = existing == null ||
            DateTime.now().difference(existing.lastSeen) > peerTtl;
        final changed = existing != null &&
            (existing.ip != peer.ip ||
                existing.publicKey != peer.publicKey ||
                existing.name != peer.name);

        _peers[deviceId] = peer;
        if (isNew || changed) _peerController.add(peer);
        break;
    }
  }

  void _reap() {
    final cutoff = DateTime.now().subtract(peerTtl);
    final lost = _peers.entries
        .where((e) => e.value.lastSeen.isBefore(cutoff))
        .map((e) => e.key)
        .toList();

    for (final deviceId in lost) {
      _peers.remove(deviceId);
      _lostController.add(deviceId);
    }
  }

  void announce() => _send(config.toJson());

  void _sendQuery() => _send({
        'type': MsgType.discoveryQuery,
        'version': protocolVersion,
        'device_id': config.deviceId,
      });

  void _sendBye() => _send({
        'type': MsgType.discoveryBye,
        'version': protocolVersion,
        'device_id': config.deviceId,
      });

  /// Fans a datagram out over multicast, the global broadcast address, and each
  /// interface's directed broadcast. Networks differ in which they permit —
  /// Android hotspots in particular drop some of these — so all three are used
  /// rather than trying to detect the environment.
  Future<void> _send(Map<String, dynamic> message) async {
    final socket = _socket;
    if (socket == null) return;

    final bytes = utf8.encode(jsonEncode(message));

    void sendTo(String address) {
      try {
        socket.send(bytes, InternetAddress(address), discoveryPort);
      } catch (_) {
        // One unreachable target must not stop the others.
      }
    }

    sendTo(multicastIP);
    sendTo('255.255.255.255');

    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback) continue;
          final parts = address.address.split('.');
          if (parts.length == 4) {
            // Hotspot and home subnets are effectively always /24.
            sendTo('${parts[0]}.${parts[1]}.${parts[2]}.255');
          }
        }
      }
    } catch (_) {
      // Interface enumeration can fail on restricted networks; ignore.
    }
  }

  Future<void> stop() async {
    if (_socket == null) return;

    _sendBye();
    _announceTimer?.cancel();
    _reapTimer?.cancel();
    _announceTimer = null;
    _reapTimer = null;

    try {
      _socket?.leaveMulticast(InternetAddress(multicastIP));
    } catch (_) {}

    _socket?.close();
    _socket = null;
    _peers.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _peerController.close();
    await _lostController.close();
  }
}
