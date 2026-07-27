import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/crypto/identity.dart';

void main() {
  group('AES-256-GCM framing', () {
    test('round trips a payload', () async {
      final key = Uint8List(32)..fillRange(0, 32, 7);
      final plaintext = utf8.encode('hello ecosystem');

      final frame = await encryptFrame(key, plaintext);
      final recovered = await decryptFrame(key, frame);

      expect(utf8.decode(recovered), 'hello ecosystem');
    });

    test('layout is nonce ‖ ciphertext ‖ 16-byte tag', () async {
      // This is the exact framing the Go side produces with gcm.Seal, so a
      // mismatch here would break every desktop↔mobile frame.
      final key = Uint8List(32);
      final frame = await encryptFrame(key, utf8.encode('x'));
      // 12-byte nonce + 1-byte ciphertext + 16-byte tag.
      expect(frame.length, 12 + 1 + 16);
    });

    test('rejects a tampered frame', () async {
      final key = Uint8List(32)..fillRange(0, 32, 3);
      final frame = await encryptFrame(key, utf8.encode('secret'));
      frame[frame.length - 1] ^= 0xFF; // corrupt the tag

      expect(() => decryptFrame(key, frame), throwsA(anything));
    });
  });

  group('handshake key agreement', () {
    test('both sides derive the same session key and code', () async {
      final client = await KeyExchange.generate();
      final server = await KeyExchange.generate();

      final nonceClient = Uint8List(16)..fillRange(0, 16, 1);
      final nonceServer = Uint8List(16)..fillRange(0, 16, 2);

      final clientSecret = await client.sharedSecret(server.publicKey);
      final serverSecret = await server.sharedSecret(client.publicKey);

      final clientKey = await deriveSessionKey(
        sharedSecret: clientSecret,
        nonceClient: nonceClient,
        nonceServer: nonceServer,
      );
      final serverKey = await deriveSessionKey(
        sharedSecret: serverSecret,
        nonceClient: nonceClient,
        nonceServer: nonceServer,
      );

      expect(clientKey, serverKey);

      final code = await verificationCode(clientKey);
      expect(code.length, 6);
      expect(await verificationCode(serverKey), code);
    });

    test('a different nonce yields a different key', () async {
      final client = await KeyExchange.generate();
      final server = await KeyExchange.generate();
      final secret = await client.sharedSecret(server.publicKey);

      final keyA = await deriveSessionKey(
        sharedSecret: secret,
        nonceClient: Uint8List(16)..fillRange(0, 16, 1),
        nonceServer: Uint8List(16)..fillRange(0, 16, 2),
      );
      final keyB = await deriveSessionKey(
        sharedSecret: secret,
        nonceClient: Uint8List(16)..fillRange(0, 16, 9),
        nonceServer: Uint8List(16)..fillRange(0, 16, 2),
      );

      expect(keyA, isNot(keyB));
    });
  });

  group('identity signatures', () {
    test('signs and verifies, and rejects a wrong key', () async {
      final identity = await DeviceIdentity.generate('device-1');
      final impostor = await DeviceIdentity.generate('device-2');
      final message = utf8.encode('transcript bytes');

      final signature = await identity.sign(message);

      expect(
        await verifySignature(
          message: message,
          signature: signature,
          publicKey: identity.publicKeyBytes,
        ),
        isTrue,
      );
      expect(
        await verifySignature(
          message: message,
          signature: signature,
          publicKey: impostor.publicKeyBytes,
        ),
        isFalse,
      );
    });

    test('survives a save/restore cycle', () async {
      final original = await DeviceIdentity.generate('device-1');
      final seed = await original.extractSeed();

      final restored = await DeviceIdentity.restore(
        deviceId: 'device-1',
        privateKeyBytes: seed,
        publicKeyBytes: original.publicKeyBytes,
      );

      final message = utf8.encode('after restart');
      final signature = await restored.sign(message);

      // A signature from the restored key must verify against the original's
      // public key, or every device would look like an impostor after reboot.
      expect(
        await verifySignature(
          message: message,
          signature: signature,
          publicKey: original.publicKeyBytes,
        ),
        isTrue,
      );
    });
  });
}
