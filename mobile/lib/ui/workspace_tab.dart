import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  // Added for the built-in dynamic-controls profiles (VS Code, Chrome) —
  // purely additive, existing buttons are unaffected.
  'undo': Icons.undo_rounded,
  'redo': Icons.redo_rounded,
  'git': Icons.account_tree_rounded,
  'run': Icons.play_circle_fill_rounded,
  'debug': Icons.bug_report_rounded,
  'back': Icons.arrow_back_rounded,
  'forward': Icons.arrow_forward_rounded,
  // Added for the generic (every-app) fallback profile.
  'copy': Icons.content_copy_rounded,
  'paste': Icons.content_paste_rounded,
  'cut': Icons.content_cut_rounded,
  'selectall': Icons.select_all_rounded,
  'close': Icons.close_rounded,
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

/// "Workspace": a per-device, per-layout arrangement of widgets — the
/// desktop-switcher, dynamic controls, minimized apps, and the user's own
/// "My Workspace" buttons — each addable/removable/resizable, with multiple
/// named layouts (e.g. "Programming", "Video editing") to switch between.
class WorkspaceTab extends StatefulWidget {
  final AppService service;
  final DeviceView device;

  const WorkspaceTab({super.key, required this.service, required this.device});

  @override
  State<WorkspaceTab> createState() => _WorkspaceTabState();
}

class _WorkspaceTabState extends State<WorkspaceTab> {
  late List<WorkspaceButton> _buttons;
  late List<WorkspaceLayout> _layouts;
  late WorkspaceLayout _layout;

  String get _deviceId => widget.device.deviceId;

  @override
  void initState() {
    super.initState();
    _buttons = widget.service.workspaceButtonsFor(_deviceId);
    _layouts = widget.service.workspaceLayoutsFor(_deviceId);
    _layout = widget.service.activeWorkspaceLayoutFor(_deviceId);
  }

  void _persistButtons() => widget.service.saveWorkspaceButtons(_deviceId, _buttons);
  void _persistLayouts() => widget.service.saveWorkspaceLayouts(_deviceId, _layouts);

  // ── My-buttons grid (unchanged behaviour, now just one widget among many) ──

  void _onReorderButtons(int oldIndex, int newIndex) {
    setState(() {
      final item = _buttons.removeAt(oldIndex);
      _buttons.insert(newIndex, item);
    });
    _persistButtons();
  }

  Future<void> _openButtonEditor({WorkspaceButton? existing}) async {
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
    _persistButtons();
  }

  void _runButton(WorkspaceButton button) {
    final p = button.actionParams;
    widget.service.sendWorkspaceAction(
      _deviceId,
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

  // ── Widget management (add/remove/resize/reorder within the layout) ──

  void _resizeWidget(WidgetInstance instance) {
    setState(() {
      instance.size = instance.size == WidgetSize.compact ? WidgetSize.full : WidgetSize.compact;
    });
    _persistLayouts();
  }

  void _removeWidget(WidgetInstance instance) {
    setState(() => _layout.widgets.removeWhere((w) => w.id == instance.id));
    _persistLayouts();
  }

  void _moveWidget(WidgetInstance instance, int delta) {
    setState(() {
      final list = _layout.widgets..sort((a, b) => a.order.compareTo(b.order));
      final idx = list.indexWhere((w) => w.id == instance.id);
      final newIdx = (idx + delta).clamp(0, list.length - 1);
      if (newIdx == idx) return;
      list.insert(newIdx, list.removeAt(idx));
      for (var i = 0; i < list.length; i++) {
        list[i].order = i;
      }
    });
    _persistLayouts();
  }

  Future<void> _openWidgetStore() async {
    final existingTypes = _layout.widgets.map((w) => w.type).toSet();
    final available = WidgetType.all.where((t) => !existingTypes.contains(t)).toList();

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.sm),
              child: Text('Add a widget', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: WeDropColors.ink)),
            ),
            if (available.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
                child: Text('Every widget is already on this layout.', style: TextStyle(color: WeDropColors.inkFaint)),
              ),
            for (final type in available)
              ListTile(
                leading: Icon(kWorkspaceIcons[WidgetType.icons[type]] ?? Icons.widgets_rounded, color: WeDropColors.brandSoft),
                title: Text(WidgetType.labels[type] ?? type, style: const TextStyle(color: WeDropColors.ink)),
                onTap: () => Navigator.pop(context, type),
              ),
            const SizedBox(height: Space.md),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;

    setState(() {
      _layout.widgets.add(WidgetInstance(id: const Uuid().v4(), type: chosen, order: _layout.widgets.length));
    });
    _persistLayouts();
  }

  // ── Layouts ──

  Future<void> _switchLayout(String layoutId) async {
    setState(() => _layout = _layouts.firstWhere((l) => l.id == layoutId, orElse: () => _layouts.first));
    await widget.service.setActiveWorkspaceLayout(_deviceId, _layout.id);
  }

  Future<void> _createLayout() async {
    final name = await _promptForName(title: 'New layout', hint: 'e.g. Video editing');
    if (name == null || name.isEmpty || !mounted) return;

    final layout = WorkspaceLayout(id: const Uuid().v4(), name: name, widgets: []);
    setState(() {
      _layouts.add(layout);
      _layout = layout;
    });
    _persistLayouts();
    await widget.service.setActiveWorkspaceLayout(_deviceId, layout.id);
  }

  void _renameLayout(String layoutId, String name) {
    // The sheet already mutated the shared WorkspaceLayout object in place;
    // just persist and refresh anything (e.g. the top bar) showing its name.
    _persistLayouts();
    if (mounted) setState(() {});
  }

  Future<void> _deleteLayout(String layoutId) async {
    if (_layouts.length <= 1) return;
    final wasActive = _layout.id == layoutId;
    setState(() {
      _layouts.removeWhere((l) => l.id == layoutId);
      if (wasActive) _layout = _layouts.first;
    });
    _persistLayouts();
    if (wasActive) {
      await widget.service.setActiveWorkspaceLayout(_deviceId, _layout.id);
    }
  }

  Future<void> _openLayoutPicker() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _LayoutPickerSheet(
        layouts: _layouts,
        activeId: _layout.id,
        onSelect: (id) {
          Navigator.pop(sheetContext);
          _switchLayout(id);
        },
        onCreate: () {
          Navigator.pop(sheetContext);
          _createLayout();
        },
        onRename: _renameLayout,
        onDelete: (id) {
          Navigator.pop(sheetContext);
          _deleteLayout(id);
        },
      ),
    );
  }

  Future<String?> _promptForName({required String title, String hint = ''}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: 'Name', hintText: hint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
  }

  // ── Full screen ──

  Future<void> _openFullScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _WorkspaceFullScreen(
          service: widget.service,
          device: widget.device,
          layout: _layout,
          buttons: _buttons,
          onReorderButtons: (oldIndex, newIndex) => setState(() => _onReorderButtons(oldIndex, newIndex)),
          onRunButton: _runButton,
          onEditButton: (b) => _openButtonEditor(existing: b),
          onAddButton: () => _openButtonEditor(),
        ),
      ),
    );
    // Buttons/layout mutations inside full screen happen on the same shared
    // objects; refresh the tab once we're back to reflect them.
    if (mounted) setState(() {});
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

    return _WorkspaceBody(
      service: widget.service,
      device: widget.device,
      layout: _layout,
      buttons: _buttons,
      onReorderButtons: _onReorderButtons,
      onRunButton: _runButton,
      onEditButton: (b) => _openButtonEditor(existing: b),
      onAddButton: _openButtonEditor,
      onResizeWidget: _resizeWidget,
      onRemoveWidget: _removeWidget,
      onMoveWidget: _moveWidget,
      showWidgetMenus: true,
      layoutName: _layout.name,
      onOpenLayoutPicker: _openLayoutPicker,
      onOpenWidgetStore: _openWidgetStore,
      topAction: IconButton(
        tooltip: 'Full screen',
        onPressed: _openFullScreen,
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.open_in_full_rounded, size: 19, color: WeDropColors.inkDim),
      ),
    );
  }
}

/// The full body of the Workspace tab: a top bar (current layout name + add-
/// widget + full-screen/exit), then every widget in the active layout in
/// order, then the "My buttons" section filling remaining space.
class _WorkspaceBody extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  final WorkspaceLayout layout;
  final List<WorkspaceButton> buttons;
  final void Function(int, int) onReorderButtons;
  final void Function(WorkspaceButton) onRunButton;
  final Future<void> Function(WorkspaceButton) onEditButton;
  final Future<void> Function() onAddButton;
  final void Function(WidgetInstance) onResizeWidget;
  final void Function(WidgetInstance) onRemoveWidget;
  final void Function(WidgetInstance, int) onMoveWidget;
  final bool showWidgetMenus;
  final String layoutName;
  final VoidCallback? onOpenLayoutPicker;
  final VoidCallback? onOpenWidgetStore;
  final Widget topAction;

  const _WorkspaceBody({
    required this.service,
    required this.device,
    required this.layout,
    required this.buttons,
    required this.onReorderButtons,
    required this.onRunButton,
    required this.onEditButton,
    required this.onAddButton,
    required this.onResizeWidget,
    required this.onRemoveWidget,
    required this.onMoveWidget,
    required this.showWidgetMenus,
    required this.layoutName,
    required this.onOpenLayoutPicker,
    required this.onOpenWidgetStore,
    required this.topAction,
  });

  WidgetInstance? _find(String type) {
    for (final w in layout.widgets) {
      if (w.type == type) return w;
    }
    return null;
  }

  Widget? _menuFor(WidgetInstance instance, {bool canResize = true}) {
    if (!showWidgetMenus) return null;
    return _WidgetMenu(
      canResize: canResize,
      isCompact: instance.size == WidgetSize.compact,
      onResize: () => onResizeWidget(instance),
      onRemove: () => onRemoveWidget(instance),
      onMoveUp: () => onMoveWidget(instance, -1),
      onMoveDown: () => onMoveWidget(instance, 1),
    );
  }

  Widget _renderOther(WidgetInstance instance) {
    switch (instance.type) {
      case WidgetType.desktopSwitcher:
        return _DesktopSwitcherCard(service: service, device: device, menu: _menuFor(instance));
      case WidgetType.adaptiveControls:
        return _DynamicControlsCard(
          service: service,
          device: device,
          state: service.adaptiveControlsOf(device.deviceId),
          menu: _menuFor(instance),
        );
      case WidgetType.minimizedApps:
        return _MinimizedAppsCard(
          service: service,
          device: device,
          state: service.minimizedAppsOf(device.deviceId),
          menu: _menuFor(instance),
        );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...layout.widgets]..sort((a, b) => a.order.compareTo(b.order));
    final others = sorted.where((w) => w.type != WidgetType.buttons).toList();
    final buttonsInstance = _find(WidgetType.buttons);

    final rows = <Widget>[];
    var i = 0;
    while (i < others.length) {
      final a = others[i];
      final pairWithNext =
          a.size == WidgetSize.compact && i + 1 < others.length && others[i + 1].size == WidgetSize.compact;
      if (pairWithNext) {
        final b = others[i + 1];
        rows.add(Padding(
          padding: const EdgeInsets.only(bottom: Space.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _renderOther(a)),
              const SizedBox(width: Space.sm),
              Expanded(child: _renderOther(b)),
            ],
          ),
        ));
        i += 2;
      } else {
        rows.add(Padding(padding: const EdgeInsets.only(bottom: Space.sm), child: _renderOther(a)));
        i += 1;
      }
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.sm, 0),
          child: Row(
            children: [
              Expanded(
                child: onOpenLayoutPicker == null
                    ? Text(layoutName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: WeDropColors.ink))
                    : InkWell(
                        borderRadius: BorderRadius.circular(Radii.control),
                        onTap: onOpenLayoutPicker,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(layoutName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 15, fontWeight: FontWeight.w600, color: WeDropColors.ink)),
                              ),
                              const Icon(Icons.expand_more_rounded, size: 18, color: WeDropColors.inkDim),
                            ],
                          ),
                        ),
                      ),
              ),
              if (onOpenWidgetStore != null)
                IconButton(
                  tooltip: 'Add widget',
                  onPressed: onOpenWidgetStore,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add_box_rounded, size: 19, color: WeDropColors.inkDim),
                ),
              topAction,
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...rows,
                if (buttonsInstance != null)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: CardLabel(
                                buttons.isEmpty ? 'My buttons' : 'My buttons · ${buttons.length}',
                              ),
                            ),
                            ?_menuFor(buttonsInstance, canResize: false),
                          ],
                        ),
                        Expanded(
                          child: _WorkspaceGrid(
                            buttons: buttons,
                            onReorder: onReorderButtons,
                            onRun: onRunButton,
                            onEdit: onEditButton,
                            onAdd: onAddButton,
                          ),
                        ),
                      ],
                    ),
                  )
                else if (onOpenWidgetStore != null)
                  Expanded(
                    child: Center(
                      child: TextButton.icon(
                        onPressed: onOpenWidgetStore,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add a widget'),
                      ),
                    ),
                  )
                else
                  const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The "..." menu on every widget card: resize (full/compact), reorder
/// (move up/down within the layout), and remove from the layout.
class _WidgetMenu extends StatelessWidget {
  final bool canResize;
  final bool isCompact;
  final VoidCallback onResize;
  final VoidCallback onRemove;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  const _WidgetMenu({
    required this.canResize,
    required this.isCompact,
    required this.onResize,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert_rounded, size: 18, color: WeDropColors.inkFaint),
      onSelected: (value) {
        switch (value) {
          case 'resize':
            onResize();
          case 'up':
            onMoveUp();
          case 'down':
            onMoveDown();
          case 'remove':
            onRemove();
        }
      },
      itemBuilder: (context) => [
        if (canResize)
          PopupMenuItem(value: 'resize', child: Text(isCompact ? 'Make full width' : 'Make compact')),
        const PopupMenuItem(value: 'up', child: Text('Move up')),
        const PopupMenuItem(value: 'down', child: Text('Move down')),
        const PopupMenuItem(value: 'remove', child: Text('Remove widget')),
      ],
    );
  }
}

/// Picks, renames, deletes, or creates a named layout for this device.
class _LayoutPickerSheet extends StatefulWidget {
  final List<WorkspaceLayout> layouts;
  final String activeId;
  final void Function(String layoutId) onSelect;
  final VoidCallback onCreate;
  final void Function(String layoutId, String newName) onRename;
  final void Function(String layoutId) onDelete;

  const _LayoutPickerSheet({
    required this.layouts,
    required this.activeId,
    required this.onSelect,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
  });

  @override
  State<_LayoutPickerSheet> createState() => _LayoutPickerSheetState();
}

class _LayoutPickerSheetState extends State<_LayoutPickerSheet> {
  Future<void> _rename(WorkspaceLayout layout) async {
    final controller = TextEditingController(text: layout.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename layout'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => layout.name = name);
    widget.onRename(layout.id, name);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.sm),
              child: Text('Layouts', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: WeDropColors.ink)),
            ),
            for (final layout in widget.layouts)
              ListTile(
                leading: Icon(
                  layout.id == widget.activeId ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: layout.id == widget.activeId ? WeDropColors.brand : WeDropColors.inkFaint,
                ),
                title: Text(layout.name, style: const TextStyle(color: WeDropColors.ink)),
                subtitle: Text('${layout.widgets.length} widget${layout.widgets.length == 1 ? '' : 's'}',
                    style: const TextStyle(color: WeDropColors.inkFaint, fontSize: 12)),
                onTap: () => widget.onSelect(layout.id),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Rename',
                      icon: const Icon(Icons.edit_rounded, size: 18, color: WeDropColors.inkFaint),
                      onPressed: () => _rename(layout),
                    ),
                    if (widget.layouts.length > 1)
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline_rounded, size: 18, color: WeDropColors.danger),
                        onPressed: () => widget.onDelete(layout.id),
                      ),
                  ],
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded, color: WeDropColors.brandSoft),
              title: const Text('New layout', style: TextStyle(color: WeDropColors.ink)),
              onTap: widget.onCreate,
            ),
            const SizedBox(height: Space.md),
          ],
        ),
      ),
    );
  }
}

/// Target width (dp) of one button tile including its share of the grid
/// gutter — the responsive grid divides available width by this to pick a
/// column count, so the tab reflows sensibly on rotation or on a tablet
/// instead of a fixed 3 columns.
const double _kTileTargetWidth = 78;

/// The reorderable button grid, factored out so both the normal Workspace
/// tab and the full-screen route render identically.
class _WorkspaceGrid extends StatelessWidget {
  final List<WorkspaceButton> buttons;
  final void Function(int, int) onReorder;
  final void Function(WorkspaceButton) onRun;
  final Future<void> Function(WorkspaceButton) onEdit;
  final Future<void> Function() onAdd;

  const _WorkspaceGrid({
    required this.buttons,
    required this.onReorder,
    required this.onRun,
    required this.onEdit,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / _kTileTargetWidth).floor().clamp(4, 10);
        return ReorderableGridView.count(
          crossAxisCount: columns,
          mainAxisSpacing: Space.xs,
          crossAxisSpacing: Space.xs,
          childAspectRatio: 0.92,
          onReorder: onReorder,
          footer: [
            _AddButtonTile(key: const ValueKey('__workspace_add__'), onTap: onAdd),
          ],
          children: [
            for (final button in buttons)
              _WorkspaceButtonTile(
                key: ValueKey(button.id),
                button: button,
                onTap: () => onRun(button),
                onLongPress: () => onEdit(button),
              ),
          ],
        );
      },
    );
  }
}

/// A dedicated full-screen route rendering the entire active layout with no
/// app bar, no other tabs, and the OS status/nav bars hidden — for propping
/// the phone up next to a keyboard and using it as a standalone control
/// surface. Layout switching and adding new widgets stay in the normal tab
/// (setup tasks); full screen is a "run mode" — tap, resize, remove, and My
/// buttons' own add/edit/reorder remain available, but no widget menus.
class _WorkspaceFullScreen extends StatefulWidget {
  final AppService service;
  final DeviceView device;
  final WorkspaceLayout layout;
  final List<WorkspaceButton> buttons;
  final void Function(int, int) onReorderButtons;
  final void Function(WorkspaceButton) onRunButton;
  final Future<void> Function(WorkspaceButton) onEditButton;
  final Future<void> Function() onAddButton;

  const _WorkspaceFullScreen({
    required this.service,
    required this.device,
    required this.layout,
    required this.buttons,
    required this.onReorderButtons,
    required this.onRunButton,
    required this.onEditButton,
    required this.onAddButton,
  });

  @override
  State<_WorkspaceFullScreen> createState() => _WorkspaceFullScreenState();
}

class _WorkspaceFullScreenState extends State<_WorkspaceFullScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Explicitly allow both orientations while this surface is up, regardless
    // of whatever the rest of the app currently prefers — this is meant to be
    // propped up next to a keyboard in either orientation.
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  Future<void> _edit(WorkspaceButton b) async {
    await widget.onEditButton(b);
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    await widget.onAddButton();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: WeDropColors.bg,
        body: SafeArea(
          child: _WorkspaceBody(
            service: widget.service,
            device: widget.device,
            layout: widget.layout,
            buttons: widget.buttons,
            onReorderButtons: (oldIndex, newIndex) => setState(() => widget.onReorderButtons(oldIndex, newIndex)),
            onRunButton: widget.onRunButton,
            onEditButton: _edit,
            onAddButton: _add,
            onResizeWidget: (_) {},
            onRemoveWidget: (_) {},
            onMoveWidget: (_, _) {},
            showWidgetMenus: false,
            layoutName: widget.layout.name,
            onOpenLayoutPicker: null,
            onOpenWidgetStore: null,
            topAction: IconButton(
              tooltip: 'Exit full screen',
              onPressed: () => Navigator.of(context).pop(),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_fullscreen_rounded, size: 19, color: WeDropColors.inkDim),
            ),
          ),
        ),
      ),
    );
  }
}

/// Moves the peer between virtual desktops using Windows' own native
/// Ctrl+Win+Left/Right shortcut — deliberately not built on the undocumented
/// virtual-desktop COM interfaces (their GUIDs change across Windows
/// versions), so this works everywhere with no per-version breakage. A first,
/// non-customizable slice: no desktop count/names/thumbnails yet, just move
/// left/right.
class _DesktopSwitcherCard extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  final Widget? menu;

  const _DesktopSwitcherCard({required this.service, required this.device, required this.menu});

  void _switch(bool forward) {
    service.sendWorkspaceAction(
      device.deviceId,
      WorkspaceAction(
        action: WorkspaceActionType.shortcut,
        modifiers: const [Modifier.ctrl, Modifier.meta],
        key: forward ? SpecialKey.right : SpecialKey.left,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WdCard(
      child: Row(
        children: [
          const Icon(Icons.desktop_windows_rounded, size: 18, color: WeDropColors.accent),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Switch desktop',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: WeDropColors.inkDim)),
          ),
          _SwitcherButton(icon: Icons.chevron_left_rounded, onTap: () => _switch(false)),
          const SizedBox(width: 8),
          _SwitcherButton(icon: Icons.chevron_right_rounded, onTap: () => _switch(true)),
          ?menu,
        ],
      ),
    );
  }
}

class _SwitcherButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _SwitcherButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WeDropColors.surfaceHi,
      borderRadius: BorderRadius.circular(Radii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: onTap,
        child: SizedBox(width: 36, height: 32, child: Icon(icon, size: 20, color: WeDropColors.inkDim)),
      ),
    );
  }
}

/// What the peer's currently focused desktop app makes available. Shows a
/// placeholder when nothing is currently recognized rather than vanishing —
/// this is now a persistent, user-addable widget, so hiding it entirely would
/// make its own remove/resize controls hard to find.
class _DynamicControlsCard extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  final AdaptiveControlsState? state;
  final Widget? menu;

  const _DynamicControlsCard({required this.service, required this.device, required this.state, required this.menu});

  @override
  Widget build(BuildContext context) {
    final controls = state?.controls ?? const [];
    final appName = state?.appName ?? '';

    return WdCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_rounded, size: 18, color: WeDropColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  controls.isEmpty ? 'Dynamic controls' : 'Now on desktop: $appName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: WeDropColors.inkDim),
                ),
              ),
              ?menu,
            ],
          ),
          const SizedBox(height: 10),
          if (controls.isEmpty)
            const Text('No recognized app is focused right now', style: TextStyle(fontSize: 12, color: WeDropColors.inkFaint))
          else
            LayoutBuilder(
              builder: (context, constraints) {
                const target = 76.0;
                const spacing = 10.0;
                final columns = ((constraints.maxWidth + spacing) / (target + spacing)).floor().clamp(1, controls.length);
                final tileWidth = (constraints.maxWidth - spacing * (columns - 1)) / columns;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final control in controls)
                      SizedBox(
                        width: tileWidth,
                        child: WdActionTile(
                          icon: kWorkspaceIcons[control.icon] ?? Icons.bolt_rounded,
                          label: control.label,
                          onTap: () => service.sendWorkspaceAction(device.deviceId, control.action),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

/// The peer's currently-minimized windows — tap one to restore and focus it.
/// Deliberately scoped to "currently minimized", not "every open window on
/// the selected virtual desktop" — see MinimizedAppsState's own doc comment
/// for why (the same undocumented-API tradeoff the desktop switcher makes).
class _MinimizedAppsCard extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  final MinimizedAppsState? state;
  final Widget? menu;

  const _MinimizedAppsCard({required this.service, required this.device, required this.state, required this.menu});

  @override
  Widget build(BuildContext context) {
    final windows = state?.windows ?? const <MinimizedWindow>[];

    return WdCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.web_asset_off_rounded, size: 18, color: WeDropColors.accent),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Minimized apps',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: WeDropColors.inkDim)),
              ),
              ?menu,
            ],
          ),
          const SizedBox(height: 10),
          if (windows.isEmpty)
            const Text('Nothing minimized right now', style: TextStyle(fontSize: 12, color: WeDropColors.inkFaint))
          else
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: windows.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final w = windows[i];
                  return _MinimizedChip(window: w, onTap: () => service.restoreWindow(device.deviceId, w.id));
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _MinimizedChip extends StatelessWidget {
  final MinimizedWindow window;
  final VoidCallback onTap;
  const _MinimizedChip({required this.window, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WeDropColors.surfaceHi,
      borderRadius: BorderRadius.circular(Radii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: onTap,
        child: Container(
          width: 92,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.crop_din_rounded, size: 18, color: WeDropColors.inkDim),
              const SizedBox(height: 4),
              Text(
                window.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: WeDropColors.ink),
              ),
            ],
          ),
        ),
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
      borderRadius: BorderRadius.circular(Radii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 17),
              const SizedBox(height: 2),
              Text(
                button.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: WeDropColors.ink,
                  fontWeight: FontWeight.w600,
                  fontSize: 9.5,
                ),
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
      borderRadius: BorderRadius.circular(Radii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(color: WeDropColors.border),
          ),
          child: const Center(
            child: Icon(Icons.add_rounded, color: WeDropColors.inkFaint, size: 20),
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
      spacing: Space.xs,
      runSpacing: Space.xs,
      children: kWorkspaceIcons.entries.map((entry) {
        final selected = entry.key == _icon;
        return InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: () => setState(() => _icon = entry.key),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: selected ? WeDropColors.brand.withValues(alpha: 0.2) : WeDropColors.surfaceHi,
              borderRadius: BorderRadius.circular(Radii.control),
              border: selected ? Border.all(color: WeDropColors.brand) : null,
            ),
            child: Icon(entry.value, size: 16, color: selected ? WeDropColors.brandSoft : WeDropColors.inkDim),
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
