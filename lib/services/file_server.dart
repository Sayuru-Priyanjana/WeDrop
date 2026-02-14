import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class FileServer {
  static const int _port = 45456; // TCP Port for File Transfer
  HttpServer? _server;

  Future<void> start() async {
    final router = Router();

    router.post('/upload', (Request request) async {
      final fileName = request.headers['X-File-Name'];
      if (fileName == null) {
        return Response.badRequest(body: 'Missing X-File-Name header');
      }

      // Sanitize filename
      final safeFileName = p.basename(fileName);

      try {
        Directory? appDocDir;
        if (Platform.isAndroid) {
          appDocDir = await getExternalStorageDirectory();
        }
        appDocDir ??= await getApplicationDocumentsDirectory();

        final savePath = p.join(appDocDir!.path, safeFileName);
        final file = File(savePath);

        print('Saving file to: $savePath');

        final sink = file.openWrite();
        try {
          await sink.addStream(request.read());
          await sink.flush();
          await sink.close();
        } catch (e) {
          await sink.close();
          rethrow;
        }

        print('File saved to $savePath');
        return Response.ok('File received successfully');
      } catch (e, stackTrace) {
        print('Error saving file: $e');
        print(stackTrace);
        return Response.internalServerError(body: 'Failed to save file: $e');
      }
    });

    // Info endpoint
    router.get('/info', (Request request) {
      return Response.ok('FileShare Server Running');
    });

    _server = await shelf_io.serve(router.call, InternetAddress.anyIPv4, _port);
    print('File Server listening on port ${_server!.port}');
  }

  void stop() {
    _server?.close();
  }
}
