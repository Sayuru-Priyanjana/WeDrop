import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_service.dart';
import '../core/protocol/messages.dart';
import 'media_controller_screen.dart';
import 'theme.dart';
import 'widgets.dart';
import 'workspace_tab.dart';

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
  late final TabController _tabs = TabController(length: 4, vsync: this);

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
            Tab(text: 'Workspace', icon: Icon(Icons.dashboard_customize_rounded, size: 18)),
          ],
        ),
      ),
      body: !connected
          ? _DisconnectedNotice(device: device)
          : TabBarView(
              controller: _tabs,
              // The Remote/Present tabs are full-surface drag areas (touchpad,
              // laser pointer) — a horizontal swipe to change slides or move
              // the cursor was constantly mistaken for a tab-switch gesture.
              // Only the tab bar itself switches tabs now.
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _OverviewTab(service: widget.service, device: device, health: health, media: media),
                _RemoteTab(service: widget.service, device: device),
                _PresentTab(service: widget.service, device: device),
                WorkspaceTab(service: widget.service, device: device),
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
        _HealthGrid(
          health: health,
          platform: device.platform,
          showAdvanced: service.settings.showAdvancedFeatures,
        ),
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
  final bool showAdvanced;
  const _HealthGrid({required this.health, required this.platform, required this.showAdvanced});

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
      // Network/CPU/memory are detail most people never look at day to day —
      // kept out of the default view and only shown once the user opts in
      // via Settings > Advanced.
      if (showAdvanced) ...[
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
      ],
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
/// Tapping the card (outside its own buttons/seek bar) opens the full
/// media controller screen.
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
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MediaControllerScreen(service: service, deviceId: device.deviceId),
        ),
      ),
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (m.artwork.isNotEmpty) ...[
                  ArtworkThumbnail(base64: m.artwork, size: 52),
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
                              fontSize: 15, fontWeight: FontWeight.w600, color: WeDropColors.ink)),
                      if (m.artist.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(m.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5, color: WeDropColors.inkFaint)),
                        ),
                    ],
                  ),
                ),
              ],
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
  // don't yank the thumb out from under their finger mid-drag. Also held
  // (optimistically) for a short window right after release: the peer only
  // confirms the seek once its next MediaState round-trips back, which is
  // visibly slower than the drag itself, so releasing it immediately made the
  // thumb jump back to the pre-seek position before snapping to the real one.
  double? _dragValue;
  Timer? _confirmTimeout;

  @override
  void didUpdateWidget(_SeekBar old) {
    super.didUpdateWidget(old);
    // A fresh position close to what we asked for confirms the seek landed —
    // stop overriding it with the optimistic value.
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
              // Keep showing the target the user dropped the thumb on until
              // the peer's next MediaState confirms it (see didUpdateWidget)
              // or this fallback timeout gives up and reverts to whatever
              // the peer actually reports.
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

  // Mouse-move deltas are coalesced here and flushed on a fixed timer instead
  // of firing a network message per onPanUpdate callback (which can be
  // dozens per second on a fast drag) — this is what caused the visible lag
  // between a swipe and the remote cursor catching up.
  double _pendingDx = 0;
  double _pendingDy = 0;
  Timer? _flushTimer;

  void _send(RemoteInput input) => widget.service.sendRemoteInput(widget.device.deviceId, input);

  void _queueMove(Offset delta, double devicePixelRatio) {
    // Normalize by device pixel ratio so a drag of the same physical distance
    // moves the remote cursor the same amount regardless of the phone's
    // screen density, then apply the user's own cursor-speed preference.
    final speed = widget.service.settings.cursorSpeed;
    _pendingDx += delta.dx / devicePixelRatio * speed;
    _pendingDy += delta.dy / devicePixelRatio * speed;
    _flushTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _flushMove());
  }

  void _flushMove() {
    if (_pendingDx == 0 && _pendingDy == 0) return;
    _send(RemoteInput(action: InputAction.mouseMove, dx: _pendingDx, dy: _pendingDy));
    _pendingDx = 0;
    _pendingDy = 0;
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _keyboard.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _CursorSpeedControl(service: widget.service),
        ),
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
                _queueMove(delta, MediaQuery.of(context).devicePixelRatio);
              },
              onPanEnd: (_) {
                _last = null;
                _flushMove();
              },
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
    } else if (value != _previous) {
      // Anything that isn't a pure append or pure truncate (autocorrect
      // replacing a word, pasting over a selection, editing mid-string) isn't
      // a simple diff — falling through here used to send nothing at all and
      // silently desync the remote text from what's shown locally. Instead,
      // clear what the remote device has and retype the field from scratch.
      for (var i = 0; i < _previous.length; i++) {
        _send(const RemoteInput(action: InputAction.key, key: SpecialKey.backspace));
      }
      if (value.isNotEmpty) {
        _send(RemoteInput(action: InputAction.type, text: value));
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

/// A small speed slider for the touchpad's mouse-move sensitivity, persisted
/// in Settings so it applies across sessions rather than resetting each time
/// the Remote tab is reopened.
class _CursorSpeedControl extends StatefulWidget {
  final AppService service;
  const _CursorSpeedControl({required this.service});

  @override
  State<_CursorSpeedControl> createState() => _CursorSpeedControlState();
}

class _CursorSpeedControlState extends State<_CursorSpeedControl> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final value = _dragValue ?? widget.service.settings.cursorSpeed;

    return Row(
      children: [
        const Icon(Icons.speed_rounded, size: 16, color: WeDropColors.inkFaint),
        const SizedBox(width: 8),
        const Text('Cursor speed', style: TextStyle(fontSize: 12, color: WeDropColors.inkFaint)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              min: 0.25,
              max: 3.0,
              value: value.clamp(0.25, 3.0),
              onChanged: (v) => setState(() => _dragValue = v),
              onChangeEnd: (v) {
                final next = widget.service.settings.copy()..cursorSpeed = v;
                widget.service.updateSettings(next);
                setState(() => _dragValue = null);
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Presentation pointer — big Prev/Next plus start, laser toggle and end.
///
/// The middle area does one of two things depending on whether the laser
/// pointer is enabled (toggled via the button that used to just blank the
/// screen):
///  - disabled (default): tap anywhere advances to the next slide.
///  - enabled: dragging moves the remote cursor like a laser pointer, the
///    same relative mouse-move messages (and cursor-speed setting) the
///    Remote tab's touchpad uses, rather than tapping to advance.
class _PresentTab extends StatefulWidget {
  final AppService service;
  final DeviceView device;
  const _PresentTab({required this.service, required this.device});

  @override
  State<_PresentTab> createState() => _PresentTabState();
}

class _PresentTabState extends State<_PresentTab> {
  bool _laserEnabled = false;
  Offset? _last;
  double _pendingDx = 0;
  double _pendingDy = 0;
  Timer? _flushTimer;

  void _present(String action) =>
      widget.service.sendRemoteInput(widget.device.deviceId, RemoteInput(action: action));

  void _queueMove(Offset delta, double devicePixelRatio) {
    final speed = widget.service.settings.cursorSpeed;
    _pendingDx += delta.dx / devicePixelRatio * speed;
    _pendingDy += delta.dy / devicePixelRatio * speed;
    _flushTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _flushMove());
  }

  void _flushMove() {
    if (_pendingDx == 0 && _pendingDy == 0) return;
    widget.service.sendRemoteInput(
      widget.device.deviceId,
      RemoteInput(action: InputAction.mouseMove, dx: _pendingDx, dy: _pendingDy),
    );
    _pendingDx = 0;
    _pendingDy = 0;
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }

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
              child: _laserEnabled
                  ? GestureDetector(
                      onPanStart: (d) => _last = d.localPosition,
                      onPanUpdate: (d) {
                        final last = _last;
                        if (last == null) return;
                        final delta = d.localPosition - last;
                        _last = d.localPosition;
                        _queueMove(delta, MediaQuery.of(context).devicePixelRatio);
                      },
                      onPanEnd: (_) {
                        _last = null;
                        _flushMove();
                      },
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.gps_fixed_rounded, size: 40, color: WeDropColors.brandSoft),
                            SizedBox(height: 12),
                            Text('Drag to move the laser pointer',
                                style:
                                    TextStyle(color: WeDropColors.brandSoft, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    )
                  : InkWell(
                      onTap: () => _present(InputAction.presentNext),
                      borderRadius: BorderRadius.circular(18),
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.ads_click_rounded, size: 40, color: WeDropColors.brandSoft),
                            SizedBox(height: 12),
                            Text('Tap anywhere for next slide',
                                style:
                                    TextStyle(color: WeDropColors.brandSoft, fontWeight: FontWeight.w600)),
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
              Expanded(
                child: _laserToggleBtn(),
              ),
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

  Widget _laserToggleBtn() {
    final active = _laserEnabled;
    return Material(
      color: active ? WeDropColors.brand.withValues(alpha: 0.2) : WeDropColors.surfaceHi,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () => setState(() => _laserEnabled = !_laserEnabled),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.gps_fixed_rounded,
                  size: 18, color: active ? WeDropColors.brandSoft : WeDropColors.inkDim),
              const SizedBox(height: 2),
              Text('Laser',
                  style: TextStyle(
                      fontSize: 11, color: active ? WeDropColors.brandSoft : WeDropColors.inkFaint)),
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
