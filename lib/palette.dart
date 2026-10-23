import 'package:flutter/material.dart';

/// The colours SpaceMan is built from. The treemap, the app theme, the logo
/// and the generated app icons all read from here, so changing a value
/// changes them together (rerun `flutter test tool/generate_icons.dart` to
/// refresh the icons).

/// Seed for the Material colour scheme.
const seedColor = Color(0xFF3B6FE0);

/// Hue of the [index]-th top-level item: calm hues spread around the wheel.
double tileHue(int index) => (index * 47.0 + 215) % 360;

/// Fill of a treemap tile. Each top-level item keeps its hue for everything
/// inside it, getting lighter (darker in dark mode) with depth.
Color tileColor(
  int hueIndex, {
  int depth = 0,
  bool isFile = false,
  required bool dark,
}) {
  final light = dark
      ? 0.30 - depth * 0.06 - (isFile ? 0.05 : 0)
      : 0.72 + depth * 0.07 + (isFile ? 0.05 : 0);
  return HSLColor.fromAHSL(
    1,
    tileHue(hueIndex),
    isFile ? 0.25 : 0.45,
    light.clamp(0.12, 0.92),
  ).toColor();
}
