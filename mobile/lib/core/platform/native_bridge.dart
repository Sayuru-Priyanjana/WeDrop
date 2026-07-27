import 'dart:async';

import 'package:flutter/services.dart';

/// The bridge to the Android side: the foreground service that keeps WeDrop
/// alive, the share sheet, notification mirroring, and media keys.
///
/// Everything here degrades quietly on platforms that do not implement the
/// channel, so the app still runs on iOS and desktop for development.
class NativeBridge {
  static const MethodChannel _channel = MethodChannel('wedrop/native');
  static const EventChannel _events = EventChannel('wedrop/events');

  static Stream<Map<String, dynamic>>? _eventStream;

  /// Events pushed up from Android: shared files, notifications, media state.
  static Stream<Map<String, dynamic>> get events {
    _eventStream ??= _events.receiveBroadcastStream().map((event) {
      if (event is Map) return Map<String, dynamic>.from(event);
      return <String, dynamic>{};
    }).handleError((_) {
      // A dropped event channel must not take the app down with it.
    });
    return _eventStream!;
  }

  /// Starts the foreground service that keeps sockets alive when the app is
  /// not on screen. Android kills background processes aggressively; a
  /// foreground service with a visible notification is the only supported way
  /// to keep an always-on sync running.
  static Future<void> startBackgroundService({required String status}) async {
    try {
      await _channel.invokeMethod('startService', {'status': status});
    } on PlatformException {
      // Not fatal — the app simply stops syncing when it is swiped away.
    } on MissingPluginException {
      // Not Android; nothing to start.
    }
  }

  static Future<void> stopBackgroundService() async {
    try {
      await _channel.invokeMethod('stopService');
    } catch (_) {}
  }

  /// Updates the text on the ongoing notification, e.g. "3 devices connected".
  static Future<void> updateServiceStatus(String status) async {
    try {
      await _channel.invokeMethod('updateStatus', {'status': status});
    } catch (_) {}
  }

  /// Any file shared into WeDrop before the Dart side was listening. Android
  /// may deliver a share intent while the engine is still starting, so the
  /// native side queues it and Dart drains it once ready.
  static Future<List<String>> consumePendingShares() async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>('consumeSharedFiles');
      return result?.map((e) => e.toString()).toList() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Whether the user has granted notification-listener access, which Android
  /// requires before any app can read other apps' notifications.
  static Future<bool> hasNotificationAccess() async {
    try {
      return await _channel.invokeMethod<bool>('hasNotificationAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system settings page where notification access is granted.
  /// There is no programmatic way to request it.
  static Future<void> requestNotificationAccess() async {
    try {
      await _channel.invokeMethod('requestNotificationAccess');
    } catch (_) {}
  }

  /// Whether the app may post its own notifications (Android 13+ runtime
  /// permission), needed to show mirrored alerts and transfer results.
  static Future<bool> requestPostNotifications() async {
    try {
      return await _channel.invokeMethod<bool>('requestPostNotifications') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Shows a local notification for something that arrived from a peer.
  static Future<void> showNotification({
    required String title,
    required String body,
    String tag = '',
  }) async {
    try {
      await _channel.invokeMethod('showNotification', {
        'title': title,
        'body': body,
        'tag': tag,
      });
    } catch (_) {}
  }

  /// Applies a media command to this device's current playback session.
  static Future<void> applyMediaCommand(String command) async {
    try {
      await _channel.invokeMethod('mediaCommand', {'command': command});
    } catch (_) {}
  }

  /// Asks Android to exempt WeDrop from battery optimisation, without which
  /// Doze can suspend the sockets for long stretches.
  static Future<void> requestIgnoreBatteryOptimisations() async {
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimisations');
    } catch (_) {}
  }

  /// A friendly name for this handset, used as the default device name.
  static Future<String?> deviceModelName() async {
    try {
      return await _channel.invokeMethod<String>('deviceName');
    } catch (_) {
      return null;
    }
  }
}
