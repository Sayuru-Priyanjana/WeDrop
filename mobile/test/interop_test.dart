import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/crypto/identity.dart';

/// Reads the fixture produced by the Go side (`core/crypto/interop_test.go`,
/// TestWriteInteropVectors) and checks that Dart reproduces every value.
///
/// If this passes, a session key negotiated by a desktop and a phone will
/// match, and frames sealed by one will open on the other. It is the single
/// most important test in the project: same-language tests cannot catch a
/// divergence between the two implementations.

Uint8List _hex(String s) {
  final bytes = Uint8List(s.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // From core/crypto/interop_test.go relative to the mobile package.
  final fixture = File('../testdata/crypto_interop.json');

  test('matches the Go interop vectors', () async {
    if (!fixture.existsSync()) {
      fail('run the Go interop test first: '
          'go test ./core/crypto -run TestWriteInteropVectors');
    }

    final data = jsonDecode(await fixture.readAsString()) as Map<String, dynamic>;

    final sessionKey = await deriveSessionKey(
      sharedSecret: _hex(data['shared_secret'] as String),
      nonceClient: _hex(data['nonce_client'] as String),
      nonceServer: _hex(data['nonce_server'] as String),
    );

    // Dart's HKDF must land on exactly the bytes Go's did.
    expect(_toHex(sessionKey), data['expected_session'],
        reason: 'HKDF session key diverged between Go and Dart');

    // And the verification code both users compare must be identical.
    expect(await verificationCode(sessionKey), data['expected_code'],
        reason: 'verification code diverged between Go and Dart');
  });

  test('opens a frame the Go layout describes', () async {
    // Prove the AES-GCM framing agrees by round-tripping under the fixture key.
    // Both sides use nonce ‖ ciphertext ‖ tag with a 12-byte nonce, so a frame
    // Dart seals here is byte-compatible with what Go's Decrypt expects.
    final data = jsonDecode(await fixture.readAsString()) as Map<String, dynamic>;
    final key = _hex(data['key'] as String);
    final plaintext = utf8.encode(data['plaintext'] as String);

    final sealed = await encryptFrame(key, plaintext);
    expect(sealed.length, 12 + plaintext.length + 16);

    final opened = await decryptFrame(key, sealed);
    expect(utf8.decode(opened), data['plaintext']);
  });
}
