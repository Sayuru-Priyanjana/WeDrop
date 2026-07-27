import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:mobile/core/discovery/discovery_service.dart';

void main() {
  runApp(const WeDropApp());
}

class WeDropApp extends StatelessWidget {
  const WeDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WeDrop',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: const Color(0xFF3B82F6),
          secondary: const Color(0xFF8B5CF6),
          surface: const Color(0xFF151A2B),
        ),
        fontFamily: 'Inter',
      ),
      home: const Dashboard(),
    );
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  DiscoveryService? _discoveryService;
  List<DiscoveryMessage> _devices = [];
  List<Map<String, dynamic>> _trustedDevices = [];

  @override
  void initState() {
    super.initState();
    _initDiscovery();
  }

  void _initDiscovery() async {
    final localConfig = DiscoveryMessage(
      type: 'wedrop_discovery',
      version: '1.0',
      deviceId: 'wd-mobile-1',
      name: 'My Phone',
      platform: 'Android',
      ip: '127.0.0.1', 
      tcpPort: 47821,
      publicKey: 'xxx', 
    );
    
    _discoveryService = DiscoveryService(localConfig);
    _discoveryService?.peerStream.listen((msg) {
      setState(() {
        if (!_devices.any((d) => d.deviceId == msg.deviceId)) {
          _devices.add(msg);
        }
      });
    });

    _discoveryService?.pairingRequestStream.listen((event) {
      final req = event['req'];
      final Socket client = event['client'];
      
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Pairing Request'),
          content: Text('${req['name']} wants to join your Ecosystem. Do you trust this device?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _sendPairingResponse(client, false);
              },
              child: const Text('Reject', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                setState(() {
                  _trustedDevices.add({
                    'device_id': req['device_id'],
                    'name': req['name'],
                    'platform': 'Windows', // Guessing based on req
                  });
                });
                _sendPairingResponse(client, true);
              },
              child: const Text('Accept'),
            ),
          ],
        ),
      );
    });
    
    await _discoveryService?.start();
  }

  void _sendPairingResponse(Socket client, bool accepted) {
    final resp = jsonEncode({'type': 'pairing_resp', 'device_id': 'wd-mobile-1', 'accepted': accepted});
    final bytes = utf8.encode(resp);
    final lenBytes = Uint8List(4)..buffer.asByteData().setUint32(0, bytes.length, Endian.big);
    client.add([...lenBytes, ...bytes]);
  }

  void _requestPairing(DiscoveryMessage peer) async {
    try {
      final socket = await Socket.connect(peer.ip, peer.tcpPort, timeout: const Duration(seconds: 2));
      final req = jsonEncode({
        'type': 'pairing_req',
        'device_id': 'wd-mobile-1',
        'name': 'My Phone',
        'public_key': 'xxx'
      });
      final bytes = utf8.encode(req);
      final lenBytes = Uint8List(4)..buffer.asByteData().setUint32(0, bytes.length, Endian.big);
      socket.add([...lenBytes, ...bytes]);

      // Wait for response
      socket.listen((data) {
        if (data.length > 4) {
          final payload = data.sublist(4);
          String jsonStr = utf8.decode(payload);
          final resp = jsonDecode(jsonStr);
          if (resp['type'] == 'pairing_resp' && resp['accepted'] == true) {
            setState(() {
              _trustedDevices.add({
                'device_id': peer.deviceId,
                'name': peer.name,
                'platform': peer.platform,
              });
            });
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Paired successfully!')));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pairing rejected.')));
          }
        }
        socket.close();
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to connect: $e')));
    }
  }

  @override
  void dispose() {
    _discoveryService?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final untrusted = _devices.where((d) => !_trustedDevices.any((t) => t['device_id'] == d.deviceId)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('WeDrop Ecosystem', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.8, -0.8),
            radius: 1.5,
            colors: [Color(0x203B82F6), Colors.transparent],
            stops: [0.0, 1.0],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('My Ecosystem', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              if (_trustedDevices.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text('No paired devices.', style: TextStyle(color: Colors.white54)),
                )
              else
                SizedBox(
                  height: 120,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _trustedDevices.length,
                    itemBuilder: (context, index) {
                      final device = _trustedDevices[index];
                      return Container(
                        width: 140,
                        margin: const EdgeInsets.only(right: 16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.3)),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.check_circle, color: Colors.green, size: 32),
                            const SizedBox(height: 8),
                            Text(device['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              
              const SizedBox(height: 32),
              const Text('Nearby Radar', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Expanded(
                child: untrusted.isEmpty
                    ? const Center(child: Text('Scanning...', style: TextStyle(color: Colors.white54)))
                    : GridView.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                          childAspectRatio: 0.85,
                        ),
                        itemCount: untrusted.length,
                        itemBuilder: (context, index) {
                          final device = untrusted[index];
                          return _DeviceCard(
                            device: device,
                            onPair: () => _requestPairing(device),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final DiscoveryMessage device;
  final VoidCallback onPair;

  const _DeviceCard({required this.device, required this.onPair});

  @override
  Widget build(BuildContext context) {
    IconData icon = Icons.device_unknown;
    if (device.platform == 'Windows') icon = Icons.laptop_windows;
    else if (device.platform == 'Linux') icon = Icons.laptop;
    else if (device.platform == 'Android') icon = Icons.phone_android;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.1),
                  Colors.transparent,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Icon(icon, color: Colors.white70),
          ),
          const Spacer(),
          Text(
            device.name,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Colors.orange,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${device.platform} • Untrusted',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onPair,
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Pair', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}
