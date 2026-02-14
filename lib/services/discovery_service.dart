import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/device.dart';
import 'profile_service.dart';

class DiscoveryService {
  static const int _port = 45455; // UDP Port
  static const String _protocolId = 'SHARE_APP';

  // Stream of discovered devices
  final _devicesController = StreamController<List<Device>>.broadcast();
  Stream<List<Device>> get devicesStream => _devicesController.stream;

  final List<Device> _devices = [];
  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  final ProfileService _profileService;

  DiscoveryService(this._profileService);

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _port);
    _socket!.broadcastEnabled = true;

    _socket!.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        final datagram = _socket!.receive();
        if (datagram != null) {
          _handleMessage(datagram);
        }
      }
    });

    // Start broadcasting existence
    _broadcastTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _broadcastPresence();
    });
  }

  void _broadcastPresence() {
    if (_socket == null) return;
    final message =
        '$_protocolId:${_profileService.deviceId}:${_profileService.deviceName}';
    final data = utf8.encode(message);
    _socket!.send(data, InternetAddress('255.255.255.255'), _port);
  }

  void _handleMessage(Datagram datagram) {
    final message = utf8.decode(datagram.data).trim();
    if (!message.startsWith(_protocolId)) return;

    final parts = message.split(':');
    if (parts.length < 3) return;

    final id = parts[1];
    final name = parts.sublist(2).join(':'); // In case name has colons
    final ip = datagram.address.address;

    // Don't add self
    if (id == _profileService.deviceId) return;

    // Update or Add device
    final device = Device(id: id, name: name, ip: ip);
    final index = _devices.indexWhere((d) => d.id == id);

    if (index != -1) {
      // Update existing (maybe name changed or IP changed)
      // For now, simpler to just replace if needed, or ignore if same.
      // We'll update the list to refresh UI timestamps if we had them.
      _devices[index] = device;
    } else {
      _devices.add(device);
      _devicesController.add(List.from(_devices));
    }
  }

  void stop() {
    _broadcastTimer?.cancel();
    _socket?.close();
  }
}
