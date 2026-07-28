import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../crypto/identity.dart';
import '../protocol/messages.dart';

/// Persistent state: this device's identity, its settings, and the trust store.
///
/// Android already sandboxes an app's preferences from every other app, so the
/// identity seed is stored there directly rather than behind a second layer of
/// encryption whose key would have to live in the same place.

const _keyDeviceId = 'wedrop.device_id';
const _keySeed = 'wedrop.identity_seed';
const _keyPublic = 'wedrop.identity_public';
const _keyName = 'wedrop.device_name';
const _keySettings = 'wedrop.settings';
const _keyTrusted = 'wedrop.trusted_devices';
const _keyWorkspace = 'wedrop.workspace_buttons';

/// Every user-facing toggle. Each feature has separate send and receive
/// switches, because "share my clipboard" and "let others change my clipboard"
/// are genuinely different decisions.
class Settings {
  bool autoSyncClipboard;
  bool receiveClipboard;
  int clipboardMaxChars;

  bool autoAcceptFiles;

  bool shareNotifications;
  bool receiveNotifications;

  bool allowMediaControl;

  /// Multiplier applied to the Remote tab's touchpad deltas before they're
  /// sent — 1.0 is the original speed, higher moves the remote cursor
  /// further per physical drag distance.
  double cursorSpeed;

  /// Off by default, unlike every other feature here: lets a paired device's
  /// "My Workspace" buttons run shell/script commands, not just
  /// shortcuts/open actions. Checked in addition to a device's own
  /// allowWorkspace, not instead of it.
  bool allowAutomation;

  bool discoverable;
  bool acceptNewPairing;
  bool runInBackground;

  /// Off by default: keeps the per-device overview down to the basics
  /// (battery, sound) most people actually look at, with network/CPU/memory
  /// tucked behind this toggle for anyone who wants the detail.
  bool showAdvancedFeatures;

  Settings({
    this.autoSyncClipboard = true,
    this.receiveClipboard = true,
    this.clipboardMaxChars = 65536,
    this.autoAcceptFiles = true,
    this.shareNotifications = true,
    this.receiveNotifications = true,
    this.allowMediaControl = true,
    this.cursorSpeed = 1.0,
    this.allowAutomation = false,
    this.discoverable = true,
    this.acceptNewPairing = true,
    this.runInBackground = true,
    this.showAdvancedFeatures = false,
  });

  /// The capabilities advertised to peers, derived from the receive switches so
  /// peers can skip sending what this device would discard.
  List<String> get capabilities => [
        if (receiveClipboard) Capability.clipboard,
        Capability.files,
        if (receiveNotifications) Capability.notifications,
        if (allowMediaControl) Capability.media,
        Capability.workspace,
        Capability.health,
      ];

  Map<String, dynamic> toJson() => {
        'auto_sync_clipboard': autoSyncClipboard,
        'receive_clipboard': receiveClipboard,
        'clipboard_max_chars': clipboardMaxChars,
        'auto_accept_files': autoAcceptFiles,
        'share_notifications': shareNotifications,
        'receive_notifications': receiveNotifications,
        'allow_media_control': allowMediaControl,
        'cursor_speed': cursorSpeed,
        'allow_automation': allowAutomation,
        'discoverable': discoverable,
        'accept_new_pairing': acceptNewPairing,
        'run_in_background': runInBackground,
        'show_advanced_features': showAdvancedFeatures,
      };

  factory Settings.fromJson(Map<String, dynamic> json) => Settings(
        autoSyncClipboard: json['auto_sync_clipboard'] as bool? ?? true,
        receiveClipboard: json['receive_clipboard'] as bool? ?? true,
        clipboardMaxChars: json['clipboard_max_chars'] as int? ?? 65536,
        autoAcceptFiles: json['auto_accept_files'] as bool? ?? true,
        shareNotifications: json['share_notifications'] as bool? ?? true,
        receiveNotifications: json['receive_notifications'] as bool? ?? true,
        allowMediaControl: json['allow_media_control'] as bool? ?? true,
        cursorSpeed: (json['cursor_speed'] as num?)?.toDouble() ?? 1.0,
        allowAutomation: json['allow_automation'] as bool? ?? false,
        discoverable: json['discoverable'] as bool? ?? true,
        acceptNewPairing: json['accept_new_pairing'] as bool? ?? true,
        runInBackground: json['run_in_background'] as bool? ?? true,
        showAdvancedFeatures: json['show_advanced_features'] as bool? ?? false,
      );

  Settings copy() => Settings.fromJson(toJson());
}

/// A paired member of the ecosystem, plus the per-device permissions that
/// override the global settings for that one peer.
class TrustedDevice {
  final String deviceId;
  String name;
  String platform;
  String formFactor;
  final String publicKey;
  final int pairedAt;
  int lastSeen;

  bool allowClipboard;
  bool allowFiles;
  bool allowNotifications;
  bool allowMedia;
  // Whether this device may send workspace actions at all. The actually-risky
  // action (running a shell command) has its own separate, off-by-default
  // gate — Settings.allowAutomation, a global switch checked in addition to
  // this one, not instead of it.
  bool allowWorkspace;

  TrustedDevice({
    required this.deviceId,
    required this.name,
    required this.publicKey,
    this.platform = '',
    this.formFactor = FormFactor.desktop,
    int? pairedAt,
    this.lastSeen = 0,
    this.allowClipboard = true,
    this.allowFiles = true,
    this.allowNotifications = true,
    this.allowMedia = true,
    this.allowWorkspace = true,
  }) : pairedAt = pairedAt ?? DateTime.now().millisecondsSinceEpoch;

  bool allows(String capability) {
    switch (capability) {
      case Capability.clipboard:
        return allowClipboard;
      case Capability.files:
        return allowFiles;
      case Capability.notifications:
        return allowNotifications;
      case Capability.media:
        return allowMedia;
      case Capability.workspace:
        return allowWorkspace;
    }
    return false;
  }

  void setPermission(String capability, bool allowed) {
    switch (capability) {
      case Capability.clipboard:
        allowClipboard = allowed;
        break;
      case Capability.files:
        allowFiles = allowed;
        break;
      case Capability.notifications:
        allowNotifications = allowed;
        break;
      case Capability.media:
        allowMedia = allowed;
        break;
      case Capability.workspace:
        allowWorkspace = allowed;
        break;
    }
  }

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'name': name,
        'platform': platform,
        'form_factor': formFactor,
        'public_key': publicKey,
        'paired_at': pairedAt,
        'last_seen': lastSeen,
        'allow_clipboard': allowClipboard,
        'allow_files': allowFiles,
        'allow_notifications': allowNotifications,
        'allow_media': allowMedia,
        'allow_workspace': allowWorkspace,
      };

  factory TrustedDevice.fromJson(Map<String, dynamic> json) => TrustedDevice(
        deviceId: json['device_id'] as String? ?? '',
        name: json['name'] as String? ?? 'Device',
        platform: json['platform'] as String? ?? '',
        formFactor: json['form_factor'] as String? ?? FormFactor.desktop,
        publicKey: json['public_key'] as String? ?? '',
        pairedAt: json['paired_at'] as int?,
        lastSeen: json['last_seen'] as int? ?? 0,
        allowClipboard: json['allow_clipboard'] as bool? ?? true,
        allowFiles: json['allow_files'] as bool? ?? true,
        allowNotifications: json['allow_notifications'] as bool? ?? true,
        allowMedia: json['allow_media'] as bool? ?? true,
        allowWorkspace: json['allow_workspace'] as bool? ?? true,
      );
}

/// One user-defined "My Workspace" button — scoped to a single paired
/// desktop (a button like "open VS Code" only means something on the
/// specific machine it targets), not a global cross-device profile.
class WorkspaceButton {
  final String id;
  String label;
  String icon;
  int colorValue;
  String actionType; // WorkspaceActionType.*
  Map<String, dynamic> actionParams;
  int order;

  WorkspaceButton({
    required this.id,
    required this.label,
    required this.icon,
    required this.colorValue,
    required this.actionType,
    this.actionParams = const {},
    this.order = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'icon': icon,
        'color_value': colorValue,
        'action_type': actionType,
        'action_params': actionParams,
        'order': order,
      };

  factory WorkspaceButton.fromJson(Map<String, dynamic> json) => WorkspaceButton(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
        colorValue: json['color_value'] as int? ?? 0xFF4F7CFF,
        actionType: json['action_type'] as String? ?? '',
        actionParams: (json['action_params'] as Map?)?.cast<String, dynamic>() ?? const {},
        order: json['order'] as int? ?? 0,
      );
}

/// Loads and saves everything that must survive a restart.
class WeDropStore {
  final SharedPreferences _prefs;

  late DeviceIdentity identity;
  late Settings settings;
  late String deviceName;
  final Map<String, TrustedDevice> _trusted = {};
  final Map<String, List<WorkspaceButton>> _workspace = {};

  WeDropStore._(this._prefs);

  /// Opens the store, creating an identity on first run.
  static Future<WeDropStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    final store = WeDropStore._(prefs);
    await store._load();
    return store;
  }

  Future<void> _load() async {
    var deviceId = _prefs.getString(_keyDeviceId);
    final seedB64 = _prefs.getString(_keySeed);
    final publicB64 = _prefs.getString(_keyPublic);

    if (deviceId != null && seedB64 != null && publicB64 != null) {
      try {
        identity = await DeviceIdentity.restore(
          deviceId: deviceId,
          privateKeyBytes: Uint8List.fromList(base64.decode(seedB64)),
          publicKeyBytes: Uint8List.fromList(base64.decode(publicB64)),
        );
      } catch (_) {
        // A key that will not load is worse than none: every handshake would
        // fail with an obscure signature error. Start fresh instead.
        deviceId = null;
      }
    }

    if (deviceId == null) {
      deviceId = const Uuid().v4();
      identity = await DeviceIdentity.generate(deviceId);
      await _prefs.setString(_keyDeviceId, deviceId);
      await _prefs.setString(_keySeed, base64.encode(await identity.extractSeed()));
      await _prefs.setString(_keyPublic, identity.publicKeyBase64);
    }

    deviceName = _prefs.getString(_keyName) ?? 'My Phone';

    final settingsRaw = _prefs.getString(_keySettings);
    settings = settingsRaw == null
        ? Settings()
        : Settings.fromJson(jsonDecode(settingsRaw) as Map<String, dynamic>);

    final trustedRaw = _prefs.getString(_keyTrusted);
    if (trustedRaw != null) {
      try {
        for (final entry in jsonDecode(trustedRaw) as List) {
          final device = TrustedDevice.fromJson(entry as Map<String, dynamic>);
          if (device.deviceId.isNotEmpty) _trusted[device.deviceId] = device;
        }
      } catch (_) {
        // A corrupt list must not stop the app from starting; the user can
        // pair again. Refusing to launch would be far worse.
      }
    }

    final workspaceRaw = _prefs.getString(_keyWorkspace);
    if (workspaceRaw != null) {
      try {
        (jsonDecode(workspaceRaw) as Map<String, dynamic>).forEach((deviceId, buttons) {
          _workspace[deviceId] = (buttons as List)
              .map((e) => WorkspaceButton.fromJson(e as Map<String, dynamic>))
              .toList();
        });
      } catch (_) {
        // A corrupt map must not stop the app from starting.
      }
    }
  }

  String get deviceId => identity.deviceId;

  List<TrustedDevice> get trustedDevices {
    final list = _trusted.values.toList();
    list.sort((a, b) => b.pairedAt.compareTo(a.pairedAt));
    return list;
  }

  TrustedDevice? trusted(String deviceId) => _trusted[deviceId];

  String? trustedKey(String deviceId) => _trusted[deviceId]?.publicKey;

  bool isTrusted(String deviceId) => _trusted.containsKey(deviceId);

  bool allows(String deviceId, String capability) =>
      _trusted[deviceId]?.allows(capability) ?? false;

  Future<void> addTrusted(TrustedDevice device) async {
    final existing = _trusted[device.deviceId];
    if (existing != null) {
      // Preserve the permissions the user already chose for this device.
      device
        ..allowClipboard = existing.allowClipboard
        ..allowFiles = existing.allowFiles
        ..allowNotifications = existing.allowNotifications
        ..allowMedia = existing.allowMedia
        ..allowWorkspace = existing.allowWorkspace;
    }
    _trusted[device.deviceId] = device;
    await _saveTrusted();
  }

  Future<void> removeTrusted(String deviceId) async {
    _trusted.remove(deviceId);
    await _saveTrusted();
  }

  Future<void> setPermission(String deviceId, String capability, bool allowed) async {
    _trusted[deviceId]?.setPermission(capability, allowed);
    await _saveTrusted();
  }

  Future<void> renameTrusted(String deviceId, String name) async {
    final device = _trusted[deviceId];
    if (device == null || device.name == name) return;
    device.name = name;
    await _saveTrusted();
  }

  /// Records that we just heard from a device, skipping the write when the
  /// stored value is already recent so an idle ecosystem is not constantly
  /// rewriting preferences.
  Future<void> touchLastSeen(String deviceId) async {
    final device = _trusted[deviceId];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (device == null || now - device.lastSeen < 60000) return;
    device.lastSeen = now;
    await _saveTrusted();
  }

  Future<void> saveSettings(Settings next) async {
    settings = next;
    await _prefs.setString(_keySettings, jsonEncode(next.toJson()));
  }

  Future<void> setDeviceName(String name) async {
    deviceName = name;
    await _prefs.setString(_keyName, name);
  }

  Future<void> _saveTrusted() async {
    final list = _trusted.values.map((d) => d.toJson()).toList();
    await _prefs.setString(_keyTrusted, jsonEncode(list));
  }

  /// This device's own "My Workspace" buttons, in display order.
  List<WorkspaceButton> workspaceButtons(String deviceId) {
    final list = List.of(_workspace[deviceId] ?? const <WorkspaceButton>[]);
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  Future<void> saveWorkspaceButtons(String deviceId, List<WorkspaceButton> buttons) async {
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].order = i;
    }
    _workspace[deviceId] = buttons;
    await _prefs.setString(
      _keyWorkspace,
      jsonEncode(_workspace.map((id, list) => MapEntry(id, list.map((b) => b.toJson()).toList()))),
    );
  }
}
