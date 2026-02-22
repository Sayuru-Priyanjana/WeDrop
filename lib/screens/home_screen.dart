import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import '../models/device.dart';
import '../models/transfer_item.dart';
import '../services/discovery_service.dart';
import '../services/profile_service.dart';
import '../services/file_server.dart';
import '../services/file_sender.dart' as sender;
import '../services/theme_provider.dart';
import 'package:provider/provider.dart';
import 'received_files_screen.dart';
import 'app_picker_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProfileService _profileService = ProfileService();
  late DiscoveryService _discoveryService;
  final FileServer _fileServer = FileServer();
  final sender.FileSender _fileSender = sender.FileSender();

  final TextEditingController _nameController = TextEditingController();

  String _deviceName = '';
  List<Device> _devices = [];
  List<TransferItem> _selectedItems = [];

  // Transfer state
  bool _isTransferring = false;
  double _progress = 0.0;
  String _transferStatus = '';

  // Stream subscriptions
  StreamSubscription? _handshakeSub;
  StreamSubscription? _serverProgressSub;
  StreamSubscription? _senderProgressSub;

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

    await _requestPermissions();

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
    _discoveryService.start();
    _discoveryService.devicesStream.listen((devices) {
      if (mounted) {
        setState(() {
          _devices = devices;
        });
      }
    });

    _handshakeSub = _fileServer.handshakeStream.listen((data) {
      _showHandshakeDialog(data['sessionId'], data['request']);
    });

    _serverProgressSub = _fileServer.progressStream.listen((progress) {
      if (mounted) {
        setState(() {
          _isTransferring = true;
          _progress = progress.transferredBytes / progress.totalBytes;
          _transferStatus =
              'Receiving... ${progress.speedMBps.toStringAsFixed(1)} MB/s';

          if (_progress >= 1.0) {
            Future.delayed(const Duration(seconds: 1), () {
              if (mounted) {
                setState(() => _isTransferring = false);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Files received successfully!')),
                );
              }
            });
          }
        });
      }
    });
  }

  void _showHandshakeDialog(String sessionId, HandshakeRequest request) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            title: const Text('Incoming Delivery'),
            content: Text(
              '${request.senderName} wants to send you:\n\n'
              '${request.fileCount} items\n'
              'Total Size: ${(request.totalSize / 1024 / 1024).toStringAsFixed(1)} MB',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _fileServer.respondToHandshake(sessionId, false);
                  Navigator.pop(context);
                },
                child: const Text(
                  'Decline',
                  style: TextStyle(color: Colors.red),
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  _fileServer.respondToHandshake(sessionId, true);
                  Navigator.pop(context);
                },
                child: const Text('Accept'),
              ),
            ],
          ),
    );
  }

  Future<void> _pickFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );

    if (result != null) {
      final uuid = const Uuid();
      final newItems =
          result.files.map((file) {
            return TransferItem(
              id: uuid.v4(),
              name: file.name,
              path: file.path!,
              size: file.size,
              type: TransferItemType.file,
            );
          }).toList();

      setState(() {
        _selectedItems.addAll(newItems);
      });
    }
  }

  Future<void> _pickApps() async {
    final List<TransferItem>? apps = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AppPickerScreen()),
    );

    if (apps != null && apps.isNotEmpty) {
      setState(() {
        _selectedItems.addAll(apps);
      });
    }
  }

  void _removeItem(TransferItem item) {
    setState(() {
      _selectedItems.removeWhere((i) => i.id == item.id);
    });
  }

  Future<void> _onDeviceTap(Device device) async {
    if (_selectedItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select items to send first')),
      );
      return;
    }

    setState(() {
      _isTransferring = true;
      _progress = 0.0;
      _transferStatus = 'Connecting...';
    });

    try {
      _senderProgressSub?.cancel();
      _senderProgressSub = _fileSender.progressStream.listen((progress) {
        if (mounted) {
          setState(() {
            _progress = progress.transferredBytes / progress.totalBytes;
            _transferStatus =
                'Sending... ${progress.speedMBps.toStringAsFixed(1)} MB/s';
          });
        }
      });

      await _fileSender.sendFiles(_selectedItems, device, _deviceName);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Transfer completed successfully!')),
        );
        setState(() {
          _selectedItems.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
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
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            content: TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Device Name',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
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

  void _showAddBottomSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder:
          (context) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.file_present)),
                  title: const Text('Files'),
                  subtitle: const Text('Documents, images, videos'),
                  onTap: () {
                    Navigator.pop(context);
                    _pickFiles();
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.apps)),
                  title: const Text('Apps'),
                  subtitle: const Text('Send installed APKs'),
                  onTap: () {
                    Navigator.pop(context);
                    _pickApps();
                  },
                ),
              ],
            ),
          ),
    );
  }

  @override
  void dispose() {
    _handshakeSub?.cancel();
    _serverProgressSub?.cancel();
    _senderProgressSub?.cancel();
    _fileSender.dispose();
    _discoveryService.stop();
    _fileServer.stop();
    super.dispose();
  }

  Widget _buildSelectedItemsList() {
    if (_selectedItems.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: Text(
            'No items selected.\nTap + to add files or apps.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return ListView.builder(
      scrollDirection: Axis.horizontal,
      itemCount: _selectedItems.length,
      itemBuilder: (context, index) {
        final item = _selectedItems[index];

        return Container(
          width: 120,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (item.icon != null)
                      Image.memory(item.icon!, width: 40, height: 40)
                    else
                      Icon(
                        item.type == TransferItemType.app
                            ? Icons.android
                            : Icons.insert_drive_file,
                        size: 40,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    const SizedBox(height: 8),
                    Text(
                      item.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${(item.size / 1024 / 1024).toStringAsFixed(1)} MB',
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  icon: const Icon(
                    Icons.cancel,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _removeItem(item),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark =
        themeProvider.themeMode == ThemeMode.dark ||
        (themeProvider.themeMode == ThemeMode.system &&
            MediaQuery.of(context).platformBrightness == Brightness.dark);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'WeDrop',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            tooltip: 'Toggle Theme',
            onPressed: () {
              themeProvider.toggleTheme(!isDark);
            },
          ),
          IconButton(
            icon: const Icon(Icons.folder_shared),
            tooltip: 'Received',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ReceivedFilesScreen()),
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // Background Gradient
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.primary.withOpacity(0.1),
                  Theme.of(context).scaffoldBackgroundColor,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),

          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Profile Section
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity(0.2),
                        child: Icon(
                          Icons.person,
                          size: 30,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Ready to Drop',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[600],
                              ),
                            ),
                            Text(
                              _deviceName,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: _showEditProfileDialog,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                ),

                // Selected Items Section
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Selected Items',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${_selectedItems.length} items',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 140, // Height for the horizontal list
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16.0),
                    child: _buildSelectedItemsList(),
                  ),
                ),

                const SizedBox(height: 24),

                // Available Devices Section
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16.0),
                  child: Text(
                    'Radar',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child:
                      _devices.isEmpty
                          ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircularProgressIndicator(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withOpacity(0.5),
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'Scanning for devices...',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ],
                            ),
                          )
                          : ListView.builder(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
                            itemCount: _devices.length,
                            itemBuilder: (context, index) {
                              final device = _devices[index];
                              return Card(
                                margin: const EdgeInsets.only(bottom: 12),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  leading: CircleAvatar(
                                    backgroundColor:
                                        Theme.of(
                                          context,
                                        ).colorScheme.secondaryContainer,
                                    child: Icon(
                                      Icons.smartphone,
                                      color:
                                          Theme.of(
                                            context,
                                          ).colorScheme.onSecondaryContainer,
                                    ),
                                  ),
                                  title: Text(
                                    device.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  subtitle: Text(device.ip),
                                  trailing: ElevatedButton.icon(
                                    onPressed:
                                        _isTransferring ||
                                                _selectedItems.isEmpty
                                            ? null
                                            : () => _onDeviceTap(device),
                                    icon: const Icon(
                                      Icons.send_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('Drop'),
                                    style: ElevatedButton.styleFrom(
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                ),
              ],
            ),
          ),

          // Transfer Overlay
          if (_isTransferring)
            Container(
              color: Colors.black54,
              child: Center(
                child: Card(
                  margin: const EdgeInsets.all(32),
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 24),
                        const Text(
                          'Transferring...',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _transferStatus,
                          style: const TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 16),
                        LinearProgressIndicator(value: _progress),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddBottomSheet,
        child: const Icon(Icons.add),
      ),
    );
  }
}
