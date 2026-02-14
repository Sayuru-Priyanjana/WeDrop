import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class ProfileService {
  static const String _prefKeyName = 'device_name';
  static const String _prefKeyId = 'device_id';

  String? _deviceName;
  String? _deviceId;

  String get deviceName => _deviceName ?? 'Unknown Device';
  String get deviceId => _deviceId ?? '';

  Future<void> loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceName = prefs.getString(_prefKeyName);
    _deviceId = prefs.getString(_prefKeyId);

    if (_deviceId == null) {
      _deviceId = const Uuid().v4();
      await prefs.setString(_prefKeyId, _deviceId!);
    }

    if (_deviceName == null) {
      // Get default device name
      DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        _deviceName = androidInfo.model;
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        _deviceName = iosInfo.name;
      } else {
        _deviceName = 'Generic Device';
      }
      await prefs.setString(_prefKeyName, _deviceName!);
    }
  }

  Future<void> updateDeviceName(String newName) async {
    final prefs = await SharedPreferences.getInstance();
    _deviceName = newName;
    await prefs.setString(_prefKeyName, newName);
  }
}
