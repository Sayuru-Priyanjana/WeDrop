import 'package:flutter/material.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:uuid/uuid.dart';

import '../core/app_service.dart';
import '../core/protocol/messages.dart';
import '../core/storage/store.dart';
import 'theme.dart';
import 'widgets.dart';

/// A curated icon set for workspace buttons, keyed by a stable string (so the
/// choice survives being persisted as JSON) rather than storing an IconData's
/// own codePoint, which is not guaranteed stable across Flutter versions.
const Map<String, IconData> kWorkspaceIcons = {
  'bolt': Icons.bolt_rounded,
  'terminal': Icons.terminal_rounded,
  'code': Icons.code_rounded,
  'folder': Icons.folder_rounded,
  'globe': Icons.public_rounded,
  'apps': Icons.apps_rounded,
  'keyboard': Icons.keyboard_rounded,
  'save': Icons.save_rounded,
  'search': Icons.search_rounded,
  'refresh': Icons.refresh_rounded,
  'star': Icons.star_rounded,
  'settings': Icons.settings_rounded,
  'music': Icons.music_note_rounded,
  'camera': Icons.camera_alt_rounded,
  'mail': Icons.mail_rounded,
  'chat': Icons.chat_rounded,
  'lock': Icons.lock_rounded,
  'power': Icons.power_settings_new_rounded,
  'link': Icons.link_rounded,
  'file': Icons.description_rounded,
  'download': Icons.download_rounded,
  'upload': Icons.upload_rounded,
  'play': Icons.play_arrow_rounded,
  'brush': Icons.brush_rounded,
  'build': Icons.build_rounded,
  'database': Icons.storage_rounded,
  'cloud': Icons.cloud_rounded,
  'home': Icons.home_rounded,
  'calendar': Icons.calendar_today_rounded,
  'note': Icons.note_rounded,
  'calculate': Icons.calculate_rounded,
  'timer': Icons.timer_rounded,
  'rocket': Icons.rocket_launch_rounded,
  'shield': Icons.shield_rounded,
  'bug': Icons.bug_report_rounded,
  'monitor': Icons.desktop_windows_rounded,
  'grid': Icons.grid_view_rounded,
};

/// A curated colour palette, not a raw colour wheel — every button reads as
/// belonging to the same set instead of the user landing on an arbitrary hue.
const List<Color> kWorkspacePalette = [
  WeDropColors.brand,
  WeDropColors.accent,
  WeDropColors.success,
  WeDropColors.warn,
  WeDropColors.danger,
  Color(0xFF29B6D8),
  Color(0xFFFF8A5C),
  Color(0xFFB868E0),
];

const Map<String, String> _kActionLabels = {
  WorkspaceActionType.shortcut: 'Shortcut',
  WorkspaceActionType.openApp: 'Open app',
  WorkspaceActionType.openFolder: 'Open folder',
  WorkspaceActionType.openUrl: 'Open website',
  WorkspaceActionType.shellCommand: 'Shell command',
};

/// "My Workspace": a grid of the user's own custom action buttons for one
/// paired device — keyboard shortcuts, launching an app/folder/URL, or
/// running a shell command — freely reordered and persisted locally.
class WorkspaceTab extends StatefulWidget {
  final AppService service;
  final DeviceView device;

  const WorkspaceTab({super.key, required this.service, required this.device});

  @override
  State<WorkspaceTab> createState() => _WorkspaceTabState();
}

class _WorkspaceTabState extends State<WorkspaceTab> {
  late List<WorkspaceButton> _buttons;

  @override
  void initState() {
    super.initState();
    _buttons = widget.service.workspaceButtonsFor(widget.device.deviceId);
  }

  void _persist() => widget.service.saveWorkspaceButtons(widget.device.deviceId, _buttons);

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _buttons.removeAt(oldIndex);
      _buttons.insert(newIndex, item);
    });
    _persist();
  }

  Future<void> _openEditor({WorkspaceButton? existing}) async {
    final result = await showModalBottomSheet<_WorkspaceEditResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _WorkspaceEditSheet(
        existing: existing,
        automationAllowed: widget.service.settings.allowAutomation,
      ),
    );
    if (result == null || !mounted) return;

    setState(() {
      if (result.delete && existing != null) {
        _buttons.removeWhere((b) => b.id == existing.id);
      } else if (existing != null) {
        final idx = _buttons.indexWhere((b) => b.id == existing.id);
        if (idx != -1) _buttons[idx] = result.button!;
      } else if (result.button != null) {
        _buttons.add(result.button!);
      }
    });
    _persist();
  }

  void _run(WorkspaceButton button) {
    final p = button.actionParams;
    widget.service.sendWorkspaceAction(
      widget.device.deviceId,
      WorkspaceAction(
        action: button.actionType,
        modifiers: (p['modifiers'] as List?)?.cast<String>() ?? const [],
        key: p['key'] as String? ?? '',
        path: p['path'] as String? ?? '',
        url: p['url'] as String? ?? '',
        command: p['command'] as String? ?? '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.device.allowWorkspace) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: EmptyState(
            icon: Icons.dashboard_customize_rounded,
            title: 'Workspace actions are off for this device',
            hint: 'Turn on "Run workspace actions" in this device\'s permissions to use custom buttons.',
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(Space.lg),
      child: ReorderableGridView.count(
        crossAxisCount: 3,
        mainAxisSpacing: Space.md,
        crossAxisSpacing: Space.md,
        childAspectRatio: 0.9,
        onReorder: _onReorder,
        footer: [
          _AddButtonTile(key: const ValueKey('__workspace_add__'), onTap: _openEditor),
        ],
        children: [
          for (final button in _buttons)
            _WorkspaceButtonTile(
              key: ValueKey(button.id),
              button: button,
              onTap: () => _run(button),
              onLongPress: () => _openEditor(existing: button),
            ),
        ],
      ),
    );
  }
}

class _WorkspaceButtonTile extends StatelessWidget {
  final WorkspaceButton button;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _WorkspaceButtonTile({
    super.key,
    required this.button,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(button.colorValue);
    final icon = kWorkspaceIcons[button.icon] ?? Icons.bolt_rounded;

    return Material(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(Radii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.card),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          padding: const EdgeInsets.all(Space.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: Space.xs),
              Text(
                button.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: WeDropColors.ink, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddButtonTile extends StatelessWidget {
  final VoidCallback onTap;
  const _AddButtonTile({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.card),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: WeDropColors.border),
          ),
          child: const Center(
            child: Icon(Icons.add_rounded, color: WeDropColors.inkFaint, size: 28),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceEditResult {
  final WorkspaceButton? button;
  final bool delete;
  const _WorkspaceEditResult({this.button, this.delete = false});
}

class _WorkspaceEditSheet extends StatefulWidget {
  final WorkspaceButton? existing;
  final bool automationAllowed;

  const _WorkspaceEditSheet({this.existing, required this.automationAllowed});

  @override
  State<_WorkspaceEditSheet> createState() => _WorkspaceEditSheetState();
}

class _WorkspaceEditSheetState extends State<_WorkspaceEditSheet> {
  late final TextEditingController _label;
  late final TextEditingController _key;
  late final TextEditingController _target; // path / url / command, depending on action type
  late String _icon;
  late int _color;
  late String _actionType;
  final Set<String> _modifiers = {};

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final params = existing?.actionParams ?? const {};

    _label = TextEditingController(text: existing?.label ?? '');
    _icon = existing?.icon ?? kWorkspaceIcons.keys.first;
    _color = existing?.colorValue ?? kWorkspacePalette.first.toARGB32();
    _actionType = existing?.actionType ?? WorkspaceActionType.shortcut;
    _modifiers.addAll((params['modifiers'] as List?)?.cast<String>() ?? const []);
    _key = TextEditingController(text: params['key'] as String? ?? '');
    _target = TextEditingController(
      text: (params['path'] ?? params['url'] ?? params['command']) as String? ?? '',
    );
  }

  @override
  void dispose() {
    _label.dispose();
    _key.dispose();
    _target.dispose();
    super.dispose();
  }

  bool get _canSave {
    if (_label.text.trim().isEmpty) return false;
    switch (_actionType) {
      case WorkspaceActionType.shortcut:
        return _key.text.trim().isNotEmpty;
      case WorkspaceActionType.shellCommand:
        return widget.automationAllowed && _target.text.trim().isNotEmpty;
      default:
        return _target.text.trim().isNotEmpty;
    }
  }

  Map<String, dynamic> get _actionParams {
    switch (_actionType) {
      case WorkspaceActionType.shortcut:
        return {'modifiers': _modifiers.toList(), 'key': _key.text.trim()};
      case WorkspaceActionType.openApp:
      case WorkspaceActionType.openFolder:
        return {'path': _target.text.trim()};
      case WorkspaceActionType.openUrl:
        return {'url': _target.text.trim()};
      case WorkspaceActionType.shellCommand:
        return {'command': _target.text.trim()};
    }
    return const {};
  }

  void _save() {
    final button = WorkspaceButton(
      id: widget.existing?.id ?? const Uuid().v4(),
      label: _label.text.trim(),
      icon: _icon,
      colorValue: _color,
      actionType: _actionType,
      actionParams: _actionParams,
      order: widget.existing?.order ?? 0,
    );
    Navigator.of(context).pop(_WorkspaceEditResult(button: button));
  }

  void _delete() => Navigator.of(context).pop(const _WorkspaceEditResult(delete: true));

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Space.lg,
        Space.lg,
        Space.lg,
        MediaQuery.of(context).viewInsets.bottom + Space.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.existing == null ? 'New button' : 'Edit button',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: WeDropColors.ink),
            ),
            const SizedBox(height: Space.lg),
            TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Label'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.lg),
            const CardLabel('Icon'),
            _iconPicker(),
            const SizedBox(height: Space.lg),
            const CardLabel('Colour'),
            _colorPicker(),
            const SizedBox(height: Space.lg),
            const CardLabel('Action'),
            _actionTypePicker(),
            const SizedBox(height: Space.md),
            _actionFields(),
            const SizedBox(height: Space.xl),
            Row(
              children: [
                if (widget.existing != null) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _delete,
                      style: OutlinedButton.styleFrom(foregroundColor: WeDropColors.danger),
                      child: const Text('Delete'),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                ],
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _canSave ? _save : null,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconPicker() {
    return Wrap(
      spacing: Space.sm,
      runSpacing: Space.sm,
      children: kWorkspaceIcons.entries.map((entry) {
        final selected = entry.key == _icon;
        return InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: () => setState(() => _icon = entry.key),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: selected ? WeDropColors.brand.withValues(alpha: 0.2) : WeDropColors.surfaceHi,
              borderRadius: BorderRadius.circular(Radii.control),
              border: selected ? Border.all(color: WeDropColors.brand) : null,
            ),
            child: Icon(entry.value, size: 20, color: selected ? WeDropColors.brandSoft : WeDropColors.inkDim),
          ),
        );
      }).toList(),
    );
  }

  Widget _colorPicker() {
    return Wrap(
      spacing: Space.sm,
      children: kWorkspacePalette.map((c) {
        final value = c.toARGB32();
        final selected = value == _color;
        return InkWell(
          borderRadius: BorderRadius.circular(Radii.pill),
          onTap: () => setState(() => _color = value),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: selected ? Border.all(color: WeDropColors.ink, width: 2) : null,
            ),
            child: selected ? const Icon(Icons.check_rounded, color: Colors.white, size: 18) : null,
          ),
        );
      }).toList(),
    );
  }

  Widget _actionTypePicker() {
    return Wrap(
      spacing: Space.sm,
      runSpacing: Space.sm,
      children: _kActionLabels.entries.map((entry) {
        return ChoiceChip(
          label: Text(entry.value),
          selected: entry.key == _actionType,
          onSelected: (_) => setState(() => _actionType = entry.key),
        );
      }).toList(),
    );
  }

  Widget _actionFields() {
    switch (_actionType) {
      case WorkspaceActionType.shortcut:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: Space.sm,
              children: [Modifier.ctrl, Modifier.shift, Modifier.alt].map((m) {
                final selected = _modifiers.contains(m);
                return FilterChip(
                  label: Text(m[0].toUpperCase() + m.substring(1)),
                  selected: selected,
                  onSelected: (v) => setState(() => v ? _modifiers.add(m) : _modifiers.remove(m)),
                );
              }).toList(),
            ),
            const SizedBox(height: Space.sm),
            TextField(
              controller: _key,
              decoration: const InputDecoration(labelText: 'Key (e.g. P, Enter, Tab)'),
              onChanged: (_) => setState(() {}),
            ),
          ],
        );
      case WorkspaceActionType.openApp:
        return TextField(
          controller: _target,
          decoration: const InputDecoration(labelText: 'Application path'),
          onChanged: (_) => setState(() {}),
        );
      case WorkspaceActionType.openFolder:
        return TextField(
          controller: _target,
          decoration: const InputDecoration(labelText: 'Folder path'),
          onChanged: (_) => setState(() {}),
        );
      case WorkspaceActionType.openUrl:
        return TextField(
          controller: _target,
          decoration: const InputDecoration(labelText: 'Website URL'),
          keyboardType: TextInputType.url,
          onChanged: (_) => setState(() {}),
        );
      case WorkspaceActionType.shellCommand:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.automationAllowed)
              Container(
                padding: const EdgeInsets.all(Space.md),
                margin: const EdgeInsets.only(bottom: Space.sm),
                decoration: BoxDecoration(
                  color: WeDropColors.danger.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(Radii.control),
                ),
                child: const Text(
                  'Shell commands are off. Turn on "Allow shell/script commands" in Settings to use this.',
                  style: TextStyle(fontSize: 12, color: WeDropColors.danger),
                ),
              ),
            TextField(
              controller: _target,
              enabled: widget.automationAllowed,
              decoration: const InputDecoration(labelText: 'Command'),
              onChanged: (_) => setState(() {}),
            ),
          ],
        );
    }
    return const SizedBox.shrink();
  }
}
