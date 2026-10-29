import 'dart:math' as math;
import 'dart:ui';

/// Squarified treemap layout (Bruls, Huizing, van Wijk) of [values],
/// largest first, in [area]. Returns one rect per value, in order.
List<Rect> squarify(List<double> values, Rect area) {
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
