import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spaceman/palette.dart';

void main() {
  test('hues spread around the wheel', () {
    final hues = [for (var i = 0; i < 8; i++) tileHue(i)];
    expect(hues.every((h) => h >= 0 && h < 360), isTrue);
    expect(hues.toSet(), hasLength(8));
  });

  test('tiles get lighter with depth, darker in dark mode', () {
    double light(Color c) => HSLColor.fromColor(c).lightness;
    expect(
      light(tileColor(0, depth: 1, dark: false)),
      greaterThan(light(tileColor(0, dark: false))),
    );
    expect(
      light(tileColor(0, depth: 1, dark: true)),
      lessThan(light(tileColor(0, dark: true))),
    );
    expect(
      light(tileColor(0, dark: true)),
      lessThan(light(tileColor(0, dark: false))),
    );
    // Very deep levels stop at a legible lightness (8-bit colour rounds).
    expect(light(tileColor(0, depth: 20, dark: false)), closeTo(0.92, 0.01));
    expect(light(tileColor(0, depth: 20, dark: true)), closeTo(0.12, 0.01));
  });
}
