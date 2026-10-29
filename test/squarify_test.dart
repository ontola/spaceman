import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:spaceman/widgets/squarify.dart';

void main() {
  const area = Rect.fromLTWH(10, 20, 300, 200);

  test('areas are proportional to the values and fill the area', () {
    final values = [600.0, 300.0, 200.0, 100.0, 50.0, 50.0];
    final rects = squarify(values, area);
    expect(rects, hasLength(values.length));
    final total = values.reduce((a, b) => a + b);
    var covered = 0.0;
    for (var i = 0; i < values.length; i++) {
      final r = rects[i];
      final a = r.width * r.height;
      covered += a;
      expect(a, closeTo(values[i] / total * area.width * area.height, 1e-6));
      // Inside the area, allowing for rounding.
      expect(area.inflate(1e-6).contains(r.topLeft), isTrue);
      expect(r.right, lessThanOrEqualTo(area.right + 1e-6));
      expect(r.bottom, lessThanOrEqualTo(area.bottom + 1e-6));
    }
    expect(covered, closeTo(area.width * area.height, 1e-6));
  });

  test('tiles do not overlap', () {
    final rects = squarify([5, 4, 3, 2, 1, 1, 1], area);
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        final o = rects[i].intersect(rects[j]);
        expect(o.width <= 1e-6 || o.height <= 1e-6, isTrue, reason: '$i, $j');
      }
    }
  });

  test('tiles stay close to square', () {
    final rects = squarify(
      List.filled(16, 1),
      const Rect.fromLTWH(0, 0, 400, 400),
    );
    for (final r in rects) {
      final ratio = r.width > r.height
          ? r.width / r.height
          : r.height / r.width;
      expect(ratio, lessThan(2));
    }
  });

  test('nothing to lay out', () {
    expect(squarify([], area), isEmpty);
    expect(squarify([0, 0], area), [Rect.zero, Rect.zero]);
    expect(squarify([1], area).single, area);
  });
}
