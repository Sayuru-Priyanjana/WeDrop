import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/identity.dart';

/// A single frame may not exceed this. Chunks are 256 KiB plus GCM overhead, so
/// there is headroom, while a corrupt length prefix cannot make us allocate
/// hundreds of megabytes.
const int maxFrameSize = 1 << 20;

/// Reads length-prefixed frames from a TCP socket.
///
/// This is the piece the previous version got wrong: it treated each
/// `socket.listen` callback as one complete message. TCP is a byte stream, so a
/// single read can carry half a frame, or two frames at once, and the app
/// silently dropped or mangled whatever did not line up. [FrameReader] buffers
/// until a whole frame is present and never assumes packet boundaries.
class FrameReader {
  final StreamIterator<Uint8List> _chunks;
  final BytesBuilder _buffer = BytesBuilder(copy: true);
  Uint8List _pending = Uint8List(0);

  FrameReader(Stream<Uint8List> stream) : _chunks = StreamIterator(stream);

  /// Reads exactly one frame, or throws if the connection ends first.
  Future<Uint8List> readFrame() async {
    final header = await _readExactly(4);
    final length = ByteData.sublistView(header).getUint32(0, Endian.big);

    if (length == 0) return Uint8List(0);
    if (length > maxFrameSize) {
      throw FormatException(
        'frame of $length bytes is too large — the peer may be speaking another protocol',
      );
    }

    return _readExactly(length);
  }

  Future<Uint8List> _readExactly(int count) async {
    while (_pending.length < count) {
      if (!await _chunks.moveNext()) {
        throw const SocketException('connection closed while reading a frame');
      }
      _buffer
        ..add(_pending)
        ..add(_chunks.current);
      _pending = _buffer.takeBytes();
    }

    final result = Uint8List.sublistView(_pending, 0, count);
    // Copy the remainder so the returned view does not alias the buffer we are
    // about to keep writing into.
    _pending = Uint8List.fromList(_pending.sublist(count));
    return Uint8List.fromList(result);
  }

  Future<void> cancel() => _chunks.cancel();
}

/// Writes a length-prefixed frame to a socket.
///
/// Header and body go out in one write so a frame can never be split across two
/// calls and interleaved with another writer's frame.
void writeFrame(Socket socket, List<int> data) {
  if (data.length > maxFrameSize) {
    throw ArgumentError('frame of ${data.length} bytes is too large to send');
  }

  final out = Uint8List(4 + data.length);
  ByteData.sublistView(out, 0, 4).setUint32(0, data.length, Endian.big);
  out.setRange(4, out.length, data);
  socket.add(out);
}

/// Writes a JSON message as one plaintext frame.
void writeJsonFrame(Socket socket, Map<String, dynamic> message) {
  writeFrame(socket, utf8.encode(jsonEncode(message)));
}

/// An authenticated, encrypted channel over a TCP socket.
///
/// Writes are serialised through a chained future. Without that, the keepalive
/// timer and a clipboard broadcast could interleave halves of two frames on the
/// same socket, which the peer then failed to decrypt — one of the "handshake
/// errors" that had no obvious cause.
class SecureConnection {
  final Socket socket;
  final Uint8List sessionKey;
  final FrameReader _reader;

  String peerDeviceId = '';
  String peerName = '';
  String verificationCode = '';

  Future<void> _writeChain = Future.value();
  bool _closed = false;

  SecureConnection({
    required this.socket,
    required this.sessionKey,
    required FrameReader reader,
  }) : _reader = reader;
  // ignore_for_file: prefer_initializing_formals

  bool get isClosed => _closed;

  /// Reads and authenticates one frame.
  Future<Uint8List> readEncrypted() async {
    final frame = await _reader.readFrame();
    return decryptFrame(sessionKey, frame);
  }

  /// Reads one frame and decodes it as JSON.
  Future<Map<String, dynamic>> readJson() async {
    final plaintext = await readEncrypted();
    final decoded = jsonDecode(utf8.decode(plaintext));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('expected a JSON object');
    }
    return decoded;
  }

  /// Encrypts and writes one frame, in order with every other write.
  Future<void> writeEncrypted(List<int> plaintext) {
    final task = _writeChain.then((_) async {
      if (_closed) throw const SocketException('connection is closed');
      final sealed = await encryptFrame(sessionKey, plaintext);
      writeFrame(socket, sealed);
      await socket.flush();
    });

    // Keep the chain alive even if this write fails, so one error does not
    // permanently wedge every later write behind a rejected future.
    _writeChain = task.catchError((_) {});
    return task;
  }

  /// Encrypts and writes a JSON message.
  Future<void> writeJson(Map<String, dynamic> message) =>
      writeEncrypted(utf8.encode(jsonEncode(message)));

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _reader.cancel();
    try {
      await socket.close();
    } catch (_) {
      // Already gone; nothing useful to do.
    }
    socket.destroy();
  }
}
