import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'core/app_service.dart';
import 'core/platform/native_bridge.dart';
import 'core/transport/connection_manager.dart' show PairingRequest;
import 'ui/screens.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Wire the two indirection hooks the UI uses to reach the platform bridge,
  // so the screen widgets never import it directly.
  NotificationAccessRequest.open = NativeBridge.requestNotificationAccess;
  BatteryOptimisationRequest.open = NativeBridge.requestIgnoreBatteryOptimisations;

  runApp(const WeDropApp());
}

class WeDropApp extends StatelessWidget {
  const WeDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WeDrop',
      debugShowCheckedModeBanner: false,
      theme: buildWeDropTheme(),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  final AppService _service = AppService();
  StreamSubscription<String>? _toastSub;

  int _tab = 0;
  String? _pairingWith;
  bool _pairingDialogOpen = false;
  bool _fileDialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _service.addListener(_onServiceChanged);
    _toastSub = _service.toasts.listen(_showToast);
    _service.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _toastSub?.cancel();
    _service.removeListener(_onServiceChanged);
    _service.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-check whether notification access was granted while away, and — the
      // important part — read and share anything copied in another app, since
      // Android only lets us read the clipboard now that we are focused again.
      _service.refreshNotificationAccess();
      _service.syncClipboardOnResume();
    }
  }

  void _onServiceChanged() {
    if (!mounted) return;
    setState(() {});
    _maybeShowPrompts();
    _maybeHandleSharedFiles();
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Surfaces the pairing and incoming-file dialogs when the service raises one.
  Future<void> _maybeShowPrompts() async {
    final pairing = _service.pairingPrompt;
    if (pairing != null && !_pairingDialogOpen) {
      _pairingDialogOpen = true;
      await _showPairingDialog(pairing);
      _pairingDialogOpen = false;
    }

    final incoming = _service.incomingFilePrompt;
    if (incoming != null && !_fileDialogOpen) {
      _fileDialogOpen = true;
      await _showIncomingFileDialog(incoming);
      _fileDialogOpen = false;
    }
  }

  /// If a file was shared into WeDrop, ask which device should receive it.
  Future<void> _maybeHandleSharedFiles() async {
    if (_service.pendingSharedFiles.isEmpty) return;
    if (_shareSheetOpen) return;

    _shareSheetOpen = true;
    final paths = List<String>.from(_service.pendingSharedFiles);
    _service.clearSharedFiles();

    await _pickTargetAndSend(paths);
    _shareSheetOpen = false;
  }

  bool _shareSheetOpen = false;

  Future<void> _showPairingDialog(PairingPrompt prompt) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PairingDialog(
        request: prompt.request,
        onDecline: () {
          Navigator.pop(context);
          _service.respondToPairing(false);
        },
        onAccept: () {
          Navigator.pop(context);
          _service.respondToPairing(true);
        },
      ),
    );
    // If the request timed out while the dialog was open, close it.
    if (mounted && _service.pairingPrompt == null && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  Future<void> _showIncomingFileDialog(IncomingFilePrompt prompt) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Incoming file'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${prompt.deviceName} wants to send you a file.'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: WeDropColors.bgSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    prompt.offer.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500, color: WeDropColors.ink),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    formatBytes(prompt.offer.size),
                    style: const TextStyle(fontSize: 12, color: WeDropColors.inkFaint),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _service.respondToIncomingFile(false);
            },
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _service.respondToIncomingFile(true);
            },
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  Future<void> _startPairing(String deviceId) async {
    setState(() => _pairingWith = deviceId);
    try {
      await _service.pairWith(deviceId);
    } catch (error) {
      _showToast(error.toString());
    } finally {
      if (mounted) setState(() => _pairingWith = null);
    }
  }

  /// Picks files from the device, then sends them to the chosen destination.
  Future<void> _sendFilesTo(DeviceView device) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths = result?.paths.whereType<String>().toList() ?? const [];
    if (paths.isEmpty) return;

    setState(() => _tab = 1);
    try {
      await _service.sendFiles(device.deviceId, paths);
    } catch (error) {
      _showToast(error.toString());
    }
  }

  /// The share-intent flow: choose a paired, online device for the shared file.
  Future<void> _pickTargetAndSend(List<String> paths) async {
    final candidates = _service.pairedDevices.where((d) => d.online).toList();

    if (candidates.isEmpty) {
      _showToast('No connected devices to send to');
      return;
    }

    final target = await showModalBottomSheet<DeviceView>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Send ${paths.length == 1 ? 'file' : '${paths.length} files'} to',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: WeDropColors.ink,
                ),
              ),
            ),
            ...candidates.map((device) => ListTile(
                  leading: Icon(
                    iconForFormFactor(device.formFactor),
                    color: WeDropColors.brandSoft,
                  ),
                  title: Text(device.name, style: const TextStyle(color: WeDropColors.ink)),
                  subtitle: Text(
                    device.connected ? 'Connected' : 'On the network',
                    style: const TextStyle(color: WeDropColors.inkFaint),
                  ),
                  onTap: () => Navigator.pop(context, device),
                )),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );

    if (target == null) return;

    setState(() => _tab = 1);
    try {
      await _service.sendFiles(target.deviceId, paths);
    } catch (error) {
      _showToast(error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_service.ready && _service.startupError.isEmpty) {
      return const _Splash();
    }
    if (_service.startupError.isNotEmpty) {
      return _StartupError(message: _service.startupError);
    }

    // The outgoing-pairing code overlays whatever tab is showing.
    final outgoing = _service.outgoingPairingCode != null
        ? _OutgoingPairingOverlay(
            name: _service.outgoingPairingName ?? 'device',
            code: _service.outgoingPairingCode!,
          )
        : null;

    final connected = _service.connectedCount;
    final unread = _service.notifications.length;

    final body = switch (_tab) {
      0 => DevicesScreen(
          service: _service,
          onSendFiles: _sendFilesTo,
          onPair: _startPairing,
          pairingWith: _pairingWith,
        ),
      1 => TransfersScreen(service: _service),
      2 => ClipboardScreen(service: _service),
      3 => NotificationsScreen(service: _service),
      _ => SettingsScreen(service: _service),
    };

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [WeDropColors.brand, WeDropColors.accent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.hub_rounded, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('WeDrop', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                Text(
                  connected == 0 ? 'No devices connected' : '$connected connected',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w400,
                    color: WeDropColors.inkFaint,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          // A soft glow, matching the desktop backdrop.
          Positioned(
            top: -120,
            right: -80,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [WeDropColors.brand.withValues(alpha: 0.14), Colors.transparent],
                ),
              ),
            ),
          ),
          SafeArea(child: body),
          ?outgoing,
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.devices_outlined),
            selectedIcon: Icon(Icons.devices_rounded),
            label: 'Devices',
          ),
          const NavigationDestination(
            icon: Icon(Icons.swap_horiz_outlined),
            selectedIcon: Icon(Icons.swap_horiz_rounded),
            label: 'Transfers',
          ),
          const NavigationDestination(
            icon: Icon(Icons.content_paste_outlined),
            selectedIcon: Icon(Icons.content_paste_rounded),
            label: 'Clipboard',
          ),
          NavigationDestination(
            icon: unread > 0
                ? Badge(label: Text('$unread'), child: const Icon(Icons.notifications_outlined))
                : const Icon(Icons.notifications_outlined),
            selectedIcon: const Icon(Icons.notifications_rounded),
            label: 'Alerts',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class _PairingDialog extends StatelessWidget {
  final PairingRequest request;
  final VoidCallback onDecline;
  final VoidCallback onAccept;

  const _PairingDialog({
    required this.request,
    required this.onDecline,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join your ecosystem?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${request.name} (${request.platform}) wants to pair with this phone.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: WeDropColors.inkDim, height: 1.4),
          ),
          const SizedBox(height: 20),
          VerificationCodeDisplay(request.verificationCode),
        ],
      ),
      actions: [
        TextButton(onPressed: onDecline, child: const Text('Decline')),
        FilledButton(onPressed: onAccept, child: const Text('Accept')),
      ],
    );
  }
}

class _OutgoingPairingOverlay extends StatelessWidget {
  final String name;
  final String code;

  const _OutgoingPairingOverlay({required this.name, required this.code});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.65),
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: WeDropColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: WeDropColors.borderHi),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.shield_outlined, size: 44, color: WeDropColors.brand),
              const SizedBox(height: 16),
              Text(
                'Waiting for $name',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: WeDropColors.ink,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Accept the request on that device to finish pairing.',
                textAlign: TextAlign.center,
                style: TextStyle(color: WeDropColors.inkDim, height: 1.4),
              ),
              const SizedBox(height: 24),
              VerificationCodeDisplay(code),
            ],
          ),
        ),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: WeDropColors.brand),
            ),
            SizedBox(height: 16),
            Text('Starting WeDrop…', style: TextStyle(color: WeDropColors.inkFaint)),
          ],
        ),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  final String message;

  const _StartupError({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 44, color: WeDropColors.danger),
              const SizedBox(height: 16),
              const Text(
                'WeDrop could not start',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: WeDropColors.danger,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: WeDropColors.inkDim, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
