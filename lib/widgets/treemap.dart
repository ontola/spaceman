import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../palette.dart';
import '../src/rust/api/spaceman.dart';
import 'item_actions.dart';
import 'not_scanned.dart';
import 'squarify.dart';

/// Where a folder's treemap was last drawn: its area and every tile in it
/// (nested ones too), in the coordinates of the Explore list area. Explore
/// zooms between levels with it.
class TreemapLayout {
  const TreemapLayout(this.area, this.tiles);

  final Rect area;
  final Map<int, Rect> tiles;
}

final treemapLayouts = <int, TreemapLayout>{};

/// The treemap's inset within the list area.
const _inset = Offset(16, 0);

/// Squarified treemap of a folder: every tile is an item, its area its
/// size. Big folders show their own contents inside them, a level or two
/// deep while the tiles stay legible.
class Treemap extends StatefulWidget {
  const Treemap({
    super.key,
    required this.model,
    required this.folderId,
    required this.onOpen,
    this.focusPath,
    this.onHover,
  });

  final AppModel model;
  final int folderId;
  final ValueChanged<int> onOpen;

  /// The tile with keyboard focus, drawn with a ring.
  final String? focusPath;

  /// Tells which item the pointer is on (null when none).
  final ValueChanged<NodeView?>? onHover;

  /// Id of the top folder of a scan.
  static const rootId = 0;

  @override
  State<Treemap> createState() => TreemapState();
}

class TreemapState extends State<Treemap> {
  List<_Tile> _tiles = const [];
  Object? _layoutKey;
  _Tile? _hover;

  AppModel get model => widget.model;

  /// The top-level tile next to [fromPath] in direction [d], by geometry;
  /// the biggest tile when nothing has focus yet.
  NodeView? neighbor(String? fromPath, AxisDirection d) {
    final tiles = _tiles.where((t) => t.node != null).toList();
    if (tiles.isEmpty) return null;
    final from = tiles.where((t) => t.node!.path == fromPath).firstOrNull;
    if (from == null) return tiles.first.node;
    final c = from.rect.center;
    _Tile? best;
    var bestScore = double.infinity;
    for (final t in tiles) {
      if (t == from) continue;
      final v = t.rect.center - c;
      final (along, across) = switch (d) {
        AxisDirection.right => (v.dx, v.dy),
        AxisDirection.left => (-v.dx, v.dy),
        AxisDirection.down => (v.dy, v.dx),
        AxisDirection.up => (-v.dy, v.dx),
      };
      if (along <= 0) continue;
      // Prefer what is straight ahead over what is merely closer.
      final score = along + across.abs() * 2;
      if (score < bestScore) {
        bestScore = score;
        best = t;
      }
    }
    return best?.node;
  }

  /// Lays out again only when the folder, the size or the scan changed.
  List<_Tile> _layout(Size size) {
    final key = (
      widget.folderId,
      size,
      model.rootNode,
      model.protectedPaths.length,
      model.showsUnscanned,
      model.access,
      model.apps,
      model.usageAccess,
    );
    if (key != _layoutKey) {
      _layoutKey = key;
      _hover = null;
      _tiles = _build(widget.folderId, Offset.zero & size, 0, 0);
      final rects = <int, Rect>{};
      void collect(List<_Tile> tiles) {
        for (final t in tiles) {
          if (t.node != null) rects[t.node!.id] = t.rect.shift(_inset);
          collect(t.children);
        }
      }

      collect(_tiles);
      treemapLayouts[widget.folderId] = TreemapLayout(_inset & size, rects);
    }
    return _tiles;
  }

  /// Children of [id] laid out in [area]. [hue] colours a whole branch.
  List<_Tile> _build(int id, Rect area, int depth, int hue) {
    final items = model
        .children(id)
        .where((n) => n.protection != ProtectionState.protected && n.size > 0)
        .toList();
    // At the top of the scan, the space it did not see gets a tile too.
    final parts = depth == 0 && id == Treemap.rootId
        ? model.unscannedParts.where((p) => p.size > 0).toList()
        : const <UnscannedPart>[];
    final unscanned = parts.fold<int>(0, (s, p) => s + p.size);
    if (items.isEmpty && unscanned == 0 || area.width < 4 || area.height < 4) {
      return const [];
    }

    // Keep it fast and legible: tiles that would be tiny are merged into
    // one "more" tile.
    final total = items.fold<int>(unscanned, (s, n) => s + n.size);
    final minArea = depth == 0 ? 600.0 : 900.0;
    final maxTiles = depth == 0 ? 150 : 40;
    final shown = <NodeView>[];
    var rest = 0;
    var restCount = 0;
    for (final n in items) {
      final a = n.size / total * area.width * area.height;
      if (shown.length < maxTiles && a >= minArea) {
        shown.add(n);
      } else {
        rest += n.size;
        restCount++;
      }
    }
    // Index into shown, the "more" tile, or -2 - k for unscanned part k;
    // laid out largest first, as squarify wants.
    const more = -1;
    final order = [for (var i = 0; i < shown.length; i++) i];
    if (rest > 0) order.add(more);
    for (var k = 0; k < parts.length; k++) {
      order.add(-2 - k);
    }
    int sizeOf(int i) => i == more
        ? rest
        : i < more
        ? parts[-2 - i].size
        : shown[i].size;
    order.sort((a, b) => sizeOf(b).compareTo(sizeOf(a)));

    final rects = squarify([for (final i in order) sizeOf(i).toDouble()], area);
    final tiles = <_Tile>[];
    for (var k = 0; k < rects.length; k++) {
      final r = rects[k];
      final i = order[k];
      if (i == more) {
        tiles.add(_Tile(null, r, depth, hue, more: restCount, moreSize: rest));
        continue;
      }
      if (i < more) {
        final part = parts[-2 - i];
        tiles.add(_Tile(null, r, depth, hue, moreSize: part.size, part: part));
        continue;
      }
      final n = shown[i];
      final tile = _Tile(n, r, depth, depth == 0 ? i : hue);
      // Nest when there is room for a header and a useful inside.
      if (n.kind == EntryKind.dir &&
          n.hasChildren &&
          depth < 2 &&
          r.width > 90 &&
          r.height > 60) {
        final inner = Rect.fromLTRB(
          r.left + 2,
          r.top + _header,
          r.right - 2,
          r.bottom - 2,
        );
        tile.children = _build(n.id, inner, depth + 1, tile.hue);
      }
      tiles.add(tile);
    }
    return tiles;
  }

  static const _header = 18.0;

  /// Deepest tile under [p].
  _Tile? _hit(List<_Tile> tiles, Offset p) {
    for (final t in tiles) {
      if (t.rect.contains(p)) return _hit(t.children, p) ?? t;
    }
    return null;
  }

  /// The folder to open for a click: the tile itself, or the folder it
  /// sits in when it is a file.
  _Tile? _folderAt(List<_Tile> tiles, Offset p, [_Tile? parent]) {
    for (final t in tiles) {
      if (t.rect.contains(p)) {
        final isDir = t.node?.kind == EntryKind.dir && t.node!.hasChildren;
        return _folderAt(t.children, p, isDir ? t : parent) ??
            (isDir ? t : parent);
      }
    }
    return null;
  }

  Future<void> _menu(BuildContext context, Offset global, _Tile tile) async {
    final node = tile.node;
    if (node == null) return;
    await showItemMenu(context, model, node, global, onOpen: widget.onOpen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: LayoutBuilder(
              builder: (context, c) {
                final tiles = _layout(c.biggest);
                final map = MouseRegion(
                  onHover: (e) {
                    final t = _hit(tiles, e.localPosition);
                    if (t != _hover) {
                      setState(() => _hover = t);
                      widget.onHover?.call(t?.node);
                    }
                  },
                  onExit: (_) {
                    setState(() => _hover = null);
                    widget.onHover?.call(null);
                  },
                  child: GestureDetector(
                    onTapUp: (d) {
                      final t = _folderAt(tiles, d.localPosition);
                      if (t != null) widget.onOpen(t.node!.id);
                    },
                    onSecondaryTapUp: (d) {
                      final t = _hit(tiles, d.localPosition);
                      if (t != null) _menu(context, d.globalPosition, t);
                    },
                    onLongPressStart: (d) {
                      final t = _hit(tiles, d.localPosition);
                      if (t != null) _menu(context, d.globalPosition, t);
                    },
                    child: CustomPaint(
                      size: c.biggest,
                      painter: _Painter(
                        tiles: tiles,
                        hover: _hover,
                        focusPath: widget.focusPath,
                        selected: model.selection.keys.toSet(),
                        theme: theme,
                      ),
                    ),
                  ),
                );
                final unseen = tiles.where((t) => t.unseen).toList();
                if (unseen.isEmpty) return map;
                // Widgets rather than paint: they have buttons.
                return Stack(
                  children: [
                    map,
                    for (final t in unseen)
                      Positioned.fromRect(
                        rect: t.rect.deflate(0.5),
                        child: MouseRegion(
                          onEnter: (_) {
                            setState(() => _hover = t);
                            widget.onHover?.call(null);
                          },
                          onExit: (_) {
                            if (_hover == t) setState(() => _hover = null);
                          },
                          child: UnscannedTile(model: model, part: t.part!),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
        // What the pointer is on, so tiles need no tooltip.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            _hover == null
                ? 'Click a folder to open it. Right-click for more.'
                : _hover!.unseen
                ? unscannedHint(_hover!.part!)
                : _hover!.node == null
                ? '${_hover!.more} smaller items, ${formatBytes(_hover!.moreSize)}'
                : '${_hover!.node!.path}  ·  ${formatBytes(_hover!.node!.size)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _Tile {
  _Tile(
    this.node,
    this.rect,
    this.depth,
    this.hue, {
    this.more = 0,
    this.moreSize = 0,
    this.part,
  });

  /// Null for the tile that merges small items.
  final NodeView? node;
  final Rect rect;
  final int depth;
  final int hue;
  final int more;
  final int moreSize;

  /// Space the scan did not see; drawn by [UnscannedTile].
  final UnscannedPart? part;
  bool get unseen => part != null;
  List<_Tile> children = const [];
}

class _Painter extends CustomPainter {
  _Painter({
    required this.tiles,
    required this.hover,
    required this.focusPath,
    required this.selected,
    required this.theme,
  });

  final List<_Tile> tiles;
  final _Tile? hover;
  final String? focusPath;
  final Set<String> selected;
  final ThemeData theme;

  bool get _dark => theme.brightness == Brightness.dark;

  Color _fill(_Tile t) {
    final node = t.node;
    if (node == null || node.kind == EntryKind.smallFiles) {
      return theme.colorScheme.surfaceContainerHighest;
    }
    return tileColor(
      t.hue,
      depth: t.depth,
      isFile: node.kind == EntryKind.file,
      dark: _dark,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final t in tiles) {
      _paintTile(canvas, t);
    }
    if (focusPath != null) _paintFocus(canvas, tiles);
    final h = hover;
    if (h != null) {
      canvas.drawRect(
        h.rect.deflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = theme.colorScheme.onSurface,
      );
    }
  }

  void _paintFocus(Canvas canvas, List<_Tile> tiles) {
    for (final t in tiles) {
      if (t.node?.path == focusPath) {
        final ring = RRect.fromRectAndRadius(
          t.rect.deflate(1.5),
          const Radius.circular(4),
        );
        canvas.drawRRect(
          ring,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = theme.colorScheme.primary,
        );
        return;
      }
      _paintFocus(canvas, t.children);
    }
  }

  void _paintTile(Canvas canvas, _Tile t) {
    if (t.unseen) return;
    final r = t.rect.deflate(0.5);
    if (r.width <= 0 || r.height <= 0) return;
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(3));
    canvas.drawRRect(rr, Paint()..color = _fill(t));

    final node = t.node;
    if (node != null && selected.contains(node.path)) {
      canvas.drawRRect(
        rr,
        Paint()..color = theme.colorScheme.primary.withValues(alpha: 0.35),
      );
      canvas.drawRRect(
        rr.deflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = theme.colorScheme.primary,
      );
    }

    final label = node == null ? '${t.more} more' : node.name;
    // A folder still being scanned is still growing.
    final sizeText =
        '${formatBytes(node?.size ?? t.moreSize)}${node?.scanning ?? false ? ' …' : ''}';
    final onFill = _dark ? Colors.white : Colors.black87;
    final nested = t.children.isNotEmpty;
    if (nested) {
      // Header strip with name and size, children below.
      _text(
        canvas,
        '$label  $sizeText',
        r.topLeft + const Offset(5, 2),
        r.width - 10,
        onFill,
        bold: true,
      );
      for (final c in t.children) {
        _paintTile(canvas, c);
      }
    } else if (r.width > 40 && r.height > 18) {
      final top = r.topLeft + const Offset(5, 3);
      _text(canvas, label, top, r.width - 10, onFill, bold: t.depth == 0);
      if (r.height > 34) {
        _text(
          canvas,
          sizeText,
          top + const Offset(0, 15),
          r.width - 10,
          onFill.withValues(alpha: 0.7),
        );
      }
    }
  }

  void _text(
    Canvas canvas,
    String s,
    Offset at,
    double maxWidth,
    Color color, {
    bool bold = false,
  }) {
    if (maxWidth < 12) return;
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_Painter old) =>
      old.tiles != tiles ||
      old.hover != hover ||
      old.focusPath != focusPath ||
      old.theme != theme ||
      !_sameSet(old.selected, selected);

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
