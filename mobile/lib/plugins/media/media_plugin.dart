import '../../core/platform/native_bridge.dart';
import '../../core/plugin/plugin.dart';
import '../../core/protocol/messages.dart';

class _Settings {
  final bool allowControl;
  const _Settings({required this.allowControl});
}

/// The media plugin: applies remote play/pause/seek/volume commands to this
/// phone's active media session, and shares what this phone is playing (and
/// what peers report playing) so a remote can render and control it.
///
/// Conceptual mirror of desktop/plugins/media (Go) — see the plugin
/// architecture refactor plan.
class MediaPlugin implements WeDropPlugin {
  /// Resolves a peer's display name — the trusted name if set, else the
  /// session's advertised name (passed as fallback).
  final String Function(String deviceId, String fallback) resolveName;

  late PluginApi _api;

  /// Latest media state reported by each peer, keyed by device ID.
  final Map<String, MediaState> peerMedia = {};
  final Map<String, DateTime> _receivedAt = {};

  MediaPlugin({required this.resolveName});

  @override
  PluginId get id => Capability.media;

  @override
  List<String> get messageTypes => [MsgType.media, MsgType.mediaState];

  @override
  void init(PluginApi api) {
    _api = api;
  }

  @override
  Future<void> handleMessage(PeerRef from, String msgType, Map<String, dynamic> raw) async {
    switch (msgType) {
      case MsgType.media:
        final command = raw['command'] as String?;
        if (command != null) {
          await _handleCommand(from, command, raw['position'] as int?, raw['volume'] as int?);
        }
        break;
      case MsgType.mediaState:
        _handleState(from, MediaState.fromJson(raw));
        break;
    }
  }

  Future<void> _handleCommand(PeerRef from, String command, int? position, int? volume) async {
    if (!_settings().allowControl) return;
    if (!_api.allows(from.deviceId)) return;

    if (command == MediaCommand.seek && position != null) {
      NativeBridge.seekMedia(position);
    } else if (command == MediaCommand.setVolume && volume != null) {
      NativeBridge.setSystemVolume(volume);
    } else {
      NativeBridge.applyMediaCommand(command);
    }
    _api.emit('applied', command);
  }

  void _handleState(PeerRef from, MediaState state) {
    peerMedia[from.deviceId] = state;
    _receivedAt[from.deviceId] = DateTime.now();

    final name = resolveName(from.deviceId, from.info.name);
    if (state.hasMedia) {
      NativeBridge.updateMediaNotification(
        deviceId: from.deviceId,
        deviceName: name,
        appName: state.app,
        title: state.title,
        artist: state.artist,
        playing: state.playing,
        position: state.position,
        duration: state.duration,
        volume: state.volume,
        artwork: state.artwork,
      );
    } else {
      NativeBridge.clearMediaNotification();
    }
    _api.emit('state_changed', null);
  }

  @override
  void onPeerConnected(PeerRef peer) {}

  /// Stops showing "now playing" for a device that just dropped.
  @override
  void onPeerDisconnected(String deviceId) {
    _receivedAt.remove(deviceId);
    if (peerMedia.remove(deviceId) != null) {
      NativeBridge.clearMediaNotification();
    }
  }

  @override
  Future<void> start() async {}

  @override
  void stop() {}

  /// Shares this phone's own now-playing state with the ecosystem, forwarded
  /// up from Android's MediaSessionManager whenever it changes.
  void broadcastLocalState(Map<String, dynamic> event) {
    if (!_settings().allowControl) return;
    if (_api.connectedPeers().isEmpty) return;

    final state = MediaState(
      hasMedia: event['has_media'] as bool? ?? false,
      playing: event['playing'] as bool? ?? false,
      title: event['title'] as String? ?? '',
      artist: event['artist'] as String? ?? '',
      app: event['app'] as String? ?? '',
      position: event['position'] as int? ?? -1,
      duration: event['duration'] as int? ?? -1,
      volume: event['volume'] as int? ?? -1,
      artwork: event['artwork'] as String? ?? '',
    );

    _api.broadcast({
      'type': MsgType.mediaState,
      'playing': state.playing,
      'has_media': state.hasMedia,
      'title': state.title,
      'artist': state.artist,
      'app': state.app,
      'volume': state.volume,
      'position': state.position,
      'duration': state.duration,
      'artwork': state.artwork,
    });
  }

  /// Sends a media command to a peer — used by AppService.sendMediaCommand.
  Future<void> sendCommand(
    String targetDeviceId,
    String command, {
    int? position,
    int? volume,
    String? playerId,
    String? deviceId,
    String? appId,
    bool? muted,
  }) {
    return _api.send(
      targetDeviceId,
      mediaMessage(
        command,
        position: position,
        volume: volume,
        playerId: playerId,
        deviceId: deviceId,
        appId: appId,
        muted: muted,
      ),
    );
  }

  /// The latest media state reported by a peer, or null if none yet.
  MediaState? mediaOf(String deviceId) => peerMedia[deviceId];

  /// The peer's playback position interpolated forward to "now".
  ///
  /// A peer only sends a fresh [MediaState] on an actual player event (track
  /// change, play/pause, a seek) — not once a second — so rendering the raw
  /// stored value verbatim leaves every progress bar frozen between those
  /// events instead of visibly advancing like real playback. This estimates
  /// "where the track actually is right now" from the last known position,
  /// how long ago that arrived, and whether it was playing, so every surface
  /// (home card, remote screen, notification) can show a smoothly moving
  /// preview without needing the peer to spam updates every second.
  MediaState? interpolatedMediaOf(String deviceId) {
    final state = peerMedia[deviceId];
    if (state == null || !state.hasMedia) return state;
    if (!state.playing || state.position < 0 || state.duration <= 0) return state;

    final receivedAt = _receivedAt[deviceId];
    if (receivedAt == null) return state;

    final elapsedMillis = DateTime.now().difference(receivedAt).inMilliseconds;
    final estimatedPosition = (state.position + elapsedMillis).clamp(0, state.duration).toInt();
    if (estimatedPosition == state.position) return state;

    return MediaState(
      playing: state.playing,
      hasMedia: state.hasMedia,
      title: state.title,
      artist: state.artist,
      app: state.app,
      volume: state.volume,
      position: estimatedPosition,
      duration: state.duration,
      artwork: state.artwork,
      players: state.players,
      selectedPlayer: state.selectedPlayer,
      audioDevices: state.audioDevices,
      appVolumes: state.appVolumes,
    );
  }

  /// Whether any known peer is actively playing with a known duration — the
  /// media ticker only needs to wake the UI while this is true.
  bool anyAnimating() => peerMedia.values.any((m) => m.hasMedia && m.playing && m.duration > 0);

  _Settings _settings() {
    final raw = _api.settings();
    return _Settings(allowControl: raw['allow_control'] == true);
  }
}
