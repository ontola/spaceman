import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../format.dart';
import '../src/rust/api/spaceman.dart';
import '../widgets/selection_bar.dart';

/// Drill-down view of where space is used, largest items first.
///
/// Folders slide like a navigation stack. Going up: swipe right (two
/// fingers on a trackpad, one on a touch screen), the mouse back button,
/// Cmd+[, Cmd+Up or Backspace.
class ExplorerScreen extends StatefulWidget {
  const ExplorerScreen({super.key, required this.model});

  final AppModel model;

  @override
  State<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends State<ExplorerScreen>
    with SingleTickerProviderStateMixin {
  /// Progress of a transition between two folder lists, like a navigation
  /// stack: 0 shows [_above] covering [_below], 1 has [_above] slid off to
  /// the right with [_below] fully in view. Going up runs 0 -> 1, opening a
  /// folder runs 1 -> 0 with the new folder on top.
  late final AnimationController _t = AnimationController(vsync: this);
  int? _below;
  int? _above;

  /// A back swipe is being dragged (the folder has not changed yet).
  bool _dragging = false;
  double _width = 1;

  static const _duration = Duration(milliseconds: 280);

  AppModel get model => widget.model;

  int? get _parentId {
    final crumbs = model.breadcrumbs(model.currentId);
    return crumbs.length > 1 ? crumbs[crumbs.length - 2].id : null;
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  void _clearTransition() {
    if (!mounted) return;
    setState(() => _below = _above = null);
  }

  /// Opens [id], sliding lists the way a navigation stack would: deeper
  /// folders come in from the right, going up slides the current one off.
  /// The breadcrumbs change right away; only the list animates.
  void _go(int id) {
    if (id == model.currentId) return;
    final from = model.currentId;
    final deeper =
        model.breadcrumbs(id).length > model.breadcrumbs(from).length;
    _t.stop();
    model.open(id);
    setState(() {
      _below = deeper ? from : id;
      _above = deeper ? id : from;
    });
    _t.value = deeper ? 1 : 0;
    _t
        .animateTo(
          deeper ? 0 : 1,
          duration: _duration,
          curve: Curves.easeOutCubic,
        )
        .whenComplete(_clearTransition);
  }

  void _up() {
    final parent = _parentId;
    if (parent != null) _go(parent);
  }

  // Back swipe. On macOS two fingers on the trackpad arrive as raw
  // pan/zoom pointer events (they never become a drag), so those are read
  // directly; touch screens use a normal horizontal drag.

  /// Whether the current trackpad gesture was claimed as a back swipe.
  bool _panLocked = false;
  bool _panRejected = false;
  double _panDx = 0;
  Duration _panTime = Duration.zero;
  double _panVelocity = 0;

  void _beginSwipe() {
    _t.stop();
    _dragging = true;
    // Catching a back slide that is still running: pick up from where it
    // is instead of jumping.
    final continuing = _above == model.currentId && _below == _parentId;
    setState(() {
      _below = _parentId;
      _above = model.currentId;
    });
    if (!continuing) _t.value = 0;
  }

  void _moveSwipe(double delta) {
    if (!_dragging) return;
    // At the top there is nowhere to go: resist like a rubber band.
    final resist = _below == null ? 0.15 : 1.0;
    _t.value = (_t.value + delta * resist / _width).clamp(0.0, 1.0);
  }

  /// Finishes the swipe from where the list is, always animating: going
  /// up when far or fast enough, springing back otherwise.
  void _endSwipe(double velocity) {
    if (!_dragging) return;
    _dragging = false;
    final target = _below;
    final t = _t.value;
    if (target != null && (velocity > 500 || (t > 0.3 && velocity > -200))) {
      _t
          .animateTo(
            1,
            duration: _duration * (1 - t).clamp(0.3, 1.0),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (!mounted) return;
            model.open(target);
            _clearTransition();
          });
    } else {
      _t
          .animateBack(
            0,
            duration: _duration * t.clamp(0.3, 1.0),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(_clearTransition);
    }
  }

  void _onPanZoomStart(PointerPanZoomStartEvent e) {
    _panLocked = _panRejected = false;
    _panDx = 0;
    _panTime = e.timeStamp;
    _panVelocity = 0;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    if (_panRejected) return;
    if (!_panLocked) {
      // Decide once, after a little movement: mostly sideways to the right
      // is a back swipe; anything else is left to the list (scrolling).
      if (e.pan.distance < 6) return;
      if (e.pan.dx <= 0 || e.pan.dx.abs() < e.pan.dy.abs() * 1.2) {
        _panRejected = true;
        return;
      }
      _panLocked = true;
      _beginSwipe();
    }
    final delta = e.pan.dx - _panDx;
    final dt = (e.timeStamp - _panTime).inMicroseconds / 1e6;
    if (dt > 0) {
      // Smoothed, so one jittery event does not decide the outcome.
      _panVelocity = 0.7 * (delta / dt) + 0.3 * _panVelocity;
    }
    _panDx = e.pan.dx;
    _panTime = e.timeStamp;
    _moveSwipe(delta);
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent e) {
    if (_panLocked) _endSwipe(_panVelocity);
    _panLocked = false;
  }

  @override
  Widget build(BuildContext context) {
    if (model.rootNode == null) {
      if (model.loadingCache) {
        return const Center(child: CircularProgressIndicator());
      }
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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true): _up,
        const SingleActivator(LogicalKeyboardKey.arrowUp, meta: true): _up,
        const SingleActivator(LogicalKeyboardKey.backspace): _up,
      },
      child: Focus(
        autofocus: true,
        child: Listener(
          onPointerDown: (e) {
            if (e.buttons & kBackMouseButton != 0) _up();
          },
          onPointerPanZoomStart: _onPanZoomStart,
          onPointerPanZoomUpdate: _onPanZoomUpdate,
          onPointerPanZoomEnd: _onPanZoomEnd,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Breadcrumbs(model: model, crumbs: crumbs, onOpen: _go),
              Expanded(
                child: GestureDetector(
                  // Touch screens; the trackpad is handled above.
                  supportedDevices: const {PointerDeviceKind.touch},
                  onHorizontalDragStart: (_) => _beginSwipe(),
                  onHorizontalDragUpdate: (d) => _moveSwipe(d.primaryDelta!),
                  onHorizontalDragEnd: (d) => _endSwipe(d.primaryVelocity ?? 0),
                  onHorizontalDragCancel: () => _endSwipe(0),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _width = constraints.maxWidth;
                      return ClipRect(child: _buildLists(context));
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLists(BuildContext context) {
    final above = _above;
    if (above == null) return _list(model.currentId);
    final below = _below;
    final background = Theme.of(context).colorScheme.surface;
    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        final t = _t.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (below != null)
              // The folder underneath trails behind with a parallax shift
              // and is dimmed while covered.
              Transform.translate(
                offset: Offset(-_width * 0.3 * (1 - t), 0),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _list(below),
                    IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.06 * (1 - t)),
                      ),
                    ),
                  ],
                ),
              ),
            Transform.translate(
              offset: Offset(_width * t, 0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: background,
                  boxShadow: [
                    if (below != null && t > 0 && t < 1)
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 16,
                        offset: const Offset(-4, 0),
                      ),
                  ],
                ),
                child: _list(above),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The contents of folder [id]: its size and its items, largest first.
  Widget _list(int id) {
    final crumbs = model.breadcrumbs(id);
    final current = crumbs.isEmpty ? model.rootNode! : crumbs.last;
    // Protected items are out of the way: they live in the Do not touch tab.
    final items = model
        .children(current.id)
        .where((n) => n.protection != ProtectionState.protected)
        .toList();
    final largest = items.isEmpty ? 1 : items.first.size;
    return ListView.builder(
      key: PageStorageKey(id),
      itemCount: items.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '${formatBytes(current.size)} in ${formatCount(current.fileCount)} files',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final node = items[i - 1];
        return _NodeRow(
          model: model,
          node: node,
          fraction: largest > 0 ? node.size / largest : 0,
          share: current.size > 0 ? node.size / current.size : 0,
          onOpen: _go,
        );
      },
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({
    required this.model,
    required this.crumbs,
    required this.onOpen,
  });

  final AppModel model;
  final List<NodeView> crumbs;
  final ValueChanged<int> onOpen;

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
            for (final (i, c) in crumbs.indexed) ...[
              if (i > 0) const Icon(Icons.chevron_right, size: 18),
              TextButton(
                onPressed: () => onOpen(c.id),
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
    required this.onOpen,
  });

  final AppModel model;
  final NodeView node;
  final ValueChanged<int> onOpen;

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
      onTap: node.hasChildren ? () => onOpen(node.id) : null,
      leading: Icon(
        icon,
        color: node.kind == EntryKind.dir ? theme.colorScheme.primary : null,
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
          const SizedBox(width: leadingGap),
          RevealButton(path: node.path),
          const SizedBox(width: leadingGap),
          ProtectToggle(model: model, node: node),
          const SizedBox(width: leadingGap),
          RowCheckbox(
            value: selectable && model.isSelected(node.path),
            onChanged: selectable
                ? (v) => model.setSelected(node, v ?? false)
                : null,
          ),
        ],
      ),
    );
  }
}
