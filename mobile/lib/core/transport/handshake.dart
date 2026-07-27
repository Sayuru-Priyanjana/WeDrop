import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/identity.dart';
import '../protocol/messages.dart';
import 'framing.dart';

const int _nonceSize = 16;
const Duration handshakeTimeout = Duration(seconds: 10);

final _random = Random.secure();

Uint8List _randomBytes(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = _random.nextInt(256);
  }
  return bytes;
}

/// Describes this device to the peer during a handshake.
class LocalInfo {
  final DeviceIdentity identity;
  final String name;
  final String platform;
  final String formFactor;

  const LocalInfo({
    required this.identity,
    required this.name,
    this.platform = 'android',
    this.formFactor = FormFactor.phone,
  });
}

/// Answers the two questions the handshake must ask before handing out a key.
abstract class PeerAuthorizer {
  /// The identity key stored for a device, or null when it is not paired.
  String? trustedKey(String deviceId);

  /// Whether this device is currently willing to consider new pairings.
  bool get pairingAllowed;
}

/// An explicit refusal from the other device, as opposed to a network failure.
class PeerException implements Exception {
  final String code;
  final String message;

  const PeerException(this.code, this.message);

  /// True when the peer says it does not know us — the one failure worth
  /// turning into "pair this device again" in the UI.
  bool get isNotPaired => code == ErrCode.notPaired || code == ErrCode.keyMismatch;

  @override
  String toString() => message.isEmpty ? code : message;
}

/// A completed, authenticated handshake.
class HandshakeResult {
  final SecureConnection connection;
  final String intent;
  final DeviceInfo peer;

  /// The key the peer proved possession of. Pairing stores this rather than
  /// anything from a UDP announcement, which is trivially spoofed.
  final String peerPublicKey;
  final String verificationCode;

  const HandshakeResult({
    required this.connection,
    required this.intent,
    required this.peer,
    required this.peerPublicKey,
    required this.verificationCode,
  });
}

/// Opens an authenticated connection to a peer.
///
/// [expectedKey] is the identity key the peer must prove. It is required for
/// session and transfer intents; for pairing it is null, because the whole
/// point is that we do not know the key yet and the users compare the code.
Future<HandshakeResult> dialHandshake({
  required String host,
  required int port,
  required LocalInfo local,
  required String intent,
  String? expectedKey,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final socket = await Socket.connect(host, port, timeout: timeout);
  // Small control messages should leave immediately; Nagle's algorithm
  // otherwise adds tens of milliseconds to every clipboard sync.
  socket.setOption(SocketOption.tcpNoDelay, true);

  final reader = FrameReader(socket);

  try {
    return await _clientHandshake(socket, reader, local, intent, expectedKey)
        .timeout(handshakeTimeout);
  } catch (_) {
    await reader.cancel();
    socket.destroy();
    rethrow;
  }
}

Future<HandshakeResult> _clientHandshake(
  Socket socket,
  FrameReader reader,
  LocalInfo local,
  String intent,
  String? expectedKey,
) async {
  final kx = await KeyExchange.generate();
  final nonceClient = _randomBytes(_nonceSize);
  final localPub = local.identity.publicKeyBytes;

  writeJsonFrame(socket, {
    'type': MsgType.handshakeInit,
    'version': protocolVersion,
    'intent': intent,
    'device_id': local.identity.deviceId,
    'name': local.name,
    'platform': local.platform,
    'form_factor': local.formFactor,
    'public_key': base64.encode(localPub),
    'ephemeral_pub': base64.encode(kx.publicKey),
    'nonce': base64.encode(nonceClient),
  });
  await socket.flush();

  final respBytes = await reader.readFrame();
  final resp = jsonDecode(utf8.decode(respBytes)) as Map<String, dynamic>;

  // The peer may refuse us outright, most often because we are not paired.
  // Surfacing its reason turns a bare "handshake failed" into something the
  // user can act on.
  if (resp['type'] == MsgType.error) {
    throw PeerException(
      resp['code'] as String? ?? ErrCode.internal,
      resp['message'] as String? ?? 'the other device refused the connection',
    );
  }
  if (resp['type'] != MsgType.handshakeResp) {
    throw PeerException(ErrCode.internal, 'unexpected reply "${resp['type']}"');
  }
  if (resp['version'] != protocolVersion) {
    throw PeerException(
      ErrCode.versionMismatch,
      'that device runs a different version of WeDrop',
    );
  }

  final peerPublicKey = resp['public_key'] as String? ?? '';

  // For an established peer the key must be exactly the one we stored. A
  // different key means either a reinstall or an impostor, and we cannot tell
  // which, so refuse and let the user re-pair deliberately.
  if (expectedKey != null && expectedKey.isNotEmpty && peerPublicKey != expectedKey) {
    throw const PeerException(
      ErrCode.keyMismatch,
      'that device\'s identity changed — remove it and pair again',
    );
  }

  final peerPub = base64.decode(peerPublicKey);
  final peerEph = base64.decode(resp['ephemeral_pub'] as String? ?? '');
  final nonceServer = base64.decode(resp['nonce'] as String? ?? '');
  final peerSig = base64.decode(resp['signature'] as String? ?? '');

  if (peerEph.length != 32 || nonceServer.length != _nonceSize) {
    throw const PeerException(ErrCode.internal, 'the other device sent malformed handshake data');
  }

  final serverDeviceId = resp['device_id'] as String? ?? '';

  final serverTranscript = buildTranscript(
    role: HandshakeRole.server,
    clientDeviceId: local.identity.deviceId,
    serverDeviceId: serverDeviceId,
    clientPub: localPub,
    serverPub: peerPub,
    clientEph: kx.publicKey,
    serverEph: peerEph,
    nonceClient: nonceClient,
    nonceServer: nonceServer,
  );

  if (!await verifySignature(
    message: serverTranscript,
    signature: peerSig,
    publicKey: peerPub,
  )) {
    throw const PeerException(
      ErrCode.badSignature,
      'the other device could not prove its identity',
    );
  }

  // Only now that the peer is authenticated do we sign anything ourselves.
  final clientTranscript = buildTranscript(
    role: HandshakeRole.client,
    clientDeviceId: local.identity.deviceId,
    serverDeviceId: serverDeviceId,
    clientPub: localPub,
    serverPub: peerPub,
    clientEph: kx.publicKey,
    serverEph: peerEph,
    nonceClient: nonceClient,
    nonceServer: nonceServer,
  );

  writeJsonFrame(socket, {
    'type': MsgType.handshakeConfirm,
    'signature': base64.encode(await local.identity.sign(clientTranscript)),
  });
  await socket.flush();

  final secret = await kx.sharedSecret(peerEph);
  final key = await deriveSessionKey(
    sharedSecret: secret,
    nonceClient: nonceClient,
    nonceServer: nonceServer,
  );
  final code = await verificationCode(key);

  final connection = SecureConnection(socket: socket, sessionKey: key, reader: reader)
    ..peerDeviceId = serverDeviceId
    ..peerName = resp['name'] as String? ?? ''
    ..verificationCode = code;

  return HandshakeResult(
    connection: connection,
    intent: intent,
    peer: DeviceInfo(
      deviceId: serverDeviceId,
      name: resp['name'] as String? ?? '',
      platform: resp['platform'] as String? ?? '',
      formFactor: resp['form_factor'] as String? ?? FormFactor.desktop,
    ),
    peerPublicKey: peerPublicKey,
    verificationCode: code,
  );
}

/// Completes the listening side of a handshake on an accepted socket.
///
/// On refusal an error frame is written first, so the dialler can tell its user
/// why instead of reporting a bare connection reset.
Future<HandshakeResult> acceptHandshake({
  required Socket socket,
  required LocalInfo local,
  required PeerAuthorizer auth,
}) async {
  socket.setOption(SocketOption.tcpNoDelay, true);
  final reader = FrameReader(socket);

  try {
    return await _serverHandshake(socket, reader, local, auth).timeout(handshakeTimeout);
  } catch (_) {
    await reader.cancel();
    socket.destroy();
    rethrow;
  }
}

void _refuse(Socket socket, String code, String message) {
  try {
    writeJsonFrame(socket, errorMessage(code, message));
  } catch (_) {
    // The socket may already be gone; the exception below is the real story.
  }
}

Future<HandshakeResult> _serverHandshake(
  Socket socket,
  FrameReader reader,
  LocalInfo local,
  PeerAuthorizer auth,
) async {
  final initBytes = await reader.readFrame();
  final init = jsonDecode(utf8.decode(initBytes)) as Map<String, dynamic>;

  if (init['type'] != MsgType.handshakeInit) {
    throw PeerException(ErrCode.internal, 'expected handshake_init, got "${init['type']}"');
  }
  if (init['version'] != protocolVersion) {
    _refuse(socket, ErrCode.versionMismatch, 'this device speaks protocol v$protocolVersion');
    throw const PeerException(ErrCode.versionMismatch, 'peer speaks a different protocol version');
  }

  final peerDeviceId = init['device_id'] as String? ?? '';
  final peerPublicKey = init['public_key'] as String? ?? '';
  final intent = init['intent'] as String? ?? '';

  if (peerDeviceId.isEmpty || peerPublicKey.isEmpty) {
    _refuse(socket, ErrCode.internal, 'incomplete handshake');
    throw const PeerException(ErrCode.internal, 'peer sent an incomplete handshake');
  }

  // Authorise before spending any time on key agreement.
  switch (intent) {
    case Intent.session:
    case Intent.transfer:
      final storedKey = auth.trustedKey(peerDeviceId);
      if (storedKey == null) {
        _refuse(socket, ErrCode.notPaired, 'this device is not in the ecosystem');
        throw const PeerException(ErrCode.notPaired, 'peer is not paired');
      }
      if (storedKey != peerPublicKey) {
        _refuse(socket, ErrCode.keyMismatch, 'identity key does not match the paired device');
        throw const PeerException(ErrCode.keyMismatch, 'peer identity key mismatch');
      }
      break;
    case Intent.pair:
      if (!auth.pairingAllowed) {
        _refuse(socket, ErrCode.notPermitted, 'this device is not accepting new pairings');
        throw const PeerException(ErrCode.notPermitted, 'pairing is switched off');
      }
      break;
    default:
      _refuse(socket, ErrCode.internal, 'unknown connection intent');
      throw PeerException(ErrCode.internal, 'unknown intent "$intent"');
  }

  final peerPub = base64.decode(peerPublicKey);
  final peerEph = base64.decode(init['ephemeral_pub'] as String? ?? '');
  final nonceClient = base64.decode(init['nonce'] as String? ?? '');

  if (peerEph.length != 32 || nonceClient.length != _nonceSize) {
    _refuse(socket, ErrCode.internal, 'malformed handshake data');
    throw const PeerException(ErrCode.internal, 'peer sent malformed handshake data');
  }

  final kx = await KeyExchange.generate();
  final nonceServer = _randomBytes(_nonceSize);
  final localPub = local.identity.publicKeyBytes;

  final serverTranscript = buildTranscript(
    role: HandshakeRole.server,
    clientDeviceId: peerDeviceId,
    serverDeviceId: local.identity.deviceId,
    clientPub: peerPub,
    serverPub: localPub,
    clientEph: peerEph,
    serverEph: kx.publicKey,
    nonceClient: nonceClient,
    nonceServer: nonceServer,
  );

  writeJsonFrame(socket, {
    'type': MsgType.handshakeResp,
    'version': protocolVersion,
    'device_id': local.identity.deviceId,
    'name': local.name,
    'platform': local.platform,
    'form_factor': local.formFactor,
    'public_key': base64.encode(localPub),
    'ephemeral_pub': base64.encode(kx.publicKey),
    'nonce': base64.encode(nonceServer),
    'signature': base64.encode(await local.identity.sign(serverTranscript)),
  });
  await socket.flush();

  final confirmBytes = await reader.readFrame();
  final confirm = jsonDecode(utf8.decode(confirmBytes)) as Map<String, dynamic>;

  if (confirm['type'] != MsgType.handshakeConfirm) {
    throw PeerException(ErrCode.internal, 'expected handshake_confirm, got "${confirm['type']}"');
  }

  final clientTranscript = buildTranscript(
    role: HandshakeRole.client,
    clientDeviceId: peerDeviceId,
    serverDeviceId: local.identity.deviceId,
    clientPub: peerPub,
    serverPub: localPub,
    clientEph: peerEph,
    serverEph: kx.publicKey,
    nonceClient: nonceClient,
    nonceServer: nonceServer,
  );

  if (!await verifySignature(
    message: clientTranscript,
    signature: base64.decode(confirm['signature'] as String? ?? ''),
    publicKey: peerPub,
  )) {
    _refuse(socket, ErrCode.badSignature, 'signature did not verify');
    throw const PeerException(ErrCode.badSignature, 'peer could not prove its identity');
  }

  final secret = await kx.sharedSecret(peerEph);
  final key = await deriveSessionKey(
    sharedSecret: secret,
    nonceClient: nonceClient,
    nonceServer: nonceServer,
  );
  final code = await verificationCode(key);

  final connection = SecureConnection(socket: socket, sessionKey: key, reader: reader)
    ..peerDeviceId = peerDeviceId
    ..peerName = init['name'] as String? ?? ''
    ..verificationCode = code;

  return HandshakeResult(
    connection: connection,
    intent: intent,
    peer: DeviceInfo(
      deviceId: peerDeviceId,
      name: init['name'] as String? ?? '',
      platform: init['platform'] as String? ?? '',
      formFactor: init['form_factor'] as String? ?? FormFactor.desktop,
    ),
    peerPublicKey: peerPublicKey,
    verificationCode: code,
  );
}
