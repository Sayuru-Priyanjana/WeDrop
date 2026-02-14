import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/device.dart';
import '../services/discovery_service.dart';
import '../services/profile_service.dart';
import '../services/file_server.dart';
import '../services/file_sender.dart';
import 'received_files_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProfileService _profileService = ProfileService();
  late DiscoveryService _discoveryService;
  final FileServer _fileServer = FileServer();
  final FileSender _fileSender = FileSender();

  final TextEditingController _nameController = TextEditingController();

  String _deviceName = '';
  List<Device> _devices = [];
  PlatformFile? _selectedFile;
  bool _isDiscovering = false;
  bool _isTransferring = false;
  double _progress = 0.0;

  @override
  void initState() {
    super.initState();
    _discoveryService = DiscoveryService(_profileService);
    _init();
  }

  Future<void> _init() async {
    await _profileService.loadProfile();
    setState(() {
      _deviceName = _profileService.deviceName;
    });

    // Request permissions
    await _requestPermissions();

    // Start discovery and server
    _startDiscovery();
    _fileServer.start();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.location,
      Permission.storage,
      Permission.manageExternalStorage,
      Permission.nearbyWifiDevices,
    ].request();
  }

  void _startDiscovery() {
    setState(() => _isDiscovering = true);
    _discoveryService.start();
    _discoveryService.devicesStream.listen((devices) {
      if (mounted) {
        setState(() {
          _devices = devices;
        });
      }
    });
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();

    if (result != null) {
      setState(() {
        _selectedFile = result.files.first;
      });
    }
  }

  Future<void> _onDeviceTap(Device device) async {
    if (_selectedFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a file first')),
      );
      return;
    }

    setState(() {
      _isTransferring = true;
      _progress = 0.0;
    });

    try {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Sending to ${device.name}...')));

      // Note: FileSender doesn't report progress callback in the simple version I wrote,
      // but I can add it easily. For now, just await.
      await _fileSender.sendFile(_selectedFile!, device);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File sent successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error sending file: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isTransferring = false);
      }
    }
  }

  void _showEditProfileDialog() {
    _nameController.text = _deviceName;
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Edit Device Name'),
            content: TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Device Name'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  if (_nameController.text.isNotEmpty) {
                    await _profileService.updateDeviceName(
                      _nameController.text,
                    );
                    await _profileService.loadProfile();
                    setState(() {
                      _deviceName = _profileService.deviceName;
                    });
                    if (mounted) Navigator.pop(context);
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
    );
  }

  @override
  void dispose() {
    _discoveryService.stop();
    _fileServer.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('File Share'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder),
            tooltip: 'Received Files',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ReceivedFilesScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: _showEditProfileDialog,
            tooltip: 'Edit Profile',
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // Device Info Header
              Container(
                padding: const EdgeInsets.all(16.0),
                color: Theme.of(context).colorScheme.surfaceVariant,
                child: Row(
                  children: [
                    const Icon(Icons.devices, size: 40),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Your Device:',
                          style: TextStyle(fontSize: 12),
                        ),
                        Text(
                          _deviceName,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              // File Selection Area
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Card(
                  child: ListTile(
                    leading: const Icon(Icons.insert_drive_file),
                    title: Text(
                      _selectedFile != null
                          ? _selectedFile!.name
                          : 'No file selected',
                    ),
                    subtitle:
                        _selectedFile != null
                            ? Text(
                              '${(_selectedFile!.size / 1024).toStringAsFixed(1)} KB',
                            )
                            : null,
                    trailing: ElevatedButton(
                      onPressed: _isTransferring ? null : _pickFile,
                      child: const Text('Select File'),
                    ),
                  ),
                ),
              ),

              const Divider(),
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Text(
                  'Available Devices',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),

              // Device List
              Expanded(
                child:
                    _devices.isEmpty
                        ? const Center(child: Text('Scanning for devices...'))
                        : ListView.builder(
                          itemCount: _devices.length,
                          itemBuilder: (context, index) {
                            final device = _devices[index];
                            return ListTile(
                              leading: const CircleAvatar(
                                child: Icon(Icons.smartphone),
                              ),
                              title: Text(device.name),
                              subtitle: Text(device.ip),
                              onTap:
                                  _isTransferring
                                      ? null
                                      : () => _onDeviceTap(device),
                              trailing:
                                  _isTransferring
                                      ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                      : const Icon(Icons.send),
                            );
                          },
                        ),
              ),
            ],
          ),
          if (_isTransferring)
            Container(
              color: Colors.black45,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
