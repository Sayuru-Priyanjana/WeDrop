import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../models/device.dart';
import '../models/transfer_item.dart';

class TransferProgress {
  final int transferredBytes;
  final int totalBytes;
  final double speedMBps;

  TransferProgress(this.transferredBytes, this.totalBytes, this.speedMBps);
}

class FileSender {
  final Dio _dio = Dio();
  static const int _port = 45456;

  final StreamController<TransferProgress> _progressController =
      StreamController.broadcast();
  Stream<TransferProgress> get progressStream => _progressController.stream;

  Future<bool> sendHandshake(
    List<TransferItem> items,
    Device targetDevice,
    String senderName,
  ) async {
    final url = 'http://${targetDevice.ip}:$_port/handshake';

    final totalSize = items.fold<int>(0, (sum, item) => sum + item.size);
    final sessionId = const Uuid().v4();

    final payload = {
      'sessionId': sessionId,
      'senderName': senderName,
      'fileCount': items.length,
      'totalSize': totalSize,
    };

    try {
      final response = await _dio.post(
        url,
        data: jsonEncode(payload),
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (status) => true, // Don't throw on 403
        ),
      );

      return response.statusCode == 200;
    } catch (e) {
      print('Handshake error: $e');
      return false;
    }
  }

  Future<void> sendFiles(
    List<TransferItem> items,
    Device targetDevice,
    String senderName,
  ) async {
    // 1. Handshake
    final accepted = await sendHandshake(items, targetDevice, senderName);
    if (!accepted) {
      throw Exception('Handshake rejected by receiver.');
    }

    // 2. Transmit
    final totalSize = items.fold<int>(0, (sum, item) => sum + item.size);
    int totalSentBytes = 0;

    final stopwatch = Stopwatch()..start();
    final lastNotifyTime = Stopwatch()..start();

    for (final item in items) {
      final url = 'http://${targetDevice.ip}:$_port/upload';
      final fileObj = File(item.path);

      if (!fileObj.existsSync()) continue;

      final stream = fileObj.openRead();
      final length = fileObj.lengthSync();

      try {
        final response = await _dio.post(
          url,
          data: stream,
          options: Options(
            headers: {
              'X-File-Name': item.name,
              'Content-Length': length.toString(),
            },
            contentType: 'application/octet-stream',
            validateStatus: (status) => true, // Tolerate 500 gracefully
          ),
          onSendProgress: (sent, total) {
            final currentTotalSent = totalSentBytes + sent;

            // Throttle updates
            if (lastNotifyTime.elapsedMilliseconds > 100) {
              final elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
              final speed =
                  elapsedSec > 0
                      ? (currentTotalSent / 1024 / 1024) / elapsedSec
                      : 0.0;

              _progressController.add(
                TransferProgress(currentTotalSent, totalSize, speed),
              );

              lastNotifyTime.reset();
            }
          },
        );

        if (response.statusCode != 200) {
          throw Exception(
            'Server rejected the file. Response: ${response.data}',
          );
        }

        totalSentBytes += length;
      } catch (e) {
        print('Error sending file ${item.name}: $e');
        rethrow;
      }
    }

    // Final update
    final elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
    final speed =
        elapsedSec > 0 ? (totalSentBytes / 1024 / 1024) / elapsedSec : 0.0;
    _progressController.add(TransferProgress(totalSize, totalSize, speed));
  }

  void dispose() {
    _progressController.close();
  }
}
