import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../palette.dart';

/// What the logo sits on. The app uses [none]; the app icons use the others.
enum LogoBackground { none, circle, roundedSquare, square }

/// SpaceMan's logo: a minimal astronaut whose visor shows a treemap, bulged
/// as if seen through the curved glass. Drawn in code from the app's colour
/// scheme and treemap palette (see palette.dart), so it follows along when
/// those change.
class SpaceManLogo extends StatelessWidget {
  const SpaceManLogo({
    super.key,
    this.size = 48,
    this.background = LogoBackground.none,
  });

  final double size;
  final LogoBackground background;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: LogoPainter(
          scheme: Theme.of(context).colorScheme,
          background: background,
        ),
      ),
    );
  }
}

class LogoPainter extends CustomPainter {
  LogoPainter({required this.scheme, this.background = LogoBackground.none});

  final ColorScheme scheme;
  final LogoBackground background;

  Color get _rim => Color.lerp(scheme.primary, Colors.black, 0.72)!;
  Color get _suit => Color.lerp(Colors.white, scheme.primary, 0.03)!;
  Color get _suitShade => Color.lerp(Colors.white, scheme.primary, 0.2)!;

  /// The treemap palette, a bit livelier so it reads at icon size.
  static Color _tile(int hue, int depth) {
    final c = HSLColor.fromColor(tileColor(hue, depth: depth, dark: false));
    return c
        .withSaturation((c.saturation * 1.6).clamp(0, 1))
        .withLightness((c.lightness - 0.1).clamp(0, 1))
        .toColor();
  }

  /// The treemap hues at full blast, for the background burst.
  static Color _vivid(int hue) =>
      HSLColor.fromAHSL(1, tileHue(hue), 0.85, 0.55).toColor();

  // Everything below is laid out in a unit square.
  static const _helmet = Offset(0.5, 0.44);
  static const _helmetR = 0.31;
  static final _visor = Rect.fromCenter(
    center: const Offset(0.5, 0.45),
    width: 0.49,
    height: 0.41,
  );
  static const _line = 0.022;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width, size.height);

    final bg = _backgroundPath();
    if (bg != null) {
      canvas.clipPath(bg);
      _burst(canvas);
    }

    _body(canvas);
    _helmetShell(canvas);
    _visorGlass(canvas);
    canvas.restore();
  }

  Path? _backgroundPath() {
    const unit = Rect.fromLTWH(0, 0, 1, 1);
    return switch (background) {
      LogoBackground.none => null,
      LogoBackground.circle => Path()..addOval(unit),
      LogoBackground.roundedSquare =>
        Path()..addRRect(
          RRect.fromRectAndRadius(unit, const Radius.circular(0.225)),
        ),
      LogoBackground.square => Path()..addRect(unit),
    };
  }

  /// A psychedelic burst radiating from the helmet: scalloped rings running
  /// through the treemap hues, crossed by light and dark rays.
  void _burst(Canvas canvas) {
    canvas.drawPaint(Paint()..color = _vivid(0));
    const steps = 360;
    for (var j = 32; j > 0; j--) {
      final base = 0.02 + j * 0.03;
      final ring = Path();
      for (var k = 0; k <= steps; k++) {
        final a = k / steps * 2 * math.pi;
        final r = base * (1 + 0.14 * math.cos(16 * a + j * 0.8));
        final p = _helmet + Offset(math.cos(a), math.sin(a)) * r;
        k == 0 ? ring.moveTo(p.dx, p.dy) : ring.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(ring..close(), Paint()..color = _vivid(j));
    }

    const rays = 48;
    for (var i = 0; i < rays; i++) {
      final a0 = i / rays * 2 * math.pi;
      final a1 = (i + 1) / rays * 2 * math.pi;
      final wedge = Path()
        ..moveTo(_helmet.dx, _helmet.dy)
        ..lineTo(_helmet.dx + math.cos(a0) * 2, _helmet.dy + math.sin(a0) * 2)
        ..lineTo(_helmet.dx + math.cos(a1) * 2, _helmet.dy + math.sin(a1) * 2)
        ..close();
      canvas.drawPath(
        wedge,
        Paint()
          ..color = i.isEven
              ? Colors.white.withValues(alpha: 0.22)
              : Colors.black.withValues(alpha: 0.14),
      );
    }

    // A dark halo behind the astronaut keeps the outline readable.
    canvas.drawCircle(
      _helmet,
      0.62,
      Paint()
        ..shader = ui.Gradient.radial(
          _helmet,
          0.62,
          [_rim.withValues(alpha: 0.45), _rim.withValues(alpha: 0)],
          [0.45, 0.8],
        ),
    );
  }

  Paint get _outline => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = _line
    ..strokeJoin = StrokeJoin.round
    ..color = _rim;

  void _shape(Canvas canvas, Path path, Color fill) {
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(path, _outline);
  }

  void _body(Canvas canvas) {
    final shoulders = Path()
      ..moveTo(0.08, 1.02)
      ..lineTo(0.12, 0.88)
      ..quadraticBezierTo(0.15, 0.76, 0.3, 0.74)
      ..lineTo(0.7, 0.74)
      ..quadraticBezierTo(0.85, 0.76, 0.88, 0.88)
      ..lineTo(0.92, 1.02)
      ..close();
    _shape(canvas, shoulders, _suit);

    // Chest box with three status lights in treemap colours.
    final box = RRect.fromLTRBR(
      0.4,
      0.86,
      0.6,
      0.95,
      const Radius.circular(0.02),
    );
    _shape(canvas, Path()..addRRect(box), _suitShade);
    for (var i = 0; i < 3; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0.42 + i * 0.056, 0.885, 0.044, 0.04),
          const Radius.circular(0.008),
        ),
        Paint()..color = _tile(i, 0),
      );
    }

    final collar = RRect.fromLTRBR(
      0.29,
      0.69,
      0.71,
      0.81,
      const Radius.circular(0.05),
    );
    _shape(canvas, Path()..addRRect(collar), _suitShade);
  }

  void _helmetShell(Canvas canvas) {
    for (final x in const [0.15, 0.79]) {
      final pad = RRect.fromLTRBR(
        x,
        0.35,
        x + 0.06,
        0.53,
        const Radius.circular(0.025),
      );
      _shape(canvas, Path()..addRRect(pad), _suitShade);
    }

    final shell = Path()
      ..addOval(Rect.fromCircle(center: _helmet, radius: _helmetR));
    canvas.drawPath(shell, Paint()..color = _suit);
    // A soft shade along the lower right gives the helmet some volume.
    canvas.save();
    canvas.clipPath(shell);
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        shell,
        Path()..addOval(
          Rect.fromCircle(
            center: _helmet.translate(-0.04, -0.05),
            radius: _helmetR,
          ),
        ),
      ),
      Paint()..color = _suitShade,
    );
    canvas.restore();
    canvas.drawPath(shell, _outline);
  }

  void _visorGlass(Canvas canvas) {
    final glass = Path()..addOval(_visor);
    canvas.drawPath(glass, Paint()..color = _rim);

    canvas.save();
    canvas.clipPath(glass);
    final fill = Paint();
    for (final t in _visorTiles) {
      fill.color = _tile(t.hue, t.shade);
      canvas.drawPath(_bulged(t.rect), fill);
    }
    // Darken towards the edge, where the glass curves away.
    canvas.save();
    canvas.translate(_visor.center.dx, _visor.center.dy);
    canvas.scale(1, _visor.height / _visor.width);
    canvas.drawCircle(
      Offset.zero,
      _visor.width / 2,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          _visor.width / 2,
          [Colors.transparent, _rim.withValues(alpha: 0.55)],
          [0.55, 1],
        ),
    );
    canvas.restore();
    // Reflection on the upper left.
    final shine = Path.combine(
      PathOperation.difference,
      Path()..addOval(_visor.deflate(0.025)),
      Path()..addOval(_visor.deflate(0.02).shift(const Offset(0.03, 0.035))),
    );
    canvas.drawPath(
      shine,
      Paint()
        ..shader = ui.Gradient.linear(_visor.topLeft, _visor.center, [
          Colors.white.withValues(alpha: 0.5),
          Colors.white.withValues(alpha: 0),
        ]),
    );
    canvas.drawCircle(
      _visor.topLeft + Offset(_visor.width * 0.27, _visor.height * 0.2),
      0.014,
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
    canvas.restore();

    canvas.drawPath(glass, _outline..strokeWidth = _line * 1.4);
  }

  /// Maps a point on the flat treemap onto the visor as if the treemap were
  /// wrapped around a sphere seen from the front: big in the middle, squeezed
  /// towards the edge.
  static Offset _warp(Offset flat) {
    // Look at the sphere slightly from the upper left.
    final q = flat - const Offset(-0.1, -0.08);
    final d = q.distance;
    var p = q;
    if (d > 0) {
      final onSphere = math.sin(math.min(d, 1.0) * math.pi / 2) / d;
      p = q * (0.85 * onSphere + 0.15);
    }
    return _visor.center +
        Offset(p.dx * _visor.width / 2, p.dy * _visor.height / 2);
  }

  static Path _bulged(Rect flat) {
    final r = flat.deflate(_tileGap / 2);
    if (r.width <= 0 || r.height <= 0) return Path();
    final radius = math.min(0.06, r.shortestSide * 0.3);
    final source = Path()
      ..addRRect(RRect.fromRectAndRadius(r, Radius.circular(radius)));
    final points = <Offset>[];
    for (final m in source.computeMetrics()) {
      for (var at = 0.0; at < m.length; at += 0.02) {
        points.add(_warp(m.getTangentForOffset(at)!.position));
      }
    }
    return Path()..addPolygon(points, true);
  }

  static const _tileGap = 0.045;

  /// A fixed little treemap on [-1.25, 1.25]², a bit larger than the visible
  /// half of the sphere so it fills the glass to the edge.
  static final List<_LogoTile> _visorTiles = () {
    final rng = math.Random(7);
    final tiles = <_LogoTile>[];
    // [shade] steps the lightness so neighbouring siblings stand apart.
    void split(Rect r, int hue, int depth, int shade) {
      if (depth == 3 || r.width * r.height < 0.09) {
        tiles.add(_LogoTile(r, hue, shade % 3));
        return;
      }
      final count = 2 + rng.nextInt(3);
      final weights = [for (var i = 0; i < count; i++) 1.0 + rng.nextInt(4)]
        ..sort((a, b) => b.compareTo(a));
      for (final (i, c) in _squarify(weights, r).indexed) {
        split(c, hue, depth + 1, shade + i);
      }
    }

    const top = <double>[24, 18, 14, 12, 10, 8, 6, 5, 3];
    final rects = _squarify(top, const Rect.fromLTRB(-1.25, -1.25, 1.25, 1.25));
    for (final (i, r) in rects.indexed) {
      split(r, i, 0, 0);
    }
    return tiles;
  }();

  @override
  bool shouldRepaint(LogoPainter old) =>
      old.scheme != scheme || old.background != background;
}

class _LogoTile {
  const _LogoTile(this.rect, this.hue, this.shade);
  final Rect rect;
  final int hue;
  final int shade;
}

/// Squarified treemap of [weights] (sorted large to small) in [area].
List<Rect> _squarify(List<double> weights, Rect area) {
  final out = <Rect>[];
  var rest = weights;
  var r = area;
  while (rest.isNotEmpty) {
    final scale = r.width * r.height / rest.fold(0.0, (a, b) => a + b);
    final side = math.min(r.width, r.height);
    double worst(List<double> row) {
      final sum = row.fold(0.0, (a, b) => a + b);
      return math.max(
        side * side * row.first / (sum * sum),
        sum * sum / (side * side * row.last),
      );
    }

    var row = <double>[];
    var best = double.infinity;
    var n = 0;
    while (n < rest.length) {
      final next = [...row, rest[n] * scale];
      final w = worst(next);
      if (row.isNotEmpty && w > best) break;
      row = next;
      best = w;
      n++;
    }
    final thick = row.fold(0.0, (a, b) => a + b) / side;
    var at = 0.0;
    for (final a in row) {
      final len = a / thick;
      out.add(
        r.width >= r.height
            ? Rect.fromLTWH(r.left, r.top + at, thick, len)
            : Rect.fromLTWH(r.left + at, r.top, len, thick),
      );
      at += len;
    }
    r = r.width >= r.height
        ? Rect.fromLTRB(r.left + thick, r.top, r.right, r.bottom)
        : Rect.fromLTRB(r.left, r.top + thick, r.right, r.bottom);
    rest = rest.sublist(n);
  }
  return out;
}
