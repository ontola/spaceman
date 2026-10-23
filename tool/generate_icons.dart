// Renders the app icons for every platform from the logo painter, so they
// follow palette.dart. Run from the repo root:
//
//   flutter test tool/generate_icons.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spaceman/palette.dart';
import 'package:spaceman/widgets/logo.dart';

final _scheme = ColorScheme.fromSeed(seedColor: seedColor);

Future<Uint8List> _render(
  int px,
  LogoBackground background, {
  double inset = 0,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final side = px * (1 - 2 * inset);
  canvas.translate(px * inset, px * inset);
  LogoPainter(
    scheme: _scheme,
    background: background,
  ).paint(canvas, Size.square(side));
  final image = await recorder.endRecording().toImage(px, px);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _write(String path, Future<Uint8List> png) async {
  await File(path).writeAsBytes(await png);
  stdout.writeln(path);
}

/// An .ico that holds one PNG per size (Windows Vista and later).
Uint8List _ico(List<(int, Uint8List)> images) {
  final out = BytesBuilder();
  final header = ByteData(6 + 16 * images.length)
    ..setUint16(2, 1, Endian.little)
    ..setUint16(4, images.length, Endian.little);
  var offset = header.lengthInBytes;
  for (final (i, (px, png)) in images.indexed) {
    final e = 6 + 16 * i;
    header
      ..setUint8(e, px >= 256 ? 0 : px)
      ..setUint8(e + 1, px >= 256 ? 0 : px)
      ..setUint16(e + 4, 1, Endian.little)
      ..setUint16(e + 6, 32, Endian.little)
      ..setUint32(e + 8, png.length, Endian.little)
      ..setUint32(e + 12, offset, Endian.little);
    offset += png.length;
  }
  out.add(header.buffer.asUint8List());
  for (final (_, png) in images) {
    out.add(png);
  }
  return out.toBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate app icons', () async {
    // macOS: rounded square on Apple's grid (824 of 1024, centred).
    const mac = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';
    for (final px in [16, 32, 64, 128, 256, 512, 1024]) {
      await _write(
        '$mac/app_icon_$px.png',
        _render(px, LogoBackground.roundedSquare, inset: 100 / 1024),
      );
    }

    // iOS masks the corners itself and wants no transparency.
    const ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final contents = jsonDecode(File('$ios/Contents.json').readAsStringSync());
    for (final img in contents['images'] as List) {
      final pt = double.parse((img['size'] as String).split('x').first);
      final scale = int.parse((img['scale'] as String).replaceAll('x', ''));
      await _write(
        '$ios/${img['filename']}',
        _render((pt * scale).round(), LogoBackground.square),
      );
    }

    // Android legacy launcher icons.
    const android = 'android/app/src/main/res';
    for (final (dir, px) in [
      ('mdpi', 48),
      ('hdpi', 72),
      ('xhdpi', 96),
      ('xxhdpi', 144),
      ('xxxhdpi', 192),
    ]) {
      await _write(
        '$android/mipmap-$dir/ic_launcher.png',
        _render(px, LogoBackground.circle, inset: 0.04),
      );
    }

    // Windows.
    final ico = [
      for (final px in [16, 24, 32, 48, 64, 128, 256])
        (px, await _render(px, LogoBackground.circle)),
    ];
    await File('windows/runner/resources/app_icon.ico').writeAsBytes(_ico(ico));
    stdout.writeln('windows/runner/resources/app_icon.ico');

    // A large copy for the README.
    await _write('assets/logo.png', _render(512, LogoBackground.circle));
  });
}
