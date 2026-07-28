import 'dart:async';

import '../protocol/messages.dart';
import 'framing.dart';

/// Keepalive cadence. Long enough that the radio stays mostly asleep, short
/// enough that a dead peer is noticed within tens of seconds.
const Duration keepaliveInterval = Duration(seconds: 25);

/// How long a session waits for any traffic before declaring the peer gone.
const Duration sessionReadTimeout = Duration(seconds: 70);

/// Callbacks for messages arriving on a control session.
///
/// Only onDeviceInfo/onUnpair/onClosed are genuinely core (peer/session
/// bookkeeping) and get their own callback. Every feature message
/// (clipboard, notification, media, media_state, health, and any future
/// type) arrives through the single onMessage callback instead of one
/// hard-coded callback per feature — this is what lets a plugin registry
/// route messages by type without the transport layer knowing the feature
/// list.
class SessionHandler {
  final void Function(Session session, String msgType, Map<String, dynamic> raw)? onMessage;
  final void Function(Session session, DeviceInfo info)? onDeviceInfo;
  final void Function(Session session)? onUnpair;
  final void Function(Session session, Object? error)? onClosed;

  const SessionHandler({
    this.onMessage,
    this.onDeviceInfo,
    this.onUnpair,
    this.onClosed,
  });
}

/// A live control channel with one peer.
class Session {
  final SecureConnection connection;
  final SessionHandler handler;

  DeviceInfo peerInfo;
  Timer? _keepalive;
  int _pingSeq = 0;
  bool _running = false;
  bool _closed = false;

  Session({
    required this.connection,
    required this.peerInfo,
    required this.handler,
  });

  String get deviceId => connection.peerDeviceId;

  /// Whether the peer advertised a capability.
  ///
  /// A peer that has not sent its list yet is assumed to support everything,
  /// so the first moments of a session are not silently lossy.
  bool supports(String capability) =>
      peerInfo.capabilities.isEmpty || peerInfo.hasCapability(capability);

  Future<void> send(Map<String, dynamic> message) => connection.writeJson(message);

  /// Drives the session until the connection fails or [close] is called.
  Future<void> run() async {
    if (_running) return;
    _running = true;

    _keepalive = Timer.periodic(keepaliveInterval, (_) async {
      try {
        await send(pingMessage(++_pingSeq));
      } catch (_) {
        await close();
      }
    });

    Object? failure;
    try {
      while (!_closed) {
        final message = await connection.readJson().timeout(sessionReadTimeout);
        await _dispatch(message);
      }
    } catch (error) {
      failure = error;
    }

    await close();
    handler.onClosed?.call(this, failure);
  }

  Future<void> _dispatch(Map<String, dynamic> message) async {
    switch (message['type'] as String?) {
      case MsgType.ping:
        await send(pongMessage(message['seq'] as int? ?? 0));
        break;

      case MsgType.pong:
        break; // the read itself is the liveness signal

      case MsgType.deviceInfo:
        peerInfo = DeviceInfo.fromJson(message);
        handler.onDeviceInfo?.call(this, peerInfo);
        break;

      case MsgType.unpair:
        handler.onUnpair?.call(this);
        break;

      default:
        // Every feature message type (clipboard, notification, media,
        // media_state, health, and anything a future plugin adds) is routed
        // generically — the transport layer does not know or care what
        // these types mean, only that something claimed them.
        final type = message['type'] as String?;
        if (type != null) {
          handler.onMessage?.call(this, type, message);
        }
        break;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _keepalive?.cancel();
    _keepalive = null;
    await connection.close();
  }
}
