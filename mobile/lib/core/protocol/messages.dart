/// The WeDrop v2 wire format, mirroring `core/protocol/messages.go`.
///
/// Both implementations must agree byte-for-byte, so every constant here has a
/// counterpart in the Go package. Change one and you must change the other.
library;

/// Protocol revision. Peers on a different revision are refused outright rather
/// than failing later with an opaque handshake error.
const int protocolVersion = 2;

const int discoveryPort = 47820;
const int transportPort = 47821;

/// Message type discriminators.
class MsgType {
  static const discovery = 'wedrop_discovery';
  static const discoveryQuery = 'wedrop_discovery_query';
  static const discoveryBye = 'wedrop_discovery_bye';

  static const handshakeInit = 'handshake_init';
  static const handshakeResp = 'handshake_resp';
  static const handshakeConfirm = 'handshake_confirm';

  static const pairingResp = 'pairing_resp';
  static const unpair = 'unpair';

  static const ping = 'ping';
  static const pong = 'pong';
  static const deviceInfo = 'device_info';

  static const clipboard = 'clipboard';
  static const notification = 'notification';
  static const media = 'media';
  static const mediaState = 'media_state';
  static const health = 'health';
  static const remoteInput = 'remote_input';
  static const workspaceAction = 'workspace_action';
  static const adaptiveControls = 'adaptive_controls';
  static const minimizedApps = 'minimized_apps';
  static const configureApp = 'configure_app';
  static const configureButtons = 'configure_buttons';
  static const workspaceButtons = 'workspace_buttons';

  static const transferOffer = 'transfer_offer';
  static const transferAccept = 'transfer_accept';
  static const transferChunk = 'transfer_chunk';
  static const transferDone = 'transfer_done';

  static const error = 'error';
}

/// What a freshly dialled connection is for.
class Intent {
  static const pair = 'pair';
  static const session = 'session';
  static const transfer = 'transfer';
}

/// Stable error codes exchanged before a connection is dropped.
class ErrCode {
  static const notPaired = 'not_paired';
  static const keyMismatch = 'key_mismatch';
  static const versionMismatch = 'version_mismatch';
  static const rejected = 'rejected';
  static const timeout = 'timeout';
  static const badSignature = 'bad_signature';
  static const notPermitted = 'not_permitted';
  static const internal = 'internal';
  static const busy = 'busy';
}

/// Capabilities a device advertises so peers can skip what it would discard.
class Capability {
  static const clipboard = 'clipboard';
  static const files = 'files';
  static const notifications = 'notifications';
  static const media = 'media';
  static const workspace = 'workspace';
  // Its own capability (a plugin id must be unique) purely so a peer can
  // advertise "I understand this message type" — always advertised, same as
  // workspace/health. Running a control's action still goes through the
  // exact same AllowWorkspace permission as any other workspace action;
  // this only gates whether the schema itself is even sent.
  static const adaptiveControls = 'adaptive_controls';
  // Same reasoning as adaptiveControls above (plugin id uniqueness); the
  // real authorization is still AllowWorkspace.
  static const minimizedApps = 'minimized_apps';
  // No toggle; always advertised.
  static const health = 'device-health';
}

/// Media commands every platform understands.
class MediaCommand {
  static const playPause = 'play_pause';
  static const next = 'next';
  static const prev = 'prev';
  static const stop = 'stop';
  static const volUp = 'vol_up';
  static const volDown = 'vol_down';
  static const mute = 'mute';
  /// Jumps to an absolute position; carries a `position` (millis) argument.
  /// Not every peer can honour it — a receiver with no active media session
  /// API silently ignores it, same as any command it cannot service.
  static const seek = 'seek';
  /// Sets an absolute system volume level (0-100), as opposed to the
  /// relative nudges volUp/volDown apply.
  static const setVolume = 'set_volume';
  /// Picks which of the peer's active sessions (MediaState.players) future
  /// play/pause/next/prev/seek commands target; carries a `player_id`
  /// argument ("" falls back to whatever the peer itself calls current).
  static const selectPlayer = 'select_player';
  /// Makes a `device_id` (from MediaState.audioDevices) the peer's default
  /// playback device.
  static const selectAudioDevice = 'select_audio_device';
  /// Sets one running app's own mixer volume on the peer, as opposed to
  /// setVolume (the whole system); carries `app_id` + `volume`.
  static const setAppVolume = 'set_app_volume';
  /// Mutes/unmutes one running app's own mixer channel on the peer; carries
  /// `app_id` + `muted`.
  static const setAppMute = 'set_app_mute';
}

/// Remote-input actions carried in a [RemoteInput] message.
class InputAction {
  static const mouseMove = 'mouse_move';
  static const mouseLeft = 'mouse_left';
  static const mouseRight = 'mouse_right';
  static const mouseMiddle = 'mouse_middle';
  static const mouseDown = 'mouse_down';
  static const mouseUp = 'mouse_up';
  static const scroll = 'scroll';
  static const type = 'type';
  static const key = 'key';

  static const presentNext = 'present_next';
  static const presentPrev = 'present_prev';
  static const presentStart = 'present_start';
  static const presentEnd = 'present_end';
  static const presentBlank = 'present_blank';
}

/// Named special keys carried in [RemoteInput.key].
class SpecialKey {
  static const backspace = 'backspace';
  static const enter = 'enter';
  static const tab = 'tab';
  static const escape = 'escape';
  static const up = 'up';
  static const down = 'down';
  static const left = 'left';
  static const right = 'right';
  static const space = 'space';
  static const home = 'home';
  static const end = 'end';
  static const delete = 'delete';

  // Function keys — added for dynamic controls (e.g. VS Code's Run/Debug).
  static const f1 = 'f1';
  static const f2 = 'f2';
  static const f3 = 'f3';
  static const f4 = 'f4';
  static const f5 = 'f5';
  static const f6 = 'f6';
  static const f7 = 'f7';
  static const f8 = 'f8';
  static const f9 = 'f9';
  static const f10 = 'f10';
  static const f11 = 'f11';
  static const f12 = 'f12';
}

/// Coarse device class, used for iconography.
class FormFactor {
  static const desktop = 'desktop';
  static const phone = 'phone';
  static const tablet = 'tablet';
}

/// A UDP presence announcement.
class DiscoveryMessage {
  final String type;
  final int version;
  final String deviceId;
  final String name;
  final String platform;
  final String formFactor;
  final String ip;
  final int tcpPort;
  final String publicKey;

  /// When this device was last heard from — local bookkeeping, not on the wire.
  final DateTime lastSeen;

  DiscoveryMessage({
    this.type = MsgType.discovery,
    this.version = protocolVersion,
    required this.deviceId,
    required this.name,
    required this.platform,
    this.formFactor = FormFactor.phone,
    this.ip = '',
    this.tcpPort = transportPort,
    required this.publicKey,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'type': type,
        'version': version,
        'device_id': deviceId,
        'name': name,
        'platform': platform,
        'form_factor': formFactor,
        'ip': ip,
        'tcp_port': tcpPort,
        'public_key': publicKey,
      };

  factory DiscoveryMessage.fromJson(Map<String, dynamic> json) => DiscoveryMessage(
        type: json['type'] as String? ?? '',
        version: json['version'] as int? ?? 0,
        deviceId: json['device_id'] as String? ?? '',
        name: json['name'] as String? ?? 'Unknown device',
        platform: json['platform'] as String? ?? '',
        formFactor: json['form_factor'] as String? ?? FormFactor.desktop,
        ip: json['ip'] as String? ?? '',
        tcpPort: json['tcp_port'] as int? ?? transportPort,
        publicKey: json['public_key'] as String? ?? '',
      );

  DiscoveryMessage copyWith({String? ip, DateTime? lastSeen}) => DiscoveryMessage(
        type: type,
        version: version,
        deviceId: deviceId,
        name: name,
        platform: platform,
        formFactor: formFactor,
        ip: ip ?? this.ip,
        tcpPort: tcpPort,
        publicKey: publicKey,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}

/// What a peer told us about itself once a session opened.
class DeviceInfo {
  final String deviceId;
  final String name;
  final String platform;
  final String formFactor;
  final List<String> capabilities;
  final int battery;

  const DeviceInfo({
    required this.deviceId,
    required this.name,
    this.platform = '',
    this.formFactor = FormFactor.desktop,
    this.capabilities = const [],
    this.battery = -1,
  });

  bool hasCapability(String capability) => capabilities.contains(capability);

  Map<String, dynamic> toJson() => {
        'type': MsgType.deviceInfo,
        'device_id': deviceId,
        'name': name,
        'platform': platform,
        'form_factor': formFactor,
        'capabilities': capabilities,
        'battery': battery,
      };

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        deviceId: json['device_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        platform: json['platform'] as String? ?? '',
        formFactor: json['form_factor'] as String? ?? FormFactor.desktop,
        capabilities:
            (json['capabilities'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        battery: json['battery'] as int? ?? -1,
      );
}

/// Clipboard text shared across the ecosystem.
class ClipboardMessage {
  final String text;
  final String origin;
  final int sequence;
  final String hash;

  const ClipboardMessage({
    required this.text,
    required this.origin,
    this.sequence = 0,
    this.hash = '',
  });

  Map<String, dynamic> toJson() => {
        'type': MsgType.clipboard,
        'text': text,
        'origin': origin,
        'sequence': sequence,
        'hash': hash,
      };

  factory ClipboardMessage.fromJson(Map<String, dynamic> json) => ClipboardMessage(
        text: json['text'] as String? ?? '',
        origin: json['origin'] as String? ?? '',
        sequence: json['sequence'] as int? ?? 0,
        hash: json['hash'] as String? ?? '',
      );
}

/// A notification mirrored from one device to another.
class NotificationMessage {
  final String id;
  final String app;
  final String title;
  final String body;
  final int time;
  final bool dismiss;

  const NotificationMessage({
    required this.id,
    required this.app,
    required this.title,
    required this.body,
    required this.time,
    this.dismiss = false,
  });

  Map<String, dynamic> toJson() => {
        'type': MsgType.notification,
        'id': id,
        'app': app,
        'title': title,
        'body': body,
        'time': time,
        if (dismiss) 'dismiss': true,
      };

  factory NotificationMessage.fromJson(Map<String, dynamic> json) => NotificationMessage(
        id: json['id'] as String? ?? '',
        app: json['app'] as String? ?? '',
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        time: json['time'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        dismiss: json['dismiss'] as bool? ?? false,
      );
}

/// One of the peer's active media sessions, for a remote to list and pick
/// which one to control — mirrors KDE Connect's own player list.
class PlayerSummary {
  final String id;
  final String title;
  final String artist;
  final bool playing;

  const PlayerSummary({
    required this.id,
    this.title = '',
    this.artist = '',
    this.playing = false,
  });

  factory PlayerSummary.fromJson(Map<String, dynamic> json) => PlayerSummary(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        playing: json['playing'] as bool? ?? false,
      );
}

/// One of the peer's playback (output) devices.
class AudioDeviceSummary {
  final String id;
  final String name;
  final bool isDefault;

  const AudioDeviceSummary({required this.id, this.name = '', this.isDefault = false});

  factory AudioDeviceSummary.fromJson(Map<String, dynamic> json) => AudioDeviceSummary(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        isDefault: json['default'] as bool? ?? false,
      );
}

/// One running app's own mixer channel on the peer.
class AppVolumeSummary {
  final String id;
  final String name;
  final int volume; // 0-100
  final bool muted;

  const AppVolumeSummary({required this.id, this.name = '', this.volume = -1, this.muted = false});

  factory AppVolumeSummary.fromJson(Map<String, dynamic> json) => AppVolumeSummary(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        volume: json['volume'] as int? ?? -1,
        muted: json['muted'] as bool? ?? false,
      );
}

/// What a peer is currently playing, so a remote can render controls.
class MediaState {
  final bool playing;
  final bool hasMedia;
  final String title;
  final String artist;
  final String app;
  final int volume; // 0-100, -1 unknown
  final int position; // millis, -1 unknown
  final int duration; // millis, -1 unknown
  /// Base64-encoded JPEG preview of the track/album art, or empty if the
  /// source has none.
  final String artwork;
  /// Every active session on the peer, not just whatever this state's own
  /// title/artist/etc. reflect — empty on peers/builds with no multi-player
  /// support.
  final List<PlayerSummary> players;
  /// The id (from players) future commands are scoped to; "" means
  /// "whatever the peer calls current".
  final String selectedPlayer;
  /// The peer's playback devices — empty on peers/builds with no device
  /// enumeration support.
  final List<AudioDeviceSummary> audioDevices;
  /// The peer's active per-app mixer channels — empty on peers/builds with
  /// no per-app volume support.
  final List<AppVolumeSummary> appVolumes;

  const MediaState({
    this.playing = false,
    this.hasMedia = false,
    this.title = '',
    this.artist = '',
    this.app = '',
    this.volume = -1,
    this.position = -1,
    this.duration = -1,
    this.artwork = '',
    this.players = const [],
    this.selectedPlayer = '',
    this.audioDevices = const [],
    this.appVolumes = const [],
  });

  factory MediaState.fromJson(Map<String, dynamic> json) => MediaState(
        playing: json['playing'] as bool? ?? false,
        hasMedia: json['has_media'] as bool? ?? false,
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        app: json['app'] as String? ?? '',
        volume: json['volume'] as int? ?? -1,
        position: json['position'] as int? ?? -1,
        duration: json['duration'] as int? ?? -1,
        artwork: json['artwork'] as String? ?? '',
        players: ((json['players'] as List?) ?? const [])
            .map((e) => PlayerSummary.fromJson(e as Map<String, dynamic>))
            .toList(),
        selectedPlayer: json['selected_player'] as String? ?? '',
        audioDevices: ((json['audio_devices'] as List?) ?? const [])
            .map((e) => AudioDeviceSummary.fromJson(e as Map<String, dynamic>))
            .toList(),
        appVolumes: ((json['app_volumes'] as List?) ?? const [])
            .map((e) => AppVolumeSummary.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// A peer's live vitals for the health panel.
class DeviceHealth {
  final String deviceId;
  final int battery; // 0-100, -1 unknown
  final bool charging;
  final int cpuPercent; // 0-100, -1 unknown
  final int memPercent; // 0-100, -1 unknown
  final String networkType; // wifi/ethernet/cellular/offline
  final String networkName;

  const DeviceHealth({
    required this.deviceId,
    this.battery = -1,
    this.charging = false,
    this.cpuPercent = -1,
    this.memPercent = -1,
    this.networkType = 'offline',
    this.networkName = '',
  });

  Map<String, dynamic> toJson() => {
        'type': MsgType.health,
        'device_id': deviceId,
        'battery': battery,
        'charging': charging,
        'cpu_percent': cpuPercent,
        'mem_percent': memPercent,
        'network_type': networkType,
        'network_name': networkName,
      };

  factory DeviceHealth.fromJson(Map<String, dynamic> json) => DeviceHealth(
        deviceId: json['device_id'] as String? ?? '',
        battery: json['battery'] as int? ?? -1,
        charging: json['charging'] as bool? ?? false,
        cpuPercent: json['cpu_percent'] as int? ?? -1,
        memPercent: json['mem_percent'] as int? ?? -1,
        networkType: json['network_type'] as String? ?? 'offline',
        networkName: json['network_name'] as String? ?? '',
      );
}

/// A mouse/keyboard/presentation event to inject on the receiving device.
class RemoteInput {
  final String action;
  final double dx;
  final double dy;
  final String text;
  final String key;

  const RemoteInput({
    required this.action,
    this.dx = 0,
    this.dy = 0,
    this.text = '',
    this.key = '',
  });

  Map<String, dynamic> toJson() => {
        'type': MsgType.remoteInput,
        'action': action,
        if (dx != 0) 'dx': dx,
        if (dy != 0) 'dy': dy,
        if (text.isNotEmpty) 'text': text,
        if (key.isNotEmpty) 'key': key,
      };
}

/// Actions a "My Workspace" button can request on the peer.
class WorkspaceActionType {
  static const shortcut = 'shortcut';
  static const openApp = 'open_app';
  static const openFolder = 'open_folder';
  static const openUrl = 'open_url';
  static const shellCommand = 'shell_command';
  // Brings a window reported by MinimizedAppsState to the front; not exposed
  // in the user-facing shortcut-button editor, only sent by the minimized-
  // apps widget itself.
  static const restoreWindow = 'restore_window';
}

/// Modifier names carried in [WorkspaceAction.modifiers].
class Modifier {
  static const ctrl = 'ctrl';
  static const shift = 'shift';
  static const alt = 'alt';
  // The Windows/Command/Super key — used by the desktop-switcher widget's
  // Ctrl+Win+Left/Right (Windows' own native virtual-desktop shortcut), not
  // exposed in the user-facing shortcut-button editor.
  static const meta = 'meta';
}

/// Runs one of a user's own custom "My Workspace" buttons on the peer — a
/// phone-triggers-local-action message with no broadcast state, the same
/// shape as [RemoteInput]. Kept as its own message rather than folded into
/// RemoteInput since its actions have nothing to do with mouse/keyboard
/// synthesis except the shortcut case, which the peer implements by reusing
/// its own RemoteInput machinery.
class WorkspaceAction {
  final String action;
  final List<String> modifiers;
  final String key;
  final String path;
  final String url;
  final String command;
  // restoreWindow: id (native window handle) from a MinimizedAppsState entry.
  final int windowId;

  const WorkspaceAction({
    required this.action,
    this.modifiers = const [],
    this.key = '',
    this.path = '',
    this.url = '',
    this.command = '',
    this.windowId = 0,
  });

  Map<String, dynamic> toJson() => {
        'type': MsgType.workspaceAction,
        'action': action,
        if (modifiers.isNotEmpty) 'modifiers': modifiers,
        if (key.isNotEmpty) 'key': key,
        if (path.isNotEmpty) 'path': path,
        if (url.isNotEmpty) 'url': url,
        if (command.isNotEmpty) 'command': command,
        if (windowId != 0) 'window_id': windowId,
      };

  /// Needed for the first time by AdaptiveControl — every earlier use of
  /// WorkspaceAction only ever sent one, never received one.
  factory WorkspaceAction.fromJson(Map<String, dynamic> json) => WorkspaceAction(
        action: json['action'] as String? ?? '',
        modifiers: (json['modifiers'] as List?)?.cast<String>() ?? const [],
        key: json['key'] as String? ?? '',
        path: json['path'] as String? ?? '',
        url: json['url'] as String? ?? '',
        command: json['command'] as String? ?? '',
        windowId: (json['window_id'] as num?)?.toInt() ?? 0,
      );
}

/// One dynamic, app-provided control the peer's currently focused
/// application makes available — its action reuses [WorkspaceAction]
/// verbatim, so running one needs no execution path beyond what already
/// handles a workspace button's own action.
class AdaptiveControl {
  final String id;
  final String label;
  /// Same curated icon-key vocabulary as WorkspaceButton.icon
  /// (ui/workspace_tab.dart's kWorkspaceIcons).
  final String icon;
  /// ARGB, matching WorkspaceButton.colorValue's convention. 0 means "no
  /// override" — the tile falls back to a default accent.
  final int color;
  final WorkspaceAction action;

  const AdaptiveControl({
    required this.id,
    required this.label,
    required this.icon,
    this.color = 0,
    required this.action,
  });

  factory AdaptiveControl.fromJson(Map<String, dynamic> json) => AdaptiveControl(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
        color: json['color'] as int? ?? 0,
        action: WorkspaceAction.fromJson((json['action'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}

/// Asks the peer to open its App Actions editor for [appName] — sent when
/// the Dynamic Controls card offers "Configure this app" for an application
/// with no defined profile yet.
class ConfigureAppRequest {
  final String appName;
  const ConfigureAppRequest({required this.appName});

  Map<String, dynamic> toJson() => {
        'type': MsgType.configureApp,
        'app_name': appName,
      };
}

/// Asks the peer to open its My Buttons editor for this device — no payload
/// needed beyond the type; the desktop identifies the device from whoever
/// sent the message.
class ConfigureButtonsRequest {
  const ConfigureButtonsRequest();

  Map<String, dynamic> toJson() => {'type': MsgType.configureButtons};
}

/// One of this device's own "My Workspace" buttons — authored entirely on
/// the desktop (its App Actions / My Buttons editor, with a keyboard-capture
/// shortcut recorder) and received here read-only. There is no editor for
/// these on the phone; tapping one just runs [action].
class WorkspaceButtonDef {
  final String id;
  final String label;
  final String icon;
  final int colorValue;
  final WorkspaceAction action;

  const WorkspaceButtonDef({
    required this.id,
    required this.label,
    required this.icon,
    this.colorValue = 0,
    required this.action,
  });

  factory WorkspaceButtonDef.fromJson(Map<String, dynamic> json) => WorkspaceButtonDef(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
        colorValue: json['color_value'] as int? ?? 0,
        action: WorkspaceAction.fromJson((json['action'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}

/// This device's whole "My Workspace" button list, sent whenever it changes
/// on the desktop (and once when this device connects).
class WorkspaceButtonsState {
  final List<WorkspaceButtonDef> buttons;
  const WorkspaceButtonsState({this.buttons = const []});

  factory WorkspaceButtonsState.fromJson(Map<String, dynamic> json) => WorkspaceButtonsState(
        buttons: ((json['buttons'] as List?) ?? const [])
            .map((e) => WorkspaceButtonDef.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// What the peer's foreground app currently makes available, broadcast
/// whenever it changes (and once when a peer connects). An empty [controls]
/// list (with [appName] empty) means no recognized app is currently focused.
class AdaptiveControlsState {
  final String appName;
  /// Raw, lowercased executable name — distinct from [appName] (a friendly
  /// display name) — echoed back verbatim in a ConfigureAppRequest since a
  /// display name cannot be reliably reversed into an exe name.
  final String exe;
  final List<AdaptiveControl> controls;

  const AdaptiveControlsState({this.appName = '', this.exe = '', this.controls = const []});

  factory AdaptiveControlsState.fromJson(Map<String, dynamic> json) => AdaptiveControlsState(
        appName: json['app_name'] as String? ?? '',
        exe: json['exe'] as String? ?? '',
        controls: ((json['controls'] as List?) ?? const [])
            .map((e) => AdaptiveControl.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// One currently-minimized top-level window on the peer. [id] is the native
/// window handle, opaque to the phone — it only ever gets echoed back in a
/// WorkspaceAction.windowId to restore that exact window.
class MinimizedWindow {
  final int id;
  final String title;
  final String appName;

  const MinimizedWindow({required this.id, required this.title, required this.appName});

  factory MinimizedWindow.fromJson(Map<String, dynamic> json) => MinimizedWindow(
        id: (json['id'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        appName: json['app_name'] as String? ?? '',
      );
}

/// The peer's currently-minimized windows, broadcast whenever the set
/// changes (and once when a peer connects). Deliberately scoped to
/// "currently minimized" rather than "every open window on the selected
/// virtual desktop" — see MinimizedAppsState in messages.go for why.
class MinimizedAppsState {
  final List<MinimizedWindow> windows;

  const MinimizedAppsState({this.windows = const []});

  factory MinimizedAppsState.fromJson(Map<String, dynamic> json) => MinimizedAppsState(
        windows: ((json['windows'] as List?) ?? const [])
            .map((e) => MinimizedWindow.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// An offer to send one file, sent on a dedicated transfer connection.
class TransferOffer {
  final String transferId;
  final String filename;
  final int size;
  final String checksum;
  final String mimeType;
  final int chunkSize;
  final int chunkCount;

  const TransferOffer({
    required this.transferId,
    required this.filename,
    required this.size,
    required this.checksum,
    this.mimeType = '',
    required this.chunkSize,
    required this.chunkCount,
  });

  Map<String, dynamic> toJson() => {
        'type': MsgType.transferOffer,
        'transfer_id': transferId,
        'filename': filename,
        'size': size,
        'checksum': checksum,
        'mime_type': mimeType,
        'chunk_size': chunkSize,
        'chunk_count': chunkCount,
      };

  factory TransferOffer.fromJson(Map<String, dynamic> json) => TransferOffer(
        transferId: json['transfer_id'] as String? ?? '',
        filename: json['filename'] as String? ?? 'file',
        size: json['size'] as int? ?? 0,
        checksum: json['checksum'] as String? ?? '',
        mimeType: json['mime_type'] as String? ?? '',
        chunkSize: json['chunk_size'] as int? ?? 262144,
        chunkCount: json['chunk_count'] as int? ?? 0,
      );
}

/// Convenience builders for the small control messages.
Map<String, dynamic> pingMessage(int seq) => {'type': MsgType.ping, 'seq': seq};

Map<String, dynamic> pongMessage(int seq) => {'type': MsgType.pong, 'seq': seq};

Map<String, dynamic> mediaMessage(
  String command, {
  int? position,
  int? volume,
  String? playerId,
  String? deviceId,
  String? appId,
  bool? muted,
}) =>
    {
      'type': MsgType.media,
      'command': command,
      'position': ?position,
      'volume': ?volume,
      'player_id': ?playerId,
      'device_id': ?deviceId,
      'app_id': ?appId,
      'muted': ?muted,
    };

Map<String, dynamic> unpairMessage(String deviceId) => {
      'type': MsgType.unpair,
      'device_id': deviceId,
    };

Map<String, dynamic> errorMessage(String code, String message) => {
      'type': MsgType.error,
      'code': code,
      'message': message,
    };

Map<String, dynamic> transferAcceptMessage(String transferId, bool accepted, [String reason = '']) =>
    {
      'type': MsgType.transferAccept,
      'transfer_id': transferId,
      'accepted': accepted,
      if (reason.isNotEmpty) 'reason': reason,
    };

Map<String, dynamic> transferChunkMessage(String transferId, int index, int size) => {
      'type': MsgType.transferChunk,
      'transfer_id': transferId,
      'index': index,
      'size': size,
    };

Map<String, dynamic> transferDoneMessage(String transferId, String checksum) => {
      'type': MsgType.transferDone,
      'transfer_id': transferId,
      'checksum': checksum,
    };
