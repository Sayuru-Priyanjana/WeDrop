import 'dart:async';
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
const _keyLayouts = 'wedrop.workspace_layouts';
const _keyActiveLayout = 'wedrop.active_layout';

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
        Capability.adaptiveControls,
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

/// The built-in Workspace-tab widget types. A "widget" here is one card in
/// the tab's layout — the same content that used to be permanently stacked
/// (desktop switcher, dynamic controls, My-buttons grid) plus the new
/// minimized-apps card, now addable/removable/resizable per named layout.
class WidgetType {
  static const desktopSwitcher = 'desktop_switcher';
  static const adaptiveControls = 'adaptive_controls';
  static const minimizedApps = 'minimized_apps';
  static const buttons = 'buttons';
  static const mediaController = 'media_controller';

  /// Display name and icon key (into ui/workspace_tab.dart's kWorkspaceIcons)
  /// for the "add widget" store — kept next to the type constants so a new
  /// widget type only needs updating in one place plus its renderer.
  static const Map<String, String> labels = {
    desktopSwitcher: 'Switch desktop',
    adaptiveControls: 'Dynamic controls',
    minimizedApps: 'Minimized apps',
    buttons: 'My buttons',
    mediaController: 'Media controller',
  };
  static const Map<String, String> icons = {
    desktopSwitcher: 'monitor',
    adaptiveControls: 'bolt',
    minimizedApps: 'apps',
    buttons: 'grid',
    mediaController: 'music',
  };

  static const all = [desktopSwitcher, adaptiveControls, minimizedApps, buttons, mediaController];
}

/// How much horizontal space a widget takes in its layout — full width, or
/// compact (paired two-per-row with another compact widget).
class WidgetSize {
  static const full = 'full';
  static const compact = 'compact';
}

/// One widget placed in a WorkspaceLayout.
class WidgetInstance {
  final String id;
  String type; // WidgetType.*
  String size; // WidgetSize.*
  int order;

  WidgetInstance({
    required this.id,
    required this.type,
    this.size = WidgetSize.full,
    this.order = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'size': size,
        'order': order,
      };

  factory WidgetInstance.fromJson(Map<String, dynamic> json) => WidgetInstance(
        id: json['id'] as String? ?? '',
        type: json['type'] as String? ?? '',
        size: json['size'] as String? ?? WidgetSize.full,
        order: json['order'] as int? ?? 0,
      );
}

/// A named, user-customizable arrangement of widgets for one paired device
/// (e.g. "Programming", "Video editing", "Music") — scoped per device for the
/// same reason WorkspaceButton is: a layout built around VS Code shortcuts
/// only means something on the specific machine it targets.
class WorkspaceLayout {
  final String id;
  String name;
  List<WidgetInstance> widgets;

  WorkspaceLayout({required this.id, required this.name, required this.widgets});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'widgets': widgets.map((w) => w.toJson()).toList(),
      };

  factory WorkspaceLayout.fromJson(Map<String, dynamic> json) => WorkspaceLayout(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? 'Layout',
        widgets: ((json['widgets'] as List?) ?? const [])
            .map((e) => WidgetInstance.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// The layout every device starts with — the same four cards the Workspace
/// tab used to show permanently, now just the first user-editable preset.
WorkspaceLayout _defaultLayout() => WorkspaceLayout(
      id: 'default',
      name: 'Default',
      widgets: [
        WidgetInstance(
          id: 'default_switcher',
          type: WidgetType.desktopSwitcher,
          size: WidgetSize.compact,
          order: 0,
        ),
        WidgetInstance(id: 'default_minimized', type: WidgetType.minimizedApps, order: 1),
        WidgetInstance(id: 'default_adaptive', type: WidgetType.adaptiveControls, order: 2),
        WidgetInstance(id: 'default_buttons', type: WidgetType.buttons, order: 3),
      ],
    );

/// Loads and saves everything that must survive a restart.
class WeDropStore {
  final SharedPreferences _prefs;

  late DeviceIdentity identity;
  late Settings settings;
  late String deviceName;
  final Map<String, TrustedDevice> _trusted = {};
  final Map<String, List<WorkspaceLayout>> _layouts = {};
  final Map<String, String> _activeLayout = {};

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

    final layoutsRaw = _prefs.getString(_keyLayouts);
    if (layoutsRaw != null) {
      try {
        (jsonDecode(layoutsRaw) as Map<String, dynamic>).forEach((deviceId, layouts) {
          _layouts[deviceId] =
              (layouts as List).map((e) => WorkspaceLayout.fromJson(e as Map<String, dynamic>)).toList();
        });
      } catch (_) {
        // A corrupt map must not stop the app from starting.
      }
    }

    final activeRaw = _prefs.getString(_keyActiveLayout);
    if (activeRaw != null) {
      try {
        (jsonDecode(activeRaw) as Map<String, dynamic>).forEach((deviceId, layoutId) {
          _activeLayout[deviceId] = layoutId as String;
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

  /// This device's saved layouts, auto-creating (and persisting) the
  /// built-in "Default" one on first access so a device is never left with
  /// zero layouts to show.
  List<WorkspaceLayout> layoutsFor(String deviceId) {
    var list = _layouts[deviceId];
    if (list == null || list.isEmpty) {
      list = [_defaultLayout()];
      _layouts[deviceId] = list;
      unawaited(_saveLayouts());
    }
    return list;
  }

  /// The layout currently selected for this device — falls back to the
  /// first layout if none was explicitly chosen yet, or the active choice
  /// was deleted out from under it.
  WorkspaceLayout activeLayoutFor(String deviceId) {
    final layouts = layoutsFor(deviceId);
    final activeId = _activeLayout[deviceId];
    return layouts.firstWhere((l) => l.id == activeId, orElse: () => layouts.first);
  }

  Future<void> saveLayouts(String deviceId, List<WorkspaceLayout> layouts) async {
    _layouts[deviceId] = layouts;
    await _saveLayouts();
  }

  Future<void> setActiveLayout(String deviceId, String layoutId) async {
    _activeLayout[deviceId] = layoutId;
    await _prefs.setString(_keyActiveLayout, jsonEncode(_activeLayout));
  }

  Future<void> _saveLayouts() async {
    await _prefs.setString(
      _keyLayouts,
      jsonEncode(_layouts.map((id, list) => MapEntry(id, list.map((l) => l.toJson()).toList()))),
    );
  }
}
