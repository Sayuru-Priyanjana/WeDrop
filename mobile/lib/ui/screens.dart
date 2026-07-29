import 'package:flutter/material.dart';

import '../core/app_service.dart';
import '../core/protocol/messages.dart';
import '../core/storage/store.dart';
import '../plugins/files/files_plugin.dart' show TransferStatus;
import 'theme.dart';
import 'widgets.dart';

/// The ecosystem screen: paired devices, then anything new nearby.
class DevicesScreen extends StatelessWidget {
  final AppService service;
  final void Function(DeviceView device) onSendFiles;
  final void Function(String deviceId) onPair;
  final void Function(DeviceView device) onOpenDevice;
  final String? pairingWith;

  const DevicesScreen({
    super.key,
    required this.service,
    required this.onSendFiles,
    required this.onPair,
    required this.onOpenDevice,
    this.pairingWith,
  });

  @override
  Widget build(BuildContext context) {
    final paired = service.pairedDevices;
    final nearby = service.discoveredDevices;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        if (paired.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 16, left: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'My ecosystem',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: WeDropColors.ink),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Trusted devices that sync automatically.',
                        style: TextStyle(fontSize: 12, color: WeDropColors.inkDim.withValues(alpha: 0.5), height: 1.3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ...paired.map(
            (device) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: PairedDeviceTile(
                device: device,
                service: service,
                onSendFiles: () => onSendFiles(device),
                onOpen: () => onOpenDevice(device),
              ),
            ),
          ),
        ] else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: WdCard(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                children: [
                  Icon(Icons.devices_rounded, size: 48, color: WeDropColors.inkDim.withValues(alpha: 0.5)),
                  const SizedBox(height: 24),
                  const Text(
                    'No devices paired',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: WeDropColors.inkDim),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pair a device below to start syncing files and clipboards.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: WeDropColors.inkDim.withValues(alpha: 0.5), height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ],

        if (nearby.isNotEmpty || paired.isNotEmpty) const SizedBox(height: 24),
        
        Padding(
          padding: const EdgeInsets.only(bottom: 16, left: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Nearby',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: WeDropColors.ink),
              ),
              const SizedBox(height: 4),
              Text(
                'Other devices running WeDrop on this network.',
                style: TextStyle(fontSize: 12, color: WeDropColors.inkDim.withValues(alpha: 0.5), height: 1.3),
              ),
            ],
          ),
        ),
        
        if (nearby.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: WdCard(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                children: [
                  Icon(Icons.wifi_tethering_rounded, size: 48, color: WeDropColors.inkDim.withValues(alpha: 0.5)),
                  const SizedBox(height: 24),
                  const Text(
                    'Nothing new nearby',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: WeDropColors.inkDim),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Open WeDrop on your other devices\nand make sure they share this Wi-Fi.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: WeDropColors.inkDim.withValues(alpha: 0.5), height: 1.4),
                  ),
                ],
              ),
            ),
          )
        else
          ...nearby.map(
            (device) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: WdCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(iconForFormFactor(device.formFactor), size: 18, color: WeDropColors.inkDim),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            device.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: WeDropColors.ink),
                          ),
                          Text(
                            '${device.platform} · ${device.ip}',
                            style: const TextStyle(fontSize: 11, color: WeDropColors.inkFaint),
                          ),
                        ],
                      ),
                    ),
                    FilledButton(
                      onPressed: pairingWith == device.deviceId ? null : () => onPair(device.deviceId),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                        minimumSize: const Size(60, 28),
                        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      child: Text(pairingWith == device.deviceId ? 'Wait' : 'Pair'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A compact battery indicator shown on connected device cards.
class _BatteryPill extends StatelessWidget {
  final int level;
  final bool charging;
  const _BatteryPill({required this.level, required this.charging});

  @override
  Widget build(BuildContext context) {
    final colour = level <= 15
        ? WeDropColors.danger
        : level <= 35
        ? WeDropColors.warn
        : WeDropColors.success;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        // Neutral pill background regardless of level — only the icon/text
        // carry the battery colour, matching the reference exactly.
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            charging ? Icons.bolt_rounded : Icons.battery_full_rounded,
            size: 12,
            color: colour,
          ),
          const SizedBox(width: 2),
          Text(
            '$level%',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: colour,
            ),
          ),
        ],
      ),
    );
  }
}

/// A paired device with its quick actions, media remote and permissions.
class PairedDeviceTile extends StatefulWidget {
  final DeviceView device;
  final AppService service;
  final VoidCallback onSendFiles;
  final VoidCallback onOpen;

  const PairedDeviceTile({
    super.key,
    required this.device,
    required this.service,
    required this.onSendFiles,
    required this.onOpen,
  });

  @override
  State<PairedDeviceTile> createState() => _PairedDeviceTileState();
}

class _PairedDeviceTileState extends State<PairedDeviceTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final health = widget.service.healthOf(device.deviceId);
    final battery = device.connected ? (health?.battery ?? -1) : -1;
    final charging = health?.charging ?? false;
    final status = device.connected ? 'connected' : device.online ? 'online' : 'offline';
    final statusLabel = device.connected ? 'Connected' : device.online ? 'On network' : device.lastSeen > 0 ? 'Seen ${timeAgo(device.lastSeen)}' : 'Offline';

    return WdCard(
      padding: EdgeInsets.zero,
      borderColor: device.connected ? Colors.white.withValues(alpha: 0.1) : WeDropColors.border,
      child: Column(
        children: [
          InkWell(
            onTap: device.connected ? widget.onOpen : null,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.card)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: WeDropColors.surfaceHi,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: WeDropColors.border, width: 1),
                        ),
                        child: Icon(iconForFormFactor(device.formFactor), size: 20, color: device.connected ? WeDropColors.ink : WeDropColors.inkDim),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(device.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: WeDropColors.ink)),
                                ),
                                if (battery >= 0) ...[
                                  const SizedBox(width: 8),
                                  _BatteryPill(level: battery, charging: charging),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                StatusDot(status),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text('${device.platform} · $statusLabel', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: WeDropColors.inkDim)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (device.online)
                        _compactDeviceAction(Icons.send_rounded, WeDropColors.brand, WeDropColors.brand.withValues(alpha: 0.15), widget.onSendFiles),
                      const SizedBox(width: 8),
                      _compactDeviceAction(Icons.close_rounded, WeDropColors.danger, WeDropColors.danger.withValues(alpha: 0.15), () => _confirmUnpair(context)),
                    ],
                  ),
                  if (device.connected) ...[
                    const SizedBox(height: 12),
                    _buildMediaRow(),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(Radii.card)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('What this device can do', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WeDropColors.ink)),
                  ),
                  Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: WeDropColors.inkDim),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                children: [
                  _permission('Share clipboard', Capability.clipboard, device.allowClipboard),
                  _permission('Send me files', Capability.files, device.allowFiles),
                  _permission('Mirror notifications', Capability.notifications, device.allowNotifications),
                  _permission('Control my media', Capability.media, device.allowMedia),
                  _permission('Run workspace actions', Capability.workspace, device.allowWorkspace),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _permission(String label, String capability, bool allowed) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 12, color: WeDropColors.ink)),
          ),
          Transform.scale(
            scale: 0.7,
            child: Switch(
              value: allowed,
              onChanged: (value) => widget.service.setPermission(widget.device.deviceId, capability, value),
            ),
          ),
        ],
      ),
    );
  }



  Widget _mediaButton(IconData icon, String command, {bool primary = false}) {
    return IconButton(
      onPressed: () => widget.service.sendMediaCommand(widget.device.deviceId, command),
      icon: Icon(icon),
      color: primary ? WeDropColors.ink : WeDropColors.inkDim,
      iconSize: primary ? 20 : 16,
      constraints: const BoxConstraints(),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildMediaRow() {
    final media = widget.device.allowMedia ? widget.service.interpolatedMediaOf(widget.device.deviceId) : null;
    if (media == null || !media.hasMedia) return const SizedBox.shrink();

    final known = media.position >= 0 && media.duration > 0;

    return Row(
      children: [
        if (media.artwork.isNotEmpty) ...[
          ArtworkThumbnail(base64: media.artwork, size: 28, radius: 4),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                media.title.isEmpty ? 'Unknown' : media.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: WeDropColors.ink),
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(Radii.pill),
                child: LinearProgressIndicator(
                  value: known ? (media.position / media.duration).clamp(0.0, 1.0) : null,
                  minHeight: 2,
                  backgroundColor: WeDropColors.border,
                  valueColor: const AlwaysStoppedAnimation(WeDropColors.ink),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _mediaButton(Icons.skip_previous_rounded, MediaCommand.prev),
        _mediaButton(media.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, MediaCommand.playPause, primary: true),
        _mediaButton(Icons.skip_next_rounded, MediaCommand.next),
      ],
    );
  }

  Widget _compactDeviceAction(IconData icon, Color color, Color bg, VoidCallback onTap) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: IconButton(
        icon: Icon(icon),
        color: color,
        iconSize: 14,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        onPressed: onTap,
      ),
    );
  }

  Future<void> _confirmUnpair(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${widget.device.name}?'),
        content: const Text(
          'It will stop syncing immediately, and you will both need to pair again to reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: WeDropColors.danger),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.service.unpair(widget.device.deviceId);
    }
  }
}

/// Transfers, newest first.
class TransfersScreen extends StatelessWidget {
  final AppService service;

  const TransfersScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    if (service.transfers.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 100),
        child: EmptyState(
          icon: Icons.swap_horiz_rounded,
          title: 'No transfers yet',
          hint:
              'Send a file from a device, or share to WeDrop from any other app.',
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 100),
      itemCount: service.transfers.length,
      separatorBuilder: (_, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final transfer = service.transfers[index];
        final ratio = transfer.size > 0
            ? transfer.transferred / transfer.size
            : 0.0;

        final (label, colour) = switch (transfer.status) {
          TransferStatus.completed => ('Done', WeDropColors.inkDim),
          TransferStatus.failed => ('Failed', WeDropColors.danger),
          TransferStatus.declined => ('Declined', WeDropColors.warn),
          TransferStatus.pending => ('Waiting', WeDropColors.brandSoft),
          TransferStatus.active => (
            '${(ratio * 100).round()}%',
            WeDropColors.brandSoft,
          ),
        };

        return WdCard(
          child: Column(
            children: [
              Row(
                children: [
                  WdIconBadge(
                    icon: transfer.incoming
                        ? Icons.download_rounded
                        : Icons.upload_rounded,
                    colour: transfer.incoming
                        ? WeDropColors.accent
                        : WeDropColors.brand,
                    size: 38,
                    tinted: true,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                transfer.filename,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w500,
                                  color: WeDropColors.ink,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            WdBadge(label, colour: colour),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${transfer.incoming ? 'from' : 'to'} ${transfer.deviceName} · '
                          '${transfer.status == TransferStatus.active && transfer.size > 0 ? '${formatBytes(transfer.transferred)} of ${formatBytes(transfer.size)}' : formatBytes(transfer.size)}'
                          '${transfer.error.isNotEmpty ? ' · ${transfer.error}' : ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: WeDropColors.inkFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (transfer.status == TransferStatus.active)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    child: LinearProgressIndicator(
                      value: transfer.size > 0 ? ratio : null,
                      minHeight: 5,
                      backgroundColor: WeDropColors.border,
                      valueColor: const AlwaysStoppedAnimation(
                        WeDropColors.brand,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Clipboard history with one-tap restore.
class ClipboardScreen extends StatelessWidget {
  final AppService service;

  const ClipboardScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 100),
      children: [
        SectionHeader(
          title: 'Clipboard',
          hint: service.settings.autoSyncClipboard
              ? 'Anything you copy is shared with your ecosystem.'
              : 'Automatic sync is off — send manually when you need it.',
          trailing: Row(
            children: [
              if (service.clipboardHistory.isNotEmpty)
                IconButton(
                  onPressed: service.clearClipboardHistory,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  color: WeDropColors.inkFaint,
                  tooltip: 'Clear list',
                ),
              FilledButton.icon(
                onPressed: () async {
                  try {
                    await service.pushClipboard();
                  } catch (error) {
                    if (context.mounted) _snack(context, error.toString());
                  }
                },
                icon: const Icon(Icons.send_rounded, size: 16),
                label: const Text('Send'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (service.clipboardHistory.isEmpty)
          const EmptyState(
            icon: Icons.content_paste_rounded,
            title: 'Nothing shared yet',
            hint:
                'Copy some text on any paired device and it will appear here.',
          )
        else
          ...service.clipboardHistory.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: WdCard(
                onTap: () async {
                  await service.copyToClipboard(entry.text);
                  if (context.mounted) _snack(context, 'Copied');
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.text,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        color: WeDropColors.inkDim,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        WdBadge(
                          entry.incoming
                              ? 'from ${entry.originName}'
                              : 'this device',
                          colour: entry.incoming
                              ? WeDropColors.brandSoft
                              : WeDropColors.inkFaint,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          timeAgo(entry.time),
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: WeDropColors.inkFaint,
                          ),
                        ),
                        const Spacer(),
                        const Icon(
                          Icons.copy_rounded,
                          size: 15,
                          color: WeDropColors.inkFaint,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Notifications mirrored from other devices.
class NotificationsScreen extends StatelessWidget {
  final AppService service;

  const NotificationsScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 100),
      children: [
        SectionHeader(
          title: 'Notifications',
          hint: 'Alerts mirrored from your other devices.',
          trailing: service.notifications.isEmpty
              ? null
              : IconButton(
                  onPressed: service.clearNotifications,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  color: WeDropColors.inkFaint,
                  tooltip: 'Clear',
                ),
        ),

        // Mirroring this phone's own alerts needs a permission only the user
        // can grant, in a settings screen we can open but not bypass.
        if (service.settings.shareNotifications &&
            !service.hasNotificationAccess)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: WdCard(
              borderColor: WeDropColors.warn.withValues(alpha: 0.35),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    color: WeDropColors.warn,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'To mirror this phone\'s notifications, WeDrop needs notification access.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: WeDropColors.inkDim,
                        height: 1.4,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await NotificationAccessRequest.open();
                      await service.refreshNotificationAccess();
                    },
                    child: const Text('Grant'),
                  ),
                ],
              ),
            ),
          ),

        if (service.notifications.isEmpty)
          const EmptyState(
            icon: Icons.notifications_none_rounded,
            title: 'Nothing to catch up on',
            hint: 'Notifications from your other devices will show up here.',
          )
        else
          ...service.notifications.map(
            (notification) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: WdCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const WdIconBadge(
                      icon: Icons.notifications_rounded,
                      size: 36,
                      iconSize: 17,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            notification.title.isEmpty
                                ? notification.app
                                : notification.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: WeDropColors.ink,
                            ),
                          ),
                          if (notification.body.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              notification.body,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: WeDropColors.inkDim,
                                height: 1.4,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Text(
                            '${notification.app} · ${notification.deviceName} · '
                            '${timeAgo(notification.time)}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: WeDropColors.inkFaint,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Indirection so the screens do not import the platform bridge directly.
class NotificationAccessRequest {
  static Future<void> Function() open = () async {};
}

/// Every switch, applied immediately.
class SettingsScreen extends StatefulWidget {
  final AppService service;

  const SettingsScreen({super.key, required this.service});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.service.deviceName,
  );

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _patch(void Function(Settings settings) change) {
    final next = widget.service.settings.copy();
    change(next);
    widget.service.updateSettings(next);
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final settings = service.settings;

    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 100),
      children: [
        const SectionHeader(
          title: 'Settings',
          hint: 'How this device behaves inside your ecosystem.',
        ),
        WdCard(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: Column(
            children: [
              SettingTile(
                title: 'Device name',
                description: 'What the other devices call this phone.',
                control: SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _nameController,
                    textAlign: TextAlign.right,
                    maxLength: 48,
                    style: const TextStyle(
                      fontSize: 13,
                      color: WeDropColors.ink,
                    ),
                    decoration: const InputDecoration(
                      counterText: '',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: (value) => service.setDeviceName(value),
                    onTapOutside: (_) {
                      FocusScope.of(context).unfocus();
                      if (_nameController.text.trim() != service.deviceName) {
                        service.setDeviceName(_nameController.text);
                      }
                    },
                  ),
                ),
              ),
              SettingTile(
                title: 'Visible on this network',
                description:
                    'Announce this device so others can find and pair with it.',
                control: Switch(
                  value: settings.discoverable,
                  onChanged: (v) => _patch((s) => s.discoverable = v),
                ),
              ),
              SettingTile(
                title: 'Accept new pairing requests',
                description: 'Turn off once your ecosystem is complete.',
                control: Switch(
                  value: settings.acceptNewPairing,
                  onChanged: (v) => _patch((s) => s.acceptNewPairing = v),
                ),
                last: true,
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),
        const SectionHeader(title: 'Clipboard'),
        WdCard(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: Column(
            children: [
              SettingTile(
                title: 'Share my clipboard automatically',
                description:
                    'Anything you copy here is sent to your ecosystem.',
                control: Switch(
                  value: settings.autoSyncClipboard,
                  onChanged: (v) => _patch((s) => s.autoSyncClipboard = v),
                ),
              ),
              SettingTile(
                title: 'Apply clipboard from other devices',
                description:
                    'Let paired devices update this phone\'s clipboard.',
                control: Switch(
                  value: settings.receiveClipboard,
                  onChanged: (v) => _patch((s) => s.receiveClipboard = v),
                ),
                last: true,
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),
        const SectionHeader(title: 'Files'),
        WdCard(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: Column(
            children: [
              SettingTile(
                title: 'Accept files without asking',
                description:
                    'Files from paired devices are saved straight away.',
                control: Switch(
                  value: settings.autoAcceptFiles,
                  onChanged: (v) => _patch((s) => s.autoAcceptFiles = v),
                ),
              ),
              SettingTile(
                title: 'Saved to',
                description: service.downloadDir,
                control: const SizedBox.shrink(),
                last: true,
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),
        const SectionHeader(title: 'Notifications and media'),
        WdCard(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: Column(
            children: [
              SettingTile(
                title: 'Show notifications from other devices',
                control: Switch(
                  value: settings.receiveNotifications,
                  onChanged: (v) => _patch((s) => s.receiveNotifications = v),
                ),
              ),
              SettingTile(
                title: 'Mirror my notifications',
                description: service.hasNotificationAccess
                    ? 'Send this phone\'s alerts to your other devices.'
                    : 'Needs notification access — tap Grant on the Notifications tab.',
                control: Switch(
                  value: settings.shareNotifications,
                  onChanged: (v) => _patch((s) => s.shareNotifications = v),
                ),
              ),
              SettingTile(
                title: 'Let other devices control my media',
                description:
                    'Play, pause and volume commands are applied here.',
                control: Switch(
                  value: settings.allowMediaControl,
                  onChanged: (v) => _patch((s) => s.allowMediaControl = v),
                ),
              ),
              SettingTile(
                title: 'Allow shell/script commands',
                description:
                    'Off by default. Lets a "My Workspace" button run an arbitrary '
                    'command on this device — only turn this on for devices you fully trust.',
                control: Switch(
                  value: settings.allowAutomation,
                  onChanged: (v) => _patch((s) => s.allowAutomation = v),
                ),
                last: true,
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),
        const SectionHeader(
          title: 'Advanced',
          hint:
              'Show extra detail like network, CPU and memory on a device\'s overview.',
        ),
        WdCard(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: Column(
            children: [
              SettingTile(
                title: 'Show advanced device stats',
                description:
                    'Adds network, CPU and memory to battery and sound.',
                control: Switch(
                  value: settings.showAdvancedFeatures,
                  onChanged: (v) => _patch((s) => s.showAdvancedFeatures = v),
                ),
                last: true,
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),
        const SectionHeader(
          title: 'Background',
          hint:
              'WeDrop shows a "connected devices" notification while it is '
              'reachable — that is what keeps files, clipboard and notifications flowing. '
              'You can dismiss it any time; it reappears when the connection state changes.',
        ),
        WdCard(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: Column(
            children: [
              SettingTile(
                title: 'Ignore battery optimisation',
                description:
                    'Stops Android suspending WeDrop while your screen is off.',
                control: TextButton(
                  onPressed: BatteryOptimisationRequest.open,
                  child: const Text('Open'),
                ),
                last: true,
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),
        const SectionHeader(title: 'This device'),
        WdCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field('Device ID', service.deviceId),
              const SizedBox(height: 12),
              _field('Identity key', service.publicKey),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w600,
            color: WeDropColors.inkFaint,
          ),
        ),
        const SizedBox(height: 5),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: WeDropColors.bgSoft,
            borderRadius: BorderRadius.circular(Radii.control),
          ),
          child: SelectableText(
            value,
            style: const TextStyle(
              fontSize: 11.5,
              fontFamily: 'monospace',
              color: WeDropColors.inkDim,
            ),
          ),
        ),
      ],
    );
  }
}

/// Indirection so the settings screen does not import the platform bridge.
class BatteryOptimisationRequest {
  static void Function() open = () {};
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
