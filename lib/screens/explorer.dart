import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../format.dart';
import '../paths.dart';
import '../src/rust/api/spaceman.dart';
import '../widgets/row_controls.dart';
import '../widgets/treemap.dart';

/// Drill-down view of where space is used, largest items first.
///
/// Folders slide like a navigation stack. Going up: swipe right (two
/// fingers on a trackpad, one on a touch screen), the mouse back button,
/// Cmd+[, Cmd+Up, Alt+Up, Alt+Left, or Left in the list.
///
/// The keyboard moves a focus ring (arrows), opens folders (Enter, or Right
/// in the list) and ticks items for removal (Backspace or Delete; without
/// a focused item they act on the one under the pointer). Space ticks the
/// item under the pointer, or else the focused one.
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

  /// Item with keyboard focus, by path so it survives re-sorting and the
  /// live view of a scan being replaced.
  String? _focusPath;
  final _focusKey = GlobalKey();
  final _treemapKey = GlobalKey<TreemapState>();

  /// Item under the pointer, the fallback for the keyboard.
  NodeView? _hovered;

  /// What the list shows for folder [id].
  List<NodeView> _items(int id) => model
      .children(id)
      .where((n) => n.protection != ProtectionState.protected)
      .toList();

  NodeView? get _focused => _focusPath == null
      ? null
      : _items(model.currentId).where((n) => n.path == _focusPath).firstOrNull;

  void _focus(NodeView? node, {bool down = true}) {
    if (node == null) return;
    setState(() => _focusPath = node.path);
    // Keep the ring in view while stepping through a long list.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _focusKey.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 120),
          alignmentPolicy: down
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
      }
    });
  }

  /// Arrow keys: up and down in the list, by position in the treemap.
  void _arrow(AxisDirection d) {
    if (model.treemap) {
      _focus(_treemapKey.currentState?.neighbor(_focusPath, d));
      return;
    }
    switch (d) {
      case AxisDirection.left:
        _up();
      case AxisDirection.right:
        _openFocused();
      case AxisDirection.up || AxisDirection.down:
        final items = _items(model.currentId);
        if (items.isEmpty) return;
        final down = d == AxisDirection.down;
        final i = items.indexWhere((n) => n.path == _focusPath);
        final next = i < 0
            ? (down ? 0 : items.length - 1)
            : (i + (down ? 1 : -1)).clamp(0, items.length - 1);
        _focus(items[next], down: down);
    }
  }

  void _openFocused() {
    final node = _focused ?? _hovered;
    if (node != null && node.kind == EntryKind.dir && node.hasChildren) {
      _go(node.id);
    }
  }

  /// Backspace or Delete: tick or untick the focused (or hovered) item for
  /// removal. In the list, focus then moves on, for quick multi-select.
  void _toggleRemoval({bool pointerFirst = false}) {
    final focused = _focused;
    final node = pointerFirst ? _hovered ?? focused : focused ?? _hovered;
    if (node == null) return;
    String? hint;
    if (model.live) {
      hint = 'Wait until the scan is done to select items for removal.';
    } else if (node.protection != ProtectionState.none) {
      hint = node.protection == ProtectionState.protected
          ? '${node.name} is marked do not touch.'
          : '${node.name} contains items marked do not touch.';
    } else if (node.kind == EntryKind.smallFiles) {
      hint = 'Small files can only be removed with their folder.';
    }
    if (hint != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(hint), duration: const Duration(seconds: 2)),
        );
      return;
    }
    model.setSelected(node, !model.isSelected(node.path));
    if (node == focused && !model.treemap) _arrow(AxisDirection.down);
  }

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
    // Going up, the folder we came out of keeps the focus.
    final fromCrumbs = model.breadcrumbs(from);
    _focusPath = fromCrumbs.length > model.breadcrumbs(id).length
        ? fromCrumbs[model.breadcrumbs(id).length].path
        : null;
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
          // A zoom eases both ways; a slide decelerates into place.
          curve: model.treemap ? Curves.easeInOutCubic : Curves.easeOutCubic,
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
        // Explorer's shortcuts on Windows and Linux.
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): _up,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _up,
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _arrow(AxisDirection.up),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _arrow(AxisDirection.down),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _arrow(AxisDirection.left),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _arrow(AxisDirection.right),
        const SingleActivator(LogicalKeyboardKey.enter): _openFocused,
        const SingleActivator(LogicalKeyboardKey.backspace): _toggleRemoval,
        const SingleActivator(LogicalKeyboardKey.delete): _toggleRemoval,
        // Space works on what the mouse points at, then the focus.
        const SingleActivator(LogicalKeyboardKey.space): () =>
            _toggleRemoval(pointerFirst: true),
        const SingleActivator(LogicalKeyboardKey.backspace, meta: true):
            _toggleRemoval,
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
              Row(
                children: [
                  Expanded(
                    child: _Breadcrumbs(
                      model: model,
                      crumbs: crumbs,
                      onOpen: _go,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: SegmentedButton<bool>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: const [
                        ButtonSegment(
                          value: false,
                          icon: Icon(Icons.view_list, size: 18),
                          tooltip: 'List',
                        ),
                        ButtonSegment(
                          value: true,
                          icon: Icon(Icons.dashboard, size: 18),
                          tooltip: 'Treemap',
                        ),
                      ],
                      selected: {model.treemap},
                      onSelectionChanged: (v) => model.setTreemap(v.single),
                    ),
                  ),
                ],
              ),
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
    if (model.treemap && below != null) {
      return AnimatedBuilder(
        animation: _t,
        builder: (context, _) =>
            _zoom(below, above, 1 - _t.value) ??
            _slide(context, below, above, _t.value),
      );
    }
    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) => _slide(context, below, above, _t.value),
    );
  }

  /// Treemap transition: the tile of [inner] inside [outer] grows to fill
  /// the area as [z] goes from 0 to 1, while the outer map zooms with it
  /// and fades out. Null until the outer map has been laid out once.
  Widget? _zoom(int outer, int inner, double z) {
    final layout = treemapLayouts[outer];
    if (layout == null) return null;
    // The tile itself, or for a jump of several levels, the tile of the
    // ancestor that contains it.
    Rect? tile;
    for (final c in model.breadcrumbs(inner).reversed) {
      tile = layout.tiles[c.id];
      if (tile != null) break;
    }
    if (tile == null || tile.isEmpty) return null;
    final full = layout.area;
    final r = Rect.lerp(tile, full, z)!;

    Matrix4 mapping(Rect from) {
      final sx = r.width / from.width, sy = r.height / from.height;
      return Matrix4.identity()
        ..translateByDouble(
          r.left - from.left * sx,
          r.top - from.top * sy,
          0,
          1,
        )
        ..scaleByDouble(sx, sy, 1, 1);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: (1 - z).clamp(0.0, 1.0),
          child: Transform(transform: mapping(tile), child: _list(outer)),
        ),
        Opacity(
          opacity: (z * 1.6).clamp(0.0, 1.0),
          child: Transform(transform: mapping(full), child: _list(inner)),
        ),
      ],
    );
  }

  Widget _slide(BuildContext context, int? below, int above, double t) {
    final background = Theme.of(context).colorScheme.surface;
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
              boxShadow: [
                if (below != null && t > 0 && t < 1)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 16,
                    offset: const Offset(-4, 0),
                  ),
              ],
            ),
            // Opaque, so the folder underneath does not show through;
            // a Material keeps the rows' ink visible.
            child: Material(color: background, child: _list(above)),
          ),
        ),
      ],
    );
  }

  /// The contents of folder [id]: its size and its items, largest first.
  Widget _list(int id) {
    if (model.treemap) {
      final current = id == model.currentId && _above == null;
      return Treemap(
        key: current ? _treemapKey : ValueKey(('treemap', id)),
        model: model,
        folderId: id,
        onOpen: _go,
        focusPath: current ? _focusPath : null,
        onHover: (n) => _hovered = n,
      );
    }
    final crumbs = model.breadcrumbs(id);
    final current = crumbs.isEmpty ? model.rootNode! : crumbs.last;
    // Protected items are out of the way: they live in the Do not touch tab.
    final items = _items(current.id);
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
        final focused = id == model.currentId && node.path == _focusPath;
        return MouseRegion(
          onEnter: (_) => _hovered = node,
          onExit: (_) {
            if (_hovered?.path == node.path) _hovered = null;
          },
          child: _NodeRow(
            key: focused ? _focusKey : null,
            model: model,
            node: node,
            fraction: largest > 0 ? node.size / largest : 0,
            share: current.size > 0 ? node.size / current.size : 0,
            onOpen: _go,
            focused: focused,
          ),
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
                child: Text(i == 0 ? lastComponent(c.name) : c.name),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    super.key,
    required this.model,
    required this.node,
    required this.fraction,
    required this.share,
    required this.onOpen,
    this.focused = false,
  });

  final AppModel model;
  final NodeView node;
  final ValueChanged<int> onOpen;

  /// Has the keyboard focus ring.
  final bool focused;

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
    // While the scan runs, folders are not fully known yet; removing
    // waits until it is done.
    final selectable =
        !model.live &&
        node.kind != EntryKind.smallFiles &&
        node.protection == ProtectionState.none;

    return ListTile(
      onTap: node.hasChildren ? () => onOpen(node.id) : null,
      shape: focused
          ? RoundedRectangleBorder(
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      leading: Icon(
        icon,
        color: node.kind == EntryKind.dir ? theme.colorScheme.primary : null,
      ),
      title: Row(
        children: [
          Flexible(child: Text(node.name, overflow: TextOverflow.ellipsis)),
          if (node.scanning) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: 'Still scanning',
              child: SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
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
      subtitle: SizeBar(fraction, padding: const EdgeInsets.only(top: 4)),
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
