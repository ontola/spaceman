import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../format.dart';
import '../src/rust/api/spaceman.dart';
import '../widgets/selection_bar.dart';

/// Drill-down view of where space is used, largest items first.
///
/// Going up a level works like Finder: two-finger swipe right, the mouse
/// back button, Cmd+[ or Cmd+Up.
class ExplorerScreen extends StatefulWidget {
  const ExplorerScreen({super.key, required this.model});

  final AppModel model;

  @override
  State<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends State<ExplorerScreen>
    with SingleTickerProviderStateMixin {
  /// Horizontal offset of the content, following the trackpad like Finder.
  late final AnimationController _offset = AnimationController.unbounded(
    vsync: this,
  );
  double _width = 1;
  bool _horizontal = false;

  AppModel get model => widget.model;

  bool get _canGoUp => model.breadcrumbs(model.currentId).length > 1;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  /// Slides the current folder out to the right and the parent in.
  Future<void> _up() async {
    if (!_canGoUp) return;
    await _offset.animateTo(
      _width,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeIn,
    );
    if (!mounted) return;
    final crumbs = model.breadcrumbs(model.currentId);
    if (crumbs.length > 1) model.open(crumbs[crumbs.length - 2].id);
    _offset.value = -_width * 0.2;
    await _offset.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _onPanZoomStart(PointerPanZoomStartEvent e) {
    _offset.stop();
    _horizontal = false;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    // Decide once per gesture; vertical ones scroll the list.
    if (!_horizontal) {
      if (e.pan.distance < 8) return;
      if (e.pan.dx.abs() < e.pan.dy.abs() * 1.5 || e.pan.dx < 0) return;
      _horizontal = true;
    }
    final dx = e.pan.dx.clamp(0.0, _width);
    // At the top there is nowhere to go: resist like a rubber band.
    _offset.value = _canGoUp ? dx : dx * 0.15;
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent e) {
    if (!_horizontal) return;
    _horizontal = false;
    if (_canGoUp && _offset.value > (_width * 0.25).clamp(60.0, 160.0)) {
      _up();
    } else {
      _offset.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true): _up,
        const SingleActivator(LogicalKeyboardKey.arrowUp, meta: true): _up,
        const SingleActivator(LogicalKeyboardKey.backspace): _up,
      },
      child: Focus(
        autofocus: true,
        child: Listener(
          onPointerPanZoomStart: _onPanZoomStart,
          onPointerPanZoomUpdate: _onPanZoomUpdate,
          onPointerPanZoomEnd: _onPanZoomEnd,
          onPointerDown: (e) {
            if (e.buttons & kBackMouseButton != 0) _up();
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              _width = constraints.maxWidth;
              return ClipRect(
                child: AnimatedBuilder(
                  animation: _offset,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(_offset.value, 0),
                    child: Opacity(
                      opacity:
                          1 -
                          (_offset.value.abs() / _width).clamp(0.0, 1.0) * 0.7,
                      child: child,
                    ),
                  ),
                  child: _buildContent(context),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (model.rootNode == null) {
      return Center(
        child: Text(
          model.scanning
              ? 'Scanning this folder for the first time. '
                    'Next time SpaceMan opens instantly from its cache.'
              : 'No scan yet',
          textAlign: TextAlign.center,
        ),
      );
    }
    final crumbs = model.breadcrumbs(model.currentId);
    final current = crumbs.isEmpty ? model.rootNode! : crumbs.last;
    final items = model.children(current.id);
    final largest = items.isEmpty ? 1 : items.first.size;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Breadcrumbs(model: model, crumbs: crumbs),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '${formatBytes(current.size)} in ${formatCount(current.fileCount)} files',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) => _NodeRow(
              model: model,
              node: items[i],
              fraction: largest > 0 ? items[i].size / largest : 0,
              share: current.size > 0 ? items[i].size / current.size : 0,
            ),
          ),
        ),
      ],
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.model, required this.crumbs});

  final AppModel model;
  final List<NodeView> crumbs;

  @override
  Widget build(BuildContext context) {
    // Left-aligned while it fits; once too long it scrolls, keeping the
    // current folder (the end) in view.
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            if (crumbs.length > 1)
              IconButton(
                tooltip: 'Up',
                icon: const Icon(Icons.arrow_upward),
                onPressed: () => model.open(crumbs[crumbs.length - 2].id),
              ),
            for (final (i, c) in crumbs.indexed) ...[
              if (i > 0) const Icon(Icons.chevron_right, size: 18),
              TextButton(
                onPressed: () => model.open(c.id),
                child: Text(i == 0 ? _short(c.name) : c.name),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Shows the scan root as its last path component.
  String _short(String path) {
    final parts = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.model,
    required this.node,
    required this.fraction,
    required this.share,
  });

  final AppModel model;
  final NodeView node;

  /// Size relative to the largest sibling, for the bar.
  final double fraction;

  /// Size relative to the parent folder, for the percentage.
  final double share;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (node.kind) {
      EntryKind.dir => Icons.folder,
      EntryKind.file => Icons.insert_drive_file_outlined,
      EntryKind.smallFiles => Icons.layers_outlined,
    };
    final selectable =
        node.kind != EntryKind.smallFiles &&
        node.protection == ProtectionState.none;

    return ListTile(
      onTap: node.hasChildren ? () => model.open(node.id) : null,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ProtectToggle(model: model, node: node),
          const SizedBox(width: leadingGap),
          RowCheckbox(
            value: selectable && model.isSelected(node.path),
            onChanged: selectable
                ? (v) => model.setSelected(node, v ?? false)
                : null,
          ),
          const SizedBox(width: leadingGap),
          Icon(
            icon,
            color: node.kind == EntryKind.dir
                ? theme.colorScheme.primary
                : null,
          ),
        ],
      ),
      title: Row(
        children: [
          Flexible(child: Text(node.name, overflow: TextOverflow.ellipsis)),
          if (node.protection == ProtectionState.containsProtected) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'Contains items marked as do not touch',
              child: Icon(
                Icons.lock_outline,
                size: 16,
                color: theme.colorScheme.tertiary,
              ),
            ),
          ],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: fraction.clamp(0, 1),
            minHeight: 6,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 120,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(formatBytes(node.size), style: theme.textTheme.titleSmall),
                Text(
                  '${(share * 100).toStringAsFixed(1)}%',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          RevealButton(path: node.path),
        ],
      ),
    );
  }
}
