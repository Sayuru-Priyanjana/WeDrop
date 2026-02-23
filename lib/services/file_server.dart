import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class HandshakeRequest {
  final String senderName;
  final int fileCount;
  final int totalSize;

  HandshakeRequest({
    required this.senderName,
    required this.fileCount,
    required this.totalSize,
  });

  factory HandshakeRequest.fromJson(Map<String, dynamic> json) {
    return HandshakeRequest(
      senderName: json['senderName'] ?? 'Unknown',
      fileCount: json['fileCount'] ?? 0,
      totalSize: json['totalSize'] ?? 0,
    );
  }
}

class TransferProgress {
  final int transferredBytes;
  final int totalBytes;
  final double speedMBps;

  TransferProgress(this.transferredBytes, this.totalBytes, this.speedMBps);
}

class FileServer {
  static const int _port = 45456;
  HttpServer? _server;

  // Stream for handshakes. The UI will listen to this and return a bool (accept/reject).
  // Using a Completer mapping to handle async responses.
  final StreamController<Map<String, dynamic>> _handshakeController =
      StreamController.broadcast();
  Stream<Map<String, dynamic>> get handshakeStream =>
      _handshakeController.stream;

  // Pending handshakes mapping sessionId to Completer
  final Map<String, Completer<bool>> _pendingHandshakes = {};

  // Stream for receive progress
  final StreamController<TransferProgress> _progressController =
      StreamController.broadcast();
  Stream<TransferProgress> get progressStream => _progressController.stream;

  Future<void> start() async {
    final router = Router();

    router.post('/handshake', (Request request) async {
      final payload = await request.readAsString();
      final data = jsonDecode(payload);

      final sessionId = data['sessionId'] as String;
      final info = HandshakeRequest.fromJson(data);

      final completer = Completer<bool>();
      _pendingHandshakes[sessionId] = completer;

      // Emit to UI
      _handshakeController.add({'sessionId': sessionId, 'request': info});

      // Wait for UI response
      final accepted = await completer.future;
      _pendingHandshakes.remove(sessionId);

      if (accepted) {
        return Response.ok('ACCEPTED');
      } else {
        return Response.forbidden('REJECTED');
      }
    });

    router.post('/upload', (Request request) async {
      final fileName = request.headers['X-File-Name'];
      if (fileName == null) {
        return Response.badRequest(body: 'Missing X-File-Name header');
      }

      final contentLengthStr = request.headers['Content-Length'];
      final totalBytes =
          contentLengthStr != null ? int.tryParse(contentLengthStr) ?? 0 : 0;

      final safeFileName = p.basename(fileName);

      try {
        // Create WeDrop directory in storage
        Directory? baseDir;
        if (Platform.isAndroid) {
          // Attempt to get public downloads folder
          baseDir = Directory('/storage/emulated/0/Download');
          if (!await baseDir.exists()) {
            try {
              await baseDir.create(recursive: true);
            } catch (e) {
              baseDir = await getExternalStorageDirectory();
            }
          }
        } else {
          baseDir = await getApplicationDocumentsDirectory();
        }

        if (baseDir == null) {
          return Response.internalServerError(body: 'Could not access storage');
        }

        Directory weDropDir = Directory(p.join(baseDir.path, 'WeDrop'));
        try {
          if (!await weDropDir.exists()) {
            await weDropDir.create(recursive: true);
          }
        } catch (dirErr) {
          print('Failed to create WeDrop dir in external storage: $dirErr');
          final fallbackDir = await getApplicationDocumentsDirectory();
          weDropDir = Directory(p.join(fallbackDir.path, 'WeDrop'));
          if (!await weDropDir.exists()) {
            await weDropDir.create(recursive: true);
          }
        }

        final savePath = p.join(weDropDir.path, safeFileName);
        final file = File(savePath);
        final sink = file.openWrite();

        int transferredBytes = 0;
        final stopwatch = Stopwatch()..start();
        final lastNotifyTime = Stopwatch()..start();

        await for (final chunk in request.read()) {
          sink.add(chunk);
          transferredBytes += chunk.length;

          // Throttle updates to ~10 per second
          if (lastNotifyTime.elapsedMilliseconds > 100) {
            final elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
            final speed =
                elapsedSec > 0
                    ? (transferredBytes / 1024 / 1024) / elapsedSec
                    : 0.0;

            _progressController.add(
              TransferProgress(transferredBytes, totalBytes, speed),
            );

            lastNotifyTime.reset();
          }
        }

        await sink.flush();
        await sink.close();

        // Final progress update
        final elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
        final speed =
            elapsedSec > 0
                ? (transferredBytes / 1024 / 1024) / elapsedSec
                : 0.0;
        _progressController.add(
          TransferProgress(totalBytes, totalBytes, speed),
        );

        return Response.ok('File received successfully');
      } catch (e, stackTrace) {
        print('Upload Failed: $e');
        print(stackTrace);
        return Response.internalServerError(body: 'Failed to save file: $e');
      }
    });

    _server = await shelf_io.serve(router.call, InternetAddress.anyIPv4, _port);
  }

  void respondToHandshake(String sessionId, bool accept) {
    if (_pendingHandshakes.containsKey(sessionId)) {
      _pendingHandshakes[sessionId]!.complete(accept);
    }
  }

  void stop() {
    _server?.close();
    _handshakeController.close();
    _progressController.close();
  }
}
