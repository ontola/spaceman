import 'dart:io';

import 'package:flutter/foundation.dart';

import 'platform.dart';
import 'src/rust/api/spaceman.dart' as core;

/// A disk the user can scan as a whole.
class Drive {
  const Drive({
    required this.path,
    required this.name,
    required this.total,
    required this.free,
    this.main = false,
  });

  final String path;
  final String name;
  final int total;
  final int free;

  /// The disk the system runs from; scanned unless the user picks another.
  final bool main;
}

/// Stands in for [listDrives] in tests.
@visibleForTesting
List<Drive> Function()? debugDrives;

/// The disks of this device, the main one first. On Android: internal
/// storage and any SD card or USB drive.
Future<List<Drive>> loadDrives() async {
  if (debugDrives != null) return debugDrives!();
  if (!Platform.isAndroid) return listDrives();
  try {
    final found = await androidVolumes();
    found.sort((a, b) => (b.$3 ? 1 : 0) - (a.$3 ? 1 : 0));
    return _measure(found);
  } on Exception {
    return const [];
  }
}

/// The disks of this computer, the main one first. Empty on phones; see
/// [loadDrives].
List<Drive> listDrives() {
  if (debugDrives != null) return debugDrives!();
  final List<(String, String, bool)> found;
  if (Platform.isMacOS) {
    found = _macDrives();
  } else if (Platform.isWindows) {
    found = _windowsDrives();
  } else if (Platform.isLinux) {
    found = _linuxDrives();
  } else {
    return const [];
  }
  return _measure(found);
}

List<Drive> _measure(List<(String, String, bool)> found) {
  final drives = <Drive>[];
  for (final (path, name, main) in found) {
    final space = core.diskSpace(path: path);
    if (space == null || space.total <= 0) continue;
    // A plain folder where a disk could be mounted, not a disk of its own.
    if (drives.isNotEmpty &&
        drives.first.total == space.total &&
        drives.first.free == space.free) {
      continue;
    }
    drives.add(
      Drive(
        path: path,
        name: name,
        total: space.total,
        free: space.free,
        main: main,
      ),
    );
  }
  return drives;
}

/// The main drive: the one the system runs from, else the biggest.
Drive? mainDrive(List<Drive> drives) {
  if (drives.isEmpty) return null;
  for (final d in drives) {
    if (d.main) return d;
  }
  return drives.reduce((a, b) => b.total > a.total ? b : a);
}

/// `/` plus everything in /Volumes. macOS lists the startup disk there too,
/// as a link to `/`, which gives it its name.
List<(String, String, bool)> _macDrives() {
  var mainName = 'Macintosh HD';
  final others = <(String, String, bool)>[];
  try {
    for (final e in Directory('/Volumes').listSync(followLinks: false)) {
      final name = e.path.substring('/Volumes/'.length);
      if (name.startsWith('.') || name.startsWith('com.apple.')) continue;
      if (e is Link) {
        if (e.targetSync() == '/') mainName = name;
      } else if (e is Directory) {
        others.add((e.path, name, false));
      }
    }
  } on FileSystemException {
    // No /Volumes to read: only the startup disk.
  }
  return [('/', mainName, true), ...others];
}

List<(String, String, bool)> _windowsDrives() {
  final system = (Platform.environment['SystemDrive'] ?? 'C:').toUpperCase();
  final drives = <(String, String, bool)>[];
  for (var c = 'C'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
    final letter = '${String.fromCharCode(c)}:';
    final path = '$letter\\';
    if (!Directory(path).existsSync()) continue;
    drives.add((path, letter, letter == system));
  }
  drives.sort((a, b) => (b.$3 ? 1 : 0) - (a.$3 ? 1 : 0));
  return drives;
}

List<(String, String, bool)> _linuxDrives() {
  final drives = <(String, String, bool)>[('/', 'Computer', true)];
  final user = Platform.environment['USER'];
  for (final parent in ['/mnt', if (user != null) '/media/$user']) {
    try {
      for (final e in Directory(parent).listSync(followLinks: false)) {
        if (e is Directory) {
          drives.add((e.path, e.path.split('/').last, false));
        }
      }
    } on FileSystemException {
      // Not there.
    }
  }
  return drives;
}
