import 'dart:io';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import '../models/device.dart';

class FileSender {
  final Dio _dio = Dio();
  static const int _port = 45456; // Must match server port

  Future<void> sendFile(PlatformFile file, Device targetDevice) async {
    final url = 'http://${targetDevice.ip}:$_port/upload';

    // We stream the file
    // PlatformFile from file_picker might have 'path' (Mobile) or 'bytes' (Web)
    // On Mobile/Desktop, path is usually available.

    Stream<List<int>>? stream;
    int length = 0;

    if (file.path != null) {
      final fileObj = File(file.path!);
      stream = fileObj.openRead();
      length = await fileObj.length();
    } else {
      // Fallback for null path (though unlikely on mobile with current setup)
      throw Exception('File path is null');
    }

    try {
      await _dio.post(
        url,
        data: stream,
        options: Options(
          headers: {
            'X-File-Name': file.name,
            'Content-Length': length, // Important for progress
          },
          contentType: 'application/octet-stream',
        ),
        onSendProgress: (sent, total) {
          print('Progress: ${(sent / total * 100).toStringAsFixed(1)}%');
        },
      );
    } catch (e) {
      print('Error sending file: $e');
      rethrow;
    }
  }
}
