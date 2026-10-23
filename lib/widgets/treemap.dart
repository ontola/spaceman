import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_model.dart';
import '../format.dart';
import '../platform.dart';
import '../src/rust/api/spaceman.dart';
import 'fly_to.dart';

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
  });

  final AppModel model;
  final int folderId;
  final ValueChanged<int> onOpen;

  @override
  State<Treemap> createState() => _TreemapState();
}

class _TreemapState extends State<Treemap> {
  List<_Tile> _tiles = const [];
  Object? _layoutKey;
  _Tile? _hover;

  AppModel get model => widget.model;

  /// Lays out again only when the folder, the size or the scan changed.
  List<_Tile> _layout(Size size) {
    final key = (
      widget.folderId,
      size,
      model.rootNode,
      model.protectedPaths.length,
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
    if (items.isEmpty || area.width < 4 || area.height < 4) return const [];

    // Keep it fast and legible: tiles that would be tiny are merged into
    // one "more" tile.
    final total = items.fold<int>(0, (s, n) => s + n.size);
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
    final values = [for (final n in shown) n.size.toDouble()];
    if (rest > 0) values.add(rest.toDouble());

    final rects = _squarify(values, area);
    final tiles = <_Tile>[];
    for (var i = 0; i < rects.length; i++) {
      final r = rects[i];
      if (i >= shown.length) {
        tiles.add(_Tile(null, r, depth, hue, more: restCount, moreSize: rest));
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

  static PopupMenuItem<String> _item(
    String value,
    IconData icon,
    String label,
  ) => PopupMenuItem(
    value: value,
    child: Row(
      children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)],
    ),
  );

  Future<void> _menu(BuildContext context, Offset global, _Tile tile) async {
    final node = tile.node;
    if (node == null) return;
    final selectable = node.protection == ProtectionState.none;
    final selected = model.isSelected(node.path);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(global.dx, global.dy, global.dx, 0),
      items: [
        if (node.kind == EntryKind.dir && node.hasChildren)
          _item('open', Icons.folder_open, 'Open'),
        if (selectable)
          _item(
            'select',
            selected ? Icons.check_box : Icons.check_box_outline_blank,
            selected ? 'Unselect' : 'Select',
          ),
        if (selectable) _item('protect', Icons.lock_outline, 'Do not touch'),
        if (canReveal)
          _item('reveal', Icons.open_in_new, 'Show in $fileManagerName'),
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'open':
        widget.onOpen(node.id);
      case 'select':
        model.setSelected(node, !selected);
      case 'protect':
        flyToDoNotTouch(context, node.name);
        model.protect(node.path);
      case 'reveal':
        reveal(node.path);
    }
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
                return MouseRegion(
                  onHover: (e) {
                    final t = _hit(tiles, e.localPosition);
                    if (t != _hover) setState(() => _hover = t);
                  },
                  onExit: (_) => setState(() => _hover = null),
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
                        selected: model.selection.keys.toSet(),
                        theme: theme,
                      ),
                    ),
                  ),
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
  });

  /// Null for the tile that merges small items.
  final NodeView? node;
  final Rect rect;
  final int depth;
  final int hue;
  final int more;
  final int moreSize;
  List<_Tile> children = const [];
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk) of [values],
/// largest first, in [area]. Returns one rect per value, in order.
List<Rect> _squarify(List<double> values, Rect area) {
  final total = values.fold<double>(0, (a, b) => a + b);
  if (total <= 0) return [for (final _ in values) Rect.zero];
  final scale = area.width * area.height / total;
  final areas = [for (final v in values) v * scale];
  final out = List<Rect>.filled(values.length, Rect.zero);

  var free = area;
  var i = 0;
  while (i < areas.length) {
    final side = math.min(free.width, free.height);
    // Grow the row while it makes the worst aspect ratio better.
    var end = i + 1;
    var sum = areas[i];
    var worst = _worst(areas, i, end, sum, side);
    while (end < areas.length) {
      final next = _worst(areas, i, end + 1, sum + areas[end], side);
      if (next > worst) break;
      sum += areas[end];
      worst = next;
      end++;
    }
    // Lay the row along the short side.
    final thick = sum / side;
    var pos = 0.0;
    final horizontal = free.width >= free.height;
    for (var k = i; k < end; k++) {
      final len = areas[k] / thick;
      out[k] = horizontal
          ? Rect.fromLTWH(free.left, free.top + pos, thick, len)
          : Rect.fromLTWH(free.left + pos, free.top, len, thick);
      pos += len;
    }
    free = horizontal
        ? Rect.fromLTRB(free.left + thick, free.top, free.right, free.bottom)
        : Rect.fromLTRB(free.left, free.top + thick, free.right, free.bottom);
    i = end;
  }
  return out;
}

double _worst(List<double> a, int from, int to, double sum, double side) {
  var hi = 0.0, lo = double.infinity;
  for (var k = from; k < to; k++) {
    hi = math.max(hi, a[k]);
    lo = math.min(lo, a[k]);
  }
  final s2 = side * side, sum2 = sum * sum;
  return math.max(s2 * hi / sum2, sum2 / (s2 * lo));
}

class _Painter extends CustomPainter {
  _Painter({
    required this.tiles,
    required this.hover,
    required this.selected,
    required this.theme,
  });

  final List<_Tile> tiles;
  final _Tile? hover;
  final Set<String> selected;
  final ThemeData theme;

  bool get _dark => theme.brightness == Brightness.dark;

  /// Calm hues spread around the wheel; each top-level item keeps its hue
  /// for everything inside it, getting lighter (darker in dark mode) with
  /// depth.
  Color _fill(_Tile t) {
    final scheme = theme.colorScheme;
    final node = t.node;
    if (node == null || node.kind == EntryKind.smallFiles) {
      return scheme.surfaceContainerHighest;
    }
    final hue = (t.hue * 47.0 + 215) % 360;
    final isFile = node.kind == EntryKind.file;
    final light = _dark
        ? 0.30 - t.depth * 0.06 - (isFile ? 0.05 : 0)
        : 0.72 + t.depth * 0.07 + (isFile ? 0.05 : 0);
    return HSLColor.fromAHSL(
      1,
      hue,
      isFile ? 0.25 : 0.45,
      light.clamp(0.12, 0.92),
    ).toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final t in tiles) {
      _paintTile(canvas, t);
    }
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

  void _paintTile(Canvas canvas, _Tile t) {
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

    final label = node == null
        ? '${t.more} more'
        : node.kind == EntryKind.smallFiles
        ? node.name
        : node.name;
    final sizeText = formatBytes(node?.size ?? t.moreSize);
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
      old.theme != theme ||
      !_sameSet(old.selected, selected);

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
