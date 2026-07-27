import 'dart:convert';
import 'dart:io';
import 'dart:async';

class DiscoveryMessage {
  final String type;
  final String version;
  final String deviceId;
  final String name;
  final String platform;
  final String ip;
  final int tcpPort;
  final String publicKey;

  DiscoveryMessage({
    required this.type,
    required this.version,
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.ip,
    required this.tcpPort,
    required this.publicKey,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'version': version,
    'device_id': deviceId,
    'name': name,
    'platform': platform,
    'ip': ip,
    'tcp_port': tcpPort,
    'public_key': publicKey,
  };

  factory DiscoveryMessage.fromJson(Map<String, dynamic> json) {
    return DiscoveryMessage(
      type: json['type'] ?? '',
      version: json['version'] ?? '',
      deviceId: json['device_id'] ?? '',
      name: json['name'] ?? '',
      platform: json['platform'] ?? '',
      ip: json['ip'] ?? '',
      tcpPort: json['tcp_port'] ?? 47821,
      publicKey: json['public_key'] ?? '',
    );
  }
}

class DiscoveryService {
  static const int port = 47820;
  static const String multicastIP = '239.255.90.90';
  
  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  final DiscoveryMessage localConfig;
  
  final Map<String, DiscoveryMessage> peers = {};
  final StreamController<DiscoveryMessage> _peerStreamController = StreamController.broadcast();
  final StreamController<Map<String, dynamic>> _pairingRequestController = StreamController.broadcast();

  Stream<DiscoveryMessage> get peerStream => _peerStreamController.stream;
  Stream<Map<String, dynamic>> get pairingRequestStream => _pairingRequestController.stream;

  ServerSocket? _tcpServer;

  DiscoveryService(this.localConfig);

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    _socket?.multicastHops = 1;
    _socket?.broadcastEnabled = true;
    
    try {
      _socket?.joinMulticast(InternetAddress(multicastIP));
    } catch (e) {
      print('Could not join multicast group: $e');
    }

    _socket?.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        Datagram? dg = _socket?.receive();
        if (dg != null) {
          try {
            final String message = utf8.decode(dg.data);
            final Map<String, dynamic> json = jsonDecode(message);
            final msg = DiscoveryMessage.fromJson(json);
            
            if (msg.type == 'wedrop_discovery' && msg.deviceId != localConfig.deviceId) {
              peers[msg.deviceId] = msg;
              _peerStreamController.add(msg);
            }
          } catch (e) {
            // Invalid message
          }
        }
      }
    });

    _broadcastTimer = Timer.periodic(const Duration(seconds: 5), (_) => _broadcast());
    _broadcast();

    // Start TCP Listener for Pairing Requests
    try {
      _tcpServer = await ServerSocket.bind(InternetAddress.anyIPv4, localConfig.tcpPort);
      _tcpServer?.listen((Socket client) {
        client.listen((List<int> data) {
          try {
            if (data.length > 4) {
              final payload = data.sublist(4);
              String jsonStr = utf8.decode(payload);
              if (jsonStr.contains('pairing_req')) {
                final json = jsonDecode(jsonStr);
                _pairingRequestController.add({'req': json, 'client': client});
              }
            }
          } catch (e) {}
        });
      });
    } catch (e) {}
  }

  Future<void> _broadcast() async {
    if (_socket == null) return;
    
    final String data = jsonEncode(localConfig.toJson());
    final List<int> bytes = utf8.encode(data);
    
    try {
      _socket?.send(bytes, InternetAddress(multicastIP), port);
    } catch (e) {
      // ignore multicast errors
    }
    
    try {
      _socket?.send(bytes, InternetAddress('255.255.255.255'), port);
    } catch (e) {
      // ignore broadcast errors
    }

    // Android Hotspot fallback: mathematically guess subnet broadcasts
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            // Hotspots are always /24
            final bcastIp = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            try {
              _socket?.send(bytes, InternetAddress(bcastIp), port);
            } catch (e) {}
          }
        }
      }
    } catch (e) {}
  }

  void stop() {
    _broadcastTimer?.cancel();
    _socket?.close();
    _socket = null;
    _tcpServer?.close();
    _tcpServer = null;
  }
}
