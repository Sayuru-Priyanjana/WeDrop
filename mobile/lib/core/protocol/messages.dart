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

Map<String, dynamic> mediaMessage(String command) => {
      'type': MsgType.media,
      'command': command,
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
