import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// "Widgets": a per-device, per-layout arrangement of widgets — the
/// desktop-switcher, dynamic controls, minimized apps, and the user's own
/// "My Workspace" buttons — each addable/removable/resizable, with multiple
/// named layouts (e.g. "Programming", "Video editing") to switch between.
/// This tab is the customize surface; the buttons and per-app controls
/// themselves are authored entirely on the desktop (see the App Actions and
/// My Buttons editors there) — the phone only arranges and runs them.
class WorkspaceTab extends StatefulWidget {
  final AppService service;
  final DeviceView device;

  const WorkspaceTab({super.key, required this.service, required this.device});

  @override
  State<WorkspaceTab> createState() => _WorkspaceTabState();
}

class _WorkspaceTabState extends State<WorkspaceTab> {
  late List<WorkspaceLayout> _layouts;
  late WorkspaceLayout _layout;

  String get _deviceId => widget.device.deviceId;

  @override
  void initState() {
    super.initState();
    _layouts = widget.service.workspaceLayoutsFor(_deviceId);
    _layout = widget.service.activeWorkspaceLayoutFor(_deviceId);
  }

  void _persistLayouts() => widget.service.saveWorkspaceLayouts(_deviceId, _layouts);

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
          layouts: _layouts,
          initialLayoutId: _layout.id,
          onLayoutChanged: _switchLayout,
        ),
      ),
    );
    // Switching layouts inside full screen mutates the same shared _layouts
    // list; refresh the tab once we're back to reflect it.
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

/// Opens a stripped-down, full-screen "run mode" for this device's active
/// layout — used by the Overview tab's Workspace preview card. The only
/// customization available here is picking a different saved layout; adding,
/// resizing, or removing widgets (and editing button/app-action content)
/// stays in the Widgets tab and the desktop app respectively.
Future<void> openWorkspaceFullScreen(BuildContext context, AppService service, DeviceView device) {
  final layouts = service.workspaceLayoutsFor(device.deviceId);
  final activeId = service.activeWorkspaceLayoutFor(device.deviceId).id;
  return Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _WorkspaceFullScreen(
        service: service,
        device: device,
        layouts: layouts,
        initialLayoutId: activeId,
        onLayoutChanged: (id) => service.setActiveWorkspaceLayout(device.deviceId, id),
      ),
    ),
  );
}

/// The full body of the Workspace/Widgets tab: a top bar (current layout
/// name + add-widget + full-screen/exit), then every widget in the active
/// layout in order, then the "My buttons" section filling remaining space.
/// Buttons and per-app dynamic controls are read live from [service] — both
/// are desktop-authoritative, so there is nothing to cache locally.
class _WorkspaceBody extends StatelessWidget {
  final AppService service;
  final DeviceView device;
  final WorkspaceLayout layout;
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

  void _runButton(WorkspaceButtonDef button) => service.sendWorkspaceAction(device.deviceId, button.action);

  Future<void> _openWidgetEditor(BuildContext context, WidgetInstance instance, {bool canResize = true}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _WidgetEditorSheet(
        title: WidgetType.labels[instance.type] ?? instance.type,
        canResize: canResize,
        isCompact: instance.size == WidgetSize.compact,
        onResize: () => onResizeWidget(instance),
        onRemove: () => onRemoveWidget(instance),
        onMoveUp: () => onMoveWidget(instance, -1),
        onMoveDown: () => onMoveWidget(instance, 1),
        buttonsPreview: instance.type == WidgetType.buttons ? service.workspaceButtonsOf(device.deviceId) : null,
        onConfigureButtons:
            instance.type == WidgetType.buttons ? () => service.requestConfigureButtons(device.deviceId) : null,
      ),
    );
  }

  Widget? _menuFor(BuildContext context, WidgetInstance instance, {bool canResize = true}) {
    if (!showWidgetMenus) return null;
    return IconButton(
      tooltip: 'Edit widget',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.tune_rounded, size: 18, color: WeDropColors.inkFaint),
      onPressed: () => _openWidgetEditor(context, instance, canResize: canResize),
    );
  }

  Widget _renderOther(BuildContext context, WidgetInstance instance) {
    switch (instance.type) {
      case WidgetType.desktopSwitcher:
        return _DesktopSwitcherCard(service: service, device: device, menu: _menuFor(context, instance));
      case WidgetType.adaptiveControls:
        return _DynamicControlsCard(
          service: service,
          device: device,
          state: service.adaptiveControlsOf(device.deviceId),
          menu: _menuFor(context, instance),
        );
      case WidgetType.minimizedApps:
        return _MinimizedAppsCard(
          service: service,
          device: device,
          state: service.minimizedAppsOf(device.deviceId),
          menu: _menuFor(context, instance),
        );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...layout.widgets]..sort((a, b) => a.order.compareTo(b.order));
    final others = sorted.where((w) => w.type != WidgetType.buttons).toList();
    final buttonsInstance = _find(WidgetType.buttons);
    final buttons = service.workspaceButtonsOf(device.deviceId);

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
              Expanded(child: _renderOther(context, a)),
              const SizedBox(width: Space.sm),
              Expanded(child: _renderOther(context, b)),
            ],
          ),
        ));
        i += 2;
      } else {
        rows.add(Padding(padding: const EdgeInsets.only(bottom: Space.sm), child: _renderOther(context, a)));
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
                            ?_menuFor(context, buttonsInstance, canResize: false),
                          ],
                        ),
                        Expanded(
                          child: _WorkspaceGrid(
                            buttons: buttons,
                            onRun: _runButton,
                            onConfigure: () => service.requestConfigureButtons(device.deviceId),
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

/// The sheet opened by tapping a widget's "tune" icon — combines resizing,
/// reordering, and removing the widget with, for the My Buttons widget, a
/// read-only preview of its content (editing that content is desktop-only).
class _WidgetEditorSheet extends StatelessWidget {
  final String title;
  final bool canResize;
  final bool isCompact;
  final VoidCallback onResize;
  final VoidCallback onRemove;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final List<WorkspaceButtonDef>? buttonsPreview;
  final VoidCallback? onConfigureButtons;

  const _WidgetEditorSheet({
    required this.title,
    required this.canResize,
    required this.isCompact,
    required this.onResize,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.buttonsPreview,
    required this.onConfigureButtons,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.lg + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: WeDropColors.ink)),
            const SizedBox(height: Space.md),
            if (canResize)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Full width', style: TextStyle(color: WeDropColors.ink)),
                subtitle: const Text('Off pairs this widget with another compact one',
                    style: TextStyle(color: WeDropColors.inkFaint, fontSize: 12)),
                value: !isCompact,
                onChanged: (_) {
                  Navigator.pop(context);
                  onResize();
                },
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.arrow_upward_rounded, color: WeDropColors.inkDim),
              title: const Text('Move up', style: TextStyle(color: WeDropColors.ink)),
              onTap: () {
                Navigator.pop(context);
                onMoveUp();
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.arrow_downward_rounded, color: WeDropColors.inkDim),
              title: const Text('Move down', style: TextStyle(color: WeDropColors.ink)),
              onTap: () {
                Navigator.pop(context);
                onMoveDown();
              },
            ),
            if (buttonsPreview != null) ...[
              const SizedBox(height: Space.md),
              const CardLabel('Buttons on this widget'),
              if (buttonsPreview!.isEmpty)
                onConfigureButtons != null
                    ? _ConfigurePrompt(
                        message: 'No buttons configured yet',
                        onTap: () {
                          Navigator.pop(context);
                          onConfigureButtons!();
                        },
                        label: 'Add on desktop',
                      )
                    : const Text(
                        'No buttons configured yet. Add them from the desktop\'s My Buttons editor.',
                        style: TextStyle(color: WeDropColors.inkFaint, fontSize: 12.5),
                      )
              else
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [
                    for (final b in buttonsPreview!)
                      Chip(
                        avatar: Icon(
                          kWorkspaceIcons[b.icon] ?? Icons.bolt_rounded,
                          size: 16,
                          color: b.colorValue != 0 ? Color(b.colorValue) : WeDropColors.brandSoft,
                        ),
                        label: Text(b.label, style: const TextStyle(fontSize: 12)),
                        backgroundColor: WeDropColors.surfaceHi,
                        side: BorderSide.none,
                      ),
                  ],
                ),
              const SizedBox(height: Space.xs),
              const Text(
                'Edit these on the desktop\'s My Buttons window.',
                style: TextStyle(color: WeDropColors.inkFaint, fontSize: 11.5, fontStyle: FontStyle.italic),
              ),
            ],
            const SizedBox(height: Space.lg),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.pop(context);
                  onRemove();
                },
                style: OutlinedButton.styleFrom(foregroundColor: WeDropColors.danger),
                child: const Text('Remove widget'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks, renames, deletes, or creates a named layout for this device — the
/// full management sheet, used only from the Widgets tab's own top bar.
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

/// A lightweight, select-only layout list — used from the full-screen "run
/// mode" (Overview's Workspace preview card, and the Widgets tab's own
/// full-screen button), where picking a layout is the only customization on
/// offer; managing layouts (rename/delete/create) stays in the Widgets tab.
class _LayoutSelectSheet extends StatelessWidget {
  final List<WorkspaceLayout> layouts;
  final String activeId;
  const _LayoutSelectSheet({required this.layouts, required this.activeId});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.sm),
            child: Text('Choose a layout', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: WeDropColors.ink)),
          ),
          for (final layout in layouts)
            ListTile(
              leading: Icon(
                layout.id == activeId ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: layout.id == activeId ? WeDropColors.brand : WeDropColors.inkFaint,
              ),
              title: Text(layout.name, style: const TextStyle(color: WeDropColors.ink)),
              subtitle: Text('${layout.widgets.length} widget${layout.widgets.length == 1 ? '' : 's'}',
                  style: const TextStyle(color: WeDropColors.inkFaint, fontSize: 12)),
              onTap: () => Navigator.pop(context, layout.id),
            ),
          const SizedBox(height: Space.md),
        ],
      ),
    );
  }
}

/// Target width (dp) of one button tile including its share of the grid
/// gutter — the responsive grid divides available width by this to pick a
/// column count, so the tab reflows sensibly on rotation or on a tablet
/// instead of a fixed 3 columns.
const double _kTileTargetWidth = 78;

/// The button grid — purely a display+trigger surface: buttons are authored
/// on the desktop, so there is no add tile, no reorder, and no long-press
/// editor here, only tap-to-run.
class _WorkspaceGrid extends StatelessWidget {
  final List<WorkspaceButtonDef> buttons;
  final void Function(WorkspaceButtonDef) onRun;
  final VoidCallback onConfigure;

  const _WorkspaceGrid({required this.buttons, required this.onRun, required this.onConfigure});

  @override
  Widget build(BuildContext context) {
    if (buttons.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No buttons configured yet.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: WeDropColors.inkFaint, height: 1.4),
              ),
              const SizedBox(height: Space.sm),
              _ConfigurePrompt(
                message: 'No buttons set up yet',
                onTap: onConfigure,
                label: 'Add on desktop',
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / _kTileTargetWidth).floor().clamp(4, 10);
        return GridView.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: Space.xs,
            crossAxisSpacing: Space.xs,
            childAspectRatio: 0.92,
          ),
          itemCount: buttons.length,
          itemBuilder: (context, i) {
            final button = buttons[i];
            return _WorkspaceButtonTile(button: button, onTap: () => onRun(button));
          },
        );
      },
    );
  }
}

/// A dedicated full-screen route rendering the entire active layout with no
/// app bar, no other tabs, and the OS status/nav bars hidden — for propping
/// the phone up next to a keyboard and using it as a standalone control
/// surface. This is a "run mode": no widget menus, no add-widget store; the
/// only customization on offer is picking a different saved layout (when
/// more than one exists).
class _WorkspaceFullScreen extends StatefulWidget {
  final AppService service;
  final DeviceView device;
  final List<WorkspaceLayout> layouts;
  final String initialLayoutId;
  final Future<void> Function(String layoutId) onLayoutChanged;

  const _WorkspaceFullScreen({
    required this.service,
    required this.device,
    required this.layouts,
    required this.initialLayoutId,
    required this.onLayoutChanged,
  });

  @override
  State<_WorkspaceFullScreen> createState() => _WorkspaceFullScreenState();
}

class _WorkspaceFullScreenState extends State<_WorkspaceFullScreen> {
  late WorkspaceLayout _layout;

  @override
  void initState() {
    super.initState();
    _layout = widget.layouts.firstWhere((l) => l.id == widget.initialLayoutId, orElse: () => widget.layouts.first);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Explicitly allow both orientations while this surface is up, regardless
    // of whatever the rest of the app currently prefers — this is meant to be
    // propped up next to a keyboard in either orientation.
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // This route is pushed via Navigator, outside DeviceScreen's own
    // subtree — DeviceScreen's own service listener (which is what makes
    // the Widgets tab pick up live Dynamic Controls/minimized-window/button
    // updates) never reaches here, so without its own listener this surface
    // would freeze on whatever was true the moment it opened.
    widget.service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onServiceChanged);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pickLayout() async {
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => _LayoutSelectSheet(layouts: widget.layouts, activeId: _layout.id),
    );
    if (id == null || !mounted) return;
    setState(() => _layout = widget.layouts.firstWhere((l) => l.id == id, orElse: () => _layout));
    await widget.onLayoutChanged(id);
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
            layout: _layout,
            onResizeWidget: (_) {},
            onRemoveWidget: (_) {},
            onMoveWidget: (_, _) {},
            showWidgetMenus: false,
            layoutName: _layout.name,
            onOpenLayoutPicker: widget.layouts.length > 1 ? _pickLayout : null,
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
    final exe = state?.exe ?? '';
    // An app is focused but has no profile yet — offer to configure it,
    // rather than showing nothing or (as before) the same nine generic
    // buttons every unrecognized app used to get.
    final needsConfigure = appName.isNotEmpty && controls.isEmpty && exe.isNotEmpty;

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
          if (needsConfigure)
            _ConfigurePrompt(
              message: 'No buttons set up for $appName yet',
              onTap: () => service.requestConfigureApp(device.deviceId, exe),
            )
          else if (controls.isEmpty)
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
                        child: _DynamicControlTile(
                          control: control,
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

class _ConfigurePrompt extends StatelessWidget {
  final String message;
  final VoidCallback onTap;
  final String label;
  const _ConfigurePrompt({required this.message, required this.onTap, this.label = 'Configure'});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WeDropColors.surfaceHi,
      borderRadius: BorderRadius.circular(Radii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.add_circle_outline_rounded, size: 18, color: WeDropColors.brandSoft),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(fontSize: 12.5, color: WeDropColors.inkDim),
                ),
              ),
              Text(label,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: WeDropColors.brandSoft)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A Dynamic Controls tile honoring the control's own colour (set from the
/// desktop's App Actions editor), matching _WorkspaceButtonTile's visual
/// language rather than WdActionTile's single fixed accent.
class _DynamicControlTile extends StatelessWidget {
  final AdaptiveControl control;
  final VoidCallback onTap;
  const _DynamicControlTile({required this.control, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = control.color != 0 ? Color(control.color) : WeDropColors.accent;
    final icon = kWorkspaceIcons[control.icon] ?? Icons.bolt_rounded;

    return Material(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(Radii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: onTap,
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(height: Space.xs),
              Text(control.label, style: AppText.caption.copyWith(color: WeDropColors.ink)),
            ],
          ),
        ),
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
  final WorkspaceButtonDef button;
  final VoidCallback onTap;

  const _WorkspaceButtonTile({required this.button, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = button.colorValue != 0 ? Color(button.colorValue) : WeDropColors.accent;
    final icon = kWorkspaceIcons[button.icon] ?? Icons.bolt_rounded;

    return Material(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(Radii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: onTap,
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
