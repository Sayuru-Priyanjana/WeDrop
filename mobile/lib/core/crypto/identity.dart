import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The Dart half of WeDrop's cryptography, matching `core/crypto` in Go.
///
/// The algorithms are fixed on both sides: Ed25519 for identity, X25519 for
/// agreement, HKDF-SHA256 to derive the session key, AES-256-GCM for frames.

final _ed25519 = Ed25519();
final _x25519 = X25519();
final _aesGcm = AesGcm.with256bits();
final _sha256 = Sha256();

/// This device's long-lived identity keypair.
class DeviceIdentity {
  final String deviceId;
  final SimpleKeyPair keyPair;
  final Uint8List publicKeyBytes;

  DeviceIdentity({
    required this.deviceId,
    required this.keyPair,
    required this.publicKeyBytes,
  });

  /// Base64 identity key, the form used everywhere on the wire.
  String get publicKeyBase64 => base64.encode(publicKeyBytes);

  /// Generates a brand-new identity.
  static Future<DeviceIdentity> generate(String deviceId) async {
    final keyPair = await _ed25519.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return DeviceIdentity(
      deviceId: deviceId,
      keyPair: keyPair,
      publicKeyBytes: Uint8List.fromList(publicKey.bytes),
    );
  }

  /// Restores an identity from its stored private and public key bytes.
  static Future<DeviceIdentity> restore({
    required String deviceId,
    required Uint8List privateKeyBytes,
    required Uint8List publicKeyBytes,
  }) async {
    final keyPair = await _ed25519.newKeyPairFromSeed(privateKeyBytes);
    return DeviceIdentity(
      deviceId: deviceId,
      keyPair: keyPair,
      publicKeyBytes: publicKeyBytes,
    );
  }

  /// The 32-byte seed to persist. Ed25519 private keys are derived from it.
  Future<Uint8List> extractSeed() async {
    return Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
  }

  /// Signs a message with this device's identity key.
  Future<Uint8List> sign(List<int> message) async {
    final signature = await _ed25519.sign(message, keyPair: keyPair);
    return Uint8List.fromList(signature.bytes);
  }
}

/// Verifies an Ed25519 signature against a raw public key.
Future<bool> verifySignature({
  required List<int> message,
  required List<int> signature,
  required List<int> publicKey,
}) async {
  try {
    return await _ed25519.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    // A malformed key or signature is a verification failure, not a crash.
    return false;
  }
}

/// An ephemeral X25519 keypair used for one handshake only.
class KeyExchange {
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;

  KeyExchange({required this.keyPair, required this.publicKey});

  static Future<KeyExchange> generate() async {
    final keyPair = await _x25519.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return KeyExchange(
      keyPair: keyPair,
      publicKey: Uint8List.fromList(publicKey.bytes),
    );
  }

  /// Computes the raw X25519 shared secret with a peer's ephemeral key.
  Future<Uint8List> sharedSecret(List<int> peerPublicKey) async {
    final secret = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }
}

/// Derives the AES-256 session key from the raw shared secret.
///
/// The curve output is never used as a cipher key directly — it is not
/// uniformly distributed, and mixing the two handshake nonces in as HKDF salt
/// is what binds the key to this particular handshake and defeats replay.
Future<Uint8List> deriveSessionKey({
  required List<int> sharedSecret,
  required List<int> nonceClient,
  required List<int> nonceServer,
}) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(sharedSecret),
    nonce: [...nonceClient, ...nonceServer],
    info: utf8.encode('wedrop/v2/session'),
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// Handshake role tags. They differ per direction so an attacker cannot reflect
/// one side's signature back at it as if it were the other's.
class HandshakeRole {
  static const client = 'client';
  static const server = 'server';
}

/// Builds the exact byte string both peers sign during the handshake.
///
/// Every field is length-prefixed so no combination of values can be re-cut
/// into a different but identically-serialised transcript.
Uint8List buildTranscript({
  required String role,
  required String clientDeviceId,
  required String serverDeviceId,
  required List<int> clientPub,
  required List<int> serverPub,
  required List<int> clientEph,
  required List<int> serverEph,
  required List<int> nonceClient,
  required List<int> nonceServer,
}) {
  final out = BytesBuilder();

  void field(List<int> bytes) {
    final length = ByteData(4)..setUint32(0, bytes.length, Endian.big);
    out.add(length.buffer.asUint8List());
    out.add(bytes);
  }

  field(utf8.encode('WEDROP-V2-HANDSHAKE'));
  field(utf8.encode(role));
  field(utf8.encode(clientDeviceId));
  field(utf8.encode(serverDeviceId));
  field(clientPub);
  field(serverPub);
  field(clientEph);
  field(serverEph);
  field(nonceClient);
  field(nonceServer);

  return out.toBytes();
}

/// The 6-digit code both devices display while pairing.
///
/// It comes from the session key, which comes from the signed transcript, so
/// matching codes on both screens rule out a machine in the middle.
Future<String> verificationCode(List<int> sessionKey) async {
  final digest = await _sha256.hash([...utf8.encode('wedrop/v2/verify'), ...sessionKey]);
  final value = ByteData.sublistView(Uint8List.fromList(digest.bytes), 0, 4).getUint32(0);
  return (value % 1000000).toString().padLeft(6, '0');
}

/// Encrypts one frame with AES-256-GCM, returning nonce ‖ ciphertext ‖ tag.
///
/// The layout matches Go's `gcm.Seal(nonce, nonce, ...)`, which prepends the
/// 12-byte nonce and appends the 16-byte tag.
Future<Uint8List> encryptFrame(List<int> key, List<int> plaintext) async {
  final secretBox = await _aesGcm.encrypt(plaintext, secretKey: SecretKey(key));
  return Uint8List.fromList([
    ...secretBox.nonce,
    ...secretBox.cipherText,
    ...secretBox.mac.bytes,
  ]);
}

/// Decrypts one frame produced by [encryptFrame] or its Go equivalent.
Future<Uint8List> decryptFrame(List<int> key, List<int> frame) async {
  const nonceLength = 12;
  const macLength = 16;

  if (frame.length < nonceLength + macLength) {
    throw const FormatException('encrypted frame is too short');
  }

  final box = SecretBox(
    frame.sublist(nonceLength, frame.length - macLength),
    nonce: frame.sublist(0, nonceLength),
    mac: Mac(frame.sublist(frame.length - macLength)),
  );

  final plaintext = await _aesGcm.decrypt(box, secretKey: SecretKey(key));
  return Uint8List.fromList(plaintext);
}

/// Hex SHA-256 of some bytes, matching Go's `crypto.HashBytes`.
Future<String> sha256Hex(List<int> data) async {
  final digest = await _sha256.hash(data);
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Streams a file through SHA-256 without loading it into memory, which matters
/// on a phone asked to send a multi-gigabyte video.
Future<String> sha256File(Stream<List<int>> stream) async {
  final sink = _sha256.newHashSink();
  await for (final chunk in stream) {
    sink.add(chunk);
  }
  sink.close();
  final digest = await sink.hash();
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
