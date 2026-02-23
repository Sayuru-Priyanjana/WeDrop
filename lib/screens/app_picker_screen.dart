import 'dart:io';
import 'package:flutter/material.dart';
import 'package:device_apps/device_apps.dart';
import 'package:uuid/uuid.dart';
import '../models/transfer_item.dart';

class AppPickerScreen extends StatefulWidget {
  const AppPickerScreen({super.key});

  @override
  State<AppPickerScreen> createState() => _AppPickerScreenState();
}

class _AppPickerScreenState extends State<AppPickerScreen> {
  bool _isLoading = true;
  List<Application> _apps = [];
  final Set<String> _selectedAppPackages = {};

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  Future<void> _loadApps() async {
    final apps = await DeviceApps.getInstalledApplications(
      includeAppIcons: true,
      includeSystemApps: false,
      onlyAppsWithLaunchIntent: true,
    );

    // Sort alphabetically
    apps.sort(
      (a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()),
    );

    if (mounted) {
      setState(() {
        _apps = apps;
        _isLoading = false;
      });
    }
  }

  void _toggleSelection(Application app) {
    setState(() {
      if (_selectedAppPackages.contains(app.packageName)) {
        _selectedAppPackages.remove(app.packageName);
      } else {
        _selectedAppPackages.add(app.packageName);
      }
    });
  }

  void _returnSelected() {
    final uuid = const Uuid();
    final selectedItems =
        _apps
            .where((app) => _selectedAppPackages.contains(app.packageName))
            .map((app) {
              final appWithIcon = app as ApplicationWithIcon;
              final file = File(app.apkFilePath);
              final size = file.existsSync() ? file.lengthSync() : 0;

              return TransferItem(
                id: uuid.v4(),
                name: '${app.appName}.apk',
                path: app.apkFilePath,
                size: size,
                type: TransferItemType.app,
                icon: appWithIcon.icon,
              );
            })
            .toList();

    Navigator.pop(context, selectedItems);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Apps'),
        actions: [
          if (_selectedAppPackages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: _returnSelected,
              tooltip: 'Confirm Selection',
            ),
        ],
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _apps.isEmpty
              ? const Center(child: Text('No apps found.'))
              : ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 80),
                itemCount: _apps.length,
                itemBuilder: (context, index) {
                  final app = _apps[index];
                  final appWithIcon = app as ApplicationWithIcon;
                  final isSelected = _selectedAppPackages.contains(
                    app.packageName,
                  );

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 4.0,
                    ),
                    child: Card(
                      child: ListTile(
                        leading: Image.memory(
                          appWithIcon.icon,
                          width: 40,
                          height: 40,
                        ),
                        title: Text(app.appName),
                        subtitle: Text(app.versionName ?? ''),
                        trailing:
                            isSelected
                                ? Icon(
                                  Icons.check_circle,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                                : const Icon(Icons.circle_outlined),
                        onTap: () => _toggleSelection(app),
                      ),
                    ),
                  );
                },
              ),
      floatingActionButton:
          _selectedAppPackages.isNotEmpty
              ? FloatingActionButton.extended(
                onPressed: _returnSelected,
                icon: const Icon(Icons.send),
                label: Text('Send (${_selectedAppPackages.length})'),
              )
              : null,
    );
  }
}
