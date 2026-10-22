import 'dart:io';

import 'package:flutter/services.dart';

import 'src/rust/api/spaceman.dart' as core;

/// Name of the system file manager, for menu labels.
String get fileManagerName {
  if (Platform.isMacOS) return 'Finder';
  if (Platform.isWindows) return 'Explorer';
  return 'file manager';
}

bool get canReveal =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Shows [path] in the system file manager, selected where supported.
Future<void> reveal(String path) async {
  if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  } else if (Platform.isWindows) {
    await Process.run('explorer', ['/select,', path]);
  } else if (Platform.isLinux) {
    final target = FileSystemEntity.isDirectorySync(path)
        ? path
        : File(path).parent.path;
    await Process.run('xdg-open', [target]);
  }
}

/// Whether removed items go to a trash the user can restore from.
bool get hasTrash => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Whether the system lets SpaceMan pick any folder by path. Android's
/// picker hands out content URIs instead, so there the app scans all of
/// shared storage and the explorer does the navigating.
bool get canPickFolder => !Platform.isAndroid && !Platform.isIOS;

const _storage = MethodChannel('spaceman/storage');

/// Whether SpaceMan may read the whole disk: Full Disk Access on macOS,
/// "All files access" on Android, always elsewhere.
Future<bool> hasDiskAccess() async {
  if (Platform.isAndroid) {
    return await _storage.invokeMethod<bool>('hasAccess') ?? false;
  }
  return core.hasFullDiskAccess();
}

/// Asks Android for "All files access". On Android 11+ this opens Settings;
/// the app checks again when it comes back to the foreground.
Future<void> requestAndroidStorageAccess() =>
    _storage.invokeMethod<void>('requestAccess');

/// Root of Android's shared storage, usually /storage/emulated/0.
Future<String?> androidStorageRoot() =>
    _storage.invokeMethod<String>('storageRoot');

/// Space used by one installed Android app.
class AppSize {
  AppSize.fromMap(Map<Object?, Object?> m)
    : package = m['package']! as String,
      label = m['label']! as String,
      app = m['app']! as int,
      data = m['data']! as int,
      cache = m['cache']! as int,
      system = m['system']! as bool;

  final String package;
  final String label;

  /// The app itself (APKs, compiled code).
  final int app;

  /// Everything the app stores, including [cache].
  final int data;
  final int cache;

  /// Came with the phone and was never updated.
  final bool system;

  int get total => app + data;
}

/// Installed apps and the totals of internal storage.
typedef AppSizes = ({List<AppSize> apps, int total, int free});

/// Whether Android lets SpaceMan read the size of other apps.
Future<bool> hasUsageAccess() async =>
    await _storage.invokeMethod<bool>('hasUsageAccess') ?? false;

/// Opens the "Usage access" setting; check again when the app resumes.
Future<void> requestUsageAccess() =>
    _storage.invokeMethod<void>('requestUsageAccess');

Future<AppSizes> appSizes() async {
  final m = (await _storage.invokeMapMethod<String, Object?>('appSizes'))!;
  return (
    apps: [
      for (final a in m['apps']! as List<Object?>)
        AppSize.fromMap(a! as Map<Object?, Object?>),
    ],
    total: m['total'] as int? ?? 0,
    free: m['free'] as int? ?? 0,
  );
}

/// The system's App info page, where the user can clear cache and storage.
Future<void> openAppInfo(String package) =>
    _storage.invokeMethod<void>('openAppInfo', {'package': package});

/// Asks the system to uninstall [package]; Android confirms with the user.
Future<void> uninstallApp(String package) =>
    _storage.invokeMethod<void>('uninstall', {'package': package});

/// Opens the Full Disk Access pane of System Settings (macOS only).
Future<void> openFullDiskAccessSettings() async {
  await Process.run('open', [
    'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles',
  ]);
}

/// Quits and starts the app again, e.g. so macOS applies a new permission.
Future<void> relaunchApp() async {
  if (Platform.isMacOS) {
    // .../SpaceMan.app/Contents/MacOS/SpaceMan -> .../SpaceMan.app
    final bundle = File(Platform.resolvedExecutable).parent.parent.parent.path;
    // Wait for this process to exit before opening the app again,
    // otherwise `open` just focuses the running instance.
    await Process.start('/bin/sh', [
      '-c',
      'while kill -0 $pid 2>/dev/null; do sleep 0.1; done; open "\$0"',
      bundle,
    ], mode: ProcessStartMode.detached);
  } else {
    await Process.start(
      Platform.resolvedExecutable,
      [],
      mode: ProcessStartMode.detached,
    );
  }
  exit(0);
}
