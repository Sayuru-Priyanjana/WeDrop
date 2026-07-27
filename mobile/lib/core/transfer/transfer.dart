import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../crypto/identity.dart';
import '../protocol/messages.dart';
import '../transport/framing.dart';

/// Deliberately modest: a phone holding a 1 MiB chunk plus its encrypted copy
/// plus framing buffers for every concurrent transfer adds up fast, and 256 KiB
/// already saturates typical Wi-Fi.
const int chunkSize = 256 * 1024;

/// Reports transfer progress. Called often, so the UI throttles before
/// rebuilding anything.
typedef ProgressCallback = void Function(int transferred, int total);

/// Raised when the receiving side declines a file.
class TransferDeclined implements Exception {
  final String reason;
  const TransferDeclined(this.reason);

  @override
  String toString() =>
      reason.isEmpty ? 'the other device declined the file' : 'declined: $reason';
}

/// Pushes one file down an established transfer connection.
class FileSender {
  final SecureConnection connection;
  final ProgressCallback? onProgress;

  const FileSender(this.connection, {this.onProgress});

  Future<void> send({
    required String transferId,
    required File file,
    String? displayName,
  }) async {
    final size = await file.length();
    final filename = displayName ?? p.basename(file.path);

    // Hash by streaming, so sending a large video never loads it into memory.
    final checksum = await sha256File(file.openRead());
    final chunkCount = (size + chunkSize - 1) ~/ chunkSize;

    await connection.writeJson(TransferOffer(
      transferId: transferId,
      filename: filename,
      size: size,
      checksum: checksum,
      chunkSize: chunkSize,
      chunkCount: chunkCount,
    ).toJson());

    // The receiver may be showing a prompt, so allow a generous window.
    final reply = await connection.readJson().timeout(const Duration(minutes: 3));
    if (reply['accepted'] != true) {
      throw TransferDeclined(reply['reason'] as String? ?? '');
    }

    var index = 0;
    var sent = 0;
    final buffer = BytesBuilder(copy: true);

    Future<void> flush({bool force = false}) async {
      while (buffer.length >= chunkSize || (force && buffer.length > 0)) {
        final take = buffer.length >= chunkSize ? chunkSize : buffer.length;
        final bytes = buffer.takeBytes();
        final chunk = Uint8List.sublistView(bytes, 0, take);

        // Anything beyond this chunk goes back on the front of the buffer.
        if (bytes.length > take) {
          final remainder = Uint8List.fromList(bytes.sublist(take));
          buffer.add(remainder);
        }

        await connection.writeJson(transferChunkMessage(transferId, index, chunk.length));
        await connection.writeEncrypted(chunk);

        index++;
        sent += chunk.length;
        onProgress?.call(sent, size);

        if (!force && buffer.length < chunkSize) break;
      }
    }

    await for (final piece in file.openRead()) {
      buffer.add(piece);
      await flush();
    }
    await flush(force: true);

    await connection.writeJson(transferDoneMessage(transferId, checksum));

    // Wait for the receiver's confirmation, so "sent" in the UI means the file
    // actually landed intact.
    final confirmation = await connection.readJson().timeout(const Duration(minutes: 2));
    if (confirmation['type'] == MsgType.error) {
      throw Exception(
        'receiver reported a problem: ${confirmation['message'] ?? 'unknown error'}',
      );
    }
  }
}

/// Writes one incoming file to disk.
class FileReceiver {
  final SecureConnection connection;
  final String saveDir;
  final ProgressCallback? onProgress;

  const FileReceiver(this.connection, this.saveDir, {this.onProgress});

  Future<void> decline(TransferOffer offer, String reason) =>
      connection.writeJson(transferAcceptMessage(offer.transferId, false, reason));

  /// Accepts an offer and streams the file to disk, returning the saved path.
  Future<String> receive(TransferOffer offer) async {
    if (offer.size < 0 || offer.chunkSize <= 0 || offer.chunkSize > maxFrameSize) {
      await decline(offer, 'malformed transfer offer');
      throw const FormatException('malformed transfer offer');
    }

    await Directory(saveDir).create(recursive: true);
    final savePath = await _uniquePath(saveDir, offer.filename);

    // Write to a temporary file and rename on success. A half-received file
    // must never appear under the real name, where the user would open it and
    // find it truncated.
    final tempPath = '$savePath.wedrop-part';
    final tempFile = File(tempPath);
    final sink = tempFile.openWrite();

    Future<void> cleanup() async {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await tempFile.delete();
      } catch (_) {}
    }

    await connection.writeJson(transferAcceptMessage(offer.transferId, true));

    var received = 0;
    try {
      while (true) {
        final header = await connection.readJson().timeout(const Duration(seconds: 60));
        final type = header['type'] as String?;

        if (type == MsgType.transferDone) {
          if (header['checksum'] != offer.checksum) {
            throw const FormatException('the sender\'s checksum changed mid-transfer');
          }
          break;
        }
        if (type != MsgType.transferChunk) {
          throw FormatException('expected a chunk, got "$type"');
        }

        final declared = header['size'] as int? ?? 0;
        if (declared <= 0 || declared > offer.chunkSize) {
          throw const FormatException('chunk declares an impossible size');
        }
        // Refuse to let a sender write more than it offered, so a misbehaving
        // peer cannot fill the phone's storage.
        if (received + declared > offer.size) {
          throw const FormatException('sender exceeded the offered file size');
        }

        final chunk = await connection.readEncrypted();
        if (chunk.length != declared) {
          throw const FormatException('chunk arrived with the wrong length');
        }

        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, offer.size);
      }

      await sink.flush();
      await sink.close();

      if (received != offer.size) {
        throw FormatException('file is incomplete: got $received of ${offer.size} bytes');
      }

      final actual = await sha256File(tempFile.openRead());
      if (actual != offer.checksum) {
        await connection.writeJson(errorMessage(ErrCode.internal, 'checksum mismatch'));
        throw const FormatException('the file arrived corrupted (checksum mismatch)');
      }

      await tempFile.rename(savePath);
      await connection.writeJson(transferDoneMessage(offer.transferId, actual));
      return savePath;
    } catch (_) {
      await cleanup();
      rethrow;
    }
  }
}

/// Reduces a peer-supplied name to a single safe path element.
///
/// The name comes from another machine, so it cannot be trusted: a filename of
/// `../../databases/app.db` would otherwise let a paired device write anywhere
/// this app can reach.
String sanitiseFilename(String name) {
  var cleaned = name.replaceAll('\\', '/').split('/').last.trim();

  cleaned = cleaned.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');

  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    throw const FormatException('unusable file name');
  }

  if (cleaned.length > 200) {
    final ext = p.extension(cleaned);
    cleaned = cleaned.substring(0, 200 - ext.length) + ext;
  }
  return cleaned;
}

/// Returns a path in [dir] that does not collide, appending " (2)", " (3)" and
/// so on rather than overwriting whatever is already there.
Future<String> _uniquePath(String dir, String filename) async {
  final safe = sanitiseFilename(filename);

  var candidate = p.join(dir, safe);
  if (!await File(candidate).exists()) return candidate;

  final ext = p.extension(safe);
  final stem = p.basenameWithoutExtension(safe);

  for (var i = 2; i < 10000; i++) {
    candidate = p.join(dir, '$stem ($i)$ext');
    if (!await File(candidate).exists()) return candidate;
  }
  throw FormatException('too many files named "$safe"');
}
