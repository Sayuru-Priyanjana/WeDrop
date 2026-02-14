import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;

class ReceivedFilesScreen extends StatefulWidget {
  const ReceivedFilesScreen({super.key});

  @override
  State<ReceivedFilesScreen> createState() => _ReceivedFilesScreenState();
}

class _ReceivedFilesScreenState extends State<ReceivedFilesScreen> {
  List<FileSystemEntity> _files = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    setState(() => _isLoading = true);
    try {
      Directory? appDocDir;
      if (Platform.isAndroid) {
        appDocDir = await getExternalStorageDirectory();
      }
      appDocDir ??= await getApplicationDocumentsDirectory();

      if (appDocDir != null) {
        final List<FileSystemEntity> files = appDocDir.listSync();
        // Filter for files only, ignore directories for now
        _files = files.whereType<File>().toList();

        // Sort by modification time (newest first)
        _files.sort(
          (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
        );
      }
    } catch (e) {
      print('Error loading files: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _openFile(String path) async {
    final result = await OpenFile.open(path);
    if (result.type != ResultType.done) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file: ${result.message}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Received Files'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadFiles),
        ],
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _files.isEmpty
              ? const Center(child: Text('No files received yet'))
              : ListView.builder(
                itemCount: _files.length,
                itemBuilder: (context, index) {
                  final file = _files[index];
                  final String fileName = p.basename(file.path);
                  return ListTile(
                    leading: const Icon(Icons.file_present),
                    title: Text(fileName),
                    subtitle: FutureBuilder<FileStat>(
                      future: file.stat(),
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          final size = (snapshot.data!.size / 1024)
                              .toStringAsFixed(1);
                          return Text('$size KB');
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                    onTap: () => _openFile(file.path),
                  );
                },
              ),
    );
  }
}
