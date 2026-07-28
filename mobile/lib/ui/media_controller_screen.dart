import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_service.dart';
import '../core/protocol/messages.dart';
import 'theme.dart';
import 'widgets.dart';

/// A full-screen, KDE-Connect-style media controller: which player to
/// control (when the peer has more than one active session), playback with
/// seek, the peer's system volume, a per-app volume mixer, and an output
/// device switcher — everything device_screen.dart's compact overview card
/// only has room to summarize.
///
/// Opened by tapping the Overview tab's media card.
class MediaControllerScreen extends StatefulWidget {
  final AppService service;
  final String deviceId;

  const MediaControllerScreen({super.key, required this.service, required this.deviceId});

  @override
  State<MediaControllerScreen> createState() => _MediaControllerScreenState();
}

class _MediaControllerScreenState extends State<MediaControllerScreen> {
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  DeviceView? get _device {
    for (final d in widget.service.pairedDevices) {
      if (d.deviceId == widget.deviceId) return d;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    final media = widget.service.interpolatedMediaOf(widget.deviceId);

    return Scaffold(
      appBar: AppBar(title: Text(device != null ? '${device.name} · Media' : 'Media')),
      body: device == null || !device.connected
          ? const Center(
              child: Text('This device is not connected', style: TextStyle(color: WeDropColors.inkDim)),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (media != null && media.players.length > 1) ...[
                  _PlayerList(service: widget.service, device: device, media: media),
                  const SizedBox(height: 16),
                ],
                _NowPlayingCard(service: widget.service, device: device, media: media),
                const SizedBox(height: 16),
                _SystemVolumeCard(service: widget.service, device: device, volume: media?.volume ?? -1),
                if (media != null && media.appVolumes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _AppMixerCard(service: widget.service, device: device, apps: media.appVolumes),
                ],
                if (media != null && media.audioDevices.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _OutputDeviceCard(service: widget.service, device: device, devices: media.audioDevices),
                ],
              ],
            ),
    );
  }
}

/// Lists every active session on the peer, so the user can pick which one
/// the rest of this page's controls target — mirrors KDE Connect's own
/// player selector, instead of always guessing at whatever the peer itself
/// currently calls "current".
class _PlayerList extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  final MediaState media;

  const _PlayerList({required this.service, required this.device, required this.media});

  @override
  Widget build(BuildContext context) {
    return WdCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Players', hint: 'Choose which one to control'),
          ...media.players.map((p) {
            final selected = p.id == media.selectedPlayer;
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => service.sendMediaCommand(device.deviceId, MediaCommand.selectPlayer, playerId: p.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                      size: 20,
                      color: selected ? WeDropColors.brand : WeDropColors.inkFaint,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.title.isEmpty ? p.id : p.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w600, color: WeDropColors.ink),
                          ),
                          if (p.artist.isNotEmpty)
                            Text(p.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, color: WeDropColors.inkFaint)),
                        ],
                      ),
                    ),
                    if (p.playing)
                      const Icon(Icons.equalizer_rounded, size: 16, color: WeDropColors.accent),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _NowPlayingCard extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  final MediaState? media;

  const _NowPlayingCard({required this.service, required this.device, required this.media});

  @override
  Widget build(BuildContext context) {
    final m = media;
    final hasMedia = m != null && m.hasMedia;

    return WdCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasMedia) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (m.artwork.isNotEmpty) ...[
                  ArtworkThumbnail(base64: m.artwork, size: 56),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(m.title.isEmpty ? 'Unknown track' : m.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600, color: WeDropColors.ink)),
                      if (m.artist.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(m.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: WeDropColors.inkFaint)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _ControllerSeekBar(
              position: m.position,
              duration: m.duration,
              onSeek: (target) =>
                  service.sendMediaCommand(device.deviceId, MediaCommand.seek, position: target),
            ),
            const SizedBox(height: 4),
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Nothing playing right now',
                  style: TextStyle(fontSize: 13, color: WeDropColors.inkFaint)),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _transportBtn(Icons.skip_previous_rounded, MediaCommand.prev),
              _transportBtn(
                m?.playing == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
                MediaCommand.playPause,
                large: true,
              ),
              _transportBtn(Icons.skip_next_rounded, MediaCommand.next),
            ],
          ),
        ],
      ),
    );
  }

  Widget _transportBtn(IconData icon, String command, {bool large = false}) {
    return IconButton(
      onPressed: () => service.sendMediaCommand(device.deviceId, command),
      icon: Icon(icon),
      iconSize: large ? 36 : 28,
      color: large ? WeDropColors.brandSoft : WeDropColors.inkDim,
    );
  }
}

/// Same drag/optimistic-update behaviour as device_screen.dart's own
/// _SeekBar (kept as a separate small copy rather than exported, since this
/// screen's imports don't otherwise need device_screen.dart).
class _ControllerSeekBar extends StatefulWidget {
  final int position;
  final int duration;
  final void Function(int targetMillis) onSeek;

  const _ControllerSeekBar({required this.position, required this.duration, required this.onSeek});

  @override
  State<_ControllerSeekBar> createState() => _ControllerSeekBarState();
}

class _ControllerSeekBarState extends State<_ControllerSeekBar> {
  double? _dragValue;
  Timer? _confirmTimeout;

  @override
  void didUpdateWidget(_ControllerSeekBar old) {
    super.didUpdateWidget(old);
    if (_dragValue != null && (widget.position - _dragValue!).abs() < 1500) {
      _confirmTimeout?.cancel();
      setState(() => _dragValue = null);
    }
  }

  @override
  void dispose() {
    _confirmTimeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final known = widget.position >= 0 && widget.duration > 0;

    if (!known) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: const LinearProgressIndicator(
          minHeight: 4,
          backgroundColor: WeDropColors.border,
          valueColor: AlwaysStoppedAnimation(WeDropColors.accent),
        ),
      );
    }

    final max = widget.duration.toDouble();
    final value = (_dragValue ?? widget.position.toDouble()).clamp(0.0, max);

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: WeDropColors.accent,
            inactiveTrackColor: WeDropColors.border,
            thumbColor: WeDropColors.accent,
          ),
          child: Slider(
            min: 0,
            max: max,
            value: value,
            onChanged: (v) => setState(() => _dragValue = v),
            onChangeEnd: (v) {
              widget.onSeek(v.toInt());
              setState(() => _dragValue = v);
              _confirmTimeout?.cancel();
              _confirmTimeout = Timer(const Duration(seconds: 4), () {
                if (mounted) setState(() => _dragValue = null);
              });
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmt(_dragValue == null ? widget.position : value.toInt()),
                  style: const TextStyle(fontSize: 11, color: WeDropColors.inkFaint)),
              Text(_fmt(widget.duration),
                  style: const TextStyle(fontSize: 11, color: WeDropColors.inkFaint)),
            ],
          ),
        ),
      ],
    );
  }

  String _fmt(int millis) {
    final total = millis ~/ 1000;
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _SystemVolumeCard extends StatefulWidget {
  final AppService service;
  final DeviceView device;
  final int volume;

  const _SystemVolumeCard({required this.service, required this.device, required this.volume});

  @override
  State<_SystemVolumeCard> createState() => _SystemVolumeCardState();
}

class _SystemVolumeCardState extends State<_SystemVolumeCard> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final known = widget.volume >= 0;
    final value = (_dragValue ?? widget.volume.toDouble()).clamp(0.0, 100.0);

    return WdCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'System volume'),
          Row(
            children: [
              const Icon(Icons.volume_down_rounded, color: WeDropColors.inkDim),
              Expanded(
                child: known
                    ? SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                          activeTrackColor: WeDropColors.brand,
                          inactiveTrackColor: WeDropColors.border,
                          thumbColor: WeDropColors.brand,
                        ),
                        child: Slider(
                          min: 0,
                          max: 100,
                          value: value,
                          onChanged: (v) => setState(() => _dragValue = v),
                          onChangeEnd: (v) {
                            widget.service.sendMediaCommand(
                              widget.device.deviceId,
                              MediaCommand.setVolume,
                              volume: v.toInt(),
                            );
                            setState(() => _dragValue = null);
                          },
                        ),
                      )
                    : const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('Unavailable', style: TextStyle(color: WeDropColors.inkFaint)),
                      ),
              ),
              const Icon(Icons.volume_up_rounded, color: WeDropColors.inkDim),
            ],
          ),
        ],
      ),
    );
  }
}

/// One row per running app currently making sound on the peer — an
/// independent mixer channel, same idea as Windows' own volume mixer.
class _AppMixerCard extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  final List<AppVolumeSummary> apps;

  const _AppMixerCard({required this.service, required this.device, required this.apps});

  @override
  Widget build(BuildContext context) {
    return WdCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'App volumes'),
          ...apps.map((a) => _AppVolumeRow(service: service, device: device, app: a)),
        ],
      ),
    );
  }
}

class _AppVolumeRow extends StatefulWidget {
  final AppService service;
  final DeviceView device;
  final AppVolumeSummary app;

  const _AppVolumeRow({required this.service, required this.device, required this.app});

  @override
  State<_AppVolumeRow> createState() => _AppVolumeRowState();
}

class _AppVolumeRowState extends State<_AppVolumeRow> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final value = (_dragValue ?? widget.app.volume.toDouble()).clamp(0.0, 100.0);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(widget.app.name.isEmpty ? widget.app.id : widget.app.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: WeDropColors.inkDim)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: widget.app.muted ? WeDropColors.inkFaint : WeDropColors.accent,
                inactiveTrackColor: WeDropColors.border,
                thumbColor: widget.app.muted ? WeDropColors.inkFaint : WeDropColors.accent,
              ),
              child: Slider(
                min: 0,
                max: 100,
                value: value,
                onChanged: (v) => setState(() => _dragValue = v),
                onChangeEnd: (v) {
                  widget.service.sendMediaCommand(
                    widget.device.deviceId,
                    MediaCommand.setAppVolume,
                    appId: widget.app.id,
                    volume: v.toInt(),
                  );
                  setState(() => _dragValue = null);
                },
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(
              widget.app.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              size: 18,
              color: widget.app.muted ? WeDropColors.danger : WeDropColors.inkFaint,
            ),
            onPressed: () => widget.service.sendMediaCommand(
              widget.device.deviceId,
              MediaCommand.setAppMute,
              appId: widget.app.id,
              muted: !widget.app.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Lists the peer's playback devices, so the user can switch its default
/// output — the same feature KDE Connect's systemvolume plugin provides via
/// its own (undocumented, best-effort) IPolicyConfig integration.
class _OutputDeviceCard extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  final List<AudioDeviceSummary> devices;

  const _OutputDeviceCard({required this.service, required this.device, required this.devices});

  @override
  Widget build(BuildContext context) {
    return WdCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Output device'),
          ...devices.map((d) {
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: d.isDefault
                  ? null
                  : () => service.sendMediaCommand(device.deviceId, MediaCommand.selectAudioDevice,
                      deviceId: d.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      d.isDefault ? Icons.check_circle_rounded : Icons.circle_outlined,
                      size: 20,
                      color: d.isDefault ? WeDropColors.brand : WeDropColors.inkFaint,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(d.name.isEmpty ? d.id : d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: d.isDefault ? FontWeight.w600 : FontWeight.w400,
                            color: WeDropColors.ink,
                          )),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
