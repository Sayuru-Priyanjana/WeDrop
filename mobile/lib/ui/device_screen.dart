import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_service.dart';
import '../core/protocol/messages.dart';
import 'theme.dart';
import 'widgets.dart';

/// The per-device remote — a KDE-Connect-style control surface.
///
/// It shows the device's live health, what it is playing (with a progress bar),
/// and gives a touchpad, keyboard and presentation controls that drive the
/// remote machine over the session.
class DeviceScreen extends StatefulWidget {
  final AppService service;
  final String deviceId;
  final void Function(DeviceView device) onSendFiles;

  const DeviceScreen({
    super.key,
    required this.service,
    required this.deviceId,
    required this.onSendFiles,
  });

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onChanged);
    _tabs.dispose();
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
    if (device == null) {
      // The device was removed while its screen was open.
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: Text('This device is no longer paired', style: TextStyle(color: WeDropColors.inkDim)),
        ),
      );
    }

    final health = widget.service.healthOf(device.deviceId);
    final media = widget.service.interpolatedMediaOf(device.deviceId);
    final connected = device.connected;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(iconForFormFactor(device.formFactor), size: 20, color: WeDropColors.brandSoft),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  Text(
                    connected ? 'Connected' : device.online ? 'On the network' : 'Offline',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w400,
                      color: connected ? WeDropColors.success : WeDropColors.inkFaint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: device.online ? () => widget.onSendFiles(device) : null,
            icon: const Icon(Icons.upload_rounded),
            tooltip: 'Send files',
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: WeDropColors.brandSoft,
          unselectedLabelColor: WeDropColors.inkFaint,
          indicatorColor: WeDropColors.brand,
          tabs: const [
            Tab(text: 'Overview', icon: Icon(Icons.dashboard_rounded, size: 18)),
            Tab(text: 'Remote', icon: Icon(Icons.mouse_rounded, size: 18)),
            Tab(text: 'Present', icon: Icon(Icons.slideshow_rounded, size: 18)),
          ],
        ),
      ),
      body: !connected
          ? _DisconnectedNotice(device: device)
          : TabBarView(
              controller: _tabs,
              children: [
                _OverviewTab(service: widget.service, device: device, health: health, media: media),
                _RemoteTab(service: widget.service, device: device),
                _PresentTab(service: widget.service, device: device),
              ],
            ),
    );
  }
}

class _DisconnectedNotice extends StatelessWidget {
  final DeviceView device;
  const _DisconnectedNotice({required this.device});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 44, color: WeDropColors.inkFaint),
            const SizedBox(height: 14),
            Text(
              device.online ? 'Connecting to ${device.name}…' : '${device.name} is offline',
              textAlign: TextAlign.center,
              style: const TextStyle(color: WeDropColors.inkDim),
            ),
            const SizedBox(height: 6),
            const Text(
              'The remote works once an encrypted session is established.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: WeDropColors.inkFaint, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Health cards + now-playing media with a progress bar and transport controls.
class _OverviewTab extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  final DeviceHealth? health;
  final MediaState? media;

  const _OverviewTab({
    required this.service,
    required this.device,
    required this.health,
    required this.media,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _HealthGrid(health: health, platform: device.platform),
        const SizedBox(height: 16),
        _MediaCard(service: service, device: device, media: media),
        const SizedBox(height: 16),
        _QuickActions(service: service, device: device),
      ],
    );
  }
}

class _HealthGrid extends StatelessWidget {
  final DeviceHealth? health;
  final String platform;
  const _HealthGrid({required this.health, required this.platform});

  @override
  Widget build(BuildContext context) {
    final h = health;

    // A wider screen (tablet/landscape) fits four tiles across; a phone fits two.
    final columns = MediaQuery.of(context).size.width > 520 ? 4 : 2;

    final tiles = <Widget>[
      _HealthTile(
        icon: h?.charging == true ? Icons.battery_charging_full_rounded : Icons.battery_full_rounded,
        label: 'Battery',
        value: h == null || h.battery < 0 ? '—' : '${h.battery}%',
        accent: _batteryColour(h?.battery ?? -1),
      ),
      _HealthTile(
        icon: _networkIcon(h?.networkType),
        label: 'Network',
        value: _networkLabel(h?.networkType),
      ),
      _HealthTile(
        icon: Icons.memory_rounded,
        label: 'CPU',
        value: h == null || h.cpuPercent < 0 ? '—' : '${h.cpuPercent}%',
      ),
      _HealthTile(
        icon: Icons.sd_storage_rounded,
        label: 'Memory',
        value: h == null || h.memPercent < 0 ? '—' : '${h.memPercent}%',
      ),
    ];

    return GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.35,
      children: tiles,
    );
  }

  Color _batteryColour(int level) {
    if (level < 0) return WeDropColors.inkFaint;
    if (level <= 15) return WeDropColors.danger;
    if (level <= 35) return WeDropColors.warn;
    return WeDropColors.success;
  }

  IconData _networkIcon(String? type) => switch (type) {
        'wifi' => Icons.wifi_rounded,
        'ethernet' => Icons.lan_rounded,
        'cellular' => Icons.signal_cellular_alt_rounded,
        _ => Icons.wifi_off_rounded,
      };

  String _networkLabel(String? type) => switch (type) {
        'wifi' => 'Wi-Fi',
        'ethernet' => 'Wired',
        'cellular' => 'Cellular',
        _ => 'Offline',
      };
}

class _HealthTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  const _HealthTile({
    required this.icon,
    required this.label,
    required this.value,
    this.accent = WeDropColors.brandSoft,
  });

  @override
  Widget build(BuildContext context) {
    return WdCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: accent, size: 22),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700, color: WeDropColors.ink)),
              Text(label, style: const TextStyle(fontSize: 11.5, color: WeDropColors.inkFaint)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Now-playing with a scrubbing-style progress bar and transport controls.
class _MediaCard extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  final MediaState? media;

  const _MediaCard({required this.service, required this.device, required this.media});

  @override
  Widget build(BuildContext context) {
    final m = media;
    final hasMedia = m != null && m.hasMedia;

    return WdCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.music_note_rounded, size: 18, color: WeDropColors.accent),
              const SizedBox(width: 8),
              Text(hasMedia ? (m.app.isEmpty ? 'Now playing' : m.app) : 'Media',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600, color: WeDropColors.inkDim)),
            ],
          ),
          const SizedBox(height: 12),
          if (hasMedia) ...[
            Text(m.title.isEmpty ? 'Unknown track' : m.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: WeDropColors.ink)),
            if (m.artist.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(m.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: WeDropColors.inkFaint)),
              ),
            const SizedBox(height: 12),
            _SeekBar(
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _mediaBtn(Icons.skip_previous_rounded, MediaCommand.prev),
              _mediaBtn(
                m?.playing == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
                MediaCommand.playPause,
                large: true,
              ),
              _mediaBtn(Icons.skip_next_rounded, MediaCommand.next),
            ],
          ),
          const Divider(height: 24),
          // A volume row with its own progress feedback.
          _VolumeControl(service: service, device: device, volume: m?.volume ?? -1),
        ],
      ),
    );
  }

  Widget _mediaBtn(IconData icon, String command, {bool large = false}) {
    return IconButton(
      onPressed: () => service.sendMediaCommand(device.deviceId, command),
      icon: Icon(icon),
      iconSize: large ? 34 : 26,
      color: large ? WeDropColors.brandSoft : WeDropColors.inkDim,
    );
  }
}

/// A track-progress bar that becomes a real, draggable seek control whenever
/// the peer reports a duration. Without one (e.g. a Windows source, which
/// cannot currently report position/duration — see media_now_playing_windows.go)
/// it falls back to a plain indeterminate bar, since there is nothing to seek.
class _SeekBar extends StatefulWidget {
  final int position;
  final int duration;
  final void Function(int targetMillis) onSeek;

  const _SeekBar({required this.position, required this.duration, required this.onSeek});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  // Held while the user is actively dragging, so incoming live-position updates
  // don't yank the thumb out from under their finger mid-drag.
  double? _dragValue;

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
              setState(() => _dragValue = null);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmt(value.toInt()),
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

/// A draggable volume slider that sets an absolute level on the peer, with
/// nudge buttons on either side for a quick tap.
class _VolumeControl extends StatefulWidget {
  final AppService service;
  final DeviceView device;
  final int volume;

  const _VolumeControl({required this.service, required this.device, required this.volume});

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  // Held while the user is dragging, so incoming live-volume updates (from
  // the peer's own periodic reports) don't yank the thumb mid-drag.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final known = widget.volume >= 0;
    final value = (_dragValue ?? widget.volume.toDouble()).clamp(0.0, 100.0);

    return Row(
      children: [
        IconButton(
          onPressed: () => widget.service.sendMediaCommand(widget.device.deviceId, MediaCommand.volDown),
          icon: const Icon(Icons.volume_down_rounded),
          color: WeDropColors.inkDim,
        ),
        Expanded(
          child: known
              ? SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 15),
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
                        volume: v.round(),
                      );
                      setState(() => _dragValue = null);
                    },
                  ),
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: const LinearProgressIndicator(
                    value: 0,
                    minHeight: 4,
                    backgroundColor: WeDropColors.border,
                  ),
                ),
        ),
        IconButton(
          onPressed: () => widget.service.sendMediaCommand(widget.device.deviceId, MediaCommand.volUp),
          icon: const Icon(Icons.volume_up_rounded),
          color: WeDropColors.inkDim,
        ),
      ],
    );
  }
}

class _QuickActions extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  const _QuickActions({required this.service, required this.device});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () async {
              try {
                await service.pushClipboard();
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(e.toString())));
                }
              }
            },
            icon: const Icon(Icons.content_paste_rounded, size: 18),
            label: const Text('Send clipboard'),
            style: OutlinedButton.styleFrom(
              foregroundColor: WeDropColors.inkDim,
              side: const BorderSide(color: WeDropColors.border),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ],
    );
  }
}

/// A touchpad + click buttons + a keyboard field — the phone as a mouse.
class _RemoteTab extends StatefulWidget {
  final AppService service;
  final DeviceView device;
  const _RemoteTab({required this.service, required this.device});

  @override
  State<_RemoteTab> createState() => _RemoteTabState();
}

class _RemoteTabState extends State<_RemoteTab> {
  final TextEditingController _keyboard = TextEditingController();
  final FocusNode _keyboardFocus = FocusNode();
  Offset? _last;

  void _send(RemoteInput input) => widget.service.sendRemoteInput(widget.device.deviceId, input);

  @override
  void dispose() {
    _keyboard.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: GestureDetector(
              onPanStart: (d) => _last = d.localPosition,
              onPanUpdate: (d) {
                final last = _last;
                if (last == null) return;
                final delta = d.localPosition - last;
                _last = d.localPosition;
                _send(RemoteInput(action: InputAction.mouseMove, dx: delta.dx, dy: delta.dy));
              },
              onPanEnd: (_) => _last = null,
              // A single tap is a left click; the OS focus follows the cursor.
              onTap: () => _send(const RemoteInput(action: InputAction.mouseLeft)),
              onLongPress: () {
                HapticFeedback.mediumImpact();
                _send(const RemoteInput(action: InputAction.mouseRight));
              },
              child: Container(
                decoration: BoxDecoration(
                  color: WeDropColors.surface.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: WeDropColors.border),
                ),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.touch_app_rounded, size: 34, color: WeDropColors.inkFaint),
                      SizedBox(height: 10),
                      Text('Drag to move · tap to click',
                          style: TextStyle(color: WeDropColors.inkFaint, fontSize: 12.5)),
                      SizedBox(height: 2),
                      Text('long-press to right-click',
                          style: TextStyle(color: WeDropColors.inkFaint, fontSize: 11.5)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: _clickButton('Left', () => _send(const RemoteInput(action: InputAction.mouseLeft))),
              ),
              const SizedBox(width: 10),
              _scrollColumn(),
              const SizedBox(width: 10),
              Expanded(
                child: _clickButton('Right', () => _send(const RemoteInput(action: InputAction.mouseRight))),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _keyboard,
                  focusNode: _keyboardFocus,
                  decoration: const InputDecoration(
                    hintText: 'Type on the other device…',
                    isDense: true,
                  ),
                  // Send each keystroke live so backspace and typing feel direct.
                  onChanged: _onKeyboardChanged,
                  onSubmitted: (_) {
                    _send(const RemoteInput(action: InputAction.key, key: SpecialKey.enter));
                    _keyboard.clear();
                    _keyboardFocus.requestFocus();
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: () =>
                    _send(const RemoteInput(action: InputAction.key, key: SpecialKey.backspace)),
                icon: const Icon(Icons.backspace_outlined, size: 18),
                style: IconButton.styleFrom(backgroundColor: WeDropColors.surfaceHi),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _previous = '';

  void _onKeyboardChanged(String value) {
    // Diff against the previous value so we send only what changed: appended
    // text is typed literally, a shorter value is a backspace.
    if (value.length > _previous.length && value.startsWith(_previous)) {
      _send(RemoteInput(action: InputAction.type, text: value.substring(_previous.length)));
    } else if (value.length < _previous.length && _previous.startsWith(value)) {
      for (var i = 0; i < _previous.length - value.length; i++) {
        _send(const RemoteInput(action: InputAction.key, key: SpecialKey.backspace));
      }
    }
    _previous = value;
  }

  Widget _clickButton(String label, VoidCallback onTap) {
    return Material(
      color: WeDropColors.surfaceHi,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 46,
          alignment: Alignment.center,
          child: Text(label,
              style: const TextStyle(fontWeight: FontWeight.w600, color: WeDropColors.inkDim)),
        ),
      ),
    );
  }

  Widget _scrollColumn() {
    return Column(
      children: [
        _scrollBtn(Icons.keyboard_arrow_up_rounded, -3),
        const SizedBox(height: 6),
        _scrollBtn(Icons.keyboard_arrow_down_rounded, 3),
      ],
    );
  }

  Widget _scrollBtn(IconData icon, double amount) {
    return Material(
      color: WeDropColors.surfaceHi,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: () => _send(RemoteInput(action: InputAction.scroll, dy: amount)),
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(width: 40, height: 20, child: Icon(icon, size: 18, color: WeDropColors.inkDim)),
      ),
    );
  }
}

/// Presentation pointer — big Prev/Next plus start, blank and end.
class _PresentTab extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  const _PresentTab({required this.service, required this.device});

  void _present(String action) => service.sendRemoteInput(
        device.deviceId,
        RemoteInput(action: action),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _slideBtn(Icons.arrow_back_rounded, 'Previous', InputAction.presentPrev)),
              const SizedBox(width: 12),
              Expanded(child: _slideBtn(Icons.arrow_forward_rounded, 'Next', InputAction.presentNext)),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Material(
              color: WeDropColors.brand.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                onTap: () => _present(InputAction.presentNext),
                borderRadius: BorderRadius.circular(18),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.ads_click_rounded, size: 40, color: WeDropColors.brandSoft),
                      SizedBox(height: 12),
                      Text('Tap anywhere for next slide',
                          style: TextStyle(color: WeDropColors.brandSoft, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _smallBtn('Start', Icons.play_arrow_rounded, InputAction.presentStart)),
              const SizedBox(width: 10),
              Expanded(child: _smallBtn('Blank', Icons.stop_circle_outlined, InputAction.presentBlank)),
              const SizedBox(width: 10),
              Expanded(child: _smallBtn('End', Icons.close_rounded, InputAction.presentEnd)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _slideBtn(IconData icon, String label, String action) {
    return Material(
      color: WeDropColors.surfaceHi,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => _present(action),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 64,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: WeDropColors.brandSoft),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(fontSize: 12, color: WeDropColors.inkDim)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _smallBtn(String label, IconData icon, String action) {
    return Material(
      color: WeDropColors.surfaceHi,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () => _present(action),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: WeDropColors.inkDim),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 11, color: WeDropColors.inkFaint)),
            ],
          ),
        ),
      ),
    );
  }
}
